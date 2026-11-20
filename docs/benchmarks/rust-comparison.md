# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the two binaries were executed alternately, before/after and
after/before, five times. The table reports medians across those executions.
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON and 44 KiB JSON
number text.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 80,532.1 | 598,506.2 | 7.43x |
| find Qwen tokenizer | 69,845.8 | 87,854.2 | 1.26x |
| find CJK tokenizer | 230,767.5 | 351,283.3 | 1.52x |
| find HTML tag | 57,345.4 | 166,754.2 | 2.91x |
| find URL | 44,672.7 | 130,171.2 | 2.91x |
| find JSON string literal | 8,475.6 | 24,210.0 | 2.86x |
| find JSON number | 34,466.5 | 84,654.4 | 2.46x |

regexz is faster on every measured case: 7.43x on tokenizer compilation,
1.26–1.52x on tokenizer scans, and 2.46–2.91x on the delimiter, URL and number
scans.

Caveats: the iteration APIs are the natural ones for each library
(`Workspace.find` in a loop versus `Regex::find_iter`), the allocators differ
(regexz uses the page allocator in these runs, Rust the system allocator), and
the tokenizer comparison uses Rust's default Unicode classes with regexz's
`unicode_perl_space` limit. The shared host is noisy; single runs vary more
than the interleaved medians above. These numbers cover the listed workloads,
not every regex feature: Rust supports more Unicode word-boundary and
property syntax, while regexz's extended mode covers lookaround, backreferences
and conditionals that Rust's `regex` rejects.

Reproduce:

```sh
zig build-exe -O ReleaseFast --dep regexz \
    -Mroot=tools/compare/zig_regex.zig -Mregexz=src/root.zig \
    -femit-bin=/tmp/regexz-compare
/tmp/regexz-compare

cd tools/compare/rust_regex
cargo run --release
```
