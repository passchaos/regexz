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
| compile Qwen tokenizer | 46,432.3 | 587,732.2 | 12.66x |
| compile xDS-like | 2,913.9 | 27,692.6 | 9.50x |
| find Qwen tokenizer | 48,171.7 | 84,670.0 | 1.76x |
| findAll Qwen, borrowed workspace | 49,666.7 | 84,565.8 | 1.70x |
| findAll Qwen, owning iterator | 51,822.5 | 85,092.5 | 1.64x |
| find CJK tokenizer | 200,899.2 | 341,878.3 | 1.70x |
| find HTML tag | 53,377.5 | 158,666.0 | 2.97x |
| find URL | 39,431.7 | 117,490.2 | 2.98x |
| find JSON string literal | 7,863.1 | 22,189.0 | 2.82x |
| find JSON number | 31,038.3 | 81,100.0 | 2.61x |
| find word boundary | 73,657.1 | 173,525.0 | 2.36x |
| split whitespace (22 KiB) | 22,403.1 | 93,095.6 | 4.16x |
| split commas (29 KiB) | 37,335.8 | 61,387.7 | 1.64x |
| fullmatch literal | 2.4 | 11.2 | 4.67x |
| fullmatch class | 6.2 | 40.0 | 6.45x |
| fullmatch xDS-like | 15.0 | 41.0 | 2.73x |
| replaceAll `a+` → `x` | 30,110.2 | 123,228.1 | 4.09x |
| replaceAll `\A|\z` → `X` | 7,616.0 | 10,023.8 | 1.32x |
| RegexSet 9 no-match patterns | 2,806.0 | 44,400.4 | 15.82x |

regexz is faster on all 19 measured cases: 12.66x on tokenizer compilation,
9.50x on a small-pattern compile, 1.64–1.76x on tokenizer scans and match
iteration, 2.36–2.98x on search scans, 1.64–4.16x on splits, 2.73–6.45x on
full-match calls, 4.09x on a set-run replacement, 1.32x on a zero-width
replacement and 15.82x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 12.66x and the xDS-like compile to 9.50x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 15.82x.

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
