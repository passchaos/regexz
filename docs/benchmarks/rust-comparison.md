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
| compile Qwen tokenizer | 66,207.3 | 497,752.2 | 7.52x |
| compile xDS-like | 4,755.8 | 24,406.3 | 5.13x |
| find Qwen tokenizer | 49,322.5 | 76,980.0 | 1.56x |
| findAll Qwen, borrowed workspace | 51,144.2 | 78,377.5 | 1.53x |
| findAll Qwen, owning iterator | 52,070.0 | 79,098.3 | 1.52x |
| find CJK tokenizer | 205,280.8 | 291,070.0 | 1.42x |
| find HTML tag | 53,929.4 | 143,584.8 | 2.66x |
| find URL | 40,142.7 | 98,851.5 | 2.46x |
| find JSON string literal | 8,526.7 | 20,689.6 | 2.43x |
| find JSON number | 31,017.1 | 72,961.7 | 2.35x |
| find word boundary | 73,233.3 | 149,178.8 | 2.04x |
| split whitespace (22 KiB) | 21,440.2 | 85,524.8 | 3.99x |
| split commas (29 KiB) | 35,854.0 | 59,086.5 | 1.65x |
| fullmatch literal | 2.3 | 10.2 | 4.43x |
| fullmatch class | 6.5 | 37.1 | 5.71x |
| fullmatch xDS-like | 13.9 | 36.4 | 2.62x |
| replaceAll `a+` → `x` | 28,783.1 | 113,339.2 | 3.94x |
| replaceAll `\A|\z` → `X` | 6,769.2 | 8,736.9 | 1.29x |
| RegexSet 9 no-match patterns | 10,852.9 | 40,681.7 | 3.75x |

regexz is faster on all 20 measured cases: 7.52x on tokenizer compilation,
5.13x on a small-pattern compile, 1.42–1.56x on tokenizer scans and match
iteration, 2.04–2.66x on search scans, 1.65–3.99x on splits, 2.62–5.71x on
full-match calls, 3.94x on a set-run replacement, 1.29x on a zero-width
replacement and 3.75x on the nine-pattern set.

The tokenizer fast branch now scans the following digit and punctuation
branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)), which lifted the Qwen
scan to 1.56x. The owning `Regex.findAll` iterator returns its workspace to a
process pool for page/smp allocators, so repeated iteration starts warm and is
1.52x ahead of Rust's `find_iter`; `Regex.findAllWith` still exposes the
explicit caller-workspace form. See
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
