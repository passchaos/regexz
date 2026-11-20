# Deterministic replay through nullable greedy capture runs

Baseline: `b6f5c6a`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The capture replay plan previously rejected a greedy set run followed by
another star, even when that following run could match empty and a mandatory
suffix lay outside both sets. Captures such as `(a*)(b*)`, `(a*)(a*)` and
`([a-z]+)([0-9]*)([A-Z]+)` therefore used interpreter replay and allocated
capture trails and backtracking choices after obtaining the winning bounds.

The one-time plan now walks past capture saves and nullable greedy stars to
find the first mandatory consumer or accept. A mandatory literal or set must
be disjoint from the current run. `canReplay` proves this condition for every
star in program order, including every skipped nullable star. Each greedy
run can then take its maximal prefix; a following nullable run never needs a
reserved minimum, and its own proof prevents it from consuming a required
suffix. Nullable sets can overlap each other, as `(a*)(a*)` demonstrates.

The consuming replay loop is unchanged. The existing workspace enum caches
the proof, with no additional field, allocation or per-match graph walk.
The one-time graph walk remains a separate function so warmed capture and
search dispatch do not inline its instruction traversal.
Overlapping mandatory consumers, lazy quantifiers and unsupported assertions
retain interpreter replay. The original capture save order, winning-bound
check and execution-budget handling remain.

## Measurement method

The fixed baseline is a `git archive` of `b6f5c6a` with the identical updated
`tools/bench/capture.zig` and `tools/bench/branch_startup.zig` copied into it.
The capture suite adds consecutive nullable runs, overlapping nullable runs,
optional ASCII/Unicode groups and lazy/mandatory-overlap controls. Empty
matches advance by one valid UTF-8 rune, or one malformed byte; the final
empty match at end of input is also consumed. A pass therefore measures the
whole nullable workload instead of stopping at its first empty match.
Every pass reads every returned capture slot into its checksum.

The startup suite adds short nullable and optional capture cases, with
separate initialization, complete first searches, cold passes, warmed first
searches and warmed passes. Both suites retain their earlier controls and
runtime pointer barriers. The capture suite uses medians of five batches of
100 passes; startup batch lengths depend on the phase and subject size.

Three executions alternate before/after, after/before, before/after.
Fresh-workspace probes record allocation counts, requested bytes and
interpreter capacities. Raw timings, counters and executable SHA-256
identities are in [`nullable-replay.json`](nullable-replay.json).

## Measurements

| Case / phase | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| capture/nullable greedy captures | 196,678.3 ns/pass | 118,418.3 ns/pass | 1.66x |
| capture/overlap nullable captures | 188,991.3 ns/pass | 110,580.4 ns/pass | 1.71x |
| capture/optional ASCII captures | 295,563.3 ns/pass | 164,842.5 ns/pass | 1.79x |
| capture/optional overlapping run | 287,930.8 ns/pass | 163,692.5 ns/pass | 1.76x |
| capture/nullable Unicode captures | 617,347.9 ns/pass | 505,012.9 ns/pass | 1.22x |
| capture/Unicode optional captures | 555,819.2 ns/pass | 390,024.6 ns/pass | 1.43x |
| capture/optional lazy control | 230,092.1 ns/pass | 232,391.7 ns/pass | 0.99x |
| capture/overlap mandatory control | 408,217.9 ns/pass | 402,142.9 ns/pass | 1.02x |
| startup/nullable greedy warm_first | 53.8 ns/iter | 31.0 ns/iter | 1.74x |
| startup/optional ASCII warm_first | 67.4 ns/iter | 32.6 ns/iter | 2.07x |
| startup/optional Unicode warm_first | 116.3 ns/iter | 75.1 ns/iter | 1.55x |
| startup/nullable greedy first | 1,192.1 ns/iter | 1,152.5 ns/iter | 1.03x |
| startup/optional Unicode first | 20,040.8 ns/iter | 20,225.0 ns/iter | 0.99x |
| startup/ASCII token warm_pass | 5.6 ns/iter | 5.5 ns/iter | 1.02x |

