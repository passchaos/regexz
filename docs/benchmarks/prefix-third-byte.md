# Third-byte filtering for multi-literal prefixes

Baseline: `efb6aba`, macOS ARM64 with NEON, Zig 0.16.0 ReleaseFast.

`MultiFilter` (shared first byte) and `PairSet` (mixed first bytes) verified
every candidate lane by comparing the complete literals. On collision-heavy
input most candidates share only the first two bytes with a literal, so the
full comparison usually failed at the third byte after a call.

Both filters now keep the distinct third bytes of their literals and, when
every literal is at least three bytes, compare the 16-lane third-byte window
against those splats and AND the result into the candidate mask before lanes
are extracted. A real match must have its third byte among the literals'
third bytes, so the stage only removes lanes that could not match; blocks at
the end without a third-byte lane skip the stage, which likewise leaves more
candidates for exact verification rather than dropping any. The third-byte
splats are deduplicated at construction and the stage only runs when the
two-byte mask has a candidate. Sets containing a two-byte literal disable the
stage entirely.

Candidate verification also checks the second and third bytes before the full
literal comparison, and the sparse `PairSet` path does the same per literal.
The dense all-lane fallback in `PairSet` is unchanged.

## Measurements

Each executable reports the median of five batches: 2,000 searches for the
microfilter suite and 1,000 for the complete-search suite. Five executions
were interleaved before/after, after/before, alternating, with both suites
run sequentially. The table reports medians across those executions. Raw
samples and executable SHA-256 identities are in
[`prefix-third-byte.json`](prefix-third-byte.json).

| Case | Before, ns/search | After, ns/search | Speedup |
| --- | ---: | ---: | ---: |
| complete Regex prefix collisions | 27,970.8 | 3,982.1 | 7.02x |
| complete Regex late literal | 28,175.8 | 4,007.5 | 7.03x |
| late complete literal | 25,778.9 | 4,698.4 | 5.49x |
| three pairs collisions | 23,685.3 | 4,682.0 | 5.06x |
| dense candidates control | 134,096.8 | 3,175.8 | 42.22x |
| wide dense control | 62,798.2 | 1,562.9 | 40.18x |
| complete Regex wide alternatives | 2,641.6 | 1,953.6 | 1.35x |
| wide pairs collisions | 2,459.8 | 1,837.0 | 1.34x |
| wide pairs absent | 2,537.6 | 1,899.7 | 1.34x |
| wide pairs late literal | 2,450.0 | 1,848.9 | 1.33x |
| short literal hit | 4.8 | 3.8 | 1.26x |
| case-folded control | 2,232.1 | 2,019.2 | 1.11x |
| capture run control | 9.4 | 9.0 | 1.04x |
| sixteen pairs absent | 673.4 | 672.1 | 1.00x |
| three pairs absent | 672.9 | 699.5 | 0.96x |
| wide short control | 10.5 | 12.1 | 0.87x |

The shared host was busy during the runs. The collision and dense-case gains
repeat in every round; the absent scans and the 12-byte short control stayed
within the observed run-to-run spread (absolute differences below 2 ns for
the short control). The dense controls previously fell back to scalar
verification at the first block; the third-byte stage now rejects those lanes
before the fallback, so both collapse to a single filtered pass.

## Validation

```sh
zig build test-lib -Dtest-filter=nibble -Dtest-filter=PairSet -Dtest-filter='wide alternation' -Dtest-filter=MultiFilter --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter=nibble -Dtest-filter=PairSet -Dtest-filter='wide alternation' -Dtest-filter=MultiFilter -Dtest-filter=prefilter -Dtest-filter='start alternation' -Dtest-filter='literal alternation' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/prefilter.zig
```

All seven Debug and fifteen ReleaseFast scoped tests and 9,252 V8
comparisons passed. Tests compare every input offset against exact literal
search over fixed, random, dense, malformed and UTF-8 inputs; the UTF-8 set
contains two-byte literals, which disables the third-byte stage.
