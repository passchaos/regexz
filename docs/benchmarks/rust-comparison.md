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
| compile Qwen tokenizer | 31,897.9 | 447,582.4 | 14.03x |
| compile xDS-like | 2,673.6 | 21,539.6 | 8.06x |
| find Qwen tokenizer | 40,446.7 | 66,615.8 | 1.65x |
| findAll Qwen (borrowed) | 40,415.8 | 73,552.5 | 1.82x |
| findAll Qwen (owning) | 40,110.0 | 66,302.5 | 1.65x |
| find CJK tokenizer | 172,670.8 | 246,375.0 | 1.43x |
| find HTML tag | 49,507.9 | 128,086.7 | 2.59x |
| find URL | 35,956.5 | 90,235.4 | 2.51x |
| find JSON string literal | 7,471.0 | 17,899.6 | 2.40x |
| find JSON number | 28,616.9 | 62,405.2 | 2.18x |
| find word boundary | 69,071.5 | 139,677.5 | 2.02x |
| find (?i) literal | 44,319.0 | 86,388.3 | 1.95x |
| find (?i) alternation | 138,796.7 | 189,480.4 | 1.37x |
| find alternation (5 words) | 153,759.4 | 177,650.8 | 1.16x |
| find 10-word alternation | 250,486.0 | 310,541.5 | 1.24x |
| find 20-word alternation | 225,697.5 | 327,511.0 | 1.45x |
| find Greek class | 50,807.9 | 91,424.2 | 1.80x |
| find prefix+suffix | 8,388.3 | 29,351.2 | 3.50x |
| find IPv4 | 123,166.3 | 142,942.7 | 1.16x |
| find date | 37,335.2 | 124,644.8 | 3.34x |
| find anchored line | 2,241.9 | 9,477.3 | 4.23x |
| replaceAll email captures | 26,552.5 | 87,761.0 | 3.31x |
| split whitespace (22 KiB) | 17,359.2 | 77,496.0 | 4.46x |
| split commas (29 KiB) | 16,250.8 | 55,935.4 | 3.44x |
| fullmatch literal | 1.8 | 9.7 | 5.39x |
| fullmatch class | 5.2 | 33.3 | 6.40x |
| fullmatch xDS-like | 10.4 | 33.0 | 3.17x |
| replaceAll a+ -> x | 22,287.1 | 104,627.5 | 4.69x |
| replaceAll \A|\z -> X | 2,830.0 | 7,912.9 | 2.80x |
| RegexSet 9 no-match patterns | 1,804.8 | 38,900.4 | 21.55x |

regexz is faster on all 30 measured cases: 14.03x on tokenizer compilation,
8.06x on a small-pattern compile, 1.43–1.82x on tokenizer scans and match
iteration, 1.16–4.23x on search scans, 3.44–4.46x on splits, 3.17–6.40x on
full-match calls, 4.69x on a set-run replacement, 3.31x on a capture
replacement, 2.80x on a zero-width replacement and 21.55x on the nine-pattern
set. The thinnest margins are the variable-width IPv4 case and the five-word
alternation at 1.16x.

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
the date case from 1.9x behind to 3.34x ahead, and `(?m)^\w+` scans line
starts directly, moving from 1.09x to 4.23x ahead.

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
