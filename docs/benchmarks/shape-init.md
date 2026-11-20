# Shape detection from ASCII bitmaps

Baseline: `d286ade`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Workspace initialization runs the shape detectors for every program. Four of
them compared a set against a per-byte expectation by probing `Set.matches`
for all 128 ASCII values: the `(?:setA+ setB)+` disjointness check and the
`.*`-style predicates `isDotExceptNewline`, `isAllExcept`, and
`isAllExceptTwo`. The `(?:[a-z0-9]+[ \n])+` loop shape alone probed 256
memberships, which dominated its workspace initialization.

The ASCII bitmap is authoritative for byte membership, so the detectors now
compare or combine the two bitmap words directly. Disjointness is one AND per
word; the "all bytes except N" predicates build the expected bitmap from the
excluded byte values and compare both words. The non-ASCII range checks are
unchanged, so the predicates accept exactly the same sets. No allocation,
workspace layout, or matching loop changes.

## Measurements

`bench-startup` separates compilation plus first match, workspace
initialization, first match, three matches that construct a fresh DFA, and
warmed matching. Each executable reports the median of five batches. Five
executions were interleaved before/after, after/before, alternating. The table
reports medians across those executions; raw samples and executable SHA-256
identities are in [`shape-init.json`](shape-init.json).

| Case / mode | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| ASCII loop / init | 417.7 | 64.6 | 6.47x |
| ASCII loop / cold | 419.4 | 66.1 | 6.34x |
| ASCII loop / dfa_cold | 413.0 | 71.7 | 5.76x |
| ASCII loop / compile_first | 1,163.8 | 790.0 | 1.47x |
| ASCII loop / warm | 4.3 | 4.3 | 1.00x |
| ASCII class / init | 67.2 | 67.7 | 0.99x |
| fragmented class / init | 78.5 | 78.8 | 1.00x |
| alternation / init | 51.3 | 51.2 | 1.00x |
| xDS path / init | 53.3 | 53.5 | 1.00x |

The ASCII loop gains repeat in every round. Programs that do not reach these
detectors are unchanged; the remaining controls moved by less than the host's
run-to-run spread.

## Validation

```sh
zig build test-lib -Dtest-filter='simple-run fast path' -Dtest-filter='chain fast path' -Dtest-filter='star fast path' -Dtest-filter='line fast path' -Dtest-filter='delimited' -Dtest-filter='shape' -Dtest-filter='notempty' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/shapes.zig
zig build bench-startup -Doptimize=ReleaseFast
```

The scoped tests cover the set-loop, chain, star, line, delimited and
not-empty shapes plus the shared workspace paths. The V8 differential harness
and the 56-case performance gate pass.
