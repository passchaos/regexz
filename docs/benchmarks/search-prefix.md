# Lightweight prefixes before ordinary Unicode miss tables

Baseline: `3cf2f3d`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Ordinary Unicode set-run searches previously prepared complete byte tables
after four valid Unicode probes, including nonmembers. A Greek search over
CJK text therefore built a table even though no rune matched. Failed scalar
probes then advanced a byte, revisiting continuation bytes before switching
to the byte automaton.

The ordinary search now uses a search-specific scalar probe. Matching probes
retain the original four-probe table policy and long matching runs still
prepare tables on demand. Valid misses accumulate in the workspace's first
filter and first attempt the compact prefix ranges already used by capture
runs. A successful prefix preparation reuses existing range vectors and
leaves the byte table absent. If the set is too wide or fragmented, the
preceding valid-miss count is restored once to the original table counter;
subsequent valid probes retain the previous preparation policy.

An ASCII member at the requested offset enters the existing ASCII run scan
directly, avoiding first-filter dispatch on that common short-hit path.
Valid rejected runes advance by their decoded width, while malformed probes
advance one byte. The prepared byte scanner also uses the exact prefix entry
when available. First-filter symbolic summaries remain intact. A small miss
counter uses existing filter padding; no extra heap-owned scanner is added.
The generic Unicode probe used by full-match and dominant-branch runs keeps
its original policy.

## Measurement method

The fixed baseline is a `git archive` of `3cf2f3d` with the identical updated
startup benchmark copied into it. Four cases add a short Greek miss, a
mixed-script Han miss, a Han match after rejected prefixes and a wide-letter
miss. Existing large CJK misses, tiny matching subjects, ASCII workloads,
mixed text, captures and replacement-related search controls remain.

Both snapshots use the identical capture benchmark as a control. Each suite
reports medians of five batches; capture passes use 100 iterations and
startup batch lengths depend on the phase and subject. Three frozen-executable
executions alternate before/after, after/before, before/after under the shared
build guard. Every complete pass reads returned capture slots into its
checksum, and runtime input-pointer barriers remain.

Fresh-workspace probes record construction and first-search allocations,
cumulative requested bytes and workspace size. Raw timings, counters and
executable SHA-256 identities are in [`search-prefix.json`](search-prefix.json).

## Measurements

| Case / phase | Before | After | Speedup |
| --- | ---: | ---: | ---: |
| startup/Greek CJK miss first | 340,563.3 ns/iter | 18,673.8 ns/iter | 18.24x |
| startup/Greek CJK miss warm_first | 325,407.3 ns/iter | 17,391.1 ns/iter | 18.71x |
| startup/Han mixed miss first | 14,707.9 ns/iter | 1,117.1 ns/iter | 13.17x |
| startup/Han mixed miss warm_first | 1,951.6 ns/iter | 561.5 ns/iter | 3.48x |
| startup/Han rejected gap first | 14,582.9 ns/iter | 1,051.7 ns/iter | 13.87x |
| startup/Han rejected gap warm_first | 1,939.2 ns/iter | 537.5 ns/iter | 3.61x |
| startup/Greek short miss warm_first | 8.4 ns/iter | 8.1 ns/iter | 1.04x |
| startup/wide letters miss first | 332,658.3 ns/iter | 330,936.7 ns/iter | 1.01x |
| startup/letters ASCII warm_first | 6.3 ns/iter | 5.9 ns/iter | 1.07x |
| startup/letters mixed warm_pass | 19,734.4 ns/iter | 21,018.2 ns/iter | 0.94x |

| Case / first search | Extra allocations | Cumulative requested bytes |
| --- | ---: | ---: |
| Greek CJK miss | 11 -> 0 | 70,732 -> 0 |
| Han mixed miss | 15 -> 0 | 156,252 -> 0 |
| Han rejected gap | 15 -> 0 | 156,252 -> 0 |
| wide letters miss | 21 -> 21 | 1,543,588 -> 1,543,588 |

All resource counters are stable across the three rounds. Selective Greek
and Han misses retain only the one 32-byte mandatory workspace allocation.
The mixed-script Han match after rejected prefixes also avoids byte-table
construction. Wide-letter misses retain their original 21 preparation
allocations and requested-byte total. Workspace size remains 6,592 bytes in
every startup phase.

The qualified gain is selective ordinary Unicode search: Greek CJK misses
improve about 18x in cold and warmed searches, and Han mixed-script misses
and rejected-prefix first searches improve about 13-14x. ASCII short hits
remain fast, with warmed first searches at 6.3 -> 5.9 ns. Capturing workloads
remain within about 9% of their baselines; wide-set warmed misses also retain
the original table path. Individual construction controls varied by 17-19%
on the shared host, so these samples do not establish a universal workspace
construction-latency gain.

## Validation

```sh
zig build test-lib -Dtest-filter='deferred search' -Dtest-filter='deferred run' -Dtest-filter='deferred workspace' -Dtest-filter='UTF8 prefix' --summary all
zig build test-lib -Dtest-filter='deferred search selective' -Dtest-filter='deferred search wide' -Dtest-filter='deferred search prefix readiness' --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter='deferred search' -Dtest-filter='deferred run' -Dtest-filter='deferred workspace' -Dtest-filter='UTF8 prefix' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/prefilter.zig src/regex/deferred_utf8_run.zig src/regex/utf8_run_search.zig src/regex/deferred_search_tests.zig tools/bench/branch_startup.zig
```

Existing byte-offset checks compare complete bounds and slots with the
interpreter before and after table preparation. New checks prove repeated
selective misses and their first successful rune use only the mandatory
workspace allocation; the failed-allocator boundary prohibits extra storage.
Wide-set checks combine an earlier successful probe with later misses to
verify that preparation counts are restored exactly once. Ready prefixes are
tested across malformed encodings, starts inside codepoints and a subsequent
optional byte-table allocation failure. Replacement and iterator reuse,
ordinary ASCII scans, full-match preparation and dominant-branch runs remain
in the scoped checks. Differential subjects include long rejected Unicode
prefixes followed by matching runes and wide-set controls.

The initial related Debug suite passed 24 tests and the new preparation
boundary supplement passed five tests. The final ReleaseFast suite passed
27 tests, with 9,252 V8 comparisons, the 56-case performance gate and
formatting checks also passing. Three complete alternating rounds covered
155 startup phases and 32 capture cases per executable. Allocation counters
and workspace value sizes were checked across all rounds.

## ASCII dispatch screen

The first prototype already removed selective miss-table allocations, but
its tiny ASCII-letter warmed first search was 6.1 -> 7.1 ns. That version is
archived in [the ASCII dispatch screen](search-prefix-ascii-screen.json),
whose candidate hashes identify the earlier entry path. The final version
recognizes an ASCII member at the requested offset before first-filter
dispatch, preserving the existing direct ASCII scan and the Unicode miss
gains. Its three-round warmed first-search result is 6.3 -> 5.9 ns.
