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
| compile Qwen tokenizer | 30,978.4 | 420,356.2 | 13.57x |
| compile xDS-like | 2,602.2 | 20,839.4 | 8.01x |
| find Qwen tokenizer | 39,633.3 | 63,168.3 | 1.59x |
| findAll Qwen (borrowed) | 37,664.2 | 63,444.2 | 1.68x |
| findAll Qwen (owning) | 38,665.0 | 66,610.0 | 1.72x |
| find CJK tokenizer | 162,240.0 | 218,525.0 | 1.35x |
| find HTML tag | 47,290.8 | 120,055.0 | 2.54x |
| find URL | 34,081.5 | 83,895.6 | 2.46x |
| find JSON string literal | 7,260.0 | 16,689.8 | 2.30x |
| find JSON number | 31,742.9 | 61,081.2 | 1.92x |
| find word boundary | 75,855.4 | 133,482.7 | 1.76x |
| find (?i) literal | 43,068.8 | 78,715.8 | 1.83x |
| find alternation (5 words) | 144,645.4 | 172,026.7 | 1.19x |
| find (?i) alternation | 129,894.0 | 172,923.5 | 1.33x |
| find 10-word alternation | 237,141.7 | 315,137.7 | 1.33x |
| find Greek class | 49,074.4 | 89,191.0 | 1.82x |
| find prefix+suffix | 8,625.4 | 28,911.0 | 3.35x |
| replaceAll email captures | 24,317.3 | 87,704.4 | 3.61x |
| find IPv4 | 63,675.2 | 123,124.0 | 1.93x |
| find date | 36,293.5 | 123,170.0 | 3.39x |
| find 20-word alternation | 221,206.3 | 324,892.5 | 1.47x |
| find anchored line | 2,302.5 | 8,388.3 | 3.64x |
| find (?i) Unicode literal | 72,426.3 | 123,847.9 | 1.71x |
| find shared-prefix alternation | 24,783.8 | 30,410.8 | 1.23x |
| find one-char alternation | 15,274.6 | 18,593.8 | 1.22x |
| find hex color | 30,019.4 | 81,261.0 | 2.71x |
| find version | 53,709.4 | 104,500.0 | 1.95x |
| find nullable prefix | 30,299.0 | 37,960.0 | 1.25x |
| find identifier | 50,017.1 | 100,457.1 | 2.01x |
| find thousands | 97,482.1 | 115,856.7 | 1.19x |
| find domain | 33,454.8 | 117,343.5 | 3.51x |
| find percent | 31,734.8 | 119,750.4 | 3.77x |
| find time | 86,317.1 | 106,360.0 | 1.23x |
| split whitespace (22 KiB) | 16,876.7 | 75,809.8 | 4.49x |
| split commas (29 KiB) | 16,055.8 | 54,656.2 | 3.40x |
| fullmatch literal | 1.7 | 9.4 | 5.53x |
| fullmatch class | 5.2 | 31.4 | 6.04x |
| fullmatch xDS-like | 9.4 | 29.6 | 3.15x |
| replaceAll a+ -> x | 21,465.2 | 100,776.9 | 4.69x |
| replaceAll \A|\z -> X | 2,820.8 | 7,667.9 | 2.72x |
| RegexSet 9 no-match patterns | 1,952.5 | 38,130.4 | 19.53x |

regexz is faster on all 41 measured cases: 13.57x on tokenizer compilation,
8.01x on a small-pattern compile, 1.35–1.72x on tokenizer scans and match
iteration, 1.19–3.77x on search scans, 3.40–4.49x on splits, 3.15–6.04x on
full-match calls, 4.69x on a set-run replacement, 3.61x on a capture
replacement, 2.72x on a zero-width replacement and 19.53x on the nine-pattern
set. The thinnest margin is the five-word alternation at 1.19x.

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
IPv4 from 1.16x to 1.93x ahead, unbounded run chains such as
`v?\d+\.\d+\.\d+` are walked directly (1.95x ahead), and four
run-anchored shapes were added: `.*test` (1.25x), identifiers (2.01x),
repeated-separator domains (3.51x) and optional-group percentages (3.77x).

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
