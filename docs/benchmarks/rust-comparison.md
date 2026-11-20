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
| compile Qwen tokenizer | 37,978.7 | 452,265.9 | 11.91x |
| compile xDS-like | 2,487.3 | 21,443.4 | 8.62x |
| find Qwen tokenizer | 42,788.3 | 66,792.5 | 1.56x |
| findAll Qwen (borrowed) | 42,799.2 | 63,587.5 | 1.49x |
| findAll Qwen (owning) | 43,368.3 | 63,558.3 | 1.47x |
| find CJK tokenizer | 167,141.7 | 231,045.0 | 1.38x |
| find HTML tag | 47,845.4 | 122,744.4 | 2.57x |
| find URL | 35,306.7 | 86,329.4 | 2.45x |
| find JSON string literal | 7,345.8 | 17,121.0 | 2.33x |
| find JSON number | 28,184.0 | 69,002.1 | 2.45x |
| find word boundary | 69,707.7 | 149,193.8 | 2.14x |
| split whitespace (22 KiB) | 18,024.2 | 82,128.8 | 4.56x |
| split commas (29 KiB) | 17,459.8 | 55,264.6 | 3.17x |
| fullmatch literal | 1.8 | 9.8 | 5.44x |
| fullmatch class | 5.1 | 32.3 | 6.33x |
| fullmatch xDS-like | 10.3 | 30.7 | 2.98x |
| replaceAll a+ -> x | 27,255.4 | 106,626.0 | 3.91x |
| replaceAll \A|\z -> X | 6,797.1 | 10,051.2 | 1.48x |
| RegexSet 9 no-match patterns | 1,941.7 | 38,545.0 | 19.85x |

regexz is faster on all 19 measured cases: 11.91x on tokenizer compilation,
8.62x on a small-pattern compile, 1.38–1.56x on tokenizer scans and match
iteration, 2.14–2.57x on search scans, 3.17–4.56x on splits, 2.98–6.33x on
full-match calls, 3.91x on a set-run replacement, 1.48x on a zero-width
replacement and 19.85x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 11.91x and the xDS-like compile to 8.62x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 19.85x. Single-byte literal replacement and
splitting translate in vectors (see
[literal byte paths](literal-byte-paths.md)). Non-ASCII fast-branch runs are
scanned once (see [direct non-ASCII run starts](nonascii-run-start.md)).
Tokenizer whitespace tails are scanned directly (see
[exact whitespace later plan](whitespace-later-plan.md)). Set-run
replacement appends without capacity checks (see
[capacity-guaranteed appends](set-run-append.md)), lifting the `a+`
replacement from 3.66x to 3.91x. Split parts append without capacity checks
(see [capacity-guaranteed split appends](split-appends.md)), lifting the
whitespace split to 4.56x and the comma split to 3.17x.

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
