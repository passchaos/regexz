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
| compile Qwen tokenizer | 31,056.4 | 430,830.1 | 13.87x |
| compile xDS-like | 2,482.1 | 20,698.9 | 8.34x |
| find Qwen tokenizer | 40,954.2 | 64,150.0 | 1.57x |
| findAll Qwen (borrowed) | 42,305.0 | 69,917.5 | 1.65x |
| findAll Qwen (owning) | 43,235.8 | 62,387.5 | 1.44x |
| find CJK tokenizer | 166,830.8 | 224,045.0 | 1.34x |
| find HTML tag | 46,952.5 | 121,882.7 | 2.60x |
| find URL | 33,305.8 | 82,652.1 | 2.48x |
| find JSON string literal | 7,131.9 | 17,074.4 | 2.39x |
| find JSON number | 27,312.3 | 60,208.1 | 2.20x |
| find word boundary | 62,793.1 | 131,606.7 | 2.10x |
| split whitespace (22 KiB) | 18,679.0 | 74,767.7 | 4.00x |
| split commas (29 KiB) | 17,520.2 | 54,734.4 | 3.12x |
| fullmatch literal | 1.8 | 9.3 | 5.17x |
| fullmatch class | 5.1 | 31.3 | 6.14x |
| fullmatch xDS-like | 9.8 | 29.0 | 2.96x |
| replaceAll a+ -> x | 22,254.2 | 100,201.5 | 4.50x |
| replaceAll \A|\z -> X | 3,504.2 | 7,802.1 | 2.23x |
| RegexSet 9 no-match patterns | 1,817.5 | 38,040.0 | 20.93x |

regexz is faster on all 19 measured cases: 13.87x on tokenizer compilation,
8.34x on a small-pattern compile, 1.34–1.65x on tokenizer scans and match
iteration, 2.10–2.60x on search scans, 3.12–4.00x on splits, 2.96–6.14x on
full-match calls, 4.50x on a set-run replacement, 2.23x on a zero-width
replacement and 20.93x on the nine-pattern set.

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
whitespace split at 4.00x and the comma split at 3.12x. `Regex.replaceAll`
and `replacen` reuse a pooled replacement workspace for page/smp allocators
(see [pooled replacement workspaces](replace-workspace-pool.md)), lifting the
zero-width replacement from 1.24x to 2.23x.

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
