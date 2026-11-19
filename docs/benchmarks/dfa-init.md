# ASCII DFA initialization

Baseline: `5694199`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

ASCII-only DFAs prefill all non-ASCII transitions as dead and never consult
the Unicode transition cache. Their constructors now omit its 4,096 entries
(64 KiB). Unicode-capable DFAs retain that cache. DFA scratch and epoch views
share one allocation, including complete cleanup if Unicode cache allocation
fails.

`bench-startup` includes a `dfa_cold` phase that creates a fresh workspace and
performs three matches, triggering the short-input lazy DFA's construction.
Other phases continue measuring compilation, initial scratch allocation and
warm matching separately. Allocation counters now distinguish workspace setup
from subsequent DFA allocations.

## Measurements

Five batch medians are collected per executable. Three executions were
interleaved before/after, after/before, before/after. Requested bytes are
cumulative allocator requests during DFA setup, not retained live memory.
Raw samples are in [`dfa-init.json`](dfa-init.json).

| Case / mode | Before, ns/iter | After, ns/iter | DFA allocations | DFA requested bytes |
| --- | ---: | ---: | ---: | ---: |
| alternation / dfa_cold | 5136.6 | 1401.7 | 11 -> 9 | 85,894 -> 20,358 |
| xDS path / dfa_cold | 6173.7 | 1860.1 | 15 -> 13 | 112,180 -> 46,644 |
| mixed Unicode / dfa_cold | 5197.1 | 4945.6 | 8 -> 7 | 68,582 -> 68,582 |
| ASCII class / warm | 4.3 | 4.2 | 0 -> 0 | 0 -> 0 |
| alternation / warm | 5.8 | 6.1 | 11 -> 9 | 85,894 -> 20,358 |
| xDS path / warm | 8.4 | 8.3 | 15 -> 13 | 112,180 -> 46,644 |
| mixed Unicode / warm | 12.9 | 13.1 | 8 -> 7 | 68,582 -> 68,582 |

The verified gain is first DFA construction: about 3.7x for alternation and
3.3x for xDS, with exactly 65,536 fewer requested cache bytes per ASCII DFA.
The warmed alternation sample varied upward by 5%; the 56-case main gate
passed. Small timing differences remain host-sensitive.

## Validation commands

```sh
zig build test-lib -Dtest-filter=DFA -Dtest-filter=borrowed -Dtest-filter='expired and interrupted' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-startup -Doptimize=ReleaseFast
```

Tests inspect absence of the ASCII cache, exercise the retained Unicode cache,
and inject each allocation failure while checking successful NFA fallback and
complete resource release. Allocation failures may be swallowed by the documented
fallback; the test accepts that behavior and still verifies allocator balances.

All 20 scoped tests, 6,900 V8 comparisons and the 56-case benchmark gate passed.
