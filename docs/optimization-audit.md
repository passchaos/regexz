# Optimization audit — 2026-11-19

Source baseline: `a2d8a85`. Reviewed the compilation and execution pipeline,
workspace ownership, search prefilters, capture replay, replacement output,
and benchmark coverage.

## Replacement output allocation

The output-owning replacement APIs used an empty `ArrayList` and grew it
incrementally. Repeated replacements in long input therefore incurred output
reallocations and copies in addition to matching and expansion work.

On the first successful match, reserve at least
`input.len - (match.end - match.start)` bytes. This estimates the unchanged
input remaining after that replacement. Use the list's normal growth policy
to retain headroom for small expansions. Subsequent expansion still grows the
buffer as necessary. A whole-input replacement starts with zero reserved
bytes; a no-match result follows its original path. The length
and caller-buffer APIs do not reserve output storage.

This is a capacity estimate: many shrinking matches can leave spare capacity
until the result is converted to an owned slice. It avoids a second search
pass, which would repeat matching work and callout side effects.

Use the scoped benchmark to measure both allocators and inspect output
allocation counts:

```sh
zig build bench-replace -Doptimize=ReleaseFast
```

It warms the engine, takes the median of five batches of 200 replacements,
then separately counts allocations and cumulative requested bytes in one
replacement. Callback counts include the callback-owned replacement strings.
Cases cover shrinking, growing, captures, no match, zero-width matches,
limited replacement, callbacks, and whole-input deletion.

## Measurements

Same shared macOS ARM64 host, 32,000-byte input. Run the compiled before and
after executables in `before/after`, `after/before`, `before/after` order.
Times below are medians of those three executions; each execution reports
its own median of five batches. Allocation counts and requested-byte totals
were identical in all three runs. Raw samples are in
[`benchmarks/replacement-allocation.json`](benchmarks/replacement-allocation.json).

| Case | Page time, us (before -> after) | SMP time, us (before -> after) | Page allocations | SMP allocations | SMP cumulative requested bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| shrink | 54.96 -> 54.02 | 51.82 -> 53.55 | 3 -> 1 | 10 -> 2 | 107,134 -> 72,123 |
| grow | 69.44 -> 54.95 | 66.12 -> 58.30 | 5 -> 2 | 11 -> 2 | 222,115 -> 120,446 |
| captures | 473.48 -> 423.78 | 413.81 -> 404.35 | 4 -> 1 | 10 -> 1 | 132,255 -> 48,123 |
| no match | 3.90 -> 3.64 | 4.92 -> 4.46 | 1 -> 1 | 2 -> 2 | 80,128 -> 80,128 |
| zero width | 540.06 -> 545.34 | 572.76 -> 530.12 | 2 -> 1 | 3 -> 2 | 80,260 -> 80,130 |
| limited | 5.00 -> 3.02 | 4.12 -> 3.57 | 2 -> 1 | 3 -> 2 | 80,252 -> 80,121 |
| callback | 7016.00 -> 6844.79 | 67.67 -> 67.18 | 4003 -> 4001 | 4010 -> 4002 | 111,134 -> 76,123 |
| delete whole input | 9.20 -> 9.12 | 9.51 -> 9.16 | 0 -> 0 | 0 -> 0 | 0 -> 0 |

The most repeatable benefit is less allocator work: SMP capture replacement
uses one allocation instead of ten, with 64% fewer cumulative requested
bytes. Growing and limited replacements also improved in these samples.
Shrinking SMP throughput was 3% slower, while the unchanged no-match path
varied by 7-10%; small timing differences need a quieter host to attribute
confidently. This change does not establish a universal throughput win.

Validation:

```sh
zig build test-lib -Dtest-filter=replacement -Dtest-filter=replacen -Dtest-filter='notempty affects replacement' -Dtest-filter='full Unicode case mapping' -Dtest-filter='substitution supports' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
zig fmt --check build.zig tools/bench/replace.zig src/regex/replace.zig src/regex/replace_tests.zig
```

All 26 scoped tests and 1,900 V8 comparisons passed. The replacement fuzzer
now compiles and executes in separate steps so compiler/wrapper diagnostics
cannot contaminate the comparison protocol.

## Next candidates

The compile-time comparison now uses heap-backed runtime subjects and input
barriers; generated code was inspected to confirm input loads and comparisons.
`bench-startup` separates compilation, workspace construction, cold matching
and warmed matching. See [benchmark calibration](benchmarks/calibration.md).

