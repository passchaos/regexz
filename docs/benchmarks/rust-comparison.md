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
| compile Qwen tokenizer | 31,363.1 | 431,797.1 | 13.77x |
| compile xDS-like | 3,332.6 | 21,359.6 | 6.41x |
| find Qwen tokenizer | 37,016.7 | 64,475.0 | 1.74x |
| findAll Qwen (borrowed) | 35,668.3 | 66,730.9 | 1.87x |
| findAll Qwen (owning) | 36,074.2 | 68,224.6 | 1.89x |
| find CJK tokenizer | 139,827.5 | 235,758.8 | 1.69x |
| find HTML tag | 51,802.8 | 132,095.6 | 2.55x |
| find URL | 35,986.4 | 98,231.6 | 2.73x |
| find JSON string literal | 8,779.5 | 19,078.8 | 2.17x |
| find JSON number | 31,149.7 | 64,811.9 | 2.08x |
| find word boundary | 74,988.2 | 133,389.7 | 1.78x |
| find (?i) literal | 42,885.7 | 81,868.5 | 1.91x |
| find alternation (5 words) | 101,191.1 | 160,397.0 | 1.59x |
| find (?i) alternation | 71,960.4 | 181,476.0 | 2.52x |
| find 10-word alternation | 181,759.3 | 305,639.0 | 1.68x |
| find Greek class | 58,008.2 | 91,461.5 | 1.58x |
| find prefix+suffix | 8,527.0 | 30,151.5 | 3.54x |
| replaceAll email captures | 24,721.3 | 91,191.2 | 3.69x |
| find IPv4 | 69,393.6 | 125,077.6 | 1.80x |
| find date | 39,344.7 | 123,453.6 | 3.14x |
| find 20-word alternation | 181,924.2 | 318,035.8 | 1.75x |
| find anchored line | 2,253.3 | 8,573.5 | 3.80x |
| find (?i) Unicode literal | 86,054.8 | 128,700.4 | 1.50x |
| find shared-prefix alternation | 22,860.8 | 30,063.1 | 1.32x |
| find one-char alternation | 11,762.2 | 18,679.5 | 1.59x |
| find hex color | 34,533.6 | 89,216.4 | 2.58x |
| find version | 60,872.2 | 112,335.1 | 1.85x |
| find nullable prefix | 9,891.5 | 42,464.4 | 4.29x |
| find identifier | 48,911.3 | 106,104.0 | 2.17x |
| find thousands | 40,441.5 | 113,157.9 | 2.80x |
| find domain | 34,934.4 | 120,457.3 | 3.45x |
| find percent | 28,350.2 | 121,983.8 | 4.30x |
| find time | 46,201.4 | 106,717.0 | 2.31x |
| find end-anchored word | 14,509.5 | 32,547.0 | 2.24x |
| find UUID | 33,292.4 | 70,567.1 | 2.12x |
| find semver | 65,108.4 | 90,320.4 | 1.39x |
| find email TLD | 10,203.6 | 21,644.3 | 2.12x |
| find CIDR | 75,493.4 | 123,563.1 | 1.64x |
| find line full | 1,745.5 | 10,142.8 | 5.81x |
| find optional prefix run | 39,667.7 | 182,021.6 | 4.59x |
| find repeated literal group | 48,599.4 | 131,940.5 | 2.71x |
| find camelCase | 68,906.9 | 102,761.4 | 1.49x |
| find key-value | 94,926.2 | 208,395.5 | 2.20x |
| find IP port | 81,245.9 | 133,920.8 | 1.65x |
| find (?i) class | 25,465.9 | 37,865.0 | 1.49x |
| find prefix alternation | 121,625.1 | 162,639.4 | 1.34x |
| find signed number | 37,016.7 | 66,350.4 | 1.79x |
| find html attribute | 50,329.2 | 106,532.7 | 2.12x |
| find markdown heading | 37,522.0 | 76,279.4 | 2.03x |
| find mixed alternation | 178,568.2 | 348,179.4 | 1.95x |
| find capitalized words | 1,837.4 | 118,755.5 | 64.63x |
| find markdown list | 18,924.5 | 30,426.3 | 1.61x |
| find JSON escaped string | 7,825.2 | 16,794.1 | 2.15x |
| find double spaces | 10,645.7 | 9,175.3 | 0.86x |
| find log level | 2,217.0 | 2,051.1 | 0.93x |
| split whitespace (22 KiB) | 17,771.9 | 75,421.6 | 4.24x |
| split commas (29 KiB) | 15,679.1 | 55,172.3 | 3.52x |
| fullmatch literal | 1.8 | 9.4 | 5.34x |
| fullmatch class | 5.2 | 32.7 | 6.23x |
| fullmatch xDS-like | 10.2 | 30.5 | 2.98x |
| replaceAll a+ -> x | 21,530.0 | 102,817.1 | 4.78x |
| replaceAll \A\|\z -> X | 2,826.2 | 7,626.4 | 2.70x |
| RegexSet 9 no-match patterns | 1,972.7 | 37,971.4 | 19.25x |

regexz is faster on all 58 measured cases. The ranges are 14.12x on
tokenizer compilation, 6.66x on a small-pattern compile, 1.32–1.63x on
tokenizer scans and match iteration, 1.09–3.99x on search scans, 3.40–4.35x
on splits, 3.36–6.19x on full-match calls, 4.91x on a set-run replacement,
3.49x on a capture replacement, 2.96x on a zero-width replacement and 20.68x
on the nine-pattern set. Two added cases are slightly behind Rust: runs of
two or more spaces at 0.86x and case-insensitive log levels at 0.93x. Among
the cases ahead, the thinnest margins are the shared-prefix alternation at
1.32x, the prefix alternation at 1.34x and semver at 1.39x.

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
Sixty-one of the 63 cases are ahead; runs of two or more spaces (0.86x) and
case-insensitive log levels (0.93x) remain slightly behind.

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
