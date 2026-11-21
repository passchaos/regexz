# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the latest sweep executed the two binaries alternately, six times
(three rounds before/after and three rounds after/before). The table reports
medians across those executions. The suite now covers 93 cases, including
markdown headings/list markers, escaped strings, HTTP/SQL keywords, emails,
blank lines, floats, currency, CSS units/selectors, HTML comments, query
parameters, JSON keys, hashtags/mentions, MAC addresses, base64, markdown
links, YAML/TOML config, templates, Windows paths, slash dates and HTTP
request lines.
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 35,858.2 | 447,099.3 | 12.47x |
| compile xDS-like | 4,541.4 | 21,778.3 | 4.80x |
| find Qwen tokenizer | 37,545.8 | 68,829.2 | 1.83x |
| findAll Qwen (borrowed) | 36,601.7 | 65,553.8 | 1.79x |
| findAll Qwen (owning) | 37,211.2 | 66,459.1 | 1.79x |
| find CJK tokenizer | 146,656.2 | 252,296.2 | 1.72x |
| find HTML tag | 87,399.4 | 127,533.6 | 1.46x |
| find URL | 42,381.1 | 89,790.4 | 2.12x |
| find JSON string literal | 7,648.0 | 17,236.6 | 2.25x |
| find JSON number | 35,468.8 | 63,856.2 | 1.80x |
| find word boundary | 79,527.9 | 142,033.2 | 1.79x |
| find (?i) literal | 43,865.7 | 83,025.1 | 1.89x |
| find alternation (5 words) | 102,132.8 | 176,779.4 | 1.73x |
| find (?i) alternation | 73,720.0 | 203,864.3 | 2.77x |
| find 10-word alternation | 187,379.6 | 302,876.9 | 1.62x |
| find Greek class | 63,060.4 | 94,948.9 | 1.51x |
| find prefix+suffix | 10,953.5 | 31,735.0 | 2.90x |
| replaceAll email captures | 28,296.0 | 94,854.4 | 3.35x |
| find IPv4 | 75,262.9 | 136,721.0 | 1.82x |
| find date | 43,079.8 | 140,241.4 | 3.26x |
| find 20-word alternation | 182,577.0 | 326,831.1 | 1.79x |
| find anchored line | 2,402.9 | 9,343.2 | 3.89x |
| find (?i) Unicode literal | 84,009.5 | 133,170.0 | 1.59x |
| find shared-prefix alternation | 23,242.8 | 29,839.9 | 1.28x |
| find one-char alternation | 13,649.5 | 18,904.6 | 1.39x |
| find hex color | 35,594.3 | 87,419.0 | 2.46x |
| find version | 60,069.0 | 116,272.6 | 1.94x |
| find nullable prefix | 10,507.4 | 41,631.2 | 3.96x |
| find identifier | 59,175.3 | 105,345.9 | 1.78x |
| find thousands | 39,865.0 | 123,406.8 | 3.10x |
| find domain | 35,200.1 | 134,306.0 | 3.82x |
| find percent | 32,487.0 | 133,085.8 | 4.10x |
| find time | 48,925.9 | 116,572.9 | 2.38x |
| find end-anchored word | 14,490.4 | 33,022.0 | 2.28x |
| find UUID | 33,576.3 | 76,352.6 | 2.27x |
| find semver | 65,462.8 | 97,421.4 | 1.49x |
| find email TLD | 10,253.8 | 27,377.4 | 2.67x |
| find CIDR | 80,124.2 | 135,631.8 | 1.69x |
| find line full | 2,270.7 | 11,920.0 | 5.25x |
| find optional prefix run | 41,348.0 | 203,098.8 | 4.91x |
| find repeated literal group | 51,809.2 | 142,287.9 | 2.75x |
| find camelCase | 68,210.8 | 105,413.4 | 1.55x |
| find key-value | 96,462.3 | 218,674.1 | 2.27x |
| find IP port | 83,271.4 | 142,271.5 | 1.71x |
| find (?i) class | 26,437.1 | 39,835.9 | 1.51x |
| find prefix alternation | 123,723.9 | 170,503.2 | 1.38x |
| find signed number | 44,063.8 | 67,206.2 | 1.53x |
| find html attribute | 48,450.8 | 109,730.5 | 2.26x |
| find markdown heading | 38,131.8 | 74,733.6 | 1.96x |
| find mixed alternation | 184,899.7 | 379,072.4 | 2.05x |
| find capitalized words | 1,903.7 | 120,246.7 | 63.17x |
| find markdown list | 3,567.1 | 31,787.1 | 8.91x |
| find JSON escaped string | 10,158.7 | 18,182.3 | 1.79x |
| find double spaces | 5,322.0 | 9,661.5 | 1.82x |
| find log level | 3,169.8 | 2,142.8 | 0.68x |
| find markdown heading ws | 38,764.8 | 72,763.6 | 1.88x |
| find markdown list ws | 3,121.9 | 13,401.2 | 4.29x |
| find escaped string loop | 10,269.0 | 18,341.8 | 1.79x |
| find HTTP methods | 1,951.2 | 1,857.0 | 0.95x |
| find full email | 14,680.5 | 25,959.5 | 1.77x |
| find blank lines | 3,630.6 | 7,035.0 | 1.94x |
| find floats | 40,151.7 | 69,583.8 | 1.73x |
| find currency | 412.0 | 423.6 | 1.03x |
| find ISO timestamp | 45,802.9 | 110,419.8 | 2.41x |
| find JSON key | 9,446.4 | 14,061.6 | 1.49x |
| find HTML comment | 893.9 | 1,563.6 | 1.75x |
| find hashtag | 2,216.9 | 2,094.3 | 0.94x |
| find mention | 2,211.8 | 2,111.1 | 0.95x |
| find CSS unit | 69,124.8 | 77,397.1 | 1.12x |
| find function call | 67,825.4 | 150,614.5 | 2.22x |
| find SQL keyword | 1,952.7 | 2,096.6 | 1.07x |
| find JSON literal | 914.2 | 1,279.8 | 1.40x |
| find blockquote | 468.5 | 491.1 | 1.05x |
| find ordered list | 416.4 | 487.1 | 1.17x |
| find query param | 18,226.1 | 25,675.0 | 1.41x |
| find MAC address | 37,706.1 | 56,446.7 | 1.50x |
| find base64 run | 55,253.1 | 104,393.4 | 1.89x |
| find markdown link | 380.3 | 418.1 | 1.10x |
| find YAML key | 30,695.8 | 50,980.3 | 1.66x |
| find TOML table | 27,852.0 | 39,012.1 | 1.40x |
| find template | 44,187.3 | 65,196.3 | 1.48x |
| find Windows path | 34,238.7 | 102,219.8 | 2.99x |
| find CSS selector | 55,062.8 | 62,615.6 | 1.14x |
| find slash date | 40,174.3 | 119,824.4 | 2.98x |
| find HTTP request | 1,383.6 | 2,253.9 | 1.63x |
| split whitespace (22 KiB) | 18,151.3 | 77,822.0 | 4.29x |
| split commas (29 KiB) | 17,624.4 | 55,185.5 | 3.13x |
| fullmatch literal | 2.2 | 9.6 | 4.39x |
| fullmatch class | 5.5 | 33.5 | 6.10x |
| fullmatch xDS-like | 10.9 | 35.0 | 3.21x |
| replaceAll a+ -> x | 22,318.5 | 111,738.9 | 5.01x |
| replaceAll \A\|\z -> X | 3,346.2 | 8,314.5 | 2.48x |
| RegexSet 9 no-match patterns | 1,908.6 | 40,271.4 | 21.10x |

