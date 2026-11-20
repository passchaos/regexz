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
| compile Qwen tokenizer | 29,292.7 | 424,807.0 | 14.50x |
| compile xDS-like | 2,319.7 | 20,586.1 | 8.87x |
| find Qwen tokenizer | 41,111.7 | 62,345.8 | 1.52x |
| findAll Qwen (borrowed) | 41,085.8 | 61,337.5 | 1.49x |
| findAll Qwen (owning) | 40,580.8 | 61,695.0 | 1.52x |
| find CJK tokenizer | 159,864.2 | 216,783.3 | 1.36x |
| find HTML tag | 46,648.3 | 117,154.0 | 2.51x |
| find URL | 33,223.3 | 82,615.2 | 2.49x |
| find JSON string literal | 7,384.8 | 16,234.0 | 2.20x |
| find JSON number | 27,353.3 | 57,436.9 | 2.10x |
| find word boundary | 61,110.2 | 128,627.1 | 2.10x |
| split whitespace (22 KiB) | 20,409.0 | 72,407.5 | 3.55x |
| split commas (29 KiB) | 19,194.4 | 54,695.2 | 2.85x |
| fullmatch literal | 1.7 | 9.4 | 5.53x |
| fullmatch class | 5.2 | 31.8 | 6.12x |
| fullmatch xDS-like | 9.4 | 28.2 | 3.00x |
| replaceAll a+ -> x | 21,223.8 | 98,274.0 | 4.63x |
| replaceAll \A|\z -> X | 3,014.8 | 8,004.4 | 2.66x |
| RegexSet 9 no-match patterns | 1,874.0 | 38,396.7 | 20.49x |

regexz is faster on all 19 measured cases: 14.50x on tokenizer compilation,
8.87x on a small-pattern compile, 1.36–1.52x on tokenizer scans and match
iteration, 2.10–2.51x on search scans, 2.85–3.55x on splits, 3.00–6.12x on
full-match calls, 4.63x on a set-run replacement, 2.66x on a zero-width
replacement and 20.49x on the nine-pattern set.

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
whitespace split at 3.55x and the comma split at 2.85x. `Regex.replaceAll`
and `replacen` reuse a pooled replacement workspace for page/smp allocators,
and the pool holds the workspace by pointer so the owning `findAll` iterator
no longer copies a 7.8 KiB struct (see
[pooled replacement workspaces](replace-workspace-pool.md)); the zero-width
replacement rose from 1.24x to 2.66x and owning `findAll` now matches the
borrowed form at 1.52x.

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
