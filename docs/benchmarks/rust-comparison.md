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
| compile Qwen tokenizer | 32,353.3 | 457,466.9 | 14.14x |
| compile xDS-like | 2,479.6 | 21,157.9 | 8.53x |
| find Qwen tokenizer | 42,089.2 | 66,018.3 | 1.57x |
| findAll Qwen (borrowed) | 40,300.0 | 66,011.7 | 1.64x |
| findAll Qwen (owning) | 38,760.0 | 65,442.5 | 1.69x |
| find CJK tokenizer | 166,493.3 | 227,533.3 | 1.37x |
| find HTML tag | 48,939.8 | 124,264.4 | 2.54x |
| find URL | 34,986.7 | 88,185.6 | 2.52x |
| find JSON string literal | 7,601.5 | 17,578.3 | 2.31x |
| find JSON number | 29,084.8 | 61,968.3 | 2.13x |
| find word boundary | 69,181.5 | 135,906.9 | 1.96x |
| find (?i) literal | 43,408.8 | 80,518.3 | 1.85x |
| find alternation (5 words) | 149,139.2 | 167,154.6 | 1.12x |
| split whitespace (22 KiB) | 20,045.6 | 76,365.2 | 3.81x |
| split commas (29 KiB) | 19,763.1 | 54,811.2 | 2.77x |
| fullmatch literal | 1.9 | 9.5 | 5.00x |
| fullmatch class | 5.3 | 33.3 | 6.28x |
| fullmatch xDS-like | 10.2 | 31.4 | 3.08x |
| replaceAll a+ -> x | 21,735.2 | 104,967.3 | 4.83x |
| replaceAll \A|\z -> X | 3,142.7 | 8,413.5 | 2.68x |
| RegexSet 9 no-match patterns | 1,891.0 | 38,673.3 | 20.45x |

regexz is faster on all 21 measured cases: 14.14x on tokenizer compilation,
8.53x on a small-pattern compile, 1.37–1.69x on tokenizer scans and match
iteration, 1.12–2.54x on search scans, 2.77–3.81x on splits, 3.08–6.28x on
full-match calls, 4.83x on a set-run replacement, 2.68x on a zero-width
replacement and 20.45x on the nine-pattern set. The thinnest margin is the
five-word alternation at 1.12x, which was 1.53x slower before the direct
literal scan.

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
borrowed form at 1.69x. The tokenizer fast branch scans ASCII runs with the
byte table before the prepared UTF-8 automaton (see
[ASCII-first run scan](ascii-first-run-scan.md)). Caseless literals and
whole-pattern literal alternations are now verified directly instead of
through the DFA (see [literal fast paths](literal-fast-paths.md)); the new
`(?i)alpha` and five-word alternation cases moved from 1.47x and 1.53x behind
to 1.85x and 1.12x ahead.

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
