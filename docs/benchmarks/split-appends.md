# Capacity-guaranteed appends in split

Baseline: `e1da85e`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`splitAsciiSet` and `splitLiteral` reserved `input.len / 8 + 1` parts and
then used the growing `append` for every part, so the list usually grew once
on the 22-29 KiB benchmarks. The reserve is now `input.len / 4 + 1` (capped
at 8192), which covers the dense-separator cases, and the hot appends use
`appendAssumeCapacity` with a capacity check only when the list fills.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| split whitespace (22 KiB) | 20,009.6 | 18,164.6 | 1.10x |
| split commas (29 KiB) | 19,768.1 | 17,071.7 | 1.16x |

Across the 65 control cases the median speedup is 1.00x; the sub-0.90 rows
are unchanged paths (a length writer, a line-delimited scan and the star
stream) measured during a slight host drift. Raw samples and executable
SHA-256 identities are in [`split-appends.json`](split-appends.json).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='split' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 877
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig
```
