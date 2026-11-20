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
| compile Qwen tokenizer | 77,527.8 | 616,670.2 | 7.95x |
| compile xDS-like | 5,460.5 | 27,356.0 | 5.01x |
| find Qwen tokenizer | 63,810.0 | 90,535.8 | 1.42x |
| findAll Qwen, borrowed workspace | 70,414.2 | 90,211.7 | 1.28x |
| findAll Qwen, fresh workspace | 350,926.7 | 90,578.3 | 0.26x |
| find CJK tokenizer | 223,910.0 | 349,015.8 | 1.56x |
| find HTML tag | 54,477.9 | 168,392.3 | 3.09x |
| find URL | 43,698.5 | 121,389.8 | 2.78x |
| find JSON string literal | 8,095.8 | 22,655.8 | 2.80x |
| find JSON number | 31,845.2 | 82,815.8 | 2.60x |
| find word boundary | 80,688.1 | 179,844.4 | 2.23x |
| fullmatch literal | 2.5 | 11.1 | 4.44x |
| fullmatch class | 6.9 | 44.8 | 6.49x |
| fullmatch xDS-like | 19.7 | 47.6 | 2.42x |
| replaceAll `a+` → `x` | 31,926.0 | 135,836.0 | 4.25x |
| replaceAll `\A|\z` → `X` | 6,820.6 | 12,334.8 | 1.81x |
| RegexSet 9 no-match patterns | 12,224.0 | 44,833.1 | 3.67x |

regexz is faster on 17 of the 18 measured cases: 7.95x on tokenizer
compilation, 5.01x on a small-pattern compile, 1.28–1.56x on tokenizer scans,
2.23–3.09x on search scans, 2.42–6.49x on full-match calls, 4.25x on a set-run
replacement, 1.81x on a zero-width replacement and 3.67x on the nine-pattern
set.

The exception is a fresh `findAll` per call (0.26x): Rust's `find_iter` reuses
a thread-local cache pool, while regexz's owning iterator builds a workspace
and pays the lazy search-DFA preparation on every call. `Regex.findAllWith`
with a caller-owned workspace reuses the warmed caches, restores the lead over
Rust (1.28x) and matches a manual `Workspace.find` loop. See
[reusing a workspace for match iteration](find-all-workspace.md).

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
