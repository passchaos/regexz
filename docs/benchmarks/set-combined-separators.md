# Combined separator scan for `RegexSet`

Baseline: `4938f3c`, macOS ARM64, Zig 0.16.0 ReleaseFast.

A `RegexSet` whose patterns are all simple chains (`set+ separator`, such as
`[a-z]+@`) decides each pattern with its own separator scan. The nine-pattern
benchmark therefore scanned the same 22 KiB input once per pattern.

`RegexSet.init` now recognizes a set where every pattern is a chain with a
single-byte literal separator, no trailing run or tail, an unbounded `set_a`
run, and a distinct ASCII-only `set_a`, and builds one combined filter:

- a separator-byte to pattern-index map;
- a nibble-table candidate filter over the separator bytes (two table lookups
  per 16 bytes on ARM64, with a byte-splat fallback on other targets);
- each pattern's `set_a` and `min_a`.

`matchesAt` scans the input once in 64-byte blocks, extracts the separator
lanes, and checks the `set_a` run before each candidate, floored at the search
offset. Patterns drop out as they match and the scan stops once all of them
have. Sets that do not qualify (set-run separators, trailing runs or tails,
fixed-count runs, duplicate separators, non-ASCII `set_a`) keep the per-pattern
searches.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`set-combined-separators.json`](set-combined-separators.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| RegexSet 9 no-match patterns | 9,511.3 | 1,992.7 | 4.77x |
| find Qwen tokenizer control | 43,555.8 | 44,425.8 | 0.98x |
| findAll Qwen, owning iterator control | 46,220.8 | 46,205.8 | 1.00x |
| find CJK tokenizer control | 178,970.8 | 181,170.0 | 0.99x |
| split whitespace control | 19,830.0 | 19,095.6 | 1.04x |
| replaceAllLen `a+` control | 11,411.0 | 12,088.8 | 0.94x |

The nine-pattern set improves in every round (8.7–10.0 us before, 1.9–2.5 us
after). Across all 66 non-target cases the median speedup is 1.00x and the
geometric mean 0.996x, so the change is neutral outside the set path; the
`replaceAllLen` control sits inside the host's usual variance.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='regex set' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 493
python3 tools/fuzz/run.py --cases 100 --seed 493
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/set.zig src/regex/nibble_filter.zig src/regex/set_tests.zig
```

The set tests cover the combined scan's matches, non-matches, search offsets,
short result buffers and the fallback sets, plus a randomized comparison
against per-pattern workspaces over ASCII, non-ASCII and invalid UTF-8 input.
