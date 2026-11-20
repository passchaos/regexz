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
| compile Qwen tokenizer | 31,741.1 | 448,304.1 | 14.12x |
| compile xDS-like | 2,520.3 | 21,290.2 | 8.45x |
| find Qwen tokenizer | 40,016.7 | 64,217.5 | 1.60x |
| findAll Qwen (borrowed) | 39,340.0 | 64,142.5 | 1.63x |
| findAll Qwen (owning) | 40,167.5 | 67,283.3 | 1.68x |
| find CJK tokenizer | 165,586.7 | 224,001.7 | 1.35x |
| find HTML tag | 47,755.2 | 126,353.5 | 2.65x |
| find URL | 33,406.5 | 86,155.8 | 2.58x |
| find JSON string literal | 7,443.5 | 18,424.2 | 2.48x |
| find JSON number | 32,150.0 | 61,467.9 | 1.91x |
| find word boundary | 64,974.0 | 132,712.3 | 2.04x |
| find (?i) literal | 42,465.0 | 80,594.4 | 1.90x |
| find (?i) alternation | 130,893.1 | 183,955.2 | 1.41x |
| find alternation (5 words) | 145,595.0 | 164,544.0 | 1.13x |
| find 10-word alternation | 248,625.6 | 298,758.3 | 1.20x |
| find Greek class | 48,529.2 | 92,655.2 | 1.91x |
| find prefix+suffix | 8,578.3 | 29,424.4 | 3.43x |
| replaceAll email captures | 24,489.0 | 84,778.5 | 3.46x |
| split whitespace (22 KiB) | 17,432.9 | 75,300.2 | 4.32x |
| split commas (29 KiB) | 16,007.5 | 54,610.2 | 3.41x |
| fullmatch literal | 1.9 | 9.5 | 5.00x |
| fullmatch class | 5.2 | 31.6 | 6.08x |
| fullmatch xDS-like | 9.6 | 29.1 | 3.03x |
| replaceAll a+ -> x | 21,463.8 | 104,556.7 | 4.87x |
| replaceAll \A|\z -> X | 2,812.1 | 8,003.1 | 2.85x |
| RegexSet 9 no-match patterns | 1,993.1 | 38,605.2 | 19.37x |

regexz is faster on all 26 measured cases: 14.12x on tokenizer compilation,
8.45x on a small-pattern compile, 1.35–1.68x on tokenizer scans and match
iteration, 1.13–3.43x on search scans, 3.41–4.32x on splits, 3.03–6.08x on
full-match calls, 4.87x on a set-run replacement, 3.46x on a capture
replacement, 2.85x on a zero-width replacement and 19.37x on the nine-pattern
set. The thinnest margin is the five-word alternation at 1.13x, which was
1.53x slower before the direct literal scan.

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
is 3.43x ahead, and the 10-word alternation moved to 1.20x with the
nibble-table candidate filter.

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
