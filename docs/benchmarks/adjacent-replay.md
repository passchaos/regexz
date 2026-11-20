# Deterministic replay for adjacent disjoint capture runs

Baseline: `9e8a0c3`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

General capture search obtains winning bounds from the search DFA, then
reconstructs capture slots. The linear replay previously accepted greedy set
runs only when their continuation accepted or began with a literal outside
the set. A following consuming set therefore forced full interpreter replay,
including capture trails and greedy backtracking choices, even when the two
sets were disjoint.

`capture_replay.zig` now owns deterministic replay. It borrows compiled
instructions, the starting instruction, capture slots, an execution counter
and its limit. A workspace enum caches the static proof on first capture
replay, with no additional allocation or construction-time graph walk. The
search workspace continues to own slots, budgets and fallback state.

After skipping capture saves, a following consuming set is accepted only
when it shares no rune with the current run. The greedy run is then forced
to its maximal length and cannot backtrack to let that continuation start.
The shared sorted-range intersection helper handles materialized ASCII and
Unicode sets during one-time preparation; warmed capture replay does not
repeat range intersections or continuation instruction walks. Overlapping
sets, lazy alternatives and other unsupported instructions retain interpreter
replay; saved capture ordering is preserved.
The original step accounting and replay/fallback budget checks are retained.

## Measurement method

The fixed baseline is a `git archive` of `9e8a0c3`, with the same updated
`tools/bench/capture.zig` copied into it. The workload adds three disjoint
capture runs over ASCII and Unicode, empty adjacent Unicode captures and an
overlapping-run control. Every pass reads every returned capture slot into
its checksum, and runtime pointer barriers retain subject loads.

The identical updated `tools/bench/branch_startup.zig` also runs on both
snapshots. It adds short disjoint ASCII, Unicode and empty-capture cases to
measure initialization, complete first searches, cold passes, warmed first
searches and warmed passes separately.

The capture executable reports the median of five batches of 100 passes;
startup phases use five batches whose lengths depend on the phase and subject
size. Three executions alternate before/after, after/before, before/after. A fresh-workspace
probe records initialization and first-find allocations, cumulative requested
bytes, and trail/choice capacities. Raw timings, counters and executable
SHA-256 identities are in [`adjacent-replay.json`](adjacent-replay.json).

## Measurements

| Case / phase | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| capture/disjoint ASCII captures | 143,821.3 ns/pass | 91,791.3 ns/pass | 1.57x |
| capture/disjoint Unicode captures | 245,495.0 ns/pass | 189,858.3 ns/pass | 1.29x |
| capture/Unicode empty captures | 267,733.8 ns/pass | 201,306.7 ns/pass | 1.33x |
| capture/overlapping run control | 171,980.4 ns/pass | 174,757.9 ns/pass | 0.98x |
| startup/disjoint ASCII warm_first | 69.7 ns/iter | 37.0 ns/iter | 1.88x |
| startup/disjoint Unicode warm_first | 112.6 ns/iter | 91.2 ns/iter | 1.23x |
| startup/empty captures warm_first | 127.8 ns/iter | 93.1 ns/iter | 1.37x |
| startup/disjoint ASCII first | 1,655.8 ns/iter | 1,628.8 ns/iter | 1.02x |
| startup/disjoint Unicode first | 25,694.6 ns/iter | 25,501.3 ns/iter | 1.01x |
| startup/empty captures first | 26,009.2 ns/iter | 25,175.0 ns/iter | 1.03x |

| Case | First-find allocations | Cumulative first-find requested bytes | Trail capacity | Choice capacity |
| --- | ---: | ---: | ---: | ---: |
| capture/disjoint ASCII captures | 24 -> 22 | 21,943 -> 21,639 | 9 -> 0 | 4 -> 0 |
| capture/disjoint Unicode captures | 103 -> 101 | 150,707 -> 150,403 | 9 -> 0 | 4 -> 0 |
| capture/Unicode empty captures | 104 -> 101 | 151,939 -> 151,267 | 23 -> 0 | 4 -> 0 |
| capture/overlapping run control | 24 -> 24 | 21,991 -> 21,991 | 9 -> 9 | 4 -> 4 |

Allocation counters are identical across all three rounds. Initialization
still allocates one block: 128 bytes for the three ordinary capture groups
and 192 bytes when two empty captures are added. Workspace size remains
6,592 bytes in every phase. The replay plan adds no heap allocation.

The qualified throughput gains are the disjoint adjacent runs. Their complete
first searches are only about 1-3% faster; these samples do not establish a
general cold-start latency improvement. Overlapping sets continue to allocate
the same interpreter records, with throughput within 2% of the baseline.

The initial three rounds showed a 43% slower Han ASCII-miss first search,
although its cold-pass and warmed-search phases varied by less than 5%.
Five further alternating startup executions with the identical frozen
executables reduced the first-search difference to 6% (485.0 -> 513.8 ns).
The large cold-start difference did not repeat. These control samples are
archived in [`adjacent-replay-controls.json`](adjacent-replay-controls.json);
small control timing differences on this shared host remain inconclusive.

## Validation

```sh
zig build test-lib -Dtest-filter='capture replay' -Dtest-filter='capture search takes DFA' -Dtest-filter='capture-aware fallback' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/capture_replay.zig src/regex/capture_replay_tests.zig src/regex/replace.zig src/regex/shapes.zig src/root.zig tools/bench/capture.zig tools/bench/branch_startup.zig
```

Native checks compare complete capture slots with a forced interpreter at
every tested byte offset, exercise overlapping/lazy/nullable controls and
verify strict errors and linear-fallback captures across execution budgets.
The eligible-case checks require the search DFA path and zero trail/choice
capacity. Inputs include ASCII, Unicode digits, supplementary Han, malformed
UTF-8 and partial prefixes. Differential seeds cover the new disjoint runs,
empty saves and overlapping/lazy/nullable controls.

All 8 scoped tests, 8,916 V8 comparisons, the 56-case performance gate and
formatting checks passed. Three alternating rounds covered 17 capture cases
and 95 startup phases per executable. Five additional startup rounds
investigated the initial cold-start control outlier. Executable identities
and allocation counters were checked across all rounds.
