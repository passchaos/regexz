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
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 33,966.4 | 450,719.2 | 13.27x |
| compile xDS-like | 3,526.2 | 21,693.5 | 6.15x |
| find Qwen tokenizer | 44,617.5 | 71,358.3 | 1.60x |
| findAll Qwen (borrowed) | 40,874.2 | 76,367.5 | 1.87x |
| findAll Qwen (owning) | 43,098.3 | 65,358.3 | 1.52x |
| find CJK tokenizer | 175,394.2 | 245,248.3 | 1.40x |
| find HTML tag | 52,134.6 | 126,186.9 | 2.42x |
| find URL | 36,080.8 | 88,841.2 | 2.46x |
| find JSON string literal | 7,760.6 | 18,145.0 | 2.34x |
| find JSON number | 33,483.3 | 64,051.2 | 1.91x |
| find word boundary | 82,404.8 | 138,758.1 | 1.68x |
| find (?i) literal | 43,227.7 | 88,674.2 | 2.05x |
| find alternation (5 words) | 145,254.8 | 174,532.9 | 1.20x |
| find (?i) alternation | 145,480.2 | 189,576.0 | 1.30x |
| find 10-word alternation | 232,291.9 | 300,299.6 | 1.29x |
| find Greek class | 58,884.8 | 88,514.4 | 1.50x |
| find prefix+suffix | 8,945.6 | 32,147.9 | 3.59x |
| replaceAll email captures | 26,358.3 | 88,650.4 | 3.36x |
| find IPv4 | 70,526.5 | 143,856.7 | 2.04x |
| find date | 44,923.1 | 139,343.1 | 3.10x |
| find 20-word alternation | 205,577.5 | 322,387.7 | 1.57x |
| find anchored line | 2,347.1 | 10,241.7 | 4.36x |
| find (?i) Unicode literal | 79,426.0 | 141,481.2 | 1.78x |
| find shared-prefix alternation | 29,305.6 | 30,779.2 | 1.05x |
| find one-char alternation | 13,190.0 | 18,957.5 | 1.44x |
| find hex color | 35,229.0 | 92,070.0 | 2.61x |
| find version | 64,570.0 | 124,132.9 | 1.92x |
| find nullable prefix | 31,324.0 | 41,123.8 | 1.31x |
| find identifier | 53,137.7 | 109,427.9 | 2.06x |
| find thousands | 41,632.5 | 121,455.4 | 2.92x |
| find domain | 35,479.6 | 134,497.9 | 3.79x |
| find percent | 34,386.9 | 131,076.5 | 3.81x |
| find time | 45,974.6 | 119,481.2 | 2.60x |
| find end-anchored word | 14,378.5 | 32,165.8 | 2.24x |
| find UUID | 30,612.3 | 77,308.3 | 2.53x |
| find semver | 95,471.7 | 100,526.9 | 1.05x |
| find email TLD | 14,244.4 | 24,001.0 | 1.68x |
| find CIDR | 75,202.7 | 130,940.0 | 1.74x |
| find line full | 2,176.7 | 15,470.8 | 7.11x |
| find optional prefix run | 112,997.9 | 195,738.1 | 1.73x |
| find repeated literal group | 126,611.3 | 143,497.1 | 1.13x |
| find camelCase | 86,604.4 | 104,896.7 | 1.21x |
| find key-value | 104,317.7 | 231,704.6 | 2.22x |
| find IP port | 102,443.3 | 156,185.6 | 1.52x |
| find (?i) class | 26,082.7 | 43,474.4 | 1.67x |
| find prefix alternation | 127,334.2 | 171,286.9 | 1.35x |
| find signed number | 43,506.3 | 63,539.0 | 1.46x |
| find html attribute | 53,628.5 | 107,701.0 | 2.01x |
| find markdown heading | 57,790.2 | 73,853.5 | 1.28x |
| find mixed alternation | 178,712.9 | 357,442.1 | 2.00x |
| split whitespace (22 KiB) | 17,269.4 | 80,967.5 | 4.69x |
| split commas (29 KiB) | 16,146.7 | 56,280.0 | 3.49x |
| fullmatch literal | 2.3 | 9.4 | 4.09x |
| fullmatch class | 6.1 | 35.0 | 5.74x |
| fullmatch xDS-like | 10.0 | 33.0 | 3.30x |
| replaceAll a+ -> x | 21,883.5 | 107,094.0 | 4.89x |
| replaceAll \A|\z -> X | 3,012.9 | 9,306.2 | 3.09x |
| RegexSet 9 no-match patterns | 2,054.6 | 38,952.7 | 18.96x |

regexz is faster on all 58 measured cases. The ranges are 13.27x on
tokenizer compilation, 6.15x on a small-pattern compile, 1.40–1.87x on
tokenizer scans and match iteration, 1.05–3.81x on search scans, 3.49–4.69x
on splits, 3.30–5.74x on full-match calls, 4.89x on a set-run replacement,
3.36x on a capture replacement, 3.09x on a zero-width replacement and 18.96x
on the nine-pattern set. The thinnest margins are the shared-prefix
alternation and the semver scan at 1.05x.

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
Optional-prefix runs take the plain set-run path (1.83x), key-value scans use
disjoint adjacent runs and `set*` runs (2.48x), and camelCase scans use
single-set elements (1.37x). Bounded sequences accept a trailing optional
group (CIDR, 1.86x), a bounded loop covers thousands separators (2.98x), and
the unbounded chain skips the first run after a failed start (semver, 1.05x).
Signed numbers, markdown headings and negated-class chains are now
scanned directly, the UTF-8 run search skips short ASCII gaps with the byte
table, and literal alternations are expanded into a product before the
literal-set filter (see the same page): the signed-number case is 1.46x
ahead, the markdown heading 1.28x, the HTML attribute 2.01x, the
case-insensitive class 1.67x, the prefix alternation 1.35x and the mixed
alternation 2.00x. Literal-alternation scans now return the matching branch
from the candidate filter, so the span needs no second verification pass,
single-byte sets accept the first-byte hit directly, and the prefix-run scan
uses packed membership bitsets: the one-char alternation moved to 1.44x,
the five-word alternation to 1.20x, the 10-word alternation to 1.29x and the
20-word alternation to 1.57x.

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
