# Targeted case-fold expansion

Baseline: `47f2213`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Case-insensitive classes are materialized at compile time by adding every
simple case-fold peer of the class runes. The fold table has 482 delta ranges;
`appendFolded` walked all of them for every range of every class, and called
the `foldNext` binary search twice per entry before testing intersection. A
class with one rune, such as the case-insensitive literals in the Qwen
tokenizer pattern, still paid for the whole table per literal.

`appendFolded` now walks the table the other way: for each class range it
binary-searches the first fold entry that can intersect the range and visits
only the overlapping entries, breaking as soon as an entry starts past the
range end. The entries and their intersections are the same, and the resulting
range list is sorted and merged exactly as before, so the compiled set is
unchanged. Classes that cover many runes still expand the same peers; they
just no longer rescan entries that cannot intersect.

`normalize` also checks whether the incoming range list is already sorted
before calling the comparison sort. Property groups and most parsed classes
arrive in order, while unions that concatenate groups out of order still take
the full sort.

## Measurements

`bench` compiles and runs the full microbenchmark suite. Each executable
reports its own medians; five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`case-fold-scan.json`](case-fold-scan.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer, page | 303,596.3 | 62,604.1 | 4.85x |
| compile Qwen tokenizer, SMP | 287,947.6 | 54,175.6 | 5.32x |
| compile xDS-like, page | 4,580.6 | 4,179.0 | 1.10x |
| compile xDS-like, SMP | 2,210.7 | 2,133.5 | 1.04x |
| find Qwen tokenizer control | 60,518.3 | 54,509.2 | 1.11x |
| find word boundary control | 62,743.8 | 66,764.0 | 0.94x |
| stream Han chain control | 437,845.9 | 472,060.4 | 0.93x |
| RegexSet 9 no-match control | 41,991.3 | 42,356.3 | 0.99x |
| Workspace.init Qwen control | 62.6 | 64.4 | 0.97x |

The compile cases improve in every round. The search and streaming controls do
not use the folding path at runtime; their 0.93–1.11x spread is the shared
host's run-to-run noise (the Qwen find case runs after the now much shorter
compile cases, so its sample also reflects a different process timeline).
Runtime paths, workspace sizes and allocation counts are unchanged.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='fold' -Dtest-filter='case-insensitive' -Dtest-filter='case insensitive' -Dtest-filter='Turkish' -Dtest-filter='unicode class' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/classes.zig
```

The class tests cover ASCII, Unicode and Turkish folding, negated classes,
set operations and the compiled range lists; the V8 fuzzer compares 9,252
case-insensitive and class-heavy searches against the reference engine.
