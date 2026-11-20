# Single-byte literal replace and split

Baseline: `eb6469d`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The literal replacement path scanned with `indexOfLiteral` and copied each gap
and each substitution with `@memcpy`. For a dense one-byte pattern such as `,`
that is two small runtime-length copies per occurrence, about 6,000 on the
29 KiB CSV input.

`replaceAll`, `replacen`, `replaceAllLen` and `replaceAllInto` now special-case
a one-byte literal:

- with a one-byte substitution the output length equals the input length, so
  the whole pass is one 16-byte vector translate (`@select`) instead of a
  search plus two copies per occurrence;
- `replaceAllLen` counts occurrences with a vector popcount instead of a
  search per occurrence;
- `replacen` takes the translate path when the limit covers every occurrence.

`Regex.split` and `splitn` now probe 16 bytes with a scalar loop around each
position before falling back to the generic search for a one-byte literal;
CSV-like delimiters sit close together.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`literal-byte-paths.json`](literal-byte-paths.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `,` → `;` | 41,032.7 | 3,096.9 | 13.25x |
| replacen `,` → `;` (limit 10000) | 40,060.2 | 4,087.1 | 9.80x |
| replaceAllLen `,` (29 KiB) | 21,851.5 | 1,071.0 | 20.40x |
| replaceAllInto `,` (29 KiB) | 31,855.2 | 490.4 | 64.96x |
| split commas (29 KiB) | 35,546.0 | 20,686.5 | 1.72x |
| replaceAll `a+` control | 26,044.0 | 25,269.8 | 1.03x |
| split whitespace control | 21,541.7 | 19,775.2 | 1.09x |

Across the 62 non-target cases the median speedup is 1.00x and the geometric
mean 1.03x; none is below 0.90x. The `a+` cases keep the existing set-run
replacement path.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replace' --summary all
zig build test-lib -Dtest-filter='split' --summary all
python3 tools/fuzz/replace.py --cases 300 --seed 727
python3 tools/fuzz/run.py --cases 100 --seed 727
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig src/regex/replace.zig
```

The replacement fuzzer diffs every output byte against the reference engine
over 5,700 comparisons; the split tests cover leading, trailing and consecutive
delimiters.
