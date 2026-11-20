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
| compile Qwen tokenizer | 30,713.4 | 426,499.3 | 13.89x |
| compile xDS-like | 3,064.0 | 20,726.5 | 6.76x |
| find Qwen tokenizer | 39,345.0 | 63,132.5 | 1.60x |
| findAll Qwen (borrowed) | 39,140.8 | 64,770.8 | 1.65x |
| findAll Qwen (owning) | 38,727.5 | 63,022.5 | 1.63x |
| find CJK tokenizer | 160,550.8 | 220,474.2 | 1.37x |
| find HTML tag | 47,307.5 | 118,777.9 | 2.51x |
| find URL | 33,965.8 | 82,935.8 | 2.44x |
| find JSON string literal | 7,188.3 | 17,049.6 | 2.37x |
| find JSON number | 32,201.0 | 59,915.6 | 1.86x |
| find word boundary | 74,365.4 | 129,084.8 | 1.74x |
| find (?i) literal | 42,542.9 | 83,323.1 | 1.96x |
| find alternation (5 words) | 139,914.8 | 167,840.6 | 1.20x |
| find (?i) alternation | 133,157.5 | 184,986.5 | 1.39x |
| find 10-word alternation | 203,542.5 | 294,334.8 | 1.45x |
| find Greek class | 54,576.3 | 89,377.9 | 1.64x |
| find prefix+suffix | 8,347.5 | 30,141.0 | 3.61x |
| replaceAll email captures | 25,256.9 | 83,838.1 | 3.32x |
| find IPv4 | 67,426.9 | 120,822.7 | 1.79x |
| find date | 39,084.8 | 122,661.0 | 3.14x |
| find 20-word alternation | 203,848.1 | 318,965.8 | 1.56x |
| find anchored line | 2,252.7 | 8,625.8 | 3.83x |
| find (?i) Unicode literal | 74,951.0 | 125,481.2 | 1.67x |
| find shared-prefix alternation | 22,584.4 | 29,772.9 | 1.32x |
| find one-char alternation | 13,026.9 | 18,448.3 | 1.42x |
| find hex color | 32,016.5 | 81,316.5 | 2.54x |
| find version | 59,561.9 | 105,966.9 | 1.78x |
| find nullable prefix | 27,208.3 | 38,558.5 | 1.42x |
| find identifier | 49,588.3 | 101,706.9 | 2.05x |
| find thousands | 37,764.6 | 114,029.8 | 3.02x |
| find domain | 32,872.5 | 115,254.0 | 3.51x |
| find percent | 32,203.1 | 122,104.8 | 3.79x |
| find time | 46,369.4 | 112,785.8 | 2.43x |
| find end-anchored word | 14,666.0 | 32,473.8 | 2.21x |
| find UUID | 30,539.4 | 60,803.1 | 1.99x |
| find semver | 89,094.0 | 87,538.5 | 0.98x |
| find email TLD | 13,151.9 | 22,855.0 | 1.74x |
| find CIDR | 74,725.8 | 119,892.7 | 1.60x |
| find line full | 2,079.6 | 10,281.7 | 4.94x |
| find optional prefix run | 103,788.8 | 181,406.7 | 1.75x |
| find repeated literal group | 43,439.2 | 131,960.0 | 3.04x |
| find camelCase | 84,826.9 | 95,126.5 | 1.12x |
| find key-value | 96,477.3 | 199,504.8 | 2.07x |
| find IP port | 94,222.9 | 135,670.8 | 1.44x |
| find (?i) class | 22,721.0 | 37,595.2 | 1.65x |
| find prefix alternation | 119,072.1 | 160,632.7 | 1.35x |
| find signed number | 41,014.2 | 61,341.0 | 1.50x |
| find html attribute | 51,950.0 | 96,836.2 | 1.86x |
| find markdown heading | 34,533.5 | 69,852.5 | 2.02x |
| find mixed alternation | 174,451.7 | 343,101.2 | 1.97x |
| split whitespace (22 KiB) | 17,304.8 | 73,187.3 | 4.23x |
| split commas (29 KiB) | 16,272.3 | 55,181.2 | 3.39x |
| fullmatch literal | 1.9 | 9.4 | 4.95x |
| fullmatch class | 5.1 | 32.1 | 6.29x |
| fullmatch xDS-like | 9.4 | 30.2 | 3.21x |
| replaceAll a+ -> x | 21,325.2 | 101,296.0 | 4.75x |
| replaceAll \A|\z -> X | 2,731.9 | 7,841.0 | 2.87x |
| RegexSet 9 no-match patterns | 1,897.7 | 38,846.5 | 20.47x |

regexz is faster on 57 of the 58 measured cases. The ranges are 13.89x on
tokenizer compilation, 6.76x on a small-pattern compile, 1.37–1.65x on
tokenizer scans and match iteration, 0.98–3.79x on search scans, 3.39–4.23x
on splits, 3.21–6.29x on full-match calls, 4.75x on a set-run replacement,
3.32x on a capture replacement, 2.87x on a zero-width replacement and 20.47x
on the nine-pattern set. The semver scan is a statistical tie (0.98x here,
0.89–1.05x across runs on this host); the thinnest clear margin is the
camelCase scan at 1.12x.

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
directly (semver, a statistical tie).

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
