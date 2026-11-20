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
| compile Qwen tokenizer | 89,418.2 | 640,264.8 | 7.16x |
| find Qwen tokenizer | 67,065.0 | 90,119.2 | 1.34x |
| find CJK tokenizer | 240,210.8 | 395,435.0 | 1.65x |
| find HTML tag | 60,277.5 | 178,094.2 | 2.95x |
| find URL | 42,538.5 | 131,715.6 | 3.10x |
| find JSON string literal | 8,299.8 | 23,814.0 | 2.87x |
| find JSON number | 39,652.1 | 89,107.5 | 2.25x |
| find word boundary | 78,983.5 | 201,496.7 | 2.55x |
| fullmatch literal | 2.7 | 10.5 | 3.89x |
| fullmatch class | 6.9 | 47.7 | 6.91x |
| fullmatch xDS-like | 19.3 | 51.6 | 2.67x |
| replaceAll `a+` → `x` | 33,508.8 | 145,517.5 | 4.34x |
| replaceAll `\A|\z` → `X` | 7,041.3 | 12,018.5 | 1.71x |
| RegexSet 9 no-match patterns | 12,344.4 | 49,323.1 | 4.00x |

regexz is faster on every measured case: 7.16x on tokenizer compilation,
1.34–1.65x on tokenizer scans, 2.25–3.10x on search scans, 2.67–6.91x on
full-match calls, 4.34x on a set-run replacement and 4.00x on the
nine-pattern set.

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
