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
| compile Qwen tokenizer | 38,931.9 | 464,224.5 | 11.92x |
| compile xDS-like | 2,719.4 | 21,781.1 | 8.01x |
| find Qwen tokenizer | 45,043.3 | 69,730.8 | 1.55x |
| findAll Qwen (borrowed) | 45,159.2 | 75,700.0 | 1.68x |
| findAll Qwen (owning) | 47,339.2 | 69,878.3 | 1.48x |
| find CJK tokenizer | 180,199.2 | 268,972.5 | 1.49x |
| find HTML tag | 48,314.6 | 131,341.9 | 2.72x |
| find URL | 34,416.7 | 94,238.1 | 2.74x |
| find JSON string literal | 7,309.2 | 17,290.4 | 2.37x |
| find JSON number | 28,076.3 | 67,936.5 | 2.42x |
| find word boundary | 64,696.3 | 136,502.9 | 2.11x |
| split whitespace (22 KiB) | 20,561.7 | 78,079.4 | 3.80x |
| split commas (29 KiB) | 19,844.6 | 55,081.7 | 2.78x |
| fullmatch literal | 1.8 | 9.5 | 5.28x |
| fullmatch class | 5.5 | 34.6 | 6.29x |
| fullmatch xDS-like | 11.0 | 33.5 | 3.05x |
| replaceAll a+ -> x | 27,023.8 | 105,619.2 | 3.91x |
| replaceAll \A|\z -> X | 7,563.3 | 7,930.8 | 1.05x |
| RegexSet 9 no-match patterns | 1,980.4 | 38,971.9 | 19.68x |

regexz is faster on all 19 measured cases: 11.92x on tokenizer compilation,
8.01x on a small-pattern compile, 1.48–1.68x on tokenizer scans and match
iteration, 2.11–2.74x on search scans, 2.78–3.80x on splits, 3.05–6.29x on
full-match calls, 3.91x on a set-run replacement, 1.05x on a zero-width
replacement and 19.68x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 11.92x and the xDS-like compile to 8.01x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 19.68x. Single-byte literal replacement and
splitting translate in vectors (see
[literal byte paths](literal-byte-paths.md)). Non-ASCII fast-branch runs are
scanned once (see [direct non-ASCII run starts](nonascii-run-start.md)),
keeping the CJK tokenizer at 1.49x. Set-run replacement appends without
capacity checks (see [capacity-guaranteed appends](set-run-append.md)),
lifting the `a+` replacement from 3.66x to 3.91x. Split parts append without
capacity checks (see
[capacity-guaranteed split appends](split-appends.md)), lifting the
whitespace split to 3.80x and the comma split to 2.78x.

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
