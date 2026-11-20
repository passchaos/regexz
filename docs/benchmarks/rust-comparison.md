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
| compile Qwen tokenizer | 32,700.3 | 461,767.6 | 14.12x |
| compile xDS-like | 2,539.8 | 22,201.0 | 8.74x |
| find Qwen tokenizer | 41,205.0 | 64,575.0 | 1.57x |
| findAll Qwen (borrowed) | 42,610.8 | 63,321.7 | 1.49x |
| findAll Qwen (owning) | 44,361.7 | 66,505.8 | 1.50x |
| find CJK tokenizer | 162,888.3 | 234,632.5 | 1.44x |
| find HTML tag | 48,089.2 | 120,827.7 | 2.51x |
| find URL | 33,571.5 | 88,766.7 | 2.64x |
| find JSON string literal | 8,401.5 | 17,291.9 | 2.06x |
| find JSON number | 27,969.8 | 64,080.8 | 2.29x |
| find word boundary | 65,542.9 | 142,159.2 | 2.17x |
| split whitespace (22 KiB) | 20,134.0 | 78,911.2 | 3.92x |
| split commas (29 KiB) | 19,018.8 | 56,157.9 | 2.95x |
| fullmatch literal | 1.7 | 9.7 | 5.71x |
| fullmatch class | 5.2 | 34.2 | 6.58x |
| fullmatch xDS-like | 10.1 | 32.5 | 3.22x |
| replaceAll a+ -> x | 27,111.5 | 107,794.8 | 3.98x |
| replaceAll \A|\z -> X | 7,383.1 | 9,183.8 | 1.24x |
| RegexSet 9 no-match patterns | 1,949.4 | 39,712.7 | 20.37x |

regexz is faster on all 19 measured cases: 14.12x on tokenizer compilation,
8.74x on a small-pattern compile, 1.44–1.57x on tokenizer scans and match
iteration, 2.06–2.64x on search scans, 2.95–3.92x on splits, 3.22–6.58x on
full-match calls, 3.98x on a set-run replacement, 1.24x on a zero-width
replacement and 20.37x on the nine-pattern set.

Compilation now selects a 16 KiB, 64 KiB or 256 KiB block by pattern shape,
reuses page-allocator blocks from a process pool, and falls back to the arena
for very large patterns (see
[compile block tiers](compile-block-tiers.md)), which lifted the Qwen
compile to 14.12x and the xDS-like compile to 8.74x; Unicode properties now
materialize once per compile (see
[per-compile Unicode property cache](property-cache.md)). The tokenizer fast branch
scans the following digit and punctuation branches directly (see
[fast-branch later plans](fast-branch-later-plans.md)); the owning
`Regex.findAll` iterator returns its workspace to a process pool for page/smp
allocators (see [match iteration workspaces](find-all-workspace.md)).
`RegexSet` scans all simple chain separators in one vector pass (see
[combined separator scan](set-combined-separators.md)), which lifted the
nine-pattern set from 4.21x to 20.37x. Single-byte literal replacement and
splitting translate in vectors (see
[literal byte paths](literal-byte-paths.md)). Non-ASCII fast-branch runs are
scanned once (see [direct non-ASCII run starts](nonascii-run-start.md)).
Tokenizer whitespace tails are scanned directly (see
[exact whitespace later plan](whitespace-later-plan.md)). Set-run
replacement appends without capacity checks (see
[capacity-guaranteed appends](set-run-append.md)), lifting the `a+`
replacement from 3.66x to 3.98x. Split parts append without capacity checks
(see [capacity-guaranteed split appends](split-appends.md)), keeping the
whitespace split at 3.92x and the comma split at 2.95x.

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
