# Runtime-input calibration and borrowed program matching

Baseline source: `bfeade1`. The generated matcher comparison used constant
subjects and observed only the final Boolean. It now uses heap-backed subjects
and a pointer/length optimization barrier on every iteration. Each comparison
reports the median of five batches; three independent executions were collected.
ARM64 disassembly confirms subject loads, length checks and content comparisons
inside the generated matching loop.

## Program-copy cost

The main benchmark's reused workspace loop copied a 416-byte `Program` before
each outlined matching call. The value API remains callable, including as a
function pointer. `Workspace.matchesBorrowed` accepts a read-only reference;
`Regex.matches`, `Regex.matchesWithWorkspace` and benchmark hot paths use it.
Private NFA and DFA helpers retain the reference throughout matching.
Disassembly of the hot loop now passes the program address directly.

| Reused workspace case | Before, ns/iter | After, ns/iter |
| --- | ---: | ---: |
| literal | 14.4 | 1.7 |
| class | 13.4 | 4.3 |
| xDS-like | 15.2 | 8.6 |
| unicode | 18.0 | 9.8 |
| (?i) literal | 15.0 | 4.5 |

The old source table uses one batch average per case; the new table uses the
median of three executions. These are shared-host comparisons, not precise
cross-host certification. Raw output is archived in
[`calibration.json`](calibration.json).

## Valid generated/runtime comparison

| Case | Generated, ns/iter | Runtime borrowed workspace, ns/iter |
| --- | ---: | ---: |
| literal | 0.5 | 1.7 |
| class | 3.5 | 4.9 |

Only the two generated-case baseline values were recalibrated. Previously
mislabelled `(alloc)` cases are now `(warm Regex API)` with their existing
regression thresholds preserved.

## Cold startup profile

`bench-startup` reports compile-plus-first-match, workspace initialization,
workspace-plus-first-match and warmed matching separately. The initial profile
found about 46 us and 187 allocations for a Han-set workspace versus about
9 ns warmed matching. This identifies Unicode automaton construction as the
next optimization target. Raw startup output is included in the JSON archive.

## Validation

```sh
zig build bench-comptime -Doptimize=ReleaseFast
zig build bench-startup -Doptimize=ReleaseFast
python3 tools/bench/check.py --runs 1
zig build test-lib -Dtest-filter=borrowed -Dtest-filter='lazy DFA' -Dtest-filter='expired and interrupted' -Dtest-filter='notempty rejects' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
```

The 56-case benchmark gate, nine focused matching/compatibility tests and
6,900 V8 comparisons passed. Budget cancellation, empty-match restrictions,
DFA fallback and repeated use remain covered. Baseline timings are averages
for runtime rows and batch medians for generated rows; the gate takes process
medians when multiple runs are requested.
