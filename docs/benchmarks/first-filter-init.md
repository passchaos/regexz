# First-byte filter construction from the ASCII bitmap

Baseline: `729e217`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Every search workspace builds a `FirstFilter` from the program's first-byte
summary: up to eight candidate bytes for the splat path and up to four
contiguous ranges for class-like sets. Construction probed all 128 ASCII
values twice, once for the byte list and once for the runs.

The ASCII bitmap is authoritative for byte membership, so construction now
walks the two bitmap words once with `@ctz`, collecting set bits in order and
closing contiguous runs as it goes. The too-many-bytes flag and the
range-disabled fallback keep their existing meaning, the non-ASCII flag and
the symbolic summary are unchanged, and no storage or matching loop changes.

## Measurements

`bench-search_startup` separates search-DFA workspace construction
(`dfa_init`), the first search (`dfa_cold`), the same search through the
one-shot `Regex` API (`api_cold`), and warmed calls. Each executable reports
the median of five batches. Five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`first-filter-init.json`](first-filter-init.json).

| Case / mode | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| ASCII lookahead / dfa_init | 289.5 | 173.5 | 1.67x |
| Unicode boundary / dfa_init | 286.0 | 173.5 | 1.65x |
| ASCII alternatives / dfa_init | 325.2 | 205.1 | 1.59x |
| Unicode ASCII subject / dfa_init | 274.0 | 178.9 | 1.53x |
| Unicode lookahead / dfa_init | 266.4 | 183.4 | 1.45x |
| greedy capture chain / dfa_init | 336.7 | 233.5 | 1.44x |
| ASCII captures / dfa_init | 328.6 | 246.9 | 1.33x |
| literal API control / dfa_init | 47.4 | 49.0 | 0.97x |
| ineligible control / dfa_init | 111.6 | 111.5 | 1.00x |
| Qwen setup / dfa_init | 587.5 | 581.0 | 1.01x |
| ASCII alternatives / api_cold | 1,465.8 | 1,081.8 | 1.35x |
| ASCII lookahead / api_cold | 981.3 | 758.4 | 1.29x |
| greedy capture chain / api_cold | 1,529.7 | 1,284.3 | 1.19x |
| ASCII alternatives / dfa_cold | 667.6 | 554.6 | 1.20x |
| ASCII lookahead / dfa_cold | 610.4 | 493.6 | 1.24x |

The init gains repeat in every round and carry into the first-search and
one-shot API paths, which include construction. Programs that never build a
first filter (literal and ineligible controls) are unchanged. Qwen setup is
unchanged because its init is dominated by the large first set and the
search-DFA preparation rather than the byte scan. Warmed calls are unchanged.

## Validation

```sh
zig build test-lib -Dtest-filter=FirstFilter -Dtest-filter=prefilter -Dtest-filter=MultiFilter -Dtest-filter=PairSet --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/prefilter.zig
zig build bench-search_startup -Doptimize=ReleaseFast
```

The scoped tests compare the filter against a naive scan at every start
offset over small, large and non-ASCII sets, and flag sets that exceed the
splat path. The V8 differential harness and the 56-case performance gate
pass.
