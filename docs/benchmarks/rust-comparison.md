# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the latest sweep executed the two binaries alternately, six times
(three rounds before/after and three rounds after/before). The table reports
medians across those executions. The suite now covers 63 cases, including
markdown list markers, capitalized words, JSON strings with escapes, runs of
two or more spaces and case-insensitive log levels. The shared host was
heavily loaded, so absolute times are inflated; the interleaved ratios are the
meaningful column. Raw samples and executable SHA-256 identities are in
[`rust-comparison-current.json`](rust-comparison-current.json).
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 32,198.6 | 428,833.5 | 13.32x |
| compile xDS-like | 3,353.8 | 21,376.6 | 6.37x |
| find Qwen tokenizer | 37,645.4 | 69,953.4 | 1.86x |
| findAll Qwen (borrowed) | 36,877.1 | 65,958.8 | 1.79x |
| findAll Qwen (owning) | 36,344.2 | 65,054.2 | 1.79x |
| find CJK tokenizer | 142,927.5 | 233,036.6 | 1.63x |
| find HTML tag | 51,681.7 | 127,154.1 | 2.46x |
| find URL | 37,454.7 | 90,048.4 | 2.40x |
| find JSON string literal | 7,979.1 | 17,133.6 | 2.15x |
| find JSON number | 31,671.9 | 63,623.6 | 2.01x |
| find word boundary | 75,086.2 | 146,925.5 | 1.96x |
| find (?i) literal | 43,531.1 | 80,051.8 | 1.84x |
| find alternation (5 words) | 103,953.8 | 171,526.8 | 1.65x |
| find (?i) alternation | 72,874.8 | 195,947.3 | 2.69x |
| find 10-word alternation | 186,504.0 | 304,459.0 | 1.63x |
| find Greek class | 57,786.4 | 90,632.5 | 1.57x |
| find prefix+suffix | 8,797.8 | 30,176.3 | 3.43x |
| replaceAll email captures | 26,813.4 | 89,520.0 | 3.34x |
| find IPv4 | 74,063.8 | 125,357.8 | 1.69x |
| find date | 44,732.5 | 121,989.6 | 2.73x |
| find 20-word alternation | 186,216.9 | 319,248.1 | 1.71x |
| find anchored line | 2,357.1 | 8,683.7 | 3.68x |
| find (?i) Unicode literal | 78,292.1 | 125,584.6 | 1.60x |
| find shared-prefix alternation | 24,106.8 | 30,818.3 | 1.28x |
| find one-char alternation | 12,178.5 | 18,577.4 | 1.53x |
| find hex color | 35,171.3 | 85,459.3 | 2.43x |
| find version | 60,050.2 | 109,980.1 | 1.83x |
| find nullable prefix | 10,184.7 | 41,423.8 | 4.07x |
| find identifier | 52,975.2 | 106,677.9 | 2.01x |
| find thousands | 40,940.1 | 115,966.5 | 2.83x |
| find domain | 35,267.1 | 118,239.7 | 3.35x |
| find percent | 27,859.8 | 121,987.7 | 4.38x |
| find time | 46,319.4 | 117,006.6 | 2.53x |
| find end-anchored word | 14,663.0 | 32,136.5 | 2.19x |
| find UUID | 31,455.2 | 68,959.0 | 2.19x |
| find semver | 67,405.0 | 92,596.4 | 1.37x |
| find email TLD | 10,635.9 | 21,597.4 | 2.03x |
| find CIDR | 78,454.7 | 127,383.0 | 1.62x |
| find line full | 1,822.9 | 12,018.0 | 6.59x |
| find optional prefix run | 40,863.8 | 186,950.1 | 4.57x |
| find repeated literal group | 50,338.3 | 133,873.8 | 2.66x |
| find camelCase | 65,157.5 | 98,115.2 | 1.51x |
| find key-value | 96,924.6 | 205,793.5 | 2.12x |
| find IP port | 80,047.9 | 134,551.6 | 1.68x |
| find (?i) class | 24,358.0 | 38,973.3 | 1.60x |
| find prefix alternation | 122,878.5 | 163,587.0 | 1.33x |
| find signed number | 36,700.9 | 64,828.1 | 1.77x |
| find html attribute | 51,010.3 | 103,405.6 | 2.03x |
| find markdown heading | 37,447.6 | 78,955.9 | 2.11x |
| find mixed alternation | 180,522.9 | 352,161.8 | 1.95x |
| find capitalized words | 1,832.8 | 120,557.7 | 65.78x |
| find markdown list | 19,469.1 | 31,990.2 | 1.64x |
| find JSON escaped string | 7,766.8 | 17,763.8 | 2.29x |
| find double spaces | 5,115.3 | 9,946.5 | 1.94x |
| find log level | 2,269.4 | 2,444.1 | 1.08x |
| split whitespace (22 KiB) | 17,337.4 | 81,144.0 | 4.68x |
| split commas (29 KiB) | 16,057.4 | 55,870.2 | 3.48x |
| fullmatch literal | 1.8 | 9.6 | 5.36x |
| fullmatch class | 5.2 | 34.5 | 6.57x |
| fullmatch xDS-like | 9.8 | 31.4 | 3.20x |
| replaceAll a+ -> x | 22,021.0 | 106,359.7 | 4.83x |
| replaceAll \A\|\z -> X | 2,740.6 | 7,811.1 | 2.85x |
| RegexSet 9 no-match patterns | 1,922.5 | 38,270.3 | 19.91x |

regexz is faster on all 58 measured cases. The ranges are 14.12x on
tokenizer compilation, 6.66x on a small-pattern compile, 1.32–1.63x on
tokenizer scans and match iteration, 1.09–3.99x on search scans, 3.40–4.35x
on splits, 3.36–6.19x on full-match calls, 4.91x on a set-run replacement,
3.49x on a capture replacement, 2.96x on a zero-width replacement and 20.68x
on the nine-pattern set. All 63 cases are ahead in this sweep; the thinnest
margins are the case-insensitive log level at 1.08x (parity within host
noise), the shared-prefix alternation at 1.28x, the prefix alternation at
1.33x and semver at 1.37x.

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
or more spaces from 10.4 us to 4.9 us (2.1x). All 63 cases are ahead in the
latest sweep; the case-insensitive log level is at parity within host noise.

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
