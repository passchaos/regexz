# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the latest sweep executed the two binaries alternately, six times
(three rounds before/after and three rounds after/before). The table reports
medians across those executions. The suite now covers 71 cases, including
markdown headings and list markers with whitespace runs, loop-form escaped
strings, HTTP methods, full email addresses, blank lines, floats and currency.
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 36,770.8 | 465,115.2 | 12.65x |
| compile xDS-like | 3,647.6 | 22,610.6 | 6.20x |
| find Qwen tokenizer | 37,504.6 | 69,887.5 | 1.86x |
| findAll Qwen (borrowed) | 36,697.9 | 66,957.1 | 1.82x |
| findAll Qwen (owning) | 36,504.6 | 63,934.2 | 1.75x |
| find CJK tokenizer | 139,897.1 | 239,501.7 | 1.71x |
| find HTML tag | 49,658.1 | 124,467.7 | 2.51x |
| find URL | 38,718.0 | 85,863.0 | 2.22x |
| find JSON string literal | 7,737.4 | 17,469.5 | 2.26x |
| find JSON number | 31,847.8 | 62,505.3 | 1.96x |
| find word boundary | 73,343.0 | 134,186.0 | 1.83x |
| find (?i) literal | 43,688.2 | 82,262.3 | 1.88x |
| find alternation (5 words) | 102,246.3 | 172,050.0 | 1.68x |
| find (?i) alternation | 72,195.3 | 191,521.5 | 2.65x |
| find 10-word alternation | 185,039.8 | 304,363.1 | 1.64x |
| find Greek class | 58,667.2 | 90,407.0 | 1.54x |
| find prefix+suffix | 9,116.9 | 32,165.1 | 3.53x |
| replaceAll email captures | 25,950.2 | 92,934.1 | 3.58x |
| find IPv4 | 70,929.1 | 135,473.5 | 1.91x |
| find date | 40,988.1 | 142,515.2 | 3.48x |
| find 20-word alternation | 182,443.2 | 326,098.5 | 1.79x |
| find anchored line | 2,279.1 | 8,906.3 | 3.91x |
| find (?i) Unicode literal | 79,147.1 | 138,559.9 | 1.75x |
| find shared-prefix alternation | 22,048.5 | 29,774.0 | 1.35x |
| find one-char alternation | 11,955.0 | 19,063.5 | 1.59x |
| find hex color | 33,903.4 | 87,387.4 | 2.58x |
| find version | 60,818.2 | 119,638.6 | 1.97x |
| find nullable prefix | 9,731.0 | 43,549.9 | 4.48x |
| find identifier | 52,538.0 | 109,856.6 | 2.09x |
| find thousands | 42,060.8 | 122,644.5 | 2.92x |
| find domain | 33,369.2 | 118,470.1 | 3.55x |
| find percent | 27,413.1 | 129,115.1 | 4.71x |
| find time | 47,679.7 | 109,035.2 | 2.29x |
| find end-anchored word | 13,911.1 | 32,512.3 | 2.34x |
| find UUID | 32,038.4 | 73,100.8 | 2.28x |
| find semver | 65,183.6 | 93,834.5 | 1.44x |
| find email TLD | 11,269.3 | 24,098.0 | 2.14x |
| find CIDR | 78,209.7 | 130,710.6 | 1.67x |
| find line full | 1,929.5 | 15,350.4 | 7.96x |
| find optional prefix run | 40,803.3 | 195,300.5 | 4.79x |
| find repeated literal group | 51,014.9 | 141,792.8 | 2.78x |
| find camelCase | 69,306.5 | 116,254.4 | 1.68x |
| find key-value | 97,367.1 | 218,036.9 | 2.24x |
| find IP port | 80,956.9 | 142,367.9 | 1.76x |
| find (?i) class | 25,086.2 | 37,749.8 | 1.50x |
| find prefix alternation | 122,882.3 | 163,931.7 | 1.33x |
| find signed number | 38,959.0 | 65,341.8 | 1.68x |
| find html attribute | 51,077.4 | 113,597.9 | 2.22x |
| find markdown heading | 38,282.3 | 73,098.4 | 1.91x |
| find mixed alternation | 182,346.5 | 355,849.8 | 1.95x |
| find capitalized words | 1,864.4 | 120,590.9 | 64.68x |
| find markdown list | 2,857.8 | 31,812.4 | 11.13x |
| find JSON escaped string | 9,103.5 | 17,871.2 | 1.96x |
| find double spaces | 5,234.3 | 12,161.9 | 2.32x |
| find log level | 2,162.9 | 2,155.3 | 1.00x |
| find markdown heading ws | 37,727.7 | 71,487.5 | 1.89x |
| find markdown list ws | 2,633.4 | 12,634.8 | 4.80x |
| find escaped string loop | 9,061.9 | 16,911.3 | 1.87x |
| find HTTP methods | 1,770.9 | 1,719.2 | 0.97x |
| find full email | 14,037.4 | 25,048.8 | 1.78x |
| find blank lines | 3,633.2 | 6,662.7 | 1.83x |
| find floats | 38,459.0 | 61,110.4 | 1.59x |
| find currency | 341.9 | 343.1 | 1.00x |
| split whitespace (22 KiB) | 16,580.3 | 74,518.9 | 4.49x |
| split commas (29 KiB) | 15,817.4 | 55,415.2 | 3.50x |
| fullmatch literal | 1.9 | 9.4 | 5.11x |
| fullmatch class | 5.4 | 32.6 | 6.04x |
| fullmatch xDS-like | 9.6 | 31.8 | 3.30x |
| replaceAll a+ -> x | 21,635.1 | 109,734.5 | 5.07x |
| replaceAll \A\|\z -> X | 2,831.9 | 7,981.4 | 2.82x |
| RegexSet 9 no-match patterns | 1,839.1 | 39,873.2 | 21.68x |

regexz is faster on 69 of the 71 measured cases; the case-insensitive
log level and the HTTP-method scan are at parity within host noise (1.00x and
0.97x). The ranges are 12.65x on tokenizer compilation, 6.20x on a
small-pattern compile, 1.71-1.86x on tokenizer scans and match iteration,
1.33-4.79x on search scans (with the direct-scan outliers at 7.96x for a full
line, 11.13x for markdown list markers and 64.68x for capitalized words),
3.50-4.49x on splits, 3.30-6.04x on full-match calls, 5.07x on a set-run
replacement, 3.58x on a capture replacement, 2.82x on a zero-width
replacement and 21.68x on the nine-pattern set. The thinnest ahead margins
are the prefix alternation at 1.33x, shared-prefix alternation at 1.35x,
semver at 1.44x, `(?i)` class at 1.50x and the CJK tokenizer at 1.71x.

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


The 71-case suite adds eight real-world patterns. Line headings and list
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
