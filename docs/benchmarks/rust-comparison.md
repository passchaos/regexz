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
| compile Qwen tokenizer | 38,263.7 | 472,730.8 | 12.35x |
| compile xDS-like | 2,576.0 | 22,689.5 | 8.81x |
| find Qwen tokenizer | 44,383.3 | 68,410.8 | 1.54x |
| findAll Qwen, borrowed workspace | 44,340.0 | 67,263.3 | 1.52x |
| findAll Qwen, owning iterator | 45,666.7 | 70,973.3 | 1.55x |
| find CJK tokenizer | 182,100.0 | 251,277.5 | 1.38x |
| find HTML tag | 48,653.8 | 127,847.3 | 2.63x |
| find URL | 35,961.3 | 92,186.7 | 2.56x |
| find JSON string literal | 7,579.6 | 18,234.2 | 2.41x |
| find JSON number | 28,531.9 | 64,954.6 | 2.28x |
| find word boundary | 65,742.7 | 152,074.6 | 2.31x |
| split whitespace (22 KiB) | 22,190.8 | 82,348.8 | 3.71x |
| split commas (29 KiB) | 21,928.5 | 56,490.8 | 2.58x |
| fullmatch literal | 1.8 | 9.6 | 5.33x |
| fullmatch class | 5.5 | 34.0 | 6.18x |
| fullmatch xDS-like | 10.9 | 32.3 | 2.96x |
| replaceAll `a+` → `x` | 28,359.8 | 109,363.1 | 3.86x |
| replaceAll `\A|\z` → `X` | 6,970.0 | 8,884.8 | 1.27x |
| RegexSet 9 no-match patterns | 1,976.7 | 40,598.5 | 20.54x |

regexz is faster on all 19 measured cases: 12.35x on tokenizer compilation,
8.81x on a small-pattern compile, 1.38–1.55x on tokenizer scans and match
iteration, 2.28–2.63x on search scans, 2.58–3.71x on splits, 2.96–6.18x on
full-match calls, 3.86x on a set-run replacement, 1.27x on a zero-width
replacement and 20.54x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 12.35x and the xDS-like compile to 8.81x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 20.54x. Single-byte literal replacement and
splitting translate in vectors (see
[literal byte paths](literal-byte-paths.md)), which lifted the comma split
from 1.64x to 2.58x.

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
