# Wide literal nibble prefilter

Baseline: `59d656d`, macOS ARM64 with NEON, Zig 0.16.0 ReleaseFast.

`PairSet` previously probed its exact two-byte bitmap at every byte when
the literal set had too many distinct first bytes for the sparse filter.
For 9–32 literals, it now tests 16 positions using four 16-byte nibble
lookup tables and eight bucket bits. Table intersections are conservative:
each candidate still passes the exact pair bitmap and complete literal
comparison, in increasing position order. The filter needs no allocation.

The lookup uses NEON `tbl`; targets without AArch64 NEON retain the existing
scan. Sparse first-byte sets also retain their existing path. When all
16 lanes are candidates, the rest of that search uses scalar verification
to avoid repeated vector overhead on dense collisions. Inputs shorter than
a vector block take the scalar tail.

## Measurements

The before snapshot uses the same benchmark inputs as the changed source.
Each executable reports the median of five batches of 2,000 searches. Three
executions were interleaved before/after, after/before, before/after, with
the microfilter and complete Regex search programs run sequentially.
The table reports medians across those executions. Raw samples and executable
paths are in [`nibble-prefilter.json`](nibble-prefilter.json).

| Case | Before, ns/search | After, ns/search | Speedup |
| --- | ---: | ---: | ---: |
| wide pairs absent | 10,433.2 | 2,402.2 | 4.34x |
| wide pairs collisions | 11,230.5 | 5,346.4 | 2.10x |
| wide pairs late literal | 11,301.4 | 5,338.5 | 2.12x |
| complete Regex wide alternatives | 11,653.7 | 5,814.8 | 2.00x |
| wide dense control | 51,244.7 | 52,885.6 | 0.97x |
| wide short control | 8.9 | 9.5 | 0.94x |
| complete Regex shared-prefix collisions | 28,349.1 | 28,248.2 | 1.00x |
| case-folded control | 1,993.6 | 2,006.1 | 0.99x |
| capture run control | 8.3 | 8.3 | 1.00x |

The benefit is for wide literal sets on long input. The dense control was
3% slower and the short control differed by 0.6 ns; unchanged controls
also varied by up to 7% on this shared host. These samples do not establish
a universal throughput gain. The first implementation regressed the dense
control by about 10%; the scalar fallback above is included in the final
measurements.

## Validation

```sh
zig build test-lib -Dtest-filter=nibble -Dtest-filter=PairSet -Dtest-filter='wide alternation' -Dtest-filter=MultiFilter --summary all
zig test -OReleaseFast -target x86_64-linux -Mroot=src/root.zig --test-filter nibble --test-no-exec
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-prefilter -Doptimize=ReleaseFast
```

All eight scoped tests, 7,200 V8 comparisons, the 56-case performance gate,
and formatting checks passed. The x86_64 tests cross-compiled successfully;
they were not executed on this ARM64 host. Tests compare every input offset
against exact literal search, cover every vector lane and block boundaries,
and include random bytes, dense candidates, malformed bytes and UTF-8 literals.
