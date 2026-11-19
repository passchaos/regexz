# Byte-table construction from membership runs

Baseline: `03be7f4`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Full-match, search, capture-run, chain, and streaming workspaces previously
filled their byte tables by probing every character separately. The shared
`byte_table` helper now expands each ASCII bitmap's contiguous one-bit runs
with range fills. The high half of a 256-entry table uses positive codepoint
ranges only when the set allows non-ASCII runes. The ASCII bitmap remains
authoritative even for directly constructed sets.

Table shapes, workspace allocation counts and hot matching loops are unchanged.
The same helper builds 128- and 256-entry tables without heap allocation.

## Measurements

Each executable reports medians of five batches. Three executions were
interleaved before/after, after/before, before/after. Raw samples are in
[`byte-table.json`](byte-table.json).

| Case / mode | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| ASCII class / init | 151.1 | 62.3 | 2.43x |
| fragmented class / init | 153.3 | 78.6 | 1.95x |
| ASCII loop / init | 597.7 | 392.2 | 1.52x |
| ASCII class / cold | 156.2 | 65.9 | 2.37x |
| ASCII class / warm | 4.4 | 4.5 | 0.98x |
| fragmented class / warm | 3.3 | 3.3 | 1.00x |
| ASCII loop / warm | 4.0 | 4.1 | 0.98x |
| xDS path / warm | 8.6 | 8.8 | 0.98x |
| Unicode run / warm | 5.0 | 5.0 | 1.00x |

The main 56-case regression gate passed. Small differences in warmed matching
remain host-sensitive; initialization is the target of this change.

## Validation

```sh
zig build test-lib -Dtest-filter='byte tables' -Dtest-filter='simple-run fast path' -Dtest-filter='chain fast path' -Dtest-filter='star fast path' -Dtest-filter='capture run' -Dtest-filter=borrowed -Dtest-filter='regex replacement' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-startup -Doptimize=ReleaseFast
```

All 27 scoped tests and 6,900 V8 comparisons passed. Tests compare every table
entry against scalar membership for zero/all-one/checkerboard bitmaps, each
single bit, random bitmaps and Latin-1/Unicode boundaries. Matching, capture,
replacement and streaming chunk boundaries remain covered.
