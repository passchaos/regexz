# Adaptive Unicode full-match DFA cache

Baseline: `6c5ced2`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Unicode-capable full-match DFAs previously allocated and cleared 4,096
transition entries (64 KiB) even for a few repeated runes. DFAs constructed
after short-input warmup now start with 256 entries (4 KiB). After 64 occupied
slot collisions, the cache attempts promotion to the original 4,096 entries
and rehashes surviving entries. Failed promotion retains the usable small
cache; exact keys prevent false hits at either capacity. Initial allocation
failure still follows the existing NFA fallback.

Inputs of at least 4,096 bytes already trigger the DFA on their first call.
Those constructions start with the original full cache, avoiding an extra
allocation on long, varied subjects. ASCII-only DFAs continue omitting Unicode
storage. The collision counter occupies one byte of existing tail padding.
ASCII and Unicode scan loops use fixed row shifts; cache writes remain inline
while allocation and rehashing live in a separate cold function.

## Measurements

`bench-startup` separates compilation plus first match, workspace initialization,
first match, three matches that construct a fresh DFA, and warmed matching.
Both source snapshots use the same updated benchmark. Each executable reports
the median of five batches. Short cases retain 2,000 iterations per cold batch
and 100,000 per warm batch. Long cases scale the iterations with input length.

Six executions were interleaved before/after and after/before. Three additional
rounds investigated variance in short warm calls; all six final-version rounds
are retained in [`rune-cache.json`](rune-cache.json). The table reports medians
across executions. Allocation statistics were identical in every round and mode.

| Case / mode | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| mixed Unicode / dfa_cold | 4,925.1 | 553.5 | 8.90x |
| mixed Unicode / warm | 12.1 | 12.3 | 0.98x |
| Unicode pattern, ASCII input / dfa_cold | 5,156.0 | 886.6 | 5.82x |
| Unicode pattern, ASCII input / warm | 7.1 | 7.2 | 0.99x |
| ASCII alternation / warm | 6.1 | 5.8 | 1.04x |
| xDS path / warm | 8.3 | 8.4 | 0.99x |
| 4,096 distinct Han runes / cold | 79,679.7 | 82,533.9 | 0.97x |
| 4,096 distinct Han runes / dfa_cold | 107,770.8 | 113,124.9 | 0.95x |
| 4,096 distinct Han runes / warm | 15,738.0 | 14,648.6 | 1.07x |
| Unicode slot collisions / dfa_cold | 85,070.3 | 85,210.9 | 1.00x |
| Unicode slot collisions / warm | 19,073.5 | 19,766.0 | 0.96x |
| fragmented ASCII class / warm | 2.9 | 3.5 | 0.83x |

Mixed Unicode keeps seven DFA allocations, but cumulative requests drop from
68,582 to 7,142 bytes and retained Unicode cache storage drops from 65,536 to
4,096 bytes (94%). Long varied inputs keep seven allocations and the original
68,582 requested bytes. The shorter collision subject promotes its small
cache, adding one allocation and 4,096 cumulative requested bytes; retained
cache storage remains 64 KiB.

The verified gain is small-input DFA construction and storage. Long-input
timings varied by 3–7%; the unchanged fragmented-class path differed by 0.6 ns.
The ASCII-input warm control initially ranged from 7.3 to 10.9 ns after the
change, then from 6.8 to 7.0 ns in the additional rounds. These shared-host
samples do not establish a universal throughput gain. The first prototype
increased register pressure in the general scan; fixed row strides and the
separate promotion function are included in the final samples above.

## Validation

```sh
zig build test-lib -Dtest-filter=DFA -Dtest-filter='rune cache' -Dtest-filter=borrowed -Dtest-filter='expired and interrupted' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/execute.zig src/regex/rune_cache.zig src/regex/rune_cache_tests.zig src/root.zig tools/bench/startup.zig
zig build bench-startup -Doptimize=ReleaseFast
```

All 25 scoped tests, 7,800 V8 comparisons, the 56-case performance gate and
formatting checks passed. Tests cover promotion, surviving entries, cached
dead transitions, optional allocation failure, cleanup at every allocation
failure, malformed/truncated UTF-8, and randomized Unicode DFA/NFA comparisons.
The V8 driver now also compares each linear program's cold full match with
three reused-workspace calls, exercising short-input lazy DFA construction.
