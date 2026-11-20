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
| compile Qwen tokenizer | 30,611.7 | 440,586.8 | 14.39x |
| compile xDS-like | 2,288.7 | 20,186.6 | 8.82x |
| find Qwen tokenizer | 38,897.5 | 64,896.7 | 1.67x |
| findAll Qwen (borrowed) | 38,873.3 | 63,091.7 | 1.62x |
| findAll Qwen (owning) | 38,323.3 | 60,745.8 | 1.59x |
| find CJK tokenizer | 163,339.2 | 214,377.5 | 1.31x |
| find HTML tag | 47,728.5 | 117,373.5 | 2.46x |
| find URL | 33,958.5 | 80,440.6 | 2.37x |
| find JSON string literal | 7,500.4 | 16,253.5 | 2.17x |
| find JSON number | 28,390.8 | 58,133.5 | 2.05x |
| find word boundary | 64,232.1 | 127,515.6 | 1.99x |
| split whitespace (22 KiB) | 18,815.6 | 72,850.8 | 3.87x |
| split commas (29 KiB) | 17,622.5 | 54,407.7 | 3.09x |
| fullmatch literal | 1.8 | 9.4 | 5.22x |
| fullmatch class | 5.0 | 31.4 | 6.28x |
| fullmatch xDS-like | 9.0 | 29.5 | 3.28x |
| replaceAll a+ -> x | 21,009.2 | 99,317.9 | 4.73x |
| replaceAll \A|\z -> X | 2,755.4 | 7,797.9 | 2.83x |
| RegexSet 9 no-match patterns | 1,856.9 | 37,246.7 | 20.06x |

regexz is faster on all 19 measured cases: 14.39x on tokenizer compilation,
8.82x on a small-pattern compile, 1.31–1.67x on tokenizer scans and match
iteration, 1.99–2.46x on search scans, 3.09–3.87x on splits, 3.28–6.28x on
full-match calls, 4.73x on a set-run replacement, 2.83x on a zero-width
replacement and 20.06x on the nine-pattern set.

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
replacement rose from 1.24x to 2.83x and owning `findAll` now matches the
borrowed form at 1.59x. The tokenizer fast branch scans ASCII runs with the
byte table before the prepared UTF-8 automaton (see
[ASCII-first run scan](ascii-first-run-scan.md)), lifting `find Qwen
tokenizer` from 1.52x to 1.67x.

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
