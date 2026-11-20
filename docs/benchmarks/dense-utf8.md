# Direct dense UTF-8 table construction

Baseline: `6c9c641`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

`Utf8Run.init` previously built a compact UTF-8 automaton, allocated its final
`Node` and `Edge` arrays, expanded those arrays into 256-entry u16 transition
rows, then freed the compact arrays. Those two final compact allocations were
temporary for expanded-table callers.

`utf8_set.buildTable` now shares the existing range-emission pass and expands
the builder's linked nodes/edges directly into the final dense table. The
builder's original scratch arrays remain under `defer` cleanup on success
and failure. Compact-automaton callers still use the same compact finish;
state numbering, byte ranges, leaf accept markers and dead rows are unchanged.

The expanded scanner retains its original table layout and lookup loops.
This change removes two temporary allocations and copies for nonempty sets,
without changing workspace value size or adding persistent storage.

## Measurement method

The fixed baseline is a `git archive` of `6c9c641` with the identical updated
startup benchmark copied into it. Three cases add long Greek, Han and Unicode
letter runs that force byte-table construction during the first search.
Existing wide misses, tiny subjects, full passes, prefix filters and capture
controls remain. Both snapshots use the same capture benchmark.

Each executable reports the median of five batches. Startup phases separate
workspace construction, complete first searches, cold passes and warmed
searches; phase lengths depend on the subject. Capture batches use 100
complete passes and read every returned slot. Runtime pointer barriers remain.

Three frozen-executable executions alternate before/after, after/before,
before/after under the shared build guard. Separate cold probes record
allocation counts, cumulative requested bytes and workspace size. Raw timings,
counters and executable SHA-256 identities are in
[`dense-utf8.json`](dense-utf8.json).

## Measurements

| Case / first search | Before, ns | After, ns | Extra allocations | Cumulative requested bytes |
| --- | ---: | ---: | ---: | ---: |
| Greek table init | 6,088.8 | 6,197.1 | 11 -> 9 | 70,732 -> 69,248 |
| Han table init | 13,326.7 | 12,902.9 | 15 -> 13 | 156,252 -> 153,136 |
| letters table init | 344,075.4 | 346,273.3 | 21 -> 19 | 1,543,588 -> 1,512,152 |

The three table-construction cases reduce extra allocations by two in every
round. Requested-byte reductions are 1,484 for Greek, 3,116 for Han and
31,436 for Unicode letters, exactly the omitted compact node/edge arrays.
Wide-letter misses and complete mixed-text passes also reduce byte-table
construction allocations from 21 to 19. Mandatory workspace initialization
and workspace value size remain unchanged; every startup phase reports
6,592 bytes.

The qualified benefit is less construction allocation and copying. Complete
first-search timing medians range from about 3% faster to 2% slower, so these
samples do not establish a general construction-latency gain. The expanded
lookup loop is unchanged and all rows match the compact reference. Warmed
construction-case searches varied by up to about 10%; other capture controls
varied by less than 10%. The Greek workspace-initialization phase was 16%
slower, while that phase does not build a table. Small shared-host timing
differences remain inconclusive.

## Validation

```sh
zig build test-lib -Dtest-filter='expanded UTF8' -Dtest-filter='utf8 automaton construction' -Dtest-filter='deferred search' -Dtest-filter='deferred workspace' -Dtest-filter='deferred run' --summary all
zig build test-lib -Dtest-filter='expanded UTF8' --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter='expanded UTF8' -Dtest-filter='utf8 automaton construction' -Dtest-filter='Unicode workspace construction' -Dtest-filter='deferred search' -Dtest-filter='deferred workspace' -Dtest-filter='deferred run' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/utf8_set.zig src/regex/utf8_run.zig src/regex/utf8_allocation_tests.zig tools/bench/branch_startup.zig
```

Expanded rows are compared with the original compact automaton for every
state and all 256 bytes. Sets include Han/Greek, Unicode letters, mixed
ASCII/Unicode, encoding-width boundaries, an empty set and the complete
codepoint range. Direct-table allocation failure is checked at every possible
allocation; the original compact constructor and workspace rollback checks
remain. Full-match/search preparation, malformed-prefix recovery, disabled
optional storage and dominant-branch scanning remain in the scoped suite.

All 24 initial related Debug tests and four expanded-table supplement checks
passed. The final ReleaseFast related suite passed 26 tests, including
compact/dense allocation rollback and workspace failure cleanup. The V8
harness passed 9,252 comparisons; the 56-case performance gate and formatting
checks passed. Three frozen-executable rounds covered 170 startup phases and
32 capture cases per executable. Allocation counters and workspace sizes
were verified across every round.