| Case | First-find allocations | Cumulative requested bytes | Trail capacity | Choice capacity |
| --- | ---: | ---: | ---: | ---: |
| nullable greedy captures | 21 -> 19 | 10,993 -> 10,689 | 9 -> 0 | 4 -> 0 |
| overlap nullable captures | 19 -> 17 | 6,129 -> 5,825 | 9 -> 0 | 4 -> 0 |
| optional ASCII captures | 24 -> 22 | 21,724 -> 21,420 | 9 -> 0 | 4 -> 0 |
| nullable Unicode captures | 77 -> 75 | 105,457 -> 105,153 | 9 -> 0 | 4 -> 0 |
| Unicode optional captures | 90 -> 87 | 124,604 -> 123,932 | 23 -> 0 | 4 -> 0 |
| optional lazy control | 7 -> 7 | 583 -> 583 | 9 -> 9 | 4 -> 4 |
| overlap mandatory control | 22 -> 22 | 12,324 -> 12,324 | 9 -> 9 | 4 -> 4 |

All counters are stable across the three rounds. The six eligible capture
cases eliminate trail and choice storage, reducing first-find allocations
by two, or three for the five-group Unicode case. Workspace initialization
still allocates one capture block: 96 bytes for two captures, 128 bytes for
three and 192 bytes for five. Workspace size remains 6,592 bytes in every
startup phase.

The qualified complete-pass gains are 1.66-1.79x for ASCII nullable/optional
captures, 1.22x for the Unicode nullable-prefix case and 1.43x for optional
Unicode captures. Lazy and overlapping mandatory controls remain within 4%
of their baselines, with interpreter capacities and allocation counts
unchanged. Other capture controls range from about 8% slower to 6% faster.

First-search timings do not establish a cold-start gain. The final Greek
CJK-miss initialization control is 20% slower (317.9 -> 382.1 ns), while its
complete first search differs by 2%. Construction has no new graph walk or
allocation. Individual initialization phases varied on this shared host;
these samples do not establish a universal construction-latency result.

## Validation

```sh
zig build test-lib -Dtest-filter='nullable capture replay' -Dtest-filter='capture replay' -Dtest-filter='capture search takes DFA' -Dtest-filter='capture-aware fallback' --summary all
zig build test-lib -Dtest-filter='nullable capture replay' --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter='capture replay' -Dtest-filter='capture search takes DFA' -Dtest-filter='capture-aware fallback' --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter='nullable capture replay retains strict budget' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/capture_replay.zig src/regex/capture_nullable_tests.zig src/root.zig tools/bench/capture.zig tools/bench/branch_startup.zig
```

Native checks compare complete capture slots with a forced interpreter at
every tested byte offset, including Unicode, malformed encodings, empty input
and `(*NOTEMPTY)`/`(*NOTEMPTY_ATSTART)`. Positive fixtures require the search
DFA path and zero trail/choice capacity. Fixed repeated captures check that
the final empty iteration replaces an earlier nonempty capture. Budget cases
cover the 6-16-step boundaries, strict errors and linear fallback captures.
Lazy loops, assertions and overlapping mandatory consumers remain controls.
V8 seeds cover the same nullable/optional shapes and fixed repeats over
ASCII, Unicode and empty subjects.

The Debug related suite passed 11 tests; the fixed-repeat supplement passed
5 tests. The final ReleaseFast related suite passed 11 tests, followed by
3 scoped fixed-repeat budget checks. The V8 harness passed 9,186 comparisons,
and the 56-case performance gate and formatting checks passed. Three final
alternating rounds covered 32 capture cases and 115 startup phases per
executable. Allocation counters and workspace sizes were checked in every
round.

## Static-check placement screen

The first prototype produced the same capture-record reductions, but a tiny
ASCII-token warmed pass was consistently 1.3 ns slower (5.3 -> 6.6 ns) in a
five-round startup follow-up. Its initial 45% nested-capture initialization
difference did not repeat; the follow-up difference was 11%. Those samples
are archived in [the first screen](nullable-replay-inline-screen.json) and
[its startup follow-up](nullable-replay-inline-controls.json). Their candidate
hashes identify the earlier graph-walk placement, not the final executable.

Keeping the one-time graph traversal in a separate function retains the
capture gains. The final frozen-executable rounds run under the shared build
guard; the same tiny ASCII-token pass is 5.6 -> 5.5 ns. This placement avoids
inlining the traversal into warmed dispatch, with no new replay state.
