# Deferred search-DFA Unicode caches

Baseline: `a933a4b`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Rune-mode search DFAs previously allocated and cleared 4,096 Unicode
transition entries (96 KiB) during construction, then allocated 32 front
cache entries per state. ASCII-only searches never used either cache.

Construction now leaves the global cache empty and borrows shared zero
front rows. Non-ASCII byte keys are nonzero, so borrowed rows always miss.
The first front-cache miss allocates both caches, commits their pointers
after successful allocation, and resumes the original computation. The
initializer is a separate cold function; cache hits retain their existing
path. Subsequent states extend the owned front rows as before.

The shared rows occupy 48 KiB of zero-filled static storage per process.
They are read before initialization and never freed or written by a
workspace. Deinitialization frees front rows only when the global cache
has been committed. Allocation failure retains the borrowed rows and
follows the existing interpreter fallback. Unicode lookaheads at an ASCII
run boundary still compute against the next rune, including cached accepts
that consume no further input.

## Measurements

`bench-search_startup` measures direct DFA initialization, initialization plus
one DFA search, a complete fresh `ReplaceWorkspace.find`, and warmed direct
and API calls. Inputs are heap-backed and timing loops retain input barriers.
Each phase reports the median of five batches: 1,000 cold calls or 20,000
warmed calls. Allocation counters separately measure direct DFA initialization
and its first search, including allocations released during setup.

The same benchmark is compiled against both snapshots. Three executions were
interleaved before/after, after/before, before/after; the startup and main
benchmark programs run sequentially within each sample. Raw samples,
allocation counts and executable SHA-256 identities are in
[`search-cache.json`](search-cache.json).

| Case / mode | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| ASCII alternatives / DFA initialization | 6,835.1 | 347.5 | 19.67x |
| ASCII alternatives / fresh API search | 8,811.8 | 1,606.2 | 5.49x |
| ASCII lookahead / fresh API search | 7,357.2 | 1,064.4 | 6.91x |
| Unicode pattern, ASCII subject / fresh API search | 8,505.0 | 1,762.6 | 4.83x |
| Unicode boundary / fresh API search | 8,302.8 | 7,755.0 | 1.07x |
| Unicode lookahead / fresh API search | 9,139.4 | 8,522.2 | 1.07x |
| ASCII alternatives / warmed API | 14.5 | 14.5 | 1.00x |
| ASCII lookahead / warmed API | 9.7 | 10.5 | 0.92x |
| Unicode lookahead / warmed API | 27.0 | 22.8 | 1.18x |
| literal control / warmed API | 8.9 | 9.6 | 0.93x |
| Qwen tokenizer / warmed pass | 52,734.2 | 50,670.8 | 1.04x |
| CJK tokenizer / warmed pass | 178,040.0 | 168,625.0 | 1.06x |
| CJK without lookahead / warmed pass | 167,715.8 | 169,699.2 | 0.99x |

For ASCII alternatives, direct setup plus first search drops from 27 to
23 allocations and from 127,240 to 20,512 cumulative requested bytes.
For ASCII lookahead, it drops from 26 to 23 allocations and from 112,280
to 10,280 requested bytes. Both retain zero owned Unicode/front-cache bytes.
Actual Unicode input retains the 96 KiB global cache and its front rows.

The verified benefit is first-search cost and per-workspace cache storage
on ASCII subjects. Small warmed controls differ by up to 0.8 ns. An unchanged
Qwen compilation control also varied by about 6% on the shared host, so these
samples do not establish a universal warmed-throughput gain. An earlier
initializer was inlined into the scan and regressed short calls and Qwen
throughput; borrowed front rows keep the initialization check inside the
front-cache miss branch in the final version.

## Validation and reproduction

```sh
zig build test-lib -Dtest-filter='search DFA' -Dtest-filter='search cache' -Dtest-filter='set lookahead' -Dtest-filter='lazy loops' -Dtest-filter='prefix loops' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-search_startup -Doptimize=ReleaseFast
python3 tools/bench/interleave.py --baseline a933a4b --rounds 3 --suite startup BEFORE_STARTUP AFTER_STARTUP --suite main BEFORE_MAIN AFTER_MAIN --output samples.json
```

All 14 scoped tests, 8,100 V8 comparisons, the 56-case performance gate and
formatting checks passed. Tests compare lookahead bounds with the interpreter
at every byte offset, cover malformed and truncated UTF-8, exercise tokenizer
state growth after ASCII searches, verify independence of workspaces borrowing
the same zero rows, and inject allocation failures while checking complete
cleanup and fallback. The interleaving tool was also checked with one identical
executable on both sides: 45 parsed cases, raw samples and matching hashes.