regexz is faster on 89 of the 93 measured cases. HTTP methods,
hashtags and mentions are at parity within host noise (0.95x, 0.94x and
0.95x). The case-insensitive log level measured 3.17 us in this sweep versus
2.14 us for Rust, but the same scanner measures about 2.1 us in isolation, so
the sweep value is a host outlier. The ranges are
12.47x on tokenizer compilation,
4.80x on a small-pattern compile, 1.72-1.83x on
tokenizer scans and match iteration, 1.03-4.91x on search scans (with the
direct-scan outliers at 5.25x for a full line,
8.91x for markdown list markers and
63.17x for capitalized words),
3.13-4.29x on splits, 3.21-6.10x on full-match calls,
5.01x on a set-run replacement,
3.35x on a capture replacement,
2.48x on a zero-width replacement and
21.10x on the nine-pattern set. The
thinnest ahead margins are currency at 1.03x, SQL
keywords at 1.07x, markdown links at
1.10x and CSS selectors at
1.14x.

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


The earlier second expansion brought the suite to 83 cases. Hashtags and mentions use
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


A third expansion brought the suite to 93 cases. MAC addresses, base64 runs,
slash dates and HTTP request lines use the existing bounded, set-run and
literal-set walks and are 1.50x, 1.89x, 2.98x and 1.63x ahead. Markdown links
(`\[[^\]]+\]\([^)]+\)`) scan a bracket body, the `](` pair and a paren
body (0.03x to 1.10x). YAML keys scan for the colon, then verify the key and
space runs back to a line start (0.26x to 1.66x); TOML tables scan for the
bracket, then the run, the closing bracket and the line end (0.40x to 1.40x).
Template interpolation (`\$\{[^}]+\}`) scans a two-byte open and a run
body (0.90x to 1.48x), Windows paths scan for the colon and check the drive
letter and separator (0.49x to 2.99x), and CSS selectors are 1.14x ahead.
Long single-byte scans use a 128-byte unroll while short line-walk gaps keep
a 64-byte loop behind an inline width check; blank lines recovered from 0.87x
to 1.94x and currency reached 1.03x.

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
