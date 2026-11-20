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

A controlled harness calls `Workspace.replaceAll` on a 22 KiB input with a
fixed workspace, 200,000 iterations per execution. Five executions were
interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll zero-width | 3,825.2 | 3,487.4 | 1.10x |

The comparison harness (`Regex.replaceAll`, which also creates a workspace per
call) is allocation-noise-dominated for this case: repeated seven-round runs
measured 0.86x, 1.10x and 1.44x on the same sources. The controlled harness
keeps the workspace fixed, so it measures the write path itself and is
stable. Raw samples and executable SHA-256 identities are in
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
