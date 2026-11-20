# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the two binaries were executed alternately, before/after and
after/before, seven times. The table reports medians across those executions.
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 60,810.8 | 488,320.5 | 8.03x |
| compile xDS-like | 4,567.9 | 23,623.0 | 5.17x |
| find Qwen tokenizer | 45,788.3 | 68,251.7 | 1.49x |
| findAll Qwen, borrowed workspace | 47,202.5 | 71,371.7 | 1.51x |
| findAll Qwen, owning iterator | 47,613.3 | 72,946.7 | 1.53x |
| find CJK tokenizer | 201,155.8 | 249,840.0 | 1.24x |
| find HTML tag | 51,064.2 | 140,998.5 | 2.76x |
| find URL | 36,084.6 | 98,598.1 | 2.73x |
| find JSON string literal | 7,793.8 | 18,843.5 | 2.42x |
| find JSON number | 29,770.6 | 69,432.7 | 2.33x |
| find word boundary | 65,959.2 | 148,101.5 | 2.25x |
| split whitespace (22 KiB) | 19,623.5 | 86,065.0 | 4.39x |
| split commas (29 KiB) | 34,757.3 | 59,205.8 | 1.70x |
| fullmatch literal | 1.9 | 10.2 | 5.37x |
| fullmatch class | 5.5 | 36.8 | 6.69x |
| fullmatch xDS-like | 10.5 | 33.3 | 3.17x |
| replaceAll `a+` → `x` | 27,057.1 | 111,999.8 | 4.14x |
| replaceAll `\A|\z` → `X` | 5,434.4 | 8,088.8 | 1.49x |
| RegexSet 9 no-match patterns | 9,935.2 | 41,566.7 | 4.18x |

regexz is faster on all 20 measured cases: 8.03x on tokenizer compilation,
5.17x on a small-pattern compile, 1.24–1.53x on tokenizer scans and match
iteration, 2.25–2.76x on search scans, 1.70–4.39x on splits, 3.17–6.69x on
full-match calls, 4.14x on a set-run replacement, 1.49x on a zero-width
replacement and 4.18x on the nine-pattern set.

The tokenizer fast branch now scans the following digit and punctuation
branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)), which lifted the Qwen
scan from 1.19x to 1.49x. The owning `Regex.findAll` iterator returns its
workspace to a process pool for page/smp allocators, so repeated iteration
starts warm and is 1.53x ahead of Rust's `find_iter`; `Regex.findAllWith`
still exposes the explicit caller-workspace form. See
[match iteration workspaces](find-all-workspace.md).

Caveats: the iteration APIs are the natural ones for each library
(`Workspace.find` in a loop versus `Regex::find_iter`), full match is
`Regex::find` plus a bounds check on the Rust side, the word-boundary case
uses `(?-u:\b\w+\b)` so both engines apply ASCII word rules, the split
comparison collects Rust's iterator into a `Vec` so both sides allocate the
parts array, the allocators differ (regexz uses the page allocator in these
runs, Rust the system allocator), and the tokenizer comparison uses Rust's
default Unicode classes with regexz's `unicode_perl_space` limit. The shared
host is noisy; single runs vary more than the interleaved medians above. These
numbers cover the listed workloads, not every regex feature: Rust supports
more Unicode word-boundary and property syntax, while regexz's extended mode
covers lookaround, backreferences and conditionals that Rust's `regex`
rejects.

Reproduce:

```sh
zig build-exe -O ReleaseFast --dep regexz \
    -Mroot=tools/compare/zig_regex.zig -Mregexz=src/root.zig \
    -femit-bin=/tmp/regexz-compare
/tmp/regexz-compare

cd tools/compare/rust_regex
cargo run --release
```
