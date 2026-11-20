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
| compile Qwen tokenizer | 59,384.7 | 473,774.3 | 7.98x |
| compile xDS-like | 2,486.6 | 22,207.4 | 8.93x |
| find Qwen tokenizer | 46,943.3 | 69,288.3 | 1.48x |
| findAll Qwen, borrowed workspace | 47,542.5 | 69,075.0 | 1.45x |
| findAll Qwen, owning iterator | 47,933.3 | 69,788.3 | 1.46x |
| find CJK tokenizer | 190,644.2 | 261,663.3 | 1.37x |
| find HTML tag | 51,345.4 | 136,064.6 | 2.65x |
| find URL | 37,189.2 | 96,370.2 | 2.59x |
| find JSON string literal | 7,825.2 | 18,972.9 | 2.42x |
| find JSON number | 28,570.0 | 66,557.9 | 2.33x |
| find word boundary | 68,839.4 | 141,351.2 | 2.05x |
| split whitespace (22 KiB) | 21,613.1 | 81,796.5 | 3.78x |
| split commas (29 KiB) | 35,349.6 | 58,306.2 | 1.65x |
| fullmatch literal | 2.0 | 9.6 | 4.80x |
| fullmatch class | 6.2 | 36.7 | 5.92x |
| fullmatch xDS-like | 12.1 | 33.0 | 2.73x |
| replaceAll `a+` → `x` | 30,552.7 | 108,445.8 | 3.55x |
| replaceAll `\A|\z` → `X` | 7,712.3 | 8,256.9 | 1.07x |
| RegexSet 9 no-match patterns | 10,141.0 | 40,259.8 | 3.97x |

regexz is faster on all 20 measured cases: 7.98x on tokenizer compilation,
8.93x on a small-pattern compile, 1.37–1.48x on tokenizer scans and match
iteration, 2.05–2.65x on search scans, 1.65–3.78x on splits, 2.73–5.92x on
full-match calls, 3.55x on a set-run replacement, 1.07x on a zero-width
replacement and 3.97x on the nine-pattern set.

Compilation now reuses the fixed compile block for page-allocator regexes
(see [reusing the compile block](compile-block-pool.md)) and compiles long
patterns in an arena (see
[arena compilation for long patterns](compile-arena-long-patterns.md)), which
lifted the xDS-like compile from 5.13x to 8.93x. The tokenizer fast branch
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
