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
| compile Qwen tokenizer | 32,951.7 | 429,117.8 | 13.02x |
| compile xDS-like | 3,197.1 | 20,928.2 | 6.55x |
| find Qwen tokenizer | 42,485.8 | 62,930.0 | 1.48x |
| findAll Qwen (borrowed) | 39,429.2 | 64,636.7 | 1.64x |
| findAll Qwen (owning) | 39,196.7 | 64,285.8 | 1.64x |
| find CJK tokenizer | 171,435.8 | 223,026.7 | 1.30x |
| find HTML tag | 49,364.6 | 124,225.6 | 2.52x |
| find URL | 34,747.1 | 91,457.1 | 2.63x |
| find JSON string literal | 7,450.8 | 17,583.8 | 2.36x |
| find JSON number | 33,111.3 | 65,539.8 | 1.98x |
| find word boundary | 76,715.6 | 135,700.8 | 1.77x |
| find (?i) literal | 42,957.7 | 91,924.6 | 2.14x |
| find alternation (5 words) | 147,894.4 | 171,887.5 | 1.16x |
| find (?i) alternation | 133,444.2 | 193,591.0 | 1.45x |
| find 10-word alternation | 239,004.6 | 296,635.2 | 1.24x |
| find Greek class | 55,319.6 | 91,928.3 | 1.66x |
| find prefix+suffix | 8,463.1 | 30,319.6 | 3.58x |
| replaceAll email captures | 25,202.9 | 91,022.7 | 3.61x |
| find IPv4 | 67,946.0 | 128,026.9 | 1.88x |
| find date | 39,371.3 | 122,793.8 | 3.12x |
| find 20-word alternation | 220,344.2 | 318,611.5 | 1.45x |
| find anchored line | 2,303.5 | 8,333.5 | 3.62x |
| find (?i) Unicode literal | 77,362.1 | 122,453.3 | 1.58x |
| find shared-prefix alternation | 27,415.2 | 28,837.1 | 1.05x |
| find one-char alternation | 16,490.6 | 18,292.3 | 1.11x |
| find hex color | 33,077.7 | 84,279.0 | 2.55x |
| find version | 61,417.9 | 112,343.3 | 1.83x |
| find nullable prefix | 28,227.7 | 38,978.8 | 1.38x |
| find identifier | 51,421.9 | 102,670.4 | 2.00x |
| find thousands | 38,534.8 | 119,962.1 | 3.11x |
| find domain | 35,330.6 | 122,351.2 | 3.46x |
| find percent | 33,632.9 | 122,876.5 | 3.65x |
| find time | 44,577.9 | 117,080.4 | 2.63x |
| find end-anchored word | 14,993.3 | 31,981.2 | 2.13x |
| find UUID | 30,980.4 | 66,844.8 | 2.16x |
| find semver | 94,372.9 | 91,374.2 | 0.97x |
| find email TLD | 13,757.9 | 23,248.3 | 1.69x |
| find CIDR | 74,567.5 | 124,538.5 | 1.67x |
| find line full | 2,165.8 | 10,912.3 | 5.04x |
| find optional prefix run | 109,409.2 | 188,523.8 | 1.72x |
| find repeated literal group | 111,197.3 | 133,422.9 | 1.20x |
| find camelCase | 83,568.3 | 99,342.1 | 1.19x |
| find key-value | 101,245.4 | 199,634.8 | 1.97x |
| find IP port | 98,440.4 | 135,499.0 | 1.38x |
| find (?i) class | 24,014.6 | 39,932.9 | 1.66x |
| find prefix alternation | 126,522.3 | 160,677.1 | 1.27x |
| find signed number | 40,760.6 | 60,457.9 | 1.48x |
| find html attribute | 52,138.1 | 103,270.2 | 1.98x |
| find markdown heading | 57,000.2 | 69,689.4 | 1.22x |
| find mixed alternation | 191,246.7 | 356,889.0 | 1.87x |
| split whitespace (22 KiB) | 16,777.5 | 76,573.3 | 4.56x |
| split commas (29 KiB) | 16,352.1 | 54,896.7 | 3.36x |
| fullmatch literal | 1.8 | 9.6 | 5.33x |
| fullmatch class | 5.2 | 33.5 | 6.44x |
| fullmatch xDS-like | 10.4 | 33.6 | 3.23x |
| replaceAll a+ -> x | 21,412.3 | 104,626.5 | 4.89x |
| replaceAll \A|\z -> X | 2,782.7 | 7,627.5 | 2.74x |
| RegexSet 9 no-match patterns | 1,825.8 | 38,688.5 | 21.19x |

regexz is faster on 57 of the 58 measured cases. The ranges are 13.02x on
tokenizer compilation, 6.55x on a small-pattern compile, 1.16–1.64x on
tokenizer scans and match iteration, 1.05–3.65x on search scans, 3.36–4.56x
on splits, 3.23–6.44x on full-match calls, 4.89x on a set-run replacement,
3.61x on a capture replacement, 2.74x on a zero-width replacement and 21.19x
on the nine-pattern set. The thinnest clear margin is the shared-prefix
alternation at 1.05x; the semver scan is a statistical tie (0.97x here,
1.06–1.15x ahead in earlier interleaved runs on this noisy host).

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
the unbounded chain skips the first run after a failed start (semver, at
parity). Signed numbers, markdown headings and negated-class chains are now
scanned directly, the UTF-8 run search skips short ASCII gaps with the byte
table, and literal alternations are expanded into a product before the
literal-set filter (see the same page): the signed-number case is 1.48x
ahead, the markdown heading 1.22x, the HTML attribute 1.98x, the
case-insensitive class 1.66x, the prefix alternation 1.27x and the mixed
alternation 1.87x.

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
