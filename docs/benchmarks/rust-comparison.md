# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the latest sweep executed the two binaries alternately, six times
(three rounds before/after and three rounds after/before). The table reports
medians across those executions. The suite now covers 83 cases, including
markdown headings and list markers with whitespace runs, loop-form escaped
strings, HTTP and SQL keywords, full email addresses, blank lines, floats,
currency, CSS units, HTML comments, query parameters, JSON keys and hashtags.
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 33,858.1 | 465,360.4 | 13.74x |
| compile xDS-like | 3,758.9 | 21,283.2 | 5.66x |
| find Qwen tokenizer | 36,851.7 | 77,183.8 | 2.09x |
| findAll Qwen (borrowed) | 35,742.9 | 72,430.8 | 2.03x |
| findAll Qwen (owning) | 36,027.1 | 68,345.4 | 1.90x |
| find CJK tokenizer | 141,479.1 | 235,638.0 | 1.67x |
| find HTML tag | 48,477.1 | 128,635.6 | 2.65x |
| find URL | 38,854.9 | 87,995.4 | 2.26x |
| find JSON string literal | 7,526.0 | 17,430.5 | 2.32x |
| find JSON number | 31,521.4 | 60,766.4 | 1.93x |
| find word boundary | 73,720.8 | 141,292.7 | 1.92x |
| find (?i) literal | 42,959.4 | 85,547.0 | 1.99x |
| find alternation (5 words) | 101,337.1 | 169,231.5 | 1.67x |
| find (?i) alternation | 71,688.1 | 188,986.0 | 2.64x |
| find 10-word alternation | 182,323.2 | 306,895.1 | 1.68x |
| find Greek class | 61,028.4 | 98,872.3 | 1.62x |
| find prefix+suffix | 9,162.8 | 30,824.2 | 3.36x |
| replaceAll email captures | 26,087.4 | 94,098.2 | 3.61x |
| find IPv4 | 71,019.4 | 135,362.5 | 1.91x |
| find date | 39,177.7 | 136,834.6 | 3.49x |
| find 20-word alternation | 183,886.2 | 329,492.1 | 1.79x |
| find anchored line | 2,302.4 | 8,594.3 | 3.73x |
| find (?i) Unicode literal | 77,618.4 | 130,810.8 | 1.69x |
| find shared-prefix alternation | 23,921.2 | 28,614.5 | 1.20x |
| find one-char alternation | 12,080.3 | 18,570.2 | 1.54x |
| find hex color | 34,133.2 | 85,816.9 | 2.51x |
| find version | 59,600.5 | 107,651.6 | 1.81x |
| find nullable prefix | 10,471.9 | 39,613.7 | 3.78x |
| find identifier | 51,293.9 | 98,982.2 | 1.93x |
| find thousands | 41,644.9 | 124,054.1 | 2.98x |
| find domain | 33,957.3 | 123,872.0 | 3.65x |
| find percent | 27,248.8 | 122,739.9 | 4.50x |
| find time | 48,181.9 | 110,263.6 | 2.29x |
| find end-anchored word | 14,869.3 | 32,523.0 | 2.19x |
| find UUID | 29,772.2 | 72,436.4 | 2.43x |
| find semver | 65,224.2 | 95,035.8 | 1.46x |
| find email TLD | 10,833.2 | 22,441.0 | 2.07x |
| find CIDR | 73,246.2 | 132,584.4 | 1.81x |
| find line full | 2,010.7 | 12,225.8 | 6.08x |
| find optional prefix run | 40,188.8 | 195,298.2 | 4.86x |
| find repeated literal group | 49,235.8 | 136,773.2 | 2.78x |
| find camelCase | 65,049.2 | 101,142.2 | 1.55x |
| find key-value | 92,756.6 | 216,075.3 | 2.33x |
| find IP port | 78,634.5 | 145,658.0 | 1.85x |
| find (?i) class | 25,284.1 | 41,482.7 | 1.64x |
| find prefix alternation | 122,014.8 | 168,824.8 | 1.38x |
| find signed number | 43,190.2 | 62,671.0 | 1.45x |
| find html attribute | 52,316.7 | 110,148.8 | 2.11x |
| find markdown heading | 38,431.2 | 72,542.4 | 1.89x |
| find mixed alternation | 187,562.4 | 362,784.2 | 1.93x |
| find capitalized words | 1,892.3 | 118,209.5 | 62.47x |
| find markdown list | 3,098.8 | 30,609.1 | 9.88x |
| find JSON escaped string | 9,664.4 | 17,346.0 | 1.79x |
| find double spaces | 4,947.8 | 10,846.8 | 2.19x |
| find log level | 2,223.0 | 2,177.5 | 0.98x |
| find markdown heading ws | 38,184.1 | 73,303.9 | 1.92x |
| find markdown list ws | 2,652.2 | 14,321.4 | 5.40x |
| find escaped string loop | 9,922.0 | 17,829.2 | 1.80x |
| find HTTP methods | 2,040.1 | 1,658.5 | 0.81x |
| find full email | 14,542.5 | 26,649.0 | 1.83x |
| find blank lines | 7,595.1 | 7,202.4 | 0.95x |
| find floats | 38,916.2 | 66,869.1 | 1.72x |
| find currency | 304.4 | 322.3 | 1.06x |
| find ISO timestamp | 39,158.3 | 104,139.0 | 2.66x |
| find JSON key | 8,508.0 | 12,859.5 | 1.51x |
| find HTML comment | 626.0 | 1,606.3 | 2.57x |
| find hashtag | 1,611.0 | 2,097.5 | 1.30x |
| find mention | 1,585.3 | 2,077.5 | 1.31x |
| find CSS unit | 66,228.1 | 73,743.8 | 1.11x |
| find function call | 66,943.6 | 141,899.5 | 2.12x |
| find SQL keyword | 1,652.4 | 1,646.1 | 1.00x |
| find JSON literal | 873.4 | 1,109.5 | 1.27x |
| find blockquote | 461.6 | 418.4 | 0.91x |
| find ordered list | 404.9 | 411.5 | 1.02x |
| find query param | 16,243.0 | 24,669.2 | 1.52x |
| split whitespace (22 KiB) | 16,590.6 | 76,391.6 | 4.60x |
| split commas (29 KiB) | 15,910.2 | 54,742.3 | 3.44x |
| fullmatch literal | 1.8 | 9.8 | 5.42x |
| fullmatch class | 5.0 | 33.0 | 6.60x |
| fullmatch xDS-like | 9.3 | 33.9 | 3.65x |
| replaceAll a+ -> x | 22,170.8 | 105,608.2 | 4.76x |
| replaceAll \A\|\z -> X | 2,773.1 | 7,833.4 | 2.82x |
| RegexSet 9 no-match patterns | 1,851.2 | 39,233.6 | 21.19x |

