# Literal-set scanner spans

Baseline: `9009928`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Whole-pattern literal alternations (`alpha|gamma|...`,
`sunday|saturday|someday`, `a|b|c`) are match-dense in the comparison
workloads: one match every few bytes. Each match previously crossed two
scanner layers that returned `?Match` by value, so the compiler built the
result in a stack temporary and copied roughly 56 bytes into the dispatch's
return slot before the caller saw it.

## Change

- Distinct-first alternations get their own fast kind
  (`literal_multi_distinct`), so the dispatch no longer reloads and tests the
  filter's `shared_first` flag per search. The distinct scanner returns a
  `bool` after writing the slots and the dispatch constructs the `Match`
  directly from those slots, removing the temporary and the copy.
- The pair-set, single-byte and case-folded set scanners return `bool` the
  same way.
- Shared-first alternations keep their existing scanner and `?Match` return:
  their verification loop already pins the branch, and the split kind lets
  the dispatch call it directly without the per-search flag test.

The slots written by the scanners are the same ones the `Match` exposes, so
`Match.group`, replacement and iteration see identical data. The kind split
is decided once at workspace construction from the immutable filter.

## Measurements

The comparison harness runs the same workloads as
[the Rust comparison](rust-comparison.md). Six executions were interleaved in
alternating order (three rounds `before, after` and three rounds `after,
before`); the table reports medians across those executions. Raw samples and
executable SHA-256 identities are in
[`literal-set-spans.json`](literal-set-spans.json).

| Case | Before, ns/iter | After, ns/iter | Change |
| --- | ---: | ---: | ---: |
| find alternation (5 words) | 120,653.4 | 103,574.7 | 1.17x faster |
| find 10-word alternation | 209,539.6 | 185,322.3 | 1.13x faster |
| find 20-word alternation | 207,829.9 | 184,680.8 | 1.13x faster |
| find (?i) alternation | 81,625.2 | 72,806.0 | 1.12x faster |
| find one-char alternation | 12,647.8 | 11,986.2 | 1.06x faster |
| find shared-prefix alternation | 23,899.3 | 22,227.0 | 1.08x faster |

An isolated benchmark that only times `find` loops reproduces the alternation
gains (5-word 1.12x, 10-word 1.12x, 20-word 1.10x) and leaves the unrelated
scanners unchanged.

The host was shared and noisy; cases that do not use these scanners moved by
up to 1.09x in the same sweep (`replaceAll \A|\z`, `RegexSet`), which bounds
the noise floor. The alternation gains are consistent across both harnesses
and every batch.

## Validation

```sh
zig build test-lib
python3 tools/fuzz/run.py --cases 400 --seed 20261125
python3 tools/fuzz/replace.py --cases 200 --seed 20261125
python3 tools/bench/check.py --runs 2
```

The full test suite, both differential fuzzers and the 67-case benchmark gate
pass.
