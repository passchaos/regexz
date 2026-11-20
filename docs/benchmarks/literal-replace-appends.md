# Capacity-guaranteed appends in literal replacement

Baseline: `e5ea666`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceLiteral` reserved `input.len` bytes and then used the growing
`appendSlice` for every gap and substitution. When the substitution is no
longer than the literal, the output never exceeds the input, so the
reservation always suffices. Those appends now use the assume-capacity
variants.

## Measurements

A controlled harness replaces `the` with `X` on the 216 KiB word text (4,000
occurrences), 1,000 iterations per execution. Five executions were
interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `the` -> `X` | 75,279.9 | 69,487.8 | 1.08x |

Raw samples and executable SHA-256 identities are in
[`literal-replace-appends.json`](literal-replace-appends.json).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replace' --summary all
python3 tools/fuzz/replace.py --cases 300 --seed 811
zig fmt --check src/regex/replace.zig
```
