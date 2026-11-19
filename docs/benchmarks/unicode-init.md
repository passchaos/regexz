# Unicode automaton initialization

Baseline: `e0e4b69`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The UTF-8 trie builder previously allocated separate range and child vectors
for every node. It now keeps nodes and linked edges in two shared arrays and
flattens them into the same compact automaton. Expanded 256-entry rows are
initialized to dead and populated directly from disjoint edge ranges, avoiding
one binary-search transition lookup per byte of every state.

The full-match workspace's six instruction buckets and five epoch arrays now
share one owned allocation. Their slice lengths remain unchanged. Constructor
error cleanup deinitializes the complete workspace, including partial UTF-8
state. The old constructor leaked its `seen` buffer when the first UTF-8 builder
allocation failed; the allocation-failure test reproduced the 140-byte leak
and now passes at every failure point.

## Startup measurements

Each executable reports medians of five batches. Three executions were
interleaved before/after, after/before, before/after. Raw samples and the real
matching benchmark cross-check are in [`unicode-init.json`](unicode-init.json).

| Case / mode | Before, ns/iter | After, ns/iter | Init allocations, before -> after |
| --- | ---: | ---: | ---: |
| literal / init | 50.5 | 46.4 | 2 -> 1 |
| ASCII class / init | 155.3 | 152.5 | 2 -> 1 |
| alternation / init | 50.6 | 45.8 | 2 -> 1 |
| xDS path / init | 52.4 | 47.1 | 2 -> 1 |
| Unicode run / compile_first | 49480.8 | 14100.5 | 187 -> 16 |
| Unicode run / init | 47888.2 | 13064.4 | 187 -> 16 |
| Unicode run / cold | 48189.7 | 13265.4 | 187 -> 16 |
| Unicode run / warm | 5.4 | 5.6 | 187 -> 16 |

Han workspace initialization improves by about 3.7x with 91% fewer allocations.
The startup harness's short xDS warm sample varied upward (8.7 to 10.2 ns), so
it was cross-checked against actual matching workloads. In that separate main
benchmark, xDS reuse measured 8.7 to 8.1 ns and the 191 KiB Han loop measured
48.82 to 48.89 us. The 56-case regression gate passed. These measurements are
host-sensitive; the constructor gain is the verified target of this change.

## Validation

```sh
zig build test-lib -Dtest-filter='utf8 automaton' -Dtest-filter='UTF8 rows' -Dtest-filter='workspace construction rolls back' -Dtest-filter='lazy DFA' -Dtest-filter=borrowed -Dtest-filter='expired and interrupted' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-startup -Doptimize=ReleaseFast
```

All 15 scoped tests and 6,900 V8 comparisons passed. Existing automaton tests
check the complete codepoint range and reject malformed UTF-8. New tests compare
every expanded transition against the compact automaton and inject allocation
failures throughout builder and Unicode workspace initialization. Scratch data
still uses 44 requested bytes per instruction; only its allocation ownership
changed.
