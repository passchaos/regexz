# Deferred UTF-8 tables for full-match workspaces

Baseline: `bf7ef1a`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Ordinary Unicode `set+` and `(?:set+ separator)+` full-match workspaces
previously constructed an expanded UTF-8 table during initialization.
`\p{L}+` therefore made 22 initialization allocations even when its subject
was entirely ASCII.

`deferred_utf8_run.CompactRun` retains the immutable program set and optional
UTF-8 storage. Full matching scans the workspace's existing ASCII byte table
before probing Unicode. Valid Unicode probes, including misses, request the
expanded table after four probes. A matching Unicode run with at least 64
input bytes remaining requests it immediately. Cached runs and separator
loops use the original table scan. A failed optional allocation disables
further preparation and retains exact scalar matching. Malformed UTF-8 does
not count toward preparation. Workspace initialization also recognizes the
`set+` shape once, avoiding a duplicate comparison of long range arrays.

Strict-budget and partial matching continue through the NFA and do not prepare
these optional tables. The program owns the borrowed set ranges; the workspace
owns and releases any prepared UTF-8 table.

## Measurement method

The fixed baseline is a `git archive` of `bf7ef1a`, with the same updated
`tools/bench/startup.zig` benchmark logic copied into it. Both executables are compiled with
ReleaseFast. Each phase reports the median of five batches; three executions
alternate before/after, after/before, before/after. Runtime input barriers are
retained. Raw timings, counters and executable SHA-256 identities are in
[`deferred-workspace.json`](deferred-workspace.json).

`init_allocations` and `init_bytes` count initialization requests.
`first_allocations` and `first_requested_bytes` count additional requests in
the first call. `post_init_allocations` and `post_init_requested_bytes` count
additional requests across three calls, including either DFA or UTF-8 storage.
These replace the previous `dfa_*` labels, which would incorrectly describe
deferred UTF-8 table requests as DFA allocations. Requested bytes are
cumulative allocator requests, rather than peak resident memory.

The legacy `dfa_cold` phase constructs a workspace and makes three calls.
For a two-line Unicode loop, the second call reaches the fourth Unicode probe
and prepares the table. That phase therefore includes the one-time table
construction; the first-call saving does not remove eventual preparation.
Warmed timings use a separate workspace with sufficient warmup calls.

## Measurements

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| Unicode letters, ASCII input / initialization | 343,033.5 | 331.9 | 1,033.54x |
| Unicode letters, ASCII input / first match | 343,689.5 | 333.7 | 1,029.94x |
| Unicode letters, mixed input / first match | 358,950.2 | 357.9 | 1,002.93x |
| Han run / initialization | 13,180.4 | 57.7 | 228.43x |
| Han run / first match | 13,199.4 | 80.5 | 163.97x |
| Greek run / first match | 6,514.5 | 101.3 | 64.31x |
| Han line loop / initialization | 13,029.1 | 65.4 | 199.22x |
| Han line loop / first match | 12,969.5 | 97.8 | 132.61x |
| Han line loop / three cold calls | 13,136.3 | 13,498.4 | 0.97x |
| Unicode letters, ASCII input / warmed match | 5.9 | 6.1 | 0.97x |
| Unicode letters, mixed input / warmed match | 3.5 | 3.9 | 0.90x |
| Han run / warmed match | 5.2 | 5.3 | 0.98x |
| Greek run / warmed match | 5.9 | 6.3 | 0.94x |
| Han line loop / warmed match | 5.8 | 5.9 | 0.98x |

Initialization drops from 22 allocations and 1,543,896 requested bytes to
one allocation and 308 bytes for `\p{L}+`. Han runs drop from 16 allocations
and 156,560 bytes to one allocation and 308 bytes; Greek runs drop from 12
allocations and 71,040 bytes to one allocation and 308 bytes. The first short
match makes no further allocation. ASCII subjects retain that allocation
count across repeated calls.

Han line-loop initialization drops from 16 allocations and 156,648 bytes to
one allocation and 396 bytes. Its first call allocates nothing further; by
the third call, 15 optional table allocations requesting 156,252 bytes have
occurred. Long and repeated Unicode still pay for the same expanded table.

The measured gain is construction and first-call latency. Short warmed
Unicode letters and Greek runs were 0.4 ns slower; other warmed target cases
were 0.1–0.2 ns slower. Unchanged controls also varied on the shared host.
These samples do not establish a warmed-throughput gain. Workspace value size
increases from 1,168 to 1,280 bytes (112 bytes), without duplicating its ASCII
table. The extra deferred state and one-time Unicode preparation are the
costs of avoiding unnecessary startup work.

## Validation

```sh
zig build test-lib -Dtest-filter='deferred workspace' -Dtest-filter='deferred run' -Dtest-filter=dominant -Dtest-filter='set lookahead' -Dtest-filter='Unicode workspace construction' --summary all
zig build test-lib -Dtest-filter='deferred workspace' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/deferred_utf8_run.zig src/regex/deferred_workspace_tests.zig src/regex/execute.zig src/root.zig tools/bench/startup.zig
```

Scoped tests compare cold and prepared matching with the NFA, exercise table
preparation within separator loops, enumerate optional allocation failures,
check cleanup and scalar fallback, and retain partial/timeout/cancellation
behavior. Inputs include ASCII, two/three/four-byte Unicode, empty runs,
missing/doubled separators, overlong encodings, surrogates, out-of-range
code points and truncated UTF-8. Differential seeds explicitly include Unicode
set runs, separator loops and a run long enough to prepare the table on its
first call.

All 17 integrated scoped tests passed. The subsequent eight-test scoped run
also passed after adding four-byte Unicode and invalid-code-point boundaries.
The V8 harness passed 8,808 comparisons across 100 patterns; the 56-case
performance gate and formatting checks passed. Three complete alternating
benchmark rounds covered 75 phases in each executable.