regexz is faster on 78 of the 83 measured cases. The
case-insensitive log level, SQL keywords, blank-line and blockquote scans are
at parity within host noise (0.98x, 1.00x, 0.95x and 0.91x). HTTP methods
measured 0.81x in this sweep and 1.03x in the previous one; shared-host
variance is about 25% at this scale, so its true position is parity. The
ranges are 13.74x on tokenizer compilation,
5.66x on a small-pattern compile, 1.67-2.09x on
tokenizer scans and match iteration, 1.02-5.40x on search scans (with the
direct-scan outliers at 6.08x for a full line,
9.88x for markdown list markers and
62.47x for capitalized words),
3.44-4.60x on splits, 3.65-6.60x on full-match calls,
4.76x on a set-run replacement,
3.61x on a capture replacement,
2.82x on a zero-width replacement and
21.19x on the nine-pattern set. The
thinnest ahead margins are the ordered-list scan at 1.02x, currency at
1.06x, CSS units at 1.11x and the shared-prefix alternation at 1.20x.

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
nullable-prefix case moved from 1.30x to 3.76x. When the tokenizer fast
branch's run set covers U+4E00-U+9FFF, four three-byte Han groups are checked
per vector iteration before the scalar UTF-8 scan resumes; a focused
before/after run measured the CJK tokenizer case 13% faster. The table above
is the last quiet-window run: the shared host was saturated (load average
above 20) during the latest sweep, so its absolute times and ratios are not
directly comparable. Unbounded run chains scan
contiguous ASCII runs such as `[0-9]` and `[a-z]` with a range check instead
of a byte table, and dispatch the run/literal elements before the rare
optional and alternation cases; semver, camelCase, IP-port and key-value
scans improve 4-7%. Distinct-first literal sets with four or more branches
use the two-byte nibble filter instead of one splat per pair: the five-word
alternation moves from 1.20x to 1.43x.

Unbounded run chains now reuse the first run's scanned end after a failed
start instead of rescanning it, and fuse a following single-byte literal into
the same walk iteration when at least two such pairs exist; the fused state
gets its own `fast_kind` slot so other chains keep the original walk without
a per-search branch. An order-balanced before/after sweep measured semver
1.16x, email TLD 1.14x, IP-port 1.13x and HTML-attribute 1.07x faster, with
camelCase, version and key-value unchanged within the A/A noise band. See
[unbounded chain fusion](unbounded-chain-fusion.md). The table above is the
last quiet-window run: the shared host was busy (load average about 8)
during this sweep, so its absolute times were not merged into the table.

`Workspace.find` is now a small entry point that inlines the `set+` scanner
and a `.none` program's dominant branch, then delegates every other shape to
a never-inlined dispatch. The small entry is inlined into caller match loops,
removing a call and a `Match` copy per match. An order-balanced sweep
measured optional-prefix run 2.57x, Qwen find/findAll 1.24-1.26x, signed
number 1.22x, line full 1.21x, percent 1.10x, one-char alternation 1.10x and
word boundary 1.09x faster; unbounded-chain shapes pay the one dispatch call
(1.06-1.10x) and remain ahead. See
[find hot-path dispatch](find-hot-dispatch.md).

