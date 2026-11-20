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
| compile Qwen tokenizer | 33,012.3 | 424,071.4 | 12.85x |
| compile xDS-like | 2,413.1 | 20,438.7 | 8.47x |
| find Qwen tokenizer | 38,041.7 | 61,796.7 | 1.62x |
| findAll Qwen (borrowed) | 39,388.3 | 64,223.3 | 1.63x |
| findAll Qwen (owning) | 38,030.0 | 68,635.8 | 1.80x |
| find CJK tokenizer | 162,194.2 | 217,668.3 | 1.34x |
| find HTML tag | 47,698.3 | 117,786.5 | 2.47x |
| find URL | 34,013.5 | 82,111.9 | 2.41x |
| find JSON string literal | 7,481.0 | 16,424.4 | 2.20x |
| find JSON number | 28,099.4 | 60,521.5 | 2.15x |
| find word boundary | 64,615.0 | 130,968.8 | 2.03x |
| find (?i) literal | 42,735.2 | 79,631.7 | 1.86x |
| find (?i) alternation | 126,952.7 | 178,561.2 | 1.41x |
| find alternation (5 words) | 142,211.9 | 168,422.3 | 1.18x |
| find 10-word alternation | 236,715.2 | 309,548.5 | 1.31x |
| find 20-word alternation | 218,029.0 | 325,040.2 | 1.49x |
| find Greek class | 48,295.6 | 90,118.5 | 1.87x |
| find prefix+suffix | 8,210.0 | 28,016.5 | 3.41x |
| find IPv4 | 106,624.6 | 123,531.9 | 1.16x |
| find date | 34,633.5 | 122,410.2 | 3.53x |
| find anchored line | 8,154.0 | 8,888.5 | 1.09x |
| replaceAll email captures | 24,688.5 | 84,300.8 | 3.41x |
| split whitespace (22 KiB) | 17,313.5 | 73,988.3 | 4.27x |
| split commas (29 KiB) | 15,741.3 | 54,549.6 | 3.47x |
| fullmatch literal | 1.7 | 9.8 | 5.76x |
| fullmatch class | 5.1 | 31.6 | 6.20x |
| fullmatch xDS-like | 9.6 | 29.7 | 3.09x |
| replaceAll a+ -> x | 20,945.8 | 98,228.3 | 4.69x |
| replaceAll \A|\z -> X | 2,840.2 | 8,318.3 | 2.93x |
| RegexSet 9 no-match patterns | 1,901.3 | 37,577.9 | 19.76x |

regexz is faster on all 30 measured cases: 12.85x on tokenizer compilation,
8.47x on a small-pattern compile, 1.34–1.80x on tokenizer scans and match
iteration, 1.09–3.53x on search scans, 3.41–4.27x on splits, 3.09–6.20x on
full-match calls, 4.69x on a set-run replacement, 3.41x on a capture
replacement, 2.93x on a zero-width replacement and 19.76x on the nine-pattern
set. The thinnest margin is the multiline anchored line scan at 1.09x.

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
`(?i)alpha` and five-word alternation cases moved from 1.47x and 1.53x
behind to 1.90x and 1.13x ahead. A `set+ literal` suffix is now searched
directly (see the same page): `\w+@example\.com` had been 1.54x slower and
is 3.41x ahead, and the 10-word alternation moved to 1.31x with the
nibble-table candidate filter. Fixed-width sequences such as
`\d{4}-\d{2}-\d{2}` are now verified directly (see the same page), taking
the date case from 1.9x behind to 3.53x ahead.

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
