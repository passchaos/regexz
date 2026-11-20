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
| compile Qwen tokenizer | 38,657.8 | 468,293.2 | 12.11x |
| compile xDS-like | 2,600.6 | 21,445.0 | 8.25x |
| find Qwen tokenizer | 43,050.8 | 64,995.0 | 1.51x |
| findAll Qwen, borrowed workspace | 43,101.7 | 65,169.2 | 1.51x |
| findAll Qwen, owning iterator | 45,323.3 | 66,326.7 | 1.46x |
| find CJK tokenizer | 163,905.0 | 227,400.0 | 1.39x |
| find HTML tag | 48,073.3 | 120,332.1 | 2.50x |
| find URL | 34,216.0 | 84,839.4 | 2.48x |
| find JSON string literal | 7,078.5 | 17,150.8 | 2.42x |
| find JSON number | 27,588.1 | 61,468.8 | 2.23x |
| find word boundary | 64,136.0 | 134,567.5 | 2.10x |
| split whitespace (22 KiB) | 21,303.8 | 80,988.1 | 3.80x |
| split commas (29 KiB) | 22,529.0 | 55,773.5 | 2.48x |
| fullmatch literal | 1.8 | 9.4 | 5.22x |
| fullmatch class | 5.1 | 33.7 | 6.61x |
| fullmatch xDS-like | 9.5 | 32.0 | 3.37x |
| replaceAll `a+` → `x` | 29,140.0 | 106,529.6 | 3.66x |
| replaceAll `\A|\z` → `X` | 6,855.6 | 7,921.9 | 1.16x |
| RegexSet 9 no-match patterns | 1,934.2 | 40,189.6 | 20.78x |

regexz is faster on all 19 measured cases: 12.11x on tokenizer compilation,
8.25x on a small-pattern compile, 1.39–1.51x on tokenizer scans and match
iteration, 2.10–2.50x on search scans, 2.48–3.80x on splits, 3.37–6.61x on
full-match calls, 3.66x on a set-run replacement, 1.16x on a zero-width
replacement and 20.78x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 12.11x and the xDS-like compile to 8.25x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 20.78x. Single-byte literal replacement and
splitting translate in vectors (see
[literal byte paths](literal-byte-paths.md)), which lifted the comma split
from 1.64x to 2.48x. Non-ASCII fast-branch runs are scanned once (see
[direct non-ASCII run starts](nonascii-run-start.md)), which kept the CJK
tokenizer at 1.39x as both sides got faster.

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
