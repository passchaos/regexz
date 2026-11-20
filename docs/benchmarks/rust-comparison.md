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
| compile Qwen tokenizer | 65,967.3 | 512,282.8 | 7.77x |
| compile xDS-like | 4,597.3 | 23,629.6 | 5.14x |
| find Qwen tokenizer | 58,700.8 | 73,080.8 | 1.24x |
| findAll Qwen, borrowed workspace | 60,432.5 | 74,121.7 | 1.23x |
| findAll Qwen, fresh workspace | 119,738.3 | 76,884.2 | 0.64x |
| find CJK tokenizer | 187,660.0 | 271,450.0 | 1.45x |
| find HTML tag | 51,163.3 | 143,051.0 | 2.80x |
| find URL | 38,075.8 | 100,283.8 | 2.63x |
| find JSON string literal | 7,904.8 | 19,849.4 | 2.51x |
| find JSON number | 29,882.7 | 70,682.5 | 2.37x |
| find word boundary | 71,860.8 | 152,073.5 | 2.12x |
| split whitespace (22 KiB) | 20,813.5 | 86,030.8 | 4.13x |
| split commas (29 KiB) | 35,362.1 | 57,285.0 | 1.62x |
| fullmatch literal | 2.2 | 9.9 | 4.50x |
| fullmatch class | 5.9 | 37.1 | 6.29x |
| fullmatch xDS-like | 13.9 | 35.3 | 2.54x |
| replaceAll `a+` → `x` | 28,417.1 | 116,394.0 | 4.10x |
| replaceAll `\A|\z` → `X` | 5,941.7 | 9,657.5 | 1.63x |
| RegexSet 9 no-match patterns | 10,695.4 | 41,169.2 | 3.85x |

regexz is faster on 19 of the 20 measured cases: 7.77x on tokenizer
compilation, 5.14x on a small-pattern compile, 1.23–1.45x on tokenizer scans,
2.12–2.80x on search scans, 1.62–4.13x on splits, 2.54–6.29x on full-match
calls, 4.10x on a set-run replacement, 1.63x on a zero-width replacement and
3.85x on the nine-pattern set.

The exception is a fresh `findAll` per call (0.64x): Rust's `find_iter` reuses
a thread-local cache pool, while regexz's owning iterator builds a workspace
and pays the lazy search-DFA preparation on every call. `Regex.findAllWith`
with a caller-owned workspace reuses the warmed caches and is ahead of Rust
(1.23x). The fresh iterator improved from 0.25x after the deferred fast-branch
table threshold change; see
[deferred fast-branch tables](deferred-fast-branch-threshold.md).

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
