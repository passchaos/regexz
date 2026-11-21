# Comparison with Rust's `regex`

macOS ARM64, Zig 0.16.0 ReleaseFast, Rust `regex` 1.13.2, November 2026.
The harnesses live in [`tools/compare`](../tools/compare): `zig_regex.zig`
runs regexz and `rust_regex` runs the same inputs and patterns through Rust's
`regex` crate. Both report the median of five batches per case.

Method: the latest sweep executed the two binaries alternately, six times
(three rounds before/after and three rounds after/before). The table reports
medians across those executions. The shared host was heavily loaded (load
average about 16), so absolute times are inflated; the interleaved ratios are
the meaningful column. Raw samples and executable SHA-256 identities are in
[`rust-comparison-current.json`](rust-comparison-current.json).
Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 32,054.6 | 449,692.2 | 14.03x |
| compile xDS-like | 3,201.1 | 22,038.8 | 6.88x |
| find Qwen tokenizer | 38,085.4 | 68,740.0 | 1.80x |
| findAll Qwen (borrowed) | 37,095.8 | 69,700.0 | 1.88x |
| findAll Qwen (owning) | 36,966.2 | 67,343.4 | 1.82x |
| find CJK tokenizer | 135,239.2 | 245,239.2 | 1.81x |
| find HTML tag | 48,347.9 | 128,865.0 | 2.67x |
| find URL | 35,493.1 | 87,640.3 | 2.47x |
| find JSON string literal | 7,970.6 | 17,495.5 | 2.20x |
| find JSON number | 31,951.0 | 65,587.6 | 2.05x |
| find word boundary | 72,929.1 | 142,647.4 | 1.96x |
| find (?i) literal | 43,248.8 | 88,017.4 | 2.04x |
| find alternation (5 words) | 104,684.2 | 183,600.5 | 1.75x |
| find (?i) alternation | 74,479.1 | 202,690.6 | 2.72x |
| find 10-word alternation | 186,990.6 | 314,084.7 | 1.68x |
| find Greek class | 60,394.8 | 94,202.8 | 1.56x |
| find prefix+suffix | 8,802.5 | 31,698.9 | 3.60x |
| replaceAll email captures | 26,913.3 | 92,728.6 | 3.45x |
| find IPv4 | 72,804.5 | 132,627.1 | 1.82x |
| find date | 39,156.1 | 130,081.6 | 3.32x |
| find 20-word alternation | 185,113.8 | 329,119.5 | 1.78x |
| find anchored line | 2,282.4 | 9,231.2 | 4.04x |
| find (?i) Unicode literal | 76,503.4 | 128,929.1 | 1.69x |
| find shared-prefix alternation | 23,820.2 | 30,196.5 | 1.27x |
| find one-char alternation | 11,961.8 | 19,163.7 | 1.60x |
| find hex color | 33,965.1 | 89,197.9 | 2.63x |
| find version | 58,454.5 | 113,213.4 | 1.94x |
| find nullable prefix | 10,083.9 | 39,992.4 | 3.97x |
| find identifier | 49,549.4 | 103,920.6 | 2.10x |
| find thousands | 41,632.3 | 118,605.0 | 2.85x |
| find domain | 34,964.4 | 126,683.1 | 3.62x |
| find percent | 27,079.0 | 129,438.2 | 4.78x |
| find time | 48,491.9 | 116,509.6 | 2.40x |
| find end-anchored word | 14,170.8 | 32,925.2 | 2.32x |
| find UUID | 32,105.3 | 72,705.1 | 2.26x |
| find semver | 74,556.9 | 99,685.8 | 1.34x |
| find email TLD | 11,870.8 | 24,679.5 | 2.08x |
| find CIDR | 75,998.9 | 131,327.8 | 1.73x |
| find line full | 1,784.8 | 14,201.1 | 7.96x |
| find optional prefix run | 41,317.9 | 201,968.9 | 4.89x |
| find repeated literal group | 48,539.1 | 137,075.3 | 2.82x |
| find camelCase | 68,315.1 | 99,915.1 | 1.46x |
| find key-value | 100,867.8 | 202,390.2 | 2.01x |
| find IP port | 83,816.5 | 139,757.0 | 1.67x |
| find (?i) class | 25,502.2 | 38,579.6 | 1.51x |
| find prefix alternation | 123,859.9 | 165,483.3 | 1.34x |
| find signed number | 38,203.0 | 64,291.1 | 1.68x |
| find html attribute | 52,431.2 | 100,567.0 | 1.92x |
| find markdown heading | 38,106.7 | 74,010.4 | 1.94x |
| find mixed alternation | 177,716.6 | 350,831.7 | 1.97x |
| split whitespace (22 KiB) | 17,925.8 | 81,016.6 | 4.52x |
| split commas (29 KiB) | 17,291.2 | 56,558.9 | 3.27x |
| fullmatch literal | 1.8 | 9.8 | 5.44x |
| fullmatch class | 5.4 | 35.0 | 6.49x |
| fullmatch xDS-like | 10.4 | 31.6 | 3.05x |
| replaceAll a+ -> x | 22,226.5 | 106,724.2 | 4.80x |
| replaceAll \A\|\z -> X | 2,953.1 | 8,265.3 | 2.80x |
| RegexSet 9 no-match patterns | 1,917.4 | 40,699.1 | 21.23x |

regexz is faster on all 58 measured cases. The ranges are 14.12x on
tokenizer compilation, 6.66x on a small-pattern compile, 1.32–1.63x on
tokenizer scans and match iteration, 1.09–3.99x on search scans, 3.40–4.35x
on splits, 3.36–6.19x on full-match calls, 4.91x on a set-run replacement,
3.49x on a capture replacement, 2.96x on a zero-width replacement and 20.68x
on the nine-pattern set. The thinnest margins are the shared-prefix
alternation at 1.27x, the prefix alternation and semver at 1.34x, and the
camelCase scan at 1.46x.

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
