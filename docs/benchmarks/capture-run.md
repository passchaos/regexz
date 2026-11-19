# Direct capture-run scanning

Baseline: `0373cee`. The general capture-search path dispatches instructions
and fills captures after locating a match. ASCII single-set runs with fixed
capture saves can instead scan the run once and write their known boundaries.

`capture_run.Plan.init` recognizes `saves -> member -> star -> saves -> accept`
when the mandatory member and star use the same ASCII set. Saves before the
run receive its start; saves after it receive its end. This includes nested
captures and adjacent empty captures. The existing workspace byte table is
reused, and the plan adds no allocations.

Small sets with up to ten ASCII members use eight scalar probes for short
separators; wider sets use two probes before switching to the SIMD prefilter.
The new dispatch tag and branch are appended to retain the original tags and
branch ordering.

The optimization remains within Pike's eligibility and capture-slot limits
(up to 127 groups). Other shapes use the existing capture-search engines.
Strict `linear_fallback = false` callers retain replay step limits and stop
scanning a match when its remaining budget is exhausted. With fallback
enabled, this deterministic linear scan supplies exact captures without
building a Pike workspace. Plans are reconstructed from deserialized programs.

## Measurements

Same shared macOS ARM64 host, ReleaseFast, SMP allocator. Each pass reads all
capture slots into a checksum. ASCII subjects contain 32,000 bytes; the Unicode
control contains 28,000 bytes. Each executable reports the median of five
batches of 100 passes. The table takes medians of three interleaved executions
in `before/after`, `after/before`, `before/after` order. Raw samples are in
[`capture-run.json`](capture-run.json).

| Case | Before, us/pass | After, us/pass | Speedup | First-find allocations, before -> after |
| --- | ---: | ---: | ---: | ---: |
| word capture | 218.64 | 67.69 | 3.23x | 1 -> 0 |
| literal capture | 109.39 | 36.30 | 3.01x | 26 -> 0 |
| digit capture | 117.51 | 37.75 | 3.11x | 1 -> 0 |
| nested capture | 281.18 | 77.23 | 3.64x | 1 -> 0 |
| empty adjacent captures | 330.50 | 74.99 | 4.41x | 1 -> 0 |
| adjacent run control | 67.37 | 68.29 | 0.99x | 0 -> 0 |
| repeated capture control | 240.57 | 242.68 | 0.99x | 33 -> 33 |
| Unicode capture control | 164.70 | 170.77 | 0.96x | 1 -> 1 |
| capture-free control | 28.57 | 28.69 | 1.00x | 0 -> 0 |
| no-match control | 0.61 | 0.61 | 0.99x | 0 -> 0 |

The complete replacement case `(\w+)` -> `[$1]` improved from 393.32 us
to 251.13 us with the final configuration (1.57x). This is a
separate end-to-end run, also using five batches; its raw output is archived
alongside the search samples. The unaffected search controls stayed within
4% in the interleaved run. Treat small timing differences as host-sensitive.

## Validation

```sh
zig build test-lib -Dtest-filter=capture -Dtest-filter=replacement -Dtest-filter='linear fallback' --summary all
zig build test-lib -Dtest-filter='capture run' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
zig build bench-capture -Doptimize=ReleaseFast
zig build bench-replace -Doptimize=ReleaseFast
```

All 48 scoped regression tests passed. After probe tuning, all eight capture-run
tests passed again, including every-offset comparison with the general engine,
strict/fallback budgets, 127/128-group boundaries, allocation-free first finds,
and serialized programs. The 100-pattern V8 differential passed all 5,400
full-match/search/capture comparisons. Its seeded cases now explicitly include
captures around greedy runs, plus nullable/lazy/repeated/Unicode controls;
compilation and execution use separate outputs so wrapper logs cannot enter
the comparison protocol.
