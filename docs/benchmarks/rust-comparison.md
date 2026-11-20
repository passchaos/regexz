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
| compile Qwen tokenizer | 32,370.5 | 462,727.2 | 14.29x |
| compile xDS-like | 2,626.1 | 21,859.3 | 8.32x |
| find Qwen tokenizer | 41,491.7 | 68,459.2 | 1.65x |
| findAll Qwen (borrowed) | 41,517.5 | 64,932.5 | 1.56x |
| findAll Qwen (owning) | 41,061.7 | 64,931.7 | 1.58x |
| find CJK tokenizer | 171,280.0 | 233,771.7 | 1.36x |
| find HTML tag | 49,582.3 | 122,412.7 | 2.47x |
| find URL | 35,436.9 | 90,997.7 | 2.57x |
| find JSON string literal | 7,441.0 | 17,707.9 | 2.38x |
| find JSON number | 28,997.5 | 63,546.9 | 2.19x |
| find word boundary | 86,475.0 | 138,838.8 | 1.61x |
| find (?i) literal | 44,385.6 | 85,918.1 | 1.94x |
| find alternation (5 words) | 148,635.6 | 168,587.9 | 1.13x |
| find (?i) alternation | 132,257.7 | 188,219.4 | 1.42x |
| find 10-word alternation | 256,611.5 | 308,439.8 | 1.20x |
| find Greek class | 50,291.9 | 101,876.5 | 2.03x |
| find prefix+suffix | 9,156.5 | 32,341.2 | 3.53x |
| replaceAll email captures | 27,262.3 | 91,578.8 | 3.36x |
| find IPv4 | 68,301.9 | 134,120.0 | 1.96x |
| find date | 39,546.0 | 133,737.1 | 3.38x |
| find 20-word alternation | 229,218.8 | 326,871.7 | 1.43x |
| find anchored line | 2,270.8 | 8,907.9 | 3.92x |
| find (?i) Unicode literal | 76,637.3 | 131,773.8 | 1.72x |
| find shared-prefix alternation | 27,527.9 | 31,310.4 | 1.14x |
| find one-char alternation | 15,988.5 | 19,085.6 | 1.19x |
| find hex color | 31,874.0 | 87,314.4 | 2.74x |
| find version | 55,470.0 | 110,800.2 | 2.00x |
| split whitespace (22 KiB) | 17,651.3 | 76,043.8 | 4.31x |
| split commas (29 KiB) | 16,434.2 | 55,972.5 | 3.41x |
| fullmatch literal | 1.8 | 9.4 | 5.22x |
| fullmatch class | 5.2 | 33.2 | 6.38x |
| fullmatch xDS-like | 10.0 | 32.8 | 3.28x |
| replaceAll a+ -> x | 21,668.5 | 104,633.8 | 4.83x |
| replaceAll \A|\z -> X | 2,792.3 | 8,014.0 | 2.87x |
| RegexSet 9 no-match patterns | 1,965.0 | 38,819.8 | 19.76x |

regexz is faster on all 35 measured cases: 14.29x on tokenizer compilation,
8.32x on a small-pattern compile, 1.36–1.65x on tokenizer scans and match
iteration, 1.13–3.92x on search scans, 3.41–4.31x on splits, 3.28–6.38x on
full-match calls, 4.83x on a set-run replacement, 3.36x on a capture
replacement, 2.87x on a zero-width replacement and 19.76x on the nine-pattern
set. The thinnest margins are the five-word alternation at 1.13x and the
shared-prefix alternation at 1.14x.

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
IPv4 from 1.16x to 1.96x ahead, and unbounded run chains such as
`v?\d+\.\d+\.\d+` are walked directly, taking the version case from
1.17x to 2.00x ahead.

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
