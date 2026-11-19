# Deferred UTF-8 tables for ordinary set-run searches

Baseline: `e7d3300`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Ordinary non-ASCII `set+` searches previously built an expanded UTF-8 table
during `ReplaceWorkspace.init`. For `\p{L}+`, even the first search of an
ASCII token made 23 initialization allocations and requested 1,543,620 bytes.

Search workspaces now use `deferred_utf8_run.CompactRun` and their existing
ASCII byte table. ASCII runs scan directly in the entry path, avoiding table
construction and an additional scanner call for every token. Short Unicode
probes use exact scalar membership until four valid probes, including misses,
request the expanded table. A matching Unicode run with at least 64 input
bytes remaining requests it immediately. Failed optional preparation disables
further requests and retains scalar matching.

`utf8_run_search.zig` owns the cold and prepared scanners. `replace.zig` shares
the resulting bounds between ordinary `find` and replacement iteration and
continues to own capture slots and the other execution engines. Prepared
Unicode search retains the byte automaton and first-byte prefilter.
The dispatch switches to prepared mode once its table becomes available,
including during a search that returns no match, so warmed calls enter the
prepared scanner directly.
The cold scanner returns preparation readiness with its optional bounds,
including when no match is found. Pure ASCII bounds report no preparation
without reading the table flag, so the caller avoids a cache check on that
return path.
The deferred entry asserts that no table is present and uses one first-byte
filter before its ASCII scan. Prepared calls use their separate dispatch
state, so the deferred entry does not repeat their cache checks.

Pure Unicode first-byte filters now skip ASCII spans in 32-byte blocks,
using the maximum of two 16-byte vectors to detect any byte at or above
`0x80`. A block hit is checked from its beginning to retain the earliest
candidate. The initial byte still returns immediately when it is non-ASCII,
so ordinary Unicode token starts do not pay for a vector scan. After an ASCII
byte, a scalar probe checks up to 16 bytes before entering the block scanner,
preserving cheap newline and other short gaps in Unicode text. The block
scanner stays in a separate function. A scalar tail handles incomplete
blocks. Contract tests cover all 16 byte alignments,
multiple candidates, vector boundaries, tails and every requested offset.

The scoped tests also exposed an existing recovery error in the prepared
scanner: after a partial UTF-8 prefix failed, it skipped the current byte even
when that byte could begin a new rune. For example, searching `\p{L}+` in
`\xe7A` missed the `A`. The prepared scanner now retries that byte from the
start state. Continuation bytes cannot begin a valid rune and advance
immediately. Cold and prepared searches agree with the interpreter at every
tested byte offset, including starts within codepoints.

## Measurement method

The fixed baseline is a `git archive` of `e7d3300`, with the updated
`tools/bench/branch_startup.zig` benchmark copied into it. Both executables use
the same benchmark logic and heap-backed runtime subjects. Existing Qwen
tokenizer controls remain, and new ordinary set-run cases cover ASCII tokens,
Unicode tokens, full ASCII/mixed/Han passes, ASCII misses and Unicode misses.
Both short and long ASCII misses are included to qualify the new filter.

Each phase reports the median of five batches. Three executions alternate
before/after, after/before, before/after. Raw samples, counters and executable
SHA-256 identities are in [`deferred-search.json`](deferred-search.json).
The phases separate initialization, initialization plus first search, complete
cold passes, warmed first searches and warmed complete passes. Long subjects
with no match use 80 warmed first searches per batch; other warmed first
searches retain 20,000 iterations. This bounds repeated full-subject scans
without changing the successful first-token controls.

Counters use a fresh workspace: `init_allocations` and `init_bytes` describe
initialization; `first_allocations` and `first_bytes` describe additional
requests during that phase's workload. Even in a warmed timing phase, these
counters describe a fresh workload, rather than the separately warmed timing
workspace. Requested bytes are cumulative allocator requests, not resident
memory.

## Measurements

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| Unicode letters, ASCII token / initialization | 349,554.2 | 990.4 | 352.94x |
| Unicode letters, ASCII token / first search | 343,773.3 | 960.8 | 357.80x |
| Unicode letters, Unicode token / first search | 345,224.6 | 945.8 | 365.01x |
| Unicode letters, ASCII text / cold pass | 343,675.0 | 17,720.9 | 19.39x |
| Unicode letters, mixed text / cold pass | 352,914.6 | 373,168.8 | 0.95x |
| Han text / cold pass | 140,406.3 | 129,747.9 | 1.08x |
| Han, long ASCII miss / first search | 16,887.5 | 502.9 | 33.58x |
| Han, long ASCII miss / warmed search | 4,126.1 | 178.1 | 23.17x |
| Unicode letters, ASCII token / warmed search | 5.4 | 7.0 | 0.77x |
| Unicode letters, Unicode token / warmed search | 5.6 | 6.9 | 0.81x |
| Unicode letters, ASCII text / warmed pass | 16,302.6 | 16,833.9 | 0.97x |
| Unicode letters, mixed text / warmed pass | 18,368.2 | 18,807.3 | 0.98x |
| Han text / warmed pass | 125,220.3 | 113,406.8 | 1.10x |
| Han, short ASCII miss / warmed search | 6.2 | 6.3 | 0.98x |
| Greek, CJK miss / warmed pass | 312,966.7 | 309,924.0 | 1.01x |

Unicode letters initialization drops from 23 allocations and 1,543,620
cumulative requested bytes to two allocations and 32 bytes. Short ASCII and
Unicode first searches allocate nothing further. A complete ASCII letters
pass also retains those two allocations. Han initialization drops from 17
allocations and 156,284 bytes to two allocations and 32 bytes; Greek
initialization drops from 13 allocations and 70,764 bytes to the same two
allocations and 32 bytes.

Complete mixed letters scanning eventually makes 21 optional table allocations
and requests 1,543,588 additional bytes. Han text prepares its table on the
first search with 15 optional allocations and 156,252 additional bytes; Greek
CJK misses prepare theirs with 11 optional allocations and 70,732 additional
bytes. These totals equal the previous eager totals. Long or repeated Unicode
still pays for its expanded table.

The measured gains are first-search latency, complete ASCII cold scanning,
and long ASCII absence scanning. ASCII and mixed letters warmed passes were
3.3% and 2.4% slower; unchanged Qwen warmed controls varied by up to 7.9% on
the shared host. Short warmed ASCII and Unicode first searches were 1.6 ns
and 1.3 ns slower; their tiny complete-pass measurements were 0.7 ns and
0.4 ns slower. The complete mixed cold pass was 5.7% slower and does not
establish a cold Unicode throughput benefit. Workspace value size increases
from 6,544 to 6,592 bytes (48 bytes), without duplicating its ASCII table.
These samples do not establish a general warmed-throughput gain.

## Validation

```sh
zig build test-lib -Dtest-filter='deferred search' -Dtest-filter=FirstFilter --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/utf8_run_search.zig src/regex/deferred_search_tests.zig src/regex/prefilter.zig src/regex/prefilter_tests.zig src/root.zig tools/bench/branch_startup.zig
```

Scoped tests cover ASCII allocation avoidance, interpreter bounds and slots
at every byte offset, Unicode cache preparation during a search, valid misses,
malformed/truncated UTF-8, surrogates and out-of-range codepoints, every optional
allocation failure and cleanup, and reuse through replacement and iterators.

The final candidate passed 12 integrated scoped tests, 8,808 V8 comparisons
and the 56-case performance gate; formatting checks passed. Three complete alternating benchmark rounds
covered 65 phases in each executable.