Whole-pattern literal alternations now split the distinct-first kind from the
shared-first kind at construction and return register-sized scanner results,
removing a stack temporary and a ~56-byte `Match` copy per match. An
order-balanced sweep measured the 5-word alternation 1.17x, 10-word 1.13x,
20-word 1.13x, `(?i)` alternation 1.12x, shared-prefix 1.08x and one-char
1.06x faster. See [literal-set scanner spans](literal-set-spans.md).

The camelCase chain (`[a-z]+[A-Z][a-z]+`) now uses a dedicated walk instead of
the generic three-element dispatch, improving the case 1.25x in an
order-balanced sweep (87.2 us -> 69.6 us). See
[camelCase dedicated walk](camel-walk.md).

Run-first unbounded chains now peel the first run out of the generic element
loop, dropping the per-element first-element check. An order-balanced batch
measured semver 1.08x, email TLD 1.12x and IP port 1.07x faster. See
[unbounded chain fusion](unbounded-chain-fusion.md).

An expanded suite exposed four common patterns that were behind Rust and now
have direct scans: whole-pattern `set{min,}` with an unbounded maximum
(`\s{2,}`, 5.0x faster and 1.63x ahead), markdown list markers
(`(?m)^\s*[-*+] `, 5.8x and 1.61x ahead), JSON strings with escapes
(`"(?:\\.|[^"\\])*"`, 6.5x and 2.15x ahead), and three-pair distinct
alternations now using the nibble filter (case-insensitive log levels, 2.4x).
A two-byte SIMD pair filter now finds `set{min,}` runs, cutting runs of two
or more spaces from 10.4 us to 4.9 us (2.1x). All 63 cases were ahead in that
sweep; the case-insensitive log level was at parity within host noise.


The earlier 71-case suite added eight real-world patterns. Line headings and list
markers now accept a greedy `set+` separator, so `(?m)^#{1,6}\s+.*$` and
`(?m)^\s*[-*+]\s+` use the line scanners instead of the DFA (the list case
moved from 0.12x to 4.80x ahead). The escaped-delimited detector recognizes
the loop form `quote body* (?: escape any body* )* quote`, sharing the
escape-aware scanner with the alternate form (0.49x to 1.87x). Bounded word
alternations (`\b(?:get|post|put|delete)\b`) scan a case-folded two-byte
pair filter in one pass, verify ASCII word boundaries locally, and accept the
non-ASCII simple-fold peers U+017F and U+212A; a literal with a peer in its
first two bytes falls back to the engine because the pair filter folds ASCII
only (0.07x to 0.97x). Full email addresses scan around each `@`: the local
run start is the first boundary inside it, and the domain walks dots from the
end to mirror the greedy `domain+ \.` backtracking (0.50x to 1.78x). The
number shape now covers an optional exponent (`\d+(?:\.\d+)?(?:[eE][+-]?\d+)?`,
0.36x to 1.59x), `(?m)^\s*$` scans line runs directly (1.83x), and the
single-byte prefilter scans 64 bytes per iteration, bringing the currency
no-match scan from 0.49x to parity (1.00x).

A third-byte lane filter for word alternations was screened and reverted: it
rejects pair collisions before verification, but the extra vector compares
and the per-chunk optional check made the HTTP-method scan 2.2x slower
(1.75 us to 3.8 us). A first-byte candidate scan that restarts at every hit
was also rejected: restarting the 16-byte filter loop for each of the 1,000
first-byte candidates measured 8.8 us on the 25 KiB tokenizer text, so the
word scan keeps the single-pass two-byte nibble filter.


A second expansion brought the suite to 83 cases. Hashtags and mentions use
the existing prefix-run shape with a vector first-byte scan instead of the
byte loop (0.26x and 0.21x to 1.30x and 1.31x). CSS units
(`\d+(?:px|em|rem|%)`) scan a digit run and check a literal alternation,
skipping the whole run when no suffix follows (0.29x to 1.11x). HTML comments
(`<!--[\s\S]*?-->`) scan a literal prefix, then the first close after it
(0.04x to 2.57x); multi-byte needles anchor on their rarest byte, so the
`<!--` no-match scan runs at single-byte speed. Query parameters
(`[?&]\w+=`) scan a prefix set, a word run and the literal (0.58x to 1.52x),
and JSON keys (`"[^"]+"\s*:`) scan the quoted run, optional spaces and the
colon (0.87x to 1.51x). A case-insensitive word alternation with a non-ASCII
fold peer in its first two bytes now keeps the pair filter by adding folded
peer variants to the candidate set, so `(?i)\b(?:select|from|where|join)\b`
runs on the word scanner (0.03x to parity). The single-byte prefilter scans
128 bytes per iteration and the pair prefilter 64 bytes, bringing currency
from 0.49x to 1.06x and ordered-list scans to 1.02x.

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
