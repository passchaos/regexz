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
| compile Qwen tokenizer | 31,623.5 | 452,852.8 | 14.32x |
| compile xDS-like | 3,322.2 | 21,733.9 | 6.54x |
| find Qwen tokenizer | 40,760.0 | 68,233.3 | 1.67x |
| findAll Qwen (borrowed) | 41,445.0 | 65,032.5 | 1.57x |
| findAll Qwen (owning) | 41,849.2 | 69,356.7 | 1.66x |
| find CJK tokenizer | 169,509.2 | 221,343.3 | 1.31x |
| find HTML tag | 49,851.5 | 122,102.3 | 2.45x |
| find URL | 35,515.8 | 87,078.8 | 2.45x |
| find JSON string literal | 7,780.0 | 17,013.3 | 2.19x |
| find JSON number | 34,266.5 | 62,013.8 | 1.81x |
| find word boundary | 80,243.1 | 144,928.5 | 1.81x |
| find (?i) literal | 44,092.5 | 93,425.4 | 2.12x |
| find alternation (5 words) | 145,442.9 | 177,416.2 | 1.22x |
| find (?i) alternation | 82,836.5 | 199,843.8 | 2.41x |
| find 10-word alternation | 206,683.5 | 309,717.9 | 1.50x |
| find Greek class | 60,582.9 | 96,720.4 | 1.60x |
| find prefix+suffix | 8,830.4 | 31,232.3 | 3.54x |
| replaceAll email captures | 28,838.3 | 92,392.1 | 3.20x |
| find IPv4 | 72,160.0 | 141,891.9 | 1.97x |
| find date | 40,790.6 | 132,985.0 | 3.26x |
| find 20-word alternation | 207,262.1 | 320,513.3 | 1.55x |
| find anchored line | 2,289.2 | 8,834.0 | 3.86x |
| find (?i) Unicode literal | 79,574.0 | 131,894.4 | 1.66x |
| find shared-prefix alternation | 24,233.5 | 30,101.9 | 1.24x |
| find one-char alternation | 13,562.3 | 18,764.2 | 1.38x |
| find hex color | 36,471.9 | 86,361.7 | 2.37x |
| find version | 63,017.1 | 121,521.5 | 1.93x |
| find nullable prefix | 10,405.2 | 39,876.2 | 3.83x |
| find identifier | 53,075.4 | 109,590.8 | 2.06x |
| find thousands | 39,976.5 | 122,334.0 | 3.06x |
| find domain | 33,643.8 | 127,415.4 | 3.79x |
| find percent | 33,622.7 | 122,820.8 | 3.65x |
| find time | 47,291.0 | 114,509.6 | 2.42x |
| find end-anchored word | 14,451.7 | 33,026.2 | 2.29x |
| find UUID | 33,030.6 | 70,343.5 | 2.13x |
| find semver | 88,163.1 | 102,510.0 | 1.16x |
| find email TLD | 13,316.9 | 24,307.1 | 1.83x |
| find CIDR | 77,437.3 | 133,551.2 | 1.72x |
| find line full | 2,160.0 | 15,025.6 | 6.96x |
| find optional prefix run | 112,785.0 | 192,879.0 | 1.71x |
| find repeated literal group | 44,726.3 | 147,160.2 | 3.29x |
| find camelCase | 89,749.4 | 102,474.4 | 1.14x |
| find key-value | 99,587.3 | 214,964.2 | 2.16x |
| find IP port | 94,584.0 | 148,692.7 | 1.57x |
| find (?i) class | 25,163.3 | 39,406.7 | 1.57x |
| find prefix alternation | 122,670.0 | 167,661.9 | 1.37x |
| find signed number | 42,812.3 | 64,618.8 | 1.51x |
| find html attribute | 53,022.9 | 102,044.2 | 1.92x |
| find markdown heading | 36,538.5 | 72,302.1 | 1.98x |
| find mixed alternation | 183,716.9 | 350,922.9 | 1.91x |
| split whitespace (22 KiB) | 16,775.6 | 79,176.2 | 4.72x |
| split commas (29 KiB) | 15,861.0 | 56,116.0 | 3.54x |
| fullmatch literal | 1.8 | 9.5 | 5.28x |
| fullmatch class | 5.3 | 33.7 | 6.36x |
| fullmatch xDS-like | 9.0 | 30.9 | 3.43x |
| replaceAll a+ -> x | 21,434.0 | 110,294.6 | 5.15x |
| replaceAll \A|\z -> X | 2,669.2 | 8,094.4 | 3.03x |
| RegexSet 9 no-match patterns | 1,932.3 | 39,024.4 | 20.20x |

regexz is faster on all 58 measured cases. The ranges are 14.32x on
tokenizer compilation, 6.54x on a small-pattern compile, 1.31–1.67x on
tokenizer scans and match iteration, 1.14–3.86x on search scans, 3.54–4.72x
on splits, 3.43–6.36x on full-match calls, 5.15x on a set-run replacement,
3.20x on a capture replacement, 3.03x on a zero-width replacement and 20.20x
on the nine-pattern set. The thinnest margins are the camelCase scan at
1.14x and the semver scan at 1.16x.

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
uses packed membership bitsets: the one-char alternation moved to 1.42x,
the five-word alternation to 1.20x, the 10-word alternation to 1.45x and the
20-word alternation to 1.56x. The candidate filters skip the three bytes
they already checked, and the third-byte stage is dropped when every
two-byte pair is distinct (shared-prefix 1.32x, prefix alternation 1.35x).
A repeated fixed literal group (`(?:ab)+`) is scanned as maximal
repetitions (3.04x ahead), markdown heading scans skip the line-break search
after a match (2.02x), and chain walks compare single-byte separators
directly (semver, 1.04x). A whole-pattern case-folded literal alternation
(`(?i)alpha|gamma`) now scans folded lanes and reports the matching branch:
the case-insensitive alternation is 2.41x ahead. The caseless-literal
detector also requires both ASCII cases per letter, which fixes a
pre-existing false positive for case-sensitive scopes inside a caseless
pattern (`(?i:ab)c` must not match `ABC`). Dot-star literals (`.*test`)
find the line end with a vector scan that stops at the first line break or
non-ASCII byte, deferring non-ASCII input to the UTF-8 run scan: the
nullable-prefix case moved from 1.30x to 3.83x.

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
