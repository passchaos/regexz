# Range-mask materialization

Baseline: `09e7e05`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

`classes.fromRanges` previously set one ASCII bitmap bit at a time. It now
builds masks for each interval, handling intervals crossing the 64-bit word
boundary explicitly. Singleton intervals retain a direct bit-set path.
The range slice, non-ASCII flag and membership semantics remain unchanged.

## Measurements

The startup executable reports medians of five batches. Three executions were
interleaved before/after, after/before, before/after. The table measures the
complete compile-plus-first-match operation. Raw samples are in
[`range-mask.json`](range-mask.json).

| Pattern | Before, ns/iter | After, ns/iter | Change |
| --- | ---: | ---: | ---: |
| literal | 1287.2 | 1307.3 | +1.6% |
| ASCII class | 846.5 | 676.2 | -20.1% |
| fragmented class | 872.4 | 862.1 | -1.2% |
| ASCII loop | 1242.9 | 1118.0 | -10.0% |
| alternation | 1029.9 | 1000.9 | -2.8% |
| xDS path | 2369.3 | 2164.9 | -8.6% |
| Unicode run | 14209.5 | 13669.7 | -3.8% |

ASCII class compilation benefits from replacing per-rune bitmap construction;
singleton-heavy and fragmented controls show smaller changes. Treat small
shared-host timing differences as noise-sensitive.

## Validation

```sh
zig build test-lib -Dtest-filter='range masks' -Dtest-filter='byte tables' -Dtest-filter='case folding is materialized' -Dtest-filter='character class set operations' -Dtest-filter='ASCII option letters' -Dtest-filter='Unicode 17 case folding' --summary all
zig build test-lib -Dtest-filter=serialization -Dtest-filter='case folding' -Dtest-filter='POSIX classes' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
```

The eleven materialization/character-class tests, nine serialization/folding
checks, 6,900 V8 comparisons and 56-case performance gate passed. Tests compare
all ASCII intervals against the scalar constructor, including 63/64 and
127/128 crossings, Unicode ranges, singleton intervals and multiple ranges.
