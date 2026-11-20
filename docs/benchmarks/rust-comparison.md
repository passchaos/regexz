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
| compile Qwen tokenizer | 56,216.3 | 448,531.7 | 7.98x |
| compile xDS-like | 4,205.9 | 22,046.7 | 5.24x |
| find Qwen tokenizer | 53,715.8 | 72,299.2 | 1.35x |
| findAll Qwen, borrowed workspace | 58,195.8 | 65,100.0 | 1.12x |
| findAll Qwen, fresh workspace | 258,623.3 | 64,619.2 | 0.25x |
| find CJK tokenizer | 180,410.8 | 242,730.0 | 1.35x |
| find HTML tag | 49,834.6 | 128,539.0 | 2.58x |
| find URL | 35,088.5 | 94,279.2 | 2.69x |
| find JSON string literal | 7,406.3 | 17,637.9 | 2.38x |
| find JSON number | 28,944.0 | 62,803.5 | 2.17x |
| find word boundary | 65,155.4 | 138,716.7 | 2.13x |
| split whitespace (22 KiB) | 18,720.4 | 83,853.3 | 4.48x |
| split commas (29 KiB) | 32,355.0 | 56,804.0 | 1.76x |
| fullmatch literal | 1.8 | 9.8 | 5.44x |
| fullmatch class | 5.4 | 33.6 | 6.22x |
| fullmatch xDS-like | 10.5 | 33.8 | 3.22x |
| replaceAll `a+` → `x` | 25,850.8 | 110,079.8 | 4.26x |
| replaceAll `\A|\z` → `X` | 4,864.2 | 8,726.5 | 1.79x |
| RegexSet 9 no-match patterns | 9,382.3 | 39,858.8 | 4.25x |

regexz is faster on 19 of the 20 measured cases: 7.98x on tokenizer
compilation, 5.24x on a small-pattern compile, 1.12–1.35x on tokenizer scans,
2.13–2.69x on search scans, 1.76–4.48x on splits, 3.22–6.22x on full-match
calls, 4.26x on a set-run replacement, 1.79x on a zero-width replacement and
4.25x on the nine-pattern set.

The exception is a fresh `findAll` per call (0.25x): Rust's `find_iter` reuses
a thread-local cache pool, while regexz's owning iterator builds a workspace
and pays the lazy search-DFA preparation on every call. `Regex.findAllWith`
with a caller-owned workspace reuses the warmed caches, restores the lead over
Rust (1.12x) and matches a manual `Workspace.find` loop. See
[reusing a workspace for match iteration](find-all-workspace.md).

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
