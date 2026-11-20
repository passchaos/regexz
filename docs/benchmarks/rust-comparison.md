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
| compile Qwen tokenizer | 37,058.9 | 430,490.8 | 11.62x |
| compile xDS-like | 2,518.8 | 21,319.2 | 8.46x |
| find Qwen tokenizer | 43,761.7 | 63,466.7 | 1.45x |
| findAll Qwen, borrowed workspace | 44,855.8 | 64,204.2 | 1.43x |
| findAll Qwen, owning iterator | 43,351.7 | 65,675.8 | 1.51x |
| find CJK tokenizer | 175,058.3 | 226,728.3 | 1.30x |
| find HTML tag | 49,092.7 | 129,262.7 | 2.63x |
| find URL | 33,385.2 | 82,840.0 | 2.48x |
| find JSON string literal | 7,243.1 | 17,733.3 | 2.45x |
| find JSON number | 28,294.4 | 62,109.2 | 2.20x |
| find word boundary | 63,863.3 | 135,928.8 | 2.13x |
| split whitespace (22 KiB) | 19,506.3 | 76,616.5 | 3.93x |
| split commas (29 KiB) | 33,747.3 | 55,859.6 | 1.66x |
| fullmatch literal | 1.8 | 9.3 | 5.17x |
| fullmatch class | 5.3 | 33.5 | 6.32x |
| fullmatch xDS-like | 9.7 | 30.2 | 3.11x |
| replaceAll `a+` → `x` | 28,269.6 | 104,421.0 | 3.69x |
| replaceAll `\A|\z` → `X` | 5,335.2 | 8,002.1 | 1.50x |
| RegexSet 9 no-match patterns | 9,395.6 | 39,590.4 | 4.21x |

regexz is faster on all 20 measured cases: 11.62x on tokenizer compilation,
8.46x on a small-pattern compile, 1.30–1.51x on tokenizer scans and match
iteration, 2.13–2.63x on search scans, 1.66–3.93x on splits, 3.11–6.32x on
full-match calls, 3.69x on a set-run replacement, 1.50x on a zero-width
replacement and 4.21x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 11.62x and the xDS-like compile to 8.46x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).

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
