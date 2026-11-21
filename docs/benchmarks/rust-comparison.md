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
| compile Qwen tokenizer | 32,508.3 | 443,805.9 | 13.65x |
| compile xDS-like | 3,281.4 | 21,302.7 | 6.49x |
| find Qwen tokenizer | 40,169.2 | 64,020.0 | 1.59x |
| findAll Qwen (borrowed) | 39,347.5 | 63,925.8 | 1.62x |
| findAll Qwen (owning) | 40,412.5 | 63,808.3 | 1.58x |
| find CJK tokenizer | 170,195.8 | 215,617.5 | 1.27x |
| find HTML tag | 47,770.6 | 126,099.4 | 2.64x |
| find URL | 34,336.3 | 90,556.2 | 2.64x |
| find JSON string literal | 7,920.8 | 16,441.5 | 2.08x |
| find JSON number | 33,086.9 | 61,819.2 | 1.87x |
| find word boundary | 77,329.8 | 141,749.8 | 1.83x |
| find (?i) literal | 42,813.8 | 84,465.4 | 1.97x |
| find alternation (5 words) | 141,190.4 | 169,289.6 | 1.20x |
| find (?i) alternation | 81,214.0 | 183,622.5 | 2.26x |
| find 10-word alternation | 204,326.7 | 296,797.1 | 1.45x |
| find Greek class | 59,894.6 | 90,530.2 | 1.51x |
| find prefix+suffix | 8,650.6 | 30,005.8 | 3.47x |
| replaceAll email captures | 25,587.9 | 89,366.9 | 3.49x |
| find IPv4 | 71,654.4 | 131,481.7 | 1.83x |
| find date | 38,817.3 | 122,942.5 | 3.17x |
| find 20-word alternation | 204,566.0 | 309,621.5 | 1.51x |
| find anchored line | 2,318.3 | 8,522.3 | 3.68x |
| find (?i) Unicode literal | 78,055.4 | 124,561.2 | 1.60x |
| find shared-prefix alternation | 22,887.5 | 31,419.0 | 1.37x |
| find one-char alternation | 13,796.0 | 18,394.4 | 1.33x |
| find hex color | 34,897.9 | 84,079.4 | 2.41x |
| find version | 62,677.1 | 112,229.0 | 1.79x |
| find nullable prefix | 10,644.0 | 39,970.0 | 3.76x |
| find identifier | 50,559.8 | 104,129.4 | 2.06x |
| find thousands | 39,532.3 | 120,640.8 | 3.05x |
| find domain | 34,369.8 | 122,254.6 | 3.56x |
| find percent | 31,810.0 | 121,807.7 | 3.83x |
| find time | 47,176.0 | 109,114.2 | 2.31x |
| find end-anchored word | 13,913.8 | 32,207.1 | 2.31x |
| find UUID | 32,889.2 | 64,294.4 | 1.95x |
| find semver | 83,701.9 | 89,036.2 | 1.06x |
| find email TLD | 13,328.1 | 23,519.0 | 1.76x |
| find CIDR | 75,383.3 | 124,250.0 | 1.65x |
| find line full | 2,130.6 | 10,590.4 | 4.97x |
| find optional prefix run | 112,081.3 | 188,916.7 | 1.69x |
| find repeated literal group | 47,167.1 | 137,040.6 | 2.91x |
| find camelCase | 89,766.7 | 96,897.9 | 1.08x |
| find key-value | 91,591.5 | 206,362.7 | 2.25x |
| find IP port | 91,278.3 | 142,306.5 | 1.56x |
| find (?i) class | 23,987.1 | 40,177.7 | 1.67x |
| find prefix alternation | 121,190.8 | 164,302.3 | 1.36x |
| find signed number | 43,908.3 | 71,386.7 | 1.63x |
| find html attribute | 51,456.9 | 103,396.7 | 2.01x |
| find markdown heading | 35,518.5 | 73,711.5 | 2.08x |
| find mixed alternation | 175,526.5 | 359,699.2 | 2.05x |
| split whitespace (22 KiB) | 17,061.5 | 74,213.8 | 4.35x |
| split commas (29 KiB) | 15,904.6 | 55,372.7 | 3.48x |
| fullmatch literal | 1.8 | 9.1 | 5.06x |
| fullmatch class | 5.1 | 32.0 | 6.27x |
| fullmatch xDS-like | 10.4 | 29.6 | 2.85x |
| replaceAll a+ -> x | 21,032.5 | 102,575.4 | 4.88x |
| replaceAll \A|\z -> X | 2,887.9 | 7,517.7 | 2.60x |
| RegexSet 9 no-match patterns | 1,999.6 | 38,202.7 | 19.11x |

regexz is faster on all 58 measured cases. The ranges are 13.65x on
tokenizer compilation, 6.49x on a small-pattern compile, 1.27–1.62x on
tokenizer scans and match iteration, 1.06–3.83x on search scans, 3.48–4.35x
on splits, 2.85–6.27x on full-match calls, 4.88x on a set-run replacement,
3.49x on a capture replacement, 2.60x on a zero-width replacement and 19.11x
on the nine-pattern set. The thinnest margins are the semver scan at 1.06x
and the camelCase scan at 1.08x.

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
nullable-prefix case moved from 1.30x to 3.76x. Unbounded run chains scan
contiguous ASCII runs such as `[0-9]` and `[a-z]` with a range check instead
of a byte table, and dispatch the run/literal elements before the rare
optional and alternation cases; semver, camelCase, IP-port and key-value
scans improve 4-7%.

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
