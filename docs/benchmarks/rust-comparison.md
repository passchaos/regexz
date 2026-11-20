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
| compile Qwen tokenizer | 32,443.4 | 462,733.6 | 14.26x |
| compile xDS-like | 2,683.4 | 22,162.4 | 8.26x |
| find Qwen tokenizer | 40,804.2 | 72,477.5 | 1.78x |
| findAll Qwen (borrowed) | 38,562.5 | 76,231.7 | 1.98x |
| findAll Qwen (owning) | 42,450.0 | 66,760.0 | 1.57x |
| find CJK tokenizer | 174,919.2 | 261,172.5 | 1.49x |
| find HTML tag | 49,707.5 | 134,479.4 | 2.71x |
| find URL | 36,386.5 | 98,211.7 | 2.70x |
| find JSON string literal | 7,776.5 | 18,211.7 | 2.34x |
| find JSON number | 28,884.6 | 69,684.4 | 2.41x |
| find word boundary | 66,539.2 | 148,872.7 | 2.24x |
| find (?i) literal | 44,583.1 | 91,241.2 | 2.05x |
| find (?i) alternation | 134,914.6 | 199,279.2 | 1.48x |
| find alternation (5 words) | 151,787.9 | 179,846.2 | 1.18x |
| find 10-word alternation | 251,041.5 | 320,274.0 | 1.28x |
| find 20-word alternation | 225,705.4 | 346,292.7 | 1.53x |
| find Greek class | 52,096.3 | 97,079.2 | 1.86x |
| find prefix+suffix | 8,403.1 | 30,948.1 | 3.68x |
| find IPv4 | 69,647.7 | 147,311.7 | 2.12x |
| find date | 37,283.1 | 136,515.6 | 3.66x |
| find anchored line | 2,345.6 | 8,645.2 | 3.69x |
| replaceAll email captures | 27,232.9 | 94,624.6 | 3.47x |
| split whitespace (22 KiB) | 17,831.3 | 80,073.8 | 4.49x |
| split commas (29 KiB) | 16,385.0 | 56,117.9 | 3.42x |
| fullmatch literal | 1.8 | 9.7 | 5.39x |
| fullmatch class | 5.4 | 33.7 | 6.24x |
| fullmatch xDS-like | 9.8 | 31.6 | 3.22x |
| replaceAll a+ -> x | 21,656.0 | 110,216.5 | 5.09x |
| replaceAll \A|\z -> X | 2,814.6 | 8,485.0 | 3.01x |
| RegexSet 9 no-match patterns | 2,005.2 | 40,261.7 | 20.08x |

regexz is faster on all 30 measured cases: 14.26x on tokenizer compilation,
8.26x on a small-pattern compile, 1.49–1.98x on tokenizer scans and match
iteration, 1.18–3.69x on search scans, 3.42–4.49x on splits, 3.22–6.24x on
full-match calls, 5.09x on a set-run replacement, 3.47x on a capture
replacement, 3.01x on a zero-width replacement and 20.08x on the nine-pattern
set. The thinnest margin is the five-word alternation at 1.18x.

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
the date case from 1.9x behind to 3.66x ahead, `(?m)^\w+` scans line starts
directly, moving from 1.09x to 3.69x ahead, and bounded set runs such as
IPv4 address shapes are walked greedily with a backtracking fallback, taking
IPv4 from 1.16x to 2.12x ahead.

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
