# CamelCase dedicated walk

Baseline: `6c4d911`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`[a-z]+[A-Z][a-z]+` was the thinnest comparison case (1.14x ahead of Rust).
The unbounded-chain walk handled it generically: per match it dispatched three
elements through the literal/run/single-set checks, reloaded the state
elements and range bounds, and carried the `index == 0` bookkeeping. A
profile attributed about 21% of the scan to the first lower-run loop, 18% to
the element dispatch, 9% to the first-byte table, and 12% to the dispatch
entry itself.

## Change

`UnboundedSequenceState` now recognizes the exact camel shape at build time:

- exactly three elements,
- the first and third are the same contiguous ASCII run with minimum one,
- the middle is one contiguous ASCII set disjoint from the run (the builder
  already rejects overlapping shapes).

The dedicated walk scans the lower run with the range check, tests the upper
byte with a second range check, requires at least one lower byte and extends
the second lower run. A failed start skips the whole first run, exactly like
the generic walk, because every start inside it shares the run end. Other
unbounded chains keep the generic walk.

## Measurements

The comparison harness runs the same workloads as
[the Rust comparison](rust-comparison.md). Six executions were interleaved in
alternating order (three rounds `before, after` and three rounds `after,
before`); the table reports medians across those executions. Raw samples and
executable SHA-256 identities are in [`camel-walk.json`](camel-walk.json).

| Case | Before, ns/iter | After, ns/iter | Change |
| --- | ---: | ---: | ---: |
| find camelCase | 87,227.1 | 69,642.8 | 1.25x faster |

An isolated `find` loop on the same input measured 82.4 us -> 62.5 us (1.32x)
with every other isolated case neutral.

The shared host was noisy (load average above 12): cases that do not use the
camel walk moved by up to 1.25x in the same sweep (`replaceAll \A|\z`,
`fullmatch xDS-like`, `split whitespace`), which bounds the noise floor. The
camel gain repeats in both harnesses and every round.

## Validation

```sh
zig build test-lib
python3 tools/fuzz/run.py --cases 400 --seed 20261126
python3 tools/fuzz/replace.py --cases 200 --seed 20261126
python3 tools/bench/check.py --runs 2
```

New span tests cover uppercase runs (`fooBARbaz`), a single-letter prefix
(`xAb`), a following capitalised word (`aBcDe`) and a non-ASCII prefix
(`éFooBar`). The full test suite, both differential fuzzers and the 67-case
benchmark gate pass.
