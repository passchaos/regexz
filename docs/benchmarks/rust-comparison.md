# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the two binaries were executed alternately, before/after and
after/before, five times. The table reports medians across those executions.
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, a 24 KiB replacement text and small full-match
subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 82,927.4 | 622,786.7 | 7.51x |
| compile xDS-like | 5,933.9 | 28,969.2 | 4.88x |
| find Qwen tokenizer | 73,728.3 | 91,090.8 | 1.24x |
| find CJK tokenizer | 239,203.3 | 363,207.5 | 1.52x |
| find HTML tag | 57,973.3 | 171,825.4 | 2.96x |
| find URL | 44,673.8 | 130,897.9 | 2.93x |
| find JSON string literal | 8,683.1 | 23,684.6 | 2.73x |
| find JSON number | 34,332.9 | 91,699.8 | 2.67x |
| find word boundary | 86,770.8 | 196,651.0 | 2.27x |
| fullmatch literal | 2.8 | 11.9 | 4.25x |
| fullmatch class | 7.4 | 45.9 | 6.20x |
| fullmatch xDS-like | 17.8 | 52.0 | 2.92x |
| replaceAll `a+` → `x` | 34,854.2 | 147,621.2 | 4.24x |
| replaceAll `\A|\z` → `X` | 7,112.9 | 11,981.9 | 1.68x |
| RegexSet 9 no-match patterns | 12,594.2 | 50,750.0 | 4.03x |

regexz is faster on every measured case: 7.51x on tokenizer compilation,
4.88x on a small-pattern compile, 1.24–1.52x on tokenizer scans, 2.27–2.96x on
search scans, 2.92–6.20x on full-match calls, 4.24x on a set-run replacement,
1.68x on a zero-width replacement and 4.03x on the nine-pattern set.

Caveats: the iteration APIs are the natural ones for each library
(`Workspace.find` in a loop versus `Regex::find_iter`), full match is
`Regex::find` plus a bounds check on the Rust side, the word-boundary case
uses `(?-u:\b\w+\b)` so both engines apply ASCII word rules, the allocators
differ (regexz uses the page allocator in these runs, Rust the system
allocator), and the tokenizer comparison uses Rust's default Unicode classes
with regexz's `unicode_perl_space` limit. The shared host is noisy; single
runs vary more than the interleaved medians above. These numbers cover the
listed workloads, not every regex feature: Rust supports more Unicode
word-boundary and property syntax, while regexz's extended mode covers
lookaround, backreferences and conditionals that Rust's `regex` rejects.

Reproduce:

```sh
zig build-exe -O ReleaseFast --dep regexz \
    -Mroot=tools/compare/zig_regex.zig -Mregexz=src/root.zig \
    -femit-bin=/tmp/regexz-compare
/tmp/regexz-compare

cd tools/compare/rust_regex
cargo run --release
```