| Priority | Owning code | Evidence and next measurement |
| --- | --- | --- |
| 1 | `execute.zig`, `search_dfa.zig`, `tools/bench/startup.zig` | Startup measurements now separate construction from matching. [Unicode initialization](benchmarks/unicode-init.md) is down from about 48 us to 13 us; [shared byte-table construction](benchmarks/byte-table.md) reduces ASCII class setup from about 151 ns to 62 ns, and [range masks](benchmarks/range-mask.md) reduce class compile-plus-first-match cost by about 20%. [ASCII DFA setup](benchmarks/dfa-init.md) omits a 64 KiB unused cache. [Adaptive Unicode full-match caching](benchmarks/rune-cache.md) cuts small-input DFA construction by 8.90x and keeps 4 KiB instead of 64 KiB. [Deferred search caches](benchmarks/search-cache.md) eliminate 96 KiB of per-workspace Unicode storage on ASCII subjects and improve complete first searches 4.83–6.91x. [Literal workspaces](benchmarks/literal-workspace.md) now require no allocation and initialize 1.78x faster. [Shared graph walks](benchmarks/search-graph.md) cut optional-chain construction allocations from 34 to 12 and Qwen DFA setup from 36 to 12. [Deferred dominant-branch tables](benchmarks/deferred-run.md) now cut Qwen first-token setup from about 0.88 ms to 0.48 us and its complete ASCII cold pass by 19.96x; repeated Unicode prepares the original tables on demand. [Deferred full-match tables](benchmarks/deferred-workspace.md) now reduce Unicode letters first matches by about 1,003–1,030x and Han first matches by 164x, with one scratch allocation at construction. [Deferred ordinary search tables](benchmarks/deferred-search.md) now cut Unicode letters first searches by about 358–365x, complete ASCII cold passes by 19.39x, and long ASCII absence scanning by 23.17x. Prepared-state dispatch retains the byte scanner. [Shared range identity](benchmarks/set-identity.md) now avoids repeated comparisons of immutable range arrays, improving wide Unicode full-match initialization 4.70–5.18x and search initialization 2.62–2.93x with allocation counts unchanged. [Borrowed full-match DFA scratch](benchmarks/dfa-scratch.md) now removes one allocation and eight requested bytes per instruction from lazy DFA construction, reusing NFA buffers with visit invalidation on engine switches. Timing samples do not establish a latency gain. [Combined capture storage](benchmarks/capture-storage.md) now retains independent active and longest-match backup views in one allocation, reducing every measured search workspace initialization from two allocations to one with requested bytes unchanged. Construction-latency gains are not established. Persisted small DFAs and remaining construction scratch remain candidates for fresh measurements. |
| 2 | `prefilter.zig`: `PairSet.indexOfAny` | The [NEON nibble prefilter](benchmarks/nibble-prefilter.md) now scans dense first-byte sets in 16-position blocks: wide-set misses improved 4.34x and complete Regex searches improved 2.00x. Exact pair and literal verification preserve earliest-match ordering. Additional target-specific paths and bucket assignment need new measurements. |
| 3 | `capture_run.zig`, `utf8_run_search.zig` | Fixed ASCII and [Unicode capture runs](benchmarks/unicode-capture.md) scan directly without additional first-find allocation. [Rejected-candidate decode reuse](benchmarks/capture-decode.md) removes duplicate decoding. [Deferred UTF-8 lead filters](benchmarks/utf8-prefix.md) now reuse the first filter's existing range vectors, improving Han/Greek misses 6.25x/3.33x, sparse Han captures 2.58x and rejected-prefix first searches 1.88-2.90x. Allocation counters and workspace size stay unchanged. Ordinary range scans retain their original code. Next measure ordinary Unicode misses: `unicodeProbe` prepares full byte tables after four valid probes, including misses, while `utf8_run_search` advances failed probes by a byte. Selective lead rejection and valid-rune advancement may reduce that work; long matching-run acceleration remains a candidate. |
| 4 | `capture_replay.zig` | [Adjacent disjoint capture replay](benchmarks/adjacent-replay.md) avoids capture trails and backtracking choices. [Nullable greedy replay](benchmarks/nullable-replay.md) now extends the cached proof through nullable greedy continuations, with 1.66-1.79x complete-pass gains over ASCII, 1.22x for Unicode nullable prefixes and 1.43x for optional Unicode captures. First-find allocations fall by two or three, with workspace size unchanged. The one-time graph walk remains separate from warmed dispatch. Cold-start latency gains are not established. Bounded optional branches still require interpreter replay; measure their record cost before widening the proof. |
| 5 | `replace.zig` | Deterministic capture replay now lives in a separate module with explicit borrowed slots and execution counters. The remaining API, search dispatch, deterministic scanners and interpreter occupy roughly 1,900 lines. Extract a cohesive scanner module when changing those paths; keep budget and capture state ownership explicit. |

Further work on these candidates needs fresh measurements before implementation.
Current warmed throughput does not establish their cold-start cost or the
benefit of replacing their fallback paths.
