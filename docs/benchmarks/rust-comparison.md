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
| compile Qwen tokenizer | 37,641.4 | 464,236.2 | 12.33x |
| compile xDS-like | 2,627.2 | 21,729.8 | 8.27x |
| find Qwen tokenizer | 43,144.2 | 69,122.5 | 1.60x |
| findAll Qwen (borrowed) | 45,263.3 | 67,660.8 | 1.49x |
| findAll Qwen (owning) | 45,296.7 | 67,445.8 | 1.49x |
| find CJK tokenizer | 164,422.5 | 236,119.2 | 1.44x |
| find HTML tag | 48,233.8 | 128,949.6 | 2.67x |
| find URL | 35,027.7 | 91,361.7 | 2.61x |
| find JSON string literal | 7,362.5 | 17,035.2 | 2.31x |
| find JSON number | 27,578.3 | 67,145.4 | 2.43x |
| find word boundary | 64,022.9 | 140,392.7 | 2.19x |
| split whitespace (22 KiB) | 21,958.3 | 76,944.4 | 3.50x |
| split commas (29 KiB) | 21,169.8 | 55,431.0 | 2.62x |
| fullmatch literal | 1.8 | 9.5 | 5.28x |
| fullmatch class | 5.3 | 33.4 | 6.30x |
| fullmatch xDS-like | 10.2 | 31.9 | 3.13x |
| replaceAll a+ -> x | 26,796.9 | 102,757.5 | 3.83x |
| replaceAll \A|\z -> X | 6,376.9 | 7,810.4 | 1.22x |
| RegexSet 9 no-match patterns | 1,981.3 | 38,797.3 | 19.58x |

regexz is faster on all 19 measured cases: 12.33x on tokenizer compilation,
8.27x on a small-pattern compile, 1.44–1.60x on tokenizer scans and match
iteration, 2.19–2.67x on search scans, 2.62–3.50x on splits, 3.13–6.30x on
full-match calls, 3.83x on a set-run replacement, 1.22x on a zero-width
replacement and 19.58x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 12.33x and the xDS-like compile to 8.27x. The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 19.58x. Single-byte literal replacement and
splitting translate in vectors (see
[literal byte paths](literal-byte-paths.md)), which lifted the comma split
from 1.64x to 2.62x. Non-ASCII fast-branch runs are scanned once (see
[direct non-ASCII run starts](nonascii-run-start.md)), keeping the CJK
tokenizer at 1.44x. Set-run replacement appends without capacity checks (see
[capacity-guaranteed appends](set-run-append.md)), lifting the `a+`
replacement from 3.66x to 3.83x.

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
