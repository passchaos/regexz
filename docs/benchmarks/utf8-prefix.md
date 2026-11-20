# Deferred UTF-8 leading-byte filters for capture runs

Baseline: `f438b55`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The fixed-save Unicode capture scanner previously treated every non-ASCII
byte as a possible start. It decoded and checked each rejected valid rune,
even when the rune's UTF-8 lead could not occur in the materialized set.
In the existing mixed-script units, Greek has nine such candidates and Han
has fourteen; their exact lead-byte sets retain two candidates each.

After eight valid rejected candidates in one search, the scanner prepares
up to four candidate-byte ranges. `utf8_prefix.zig` derives them from the
materialized rune ranges and exact ASCII bitmap. The lead mapping is
monotonic across UTF-8 widths, with invalid scalar endpoints admitted
conservatively. Prefix hits still go through the existing UTF-8 decoder and
exact rune-membership check; shared F0 leads can therefore remain false
positives for supplementary scripts and emoji.

The workspace reuses `FirstFilter`'s existing byte ranges and vector bounds.
A small enum records unprepared, ready or disabled state; the symbolic
first-rune summary remains intact. Sets with more than 24 lead bytes or more
than four combined ASCII/lead ranges retain their original filter, and the
disabled state avoids repeated preparation attempts. Immediate matches and
construction do not prepare a prefix filter. No additional heap storage is
introduced.

Prepared capture scans use a dedicated entry with exact vector first-hit
selection and the same range predicate in their scalar tails. Its scalar
first-byte probe avoids the vector loop for an immediate prefix hit. Ordinary
first-rune scans retain their original dispatch and range scanner. The
unprepared capture filter still admits all non-ASCII bytes. Matching runs,
capture saves, rune-count budgets
and malformed-sequence advancement retain their existing paths.

## Measurement method

The fixed baseline is a `git archive` of `f438b55`. Both snapshots use the
same capture suite and the identical updated startup suite. Four startup
cases add tiny Greek/Han hits and short capture searches after long rejected
prefixes. Existing mixed-script misses, sparse captures, continuous runs,
ASCII misses and nullable-replay controls remain. Every capture pass reads
all returned slots; runtime input-pointer barriers remain in both suites.

Capture timings are medians of five batches of 100 complete passes. Startup
phases separate initialization, complete first searches, cold passes, warmed
first searches and warmed passes, with phase-specific batch lengths. Three
frozen-executable executions alternate before/after, after/before,
before/after under the shared build guard.

Fresh-workspace probes record initialization and first-find allocation
counts, requested bytes, interpreter capacities and workspace size. Raw
timings, counters and executable SHA-256 identities are in
[`utf8-prefix.json`](utf8-prefix.json).

## Measurements

| Case / phase | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| capture/Han mixed-script miss | 164,554.6 ns/pass | 26,338.8 ns/pass | 6.25x |
| capture/Greek mixed-script miss | 116,092.9 ns/pass | 34,914.6 ns/pass | 3.33x |
| capture/Han after long prefix | 167,867.1 ns/pass | 25,545.4 ns/pass | 6.57x |
| capture/Greek after long prefix | 118,275.0 ns/pass | 33,223.8 ns/pass | 3.56x |
| capture/Han sparse captures | 168,793.3 ns/pass | 65,359.2 ns/pass | 2.58x |
| capture/Han capture | 64,680.0 ns/pass | 18,534.6 ns/pass | 3.49x |
| startup/Greek capture gap first | 2,147.5 ns/iter | 1,145.0 ns/iter | 1.88x |
| startup/Han capture gap first | 2,895.0 ns/iter | 997.1 ns/iter | 2.90x |
| startup/Greek capture gap warm_first | 1,853.7 ns/iter | 612.8 ns/iter | 3.02x |
| startup/Han capture gap warm_first | 2,561.7 ns/iter | 467.7 ns/iter | 5.48x |
| startup/Greek tiny hit warm_first | 15.0 ns/iter | 15.9 ns/iter | 0.94x |
| startup/Han tiny hit warm_first | 12.4 ns/iter | 12.3 ns/iter | 1.01x |
| startup/letters mixed warm_pass | 19,239.1 ns/iter | 19,772.4 ns/iter | 0.97x |

All allocation and capacity counters are identical before and after in
every round. New capture-gap and tiny-hit cases retain zero first-find
allocations and no trail/choice storage. Initialization still uses one
capture block, and workspace size remains 6,592 bytes in all startup phases.

The qualified complete-pass gains are 6.25x over Han misses, 3.33x over Greek
misses, 2.58x over sparse Han captures and 3.49x over the original mixed-script
Han capture. Complete first searches after the short rejected prefixes
improve 1.88x over Greek and 2.90x over Han. Their warmed searches also retain
the prepared filter. Tiny Han first searches are essentially unchanged; the
tiny Greek warmed first search differs by 0.9 ns. Other control phases stay
within 15% of their baselines on the shared host. Construction timing gains
are not established.

## Validation

```sh
zig build test-lib -Dtest-filter='UTF8 prefix' -Dtest-filter='FirstFilter' -Dtest-filter='capture run' --summary all
zig build test-lib -Dtest-filter='UTF8 prefix ranges' -Dtest-filter='UTF8 prefix FirstFilter' --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter='UTF8 prefix' -Dtest-filter='FirstFilter' -Dtest-filter='capture run' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/utf8_prefix.zig src/regex/utf8_prefix_tests.zig src/regex/prefilter.zig src/regex/capture_run.zig src/root.zig tools/bench/branch_startup.zig
```

Native tests enumerate valid members of the materialized sets and compare
their lead bytes with the compact filter. They include Greek, Han, Cyrillic,
Hiragana, folded Kelvin-sign membership, mixed ASCII/Unicode sets, UTF-8
width boundaries and U+10FFFF. Every vector hit position and tail offset is
checked against independently enumerated membership. Existing ordinary
first-filter scans are still checked against their naive byte oracle.

Integration tests compare all tested byte offsets with a forced interpreter
after preparation, including overlong encodings, surrogates, out-of-range
values and a fresh valid rune inside a malformed prefix. A failing allocator
rejects any allocation beyond the mandatory capture block. Wide and
fragmented sets verify disabled-state fallback. Strict and linear-fallback
budgets compare prepared scans with the original capture scanner whose
preparation is disabled. Differential probes add encoding-boundary members
and long rejected prefixes before Unicode-caseless Kelvin-sign matches.

All 19 related Debug tests passed, followed by four encoding-boundary
supplement checks. The final dedicated-entry version passed 19 related
ReleaseFast tests, 9,207 V8 comparisons, the 56-case performance gate and
formatting checks. Three complete alternating rounds covered 32 capture
cases and 135 startup phases per executable. Allocation counters, interpreter
capacities and workspace sizes were checked across every round.

## Shared range-path screen

The first prototype changed the generic range scanner to support prepared
prefixes. Its capture misses improved, but an ordinary mixed-Unicode warmed
pass regressed from 19,302.6 to 29,895.8 ns. Those samples are archived
in [the shared-path screen](utf8-prefix-shared-range-screen.json), whose
candidate hashes identify the earlier implementation.

The final version restores the original ordinary `indexOfRanges` body and
uses a dedicated `indexOfRuneCandidates` entry for capture prefix scans. The
ordinary mixed-Unicode warmed pass is 19,239.1 -> 19,772.4 ns
in the final frozen-executable rounds. Capture scanning retains the prepared
range vectors without expanding the generic hot scan.
