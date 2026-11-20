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
| compile Qwen tokenizer | 32,303.8 | 457,996.9 | 14.18x |
| compile xDS-like | 2,737.8 | 21,113.6 | 7.71x |
| find Qwen tokenizer | 40,563.3 | 64,968.3 | 1.60x |
| findAll Qwen (borrowed) | 39,467.5 | 65,511.7 | 1.66x |
| findAll Qwen (owning) | 39,257.5 | 67,985.0 | 1.73x |
| find CJK tokenizer | 165,729.2 | 229,746.7 | 1.39x |
| find HTML tag | 48,469.4 | 120,769.2 | 2.49x |
| find URL | 33,907.9 | 85,839.8 | 2.53x |
| find JSON string literal | 7,523.1 | 18,231.9 | 2.42x |
| find JSON number | 31,610.6 | 63,036.0 | 1.99x |
| find word boundary | 78,359.6 | 135,019.6 | 1.72x |
| find (?i) literal | 43,307.5 | 89,166.5 | 2.06x |
| find alternation (5 words) | 145,461.3 | 171,530.8 | 1.18x |
| find (?i) alternation | 138,059.2 | 192,763.1 | 1.40x |
| find 10-word alternation | 250,965.0 | 305,893.5 | 1.22x |
| find Greek class | 51,476.5 | 99,791.9 | 1.94x |
| find prefix+suffix | 8,709.8 | 31,120.8 | 3.57x |
| replaceAll email captures | 26,751.5 | 92,439.2 | 3.46x |
| find IPv4 | 70,962.7 | 130,207.3 | 1.83x |
| find date | 38,248.3 | 130,038.1 | 3.40x |
| find 20-word alternation | 230,337.7 | 321,174.8 | 1.39x |
| find anchored line | 2,338.1 | 8,576.5 | 3.67x |
| find (?i) Unicode literal | 75,070.8 | 130,800.8 | 1.74x |
| find shared-prefix alternation | 25,060.4 | 29,936.0 | 1.19x |
| find one-char alternation | 15,957.9 | 18,661.2 | 1.17x |
| find hex color | 31,758.3 | 83,992.7 | 2.64x |
| find version | 59,860.4 | 107,205.0 | 1.79x |
| find nullable prefix | 30,044.2 | 38,825.8 | 1.29x |
| find identifier | 51,698.3 | 102,993.1 | 1.99x |
| find thousands | 105,412.7 | 116,347.5 | 1.10x |
| find domain | 32,834.6 | 117,127.3 | 3.57x |
| find percent | 31,602.5 | 118,871.9 | 3.76x |
| find time | 90,420.0 | 110,856.0 | 1.23x |
| find end-anchored word | 14,283.3 | 32,357.1 | 2.27x |
| find UUID | 30,117.3 | 69,327.3 | 2.30x |
| find semver | 92,979.0 | 93,907.7 | 1.01x |
| find email TLD | 17,598.1 | 23,567.3 | 1.34x |
| find CIDR | 119,109.0 | 130,400.2 | 1.09x |
| find line full | 2,138.3 | 10,364.0 | 4.85x |
| split whitespace (22 KiB) | 17,437.7 | 77,905.4 | 4.47x |
| split commas (29 KiB) | 16,141.3 | 55,392.9 | 3.43x |
| fullmatch literal | 1.8 | 9.3 | 5.17x |
| fullmatch class | 5.1 | 31.5 | 6.18x |
| fullmatch xDS-like | 9.9 | 30.2 | 3.05x |
| replaceAll a+ -> x | 20,847.7 | 103,208.5 | 4.95x |
| replaceAll \A|\z -> X | 3,189.4 | 7,751.5 | 2.43x |
| RegexSet 9 no-match patterns | 1,964.2 | 39,347.7 | 20.03x |

regexz is faster on all 47 measured cases. The ranges are 13.57x on
tokenizer compilation, 8.01x on a small-pattern compile, 1.35–1.72x on
tokenizer scans and match iteration, 1.01–3.77x on search scans, 3.40–4.49x
on splits, 3.15–6.04x on full-match calls, 4.69x on a set-run replacement,
3.61x on a capture replacement, 2.72x on a zero-width replacement and 19.53x
on the nine-pattern set. The thinnest margins are the semver scan at 1.01x
and the CIDR scan at 1.09x.

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
Email TLDs with a literal alternation are walked directly (1.22x), and
end-anchored word runs use a byte table with a cheap boundary check (2.29x).

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
