# Exact-size replacement for edge-only zero-width patterns

Baseline: `a3c2721`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceAll` on a zero-width pattern such as `\A|\z` grew an ArrayList: the
first substitution allocated a tiny buffer, the input copy reallocated, the
trailing substitution grew again, and `toOwnedSlice` could shrink.

When every zero-width path asserts only text edges (`start_text`, `end_text`,
`end_text_or_newline`), the match set is bounded by the text start, the final
newline and the text end. `replaceAll` now computes the exact length,
allocates once and writes once for those plans.

## Measurements

The comparison harness (`tools/compare/zig_regex.zig`) was compiled for both
trees and executed alternately before/after five times:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `\A|\z` -> `X` | 8,801.7 | 6,113.1 | 1.44x |

The other 18 comparison cases keep a 1.06x median. Raw samples and executable
SHA-256 identities are in
[`edge-zero-replace.json`](edge-zero-replace.json).

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/replace.py --cases 300 --seed 617
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig
```

The replacement fuzzer covers zero-width patterns with capture slots and
substitution expansion; the full suite covers line-edge plans that stay on
the general path.
