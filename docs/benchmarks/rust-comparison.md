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
| compile Qwen tokenizer | 31,794.0 | 449,019.2 | 14.12x |
| compile xDS-like | 3,199.6 | 21,314.8 | 6.66x |
| find Qwen tokenizer | 41,140.0 | 62,489.2 | 1.52x |
| findAll Qwen (borrowed) | 39,335.0 | 64,015.0 | 1.63x |
| findAll Qwen (owning) | 40,002.5 | 64,207.5 | 1.61x |
| find CJK tokenizer | 166,246.7 | 219,548.3 | 1.32x |
| find HTML tag | 48,264.4 | 122,728.5 | 2.54x |
| find URL | 34,047.9 | 83,379.0 | 2.45x |
| find JSON string literal | 7,559.4 | 16,675.0 | 2.21x |
| find JSON number | 33,491.7 | 59,966.5 | 1.79x |
| find word boundary | 78,123.3 | 133,734.8 | 1.71x |
| find (?i) literal | 43,399.8 | 91,349.6 | 2.10x |
| find alternation (5 words) | 118,922.9 | 169,726.7 | 1.43x |
| find (?i) alternation | 81,976.3 | 187,332.5 | 2.29x |
| find 10-word alternation | 204,345.6 | 299,471.0 | 1.47x |
| find Greek class | 55,353.5 | 89,955.6 | 1.63x |
| find prefix+suffix | 8,362.3 | 29,990.0 | 3.59x |
| replaceAll email captures | 25,170.6 | 87,837.1 | 3.49x |
| find IPv4 | 68,860.6 | 126,338.8 | 1.83x |
| find date | 38,900.2 | 128,557.9 | 3.30x |
| find 20-word alternation | 204,311.3 | 316,768.1 | 1.55x |
| find anchored line | 2,248.1 | 8,967.5 | 3.99x |
| find (?i) Unicode literal | 76,509.6 | 135,834.0 | 1.78x |
| find shared-prefix alternation | 23,031.0 | 30,605.4 | 1.33x |
| find one-char alternation | 13,059.2 | 18,519.4 | 1.42x |
| find hex color | 32,047.7 | 82,398.8 | 2.57x |
| find version | 58,372.9 | 111,040.8 | 1.90x |
| find nullable prefix | 10,666.5 | 39,935.6 | 3.74x |
| find identifier | 51,435.8 | 106,090.6 | 2.06x |
| find thousands | 39,579.4 | 121,256.7 | 3.06x |
| find domain | 33,230.6 | 122,757.9 | 3.69x |
| find percent | 32,527.1 | 123,401.5 | 3.79x |
| find time | 44,928.1 | 108,173.5 | 2.41x |
| find end-anchored word | 13,829.2 | 32,515.6 | 2.35x |
| find UUID | 30,089.6 | 67,712.3 | 2.25x |
| find semver | 84,123.1 | 92,059.0 | 1.09x |
| find email TLD | 12,456.9 | 23,174.0 | 1.86x |
| find CIDR | 74,077.1 | 128,007.1 | 1.73x |
| find line full | 2,197.5 | 10,897.7 | 4.96x |
| find optional prefix run | 111,057.9 | 192,501.7 | 1.73x |
| find repeated literal group | 45,504.6 | 135,762.7 | 2.98x |
| find camelCase | 82,820.2 | 97,976.5 | 1.18x |
| find key-value | 93,295.2 | 207,379.4 | 2.22x |
| find IP port | 88,040.2 | 139,337.9 | 1.58x |
| find (?i) class | 23,930.6 | 37,970.2 | 1.59x |
| find prefix alternation | 119,638.3 | 162,159.8 | 1.36x |
| find signed number | 41,384.6 | 61,365.0 | 1.48x |
| find html attribute | 52,370.0 | 98,699.0 | 1.88x |
| find markdown heading | 36,028.5 | 69,461.7 | 1.93x |
| find mixed alternation | 182,329.2 | 353,469.6 | 1.94x |
| split whitespace (22 KiB) | 17,291.9 | 75,228.3 | 4.35x |
| split commas (29 KiB) | 16,366.9 | 55,615.8 | 3.40x |
| fullmatch literal | 1.7 | 9.5 | 5.59x |
| fullmatch class | 5.4 | 33.4 | 6.19x |
| fullmatch xDS-like | 9.2 | 30.9 | 3.36x |
| replaceAll a+ -> x | 21,332.1 | 104,740.0 | 4.91x |
| replaceAll \A|\z -> X | 2,684.2 | 7,936.7 | 2.96x |
| RegexSet 9 no-match patterns | 1,871.5 | 38,709.0 | 20.68x |

regexz is faster on all 58 measured cases. The ranges are 14.12x on
tokenizer compilation, 6.66x on a small-pattern compile, 1.32–1.63x on
tokenizer scans and match iteration, 1.09–3.99x on search scans, 3.40–4.35x
on splits, 3.36–6.19x on full-match calls, 4.91x on a set-run replacement,
3.49x on a capture replacement, 2.96x on a zero-width replacement and 20.68x
on the nine-pattern set. The thinnest margins are the semver scan at 1.09x
and the camelCase scan at 1.18x.

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
