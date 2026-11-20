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
| compile Qwen tokenizer | 75,087.5 | 576,851.8 | 7.68x |
| compile xDS-like | 5,482.0 | 27,045.4 | 4.93x |
| find Qwen tokenizer | 65,626.7 | 78,330.0 | 1.19x |
| findAll Qwen, borrowed workspace | 65,677.5 | 80,819.2 | 1.23x |
| findAll Qwen, owning iterator | 68,230.8 | 77,995.8 | 1.14x |
| find CJK tokenizer | 216,050.0 | 296,150.8 | 1.37x |
| find HTML tag | 56,468.3 | 158,465.4 | 2.81x |
| find URL | 39,948.8 | 112,293.1 | 2.81x |
| find JSON string literal | 8,345.4 | 21,805.6 | 2.61x |
| find JSON number | 32,067.3 | 83,033.5 | 2.59x |
| find word boundary | 74,522.3 | 173,043.1 | 2.32x |
| split whitespace (22 KiB) | 22,577.9 | 98,208.3 | 4.35x |
| split commas (29 KiB) | 37,827.3 | 63,770.0 | 1.69x |
| fullmatch literal | 2.5 | 11.5 | 4.60x |
| fullmatch class | 6.8 | 42.9 | 6.31x |
| fullmatch xDS-like | 15.9 | 41.6 | 2.62x |
| replaceAll `a+` → `x` | 33,359.6 | 133,746.2 | 4.01x |
| replaceAll `\A|\z` → `X` | 7,398.5 | 10,885.2 | 1.47x |
| RegexSet 9 no-match patterns | 12,077.1 | 46,364.0 | 3.84x |

regexz is faster on all 20 measured cases: 7.68x on tokenizer compilation,
4.93x on a small-pattern compile, 1.14–1.37x on tokenizer scans and match
iteration, 2.32–2.81x on search scans, 1.69–4.35x on splits, 2.62–6.31x on
full-match calls, 4.01x on a set-run replacement, 1.47x on a zero-width
replacement and 3.84x on the nine-pattern set.

The owning `Regex.findAll` iterator used to trail Rust (0.25x) because Rust's
`find_iter` reuses a thread-local cache pool while regexz built a workspace
per call. The owning iterator now returns its workspace to a process pool for
page/smp allocators, so repeated iteration starts warm: it improved 1.91x and
is ahead of Rust (1.14x). `Regex.findAllWith` still exposes the explicit
caller-workspace form. See
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
