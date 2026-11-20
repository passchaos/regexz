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
text and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 29,924.3 | 449,230.7 | 15.01x |
| compile xDS-like | 2,715.1 | 21,268.5 | 7.83x |
| find Qwen tokenizer | 41,217.5 | 67,758.3 | 1.64x |
| findAll Qwen (borrowed) | 39,414.2 | 69,272.5 | 1.76x |
| findAll Qwen (owning) | 39,000.0 | 64,843.3 | 1.66x |
| find CJK tokenizer | 159,757.5 | 236,301.7 | 1.48x |
| find HTML tag | 47,155.0 | 124,226.7 | 2.63x |
| find URL | 33,129.4 | 83,592.5 | 2.52x |
| find JSON string literal | 7,173.5 | 17,992.3 | 2.51x |
| find JSON number | 31,379.8 | 63,138.3 | 2.01x |
| find word boundary | 76,200.4 | 141,258.8 | 1.85x |
| find (?i) literal | 41,946.5 | 89,016.0 | 2.12x |
| find alternation (5 words) | 144,431.3 | 177,995.0 | 1.23x |
| find (?i) alternation | 126,434.0 | 180,758.8 | 1.43x |
| find 10-word alternation | 238,792.1 | 309,051.5 | 1.29x |
| find Greek class | 50,128.1 | 91,842.9 | 1.83x |
| find prefix+suffix | 9,280.0 | 31,630.0 | 3.41x |
| replaceAll email captures | 25,677.9 | 87,944.8 | 3.42x |
| find IPv4 | 65,479.8 | 133,090.4 | 2.03x |
| find date | 36,634.2 | 130,819.4 | 3.57x |
| find 20-word alternation | 220,486.9 | 323,922.7 | 1.47x |
| find anchored line | 2,357.9 | 8,377.9 | 3.55x |
| find (?i) Unicode literal | 74,621.3 | 129,385.4 | 1.73x |
| find shared-prefix alternation | 23,745.4 | 29,702.7 | 1.25x |
| find one-char alternation | 15,372.3 | 18,470.2 | 1.20x |
| find hex color | 30,410.4 | 86,749.4 | 2.85x |
| find version | 54,681.5 | 110,095.0 | 2.01x |
| find nullable prefix | 31,054.0 | 40,427.3 | 1.30x |
| find identifier | 51,940.6 | 104,855.8 | 2.02x |
| find thousands | 99,561.9 | 116,156.0 | 1.17x |
| find domain | 32,439.0 | 117,753.5 | 3.63x |
| find percent | 32,198.8 | 123,724.2 | 3.84x |
| find time | 89,749.6 | 109,843.8 | 1.22x |
| find end-anchored word | 13,771.0 | 32,222.3 | 2.34x |
| find UUID | 29,809.2 | 72,936.2 | 2.45x |
| find semver | 90,772.3 | 92,049.8 | 1.01x |
| find email TLD | 18,522.1 | 22,940.4 | 1.24x |
| find CIDR | 113,576.9 | 124,839.6 | 1.10x |
| find line full | 2,168.5 | 10,660.0 | 4.92x |
| find optional prefix run | 106,509.6 | 194,864.6 | 1.83x |
| find repeated literal group | 107,060.0 | 136,540.0 | 1.28x |
| find camelCase | 75,770.4 | 103,592.5 | 1.37x |
| find key-value | 85,474.4 | 211,946.9 | 2.48x |
| find IP port | 92,263.5 | 140,079.8 | 1.52x |
| split whitespace (22 KiB) | 17,030.2 | 76,300.8 | 4.48x |
| split commas (29 KiB) | 15,804.0 | 55,082.9 | 3.49x |
| fullmatch literal | 1.7 | 9.6 | 5.65x |
| fullmatch class | 5.1 | 32.6 | 6.39x |
| fullmatch xDS-like | 9.7 | 29.9 | 3.08x |
| replaceAll a+ -> x | 22,697.1 | 101,189.8 | 4.46x |
| replaceAll \A|\z -> X | 2,856.0 | 7,909.2 | 2.77x |
| RegexSet 9 no-match patterns | 1,962.9 | 38,031.0 | 19.37x |

regexz is faster on all 52 measured cases. The ranges are 13.57x on
tokenizer compilation, 8.01x on a small-pattern compile, 1.35–1.72x on
tokenizer scans and match iteration, 1.01–3.77x on search scans, 3.40–4.49x
on splits, 3.15–6.04x on full-match calls, 4.69x on a set-run replacement,
3.61x on a capture replacement, 2.72x on a zero-width replacement and 19.53x
on the nine-pattern set. The thinnest margins are the semver scan at 1.01x
and the CIDR scan at 1.10x.

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
single-set elements (1.37x).

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
