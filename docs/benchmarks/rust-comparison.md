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
| compile Qwen tokenizer | 30,956.4 | 446,618.2 | 14.43x |
| compile xDS-like | 2,922.0 | 21,375.1 | 7.32x |
| find Qwen tokenizer | 39,898.3 | 68,059.2 | 1.71x |
| findAll Qwen (borrowed) | 38,515.8 | 68,595.8 | 1.78x |
| findAll Qwen (owning) | 39,251.7 | 73,615.8 | 1.88x |
| find CJK tokenizer | 167,500.8 | 245,797.5 | 1.47x |
| find HTML tag | 50,025.6 | 128,048.8 | 2.56x |
| find URL | 35,755.8 | 90,945.8 | 2.54x |
| find JSON string literal | 7,482.5 | 17,501.2 | 2.34x |
| find JSON number | 32,363.1 | 65,508.3 | 2.02x |
| find word boundary | 76,080.8 | 145,509.4 | 1.91x |
| find (?i) literal | 43,202.9 | 87,304.2 | 2.02x |
| find alternation (5 words) | 146,440.6 | 185,761.0 | 1.27x |
| find (?i) alternation | 128,452.9 | 195,544.6 | 1.52x |
| find 10-word alternation | 248,933.1 | 306,724.6 | 1.23x |
| find Greek class | 51,923.5 | 97,324.2 | 1.87x |
| find prefix+suffix | 8,302.9 | 31,140.4 | 3.75x |
| replaceAll email captures | 25,511.7 | 91,393.8 | 3.58x |
| find IPv4 | 67,884.8 | 132,806.7 | 1.96x |
| find date | 37,977.7 | 127,455.8 | 3.36x |
| find 20-word alternation | 228,036.9 | 327,488.1 | 1.44x |
| find anchored line | 2,240.2 | 9,458.3 | 4.22x |
| find (?i) Unicode literal | 75,105.4 | 133,896.7 | 1.78x |
| find shared-prefix alternation | 24,990.6 | 30,724.8 | 1.23x |
| find one-char alternation | 15,789.0 | 18,500.6 | 1.17x |
| find hex color | 32,020.6 | 85,061.0 | 2.66x |
| find version | 55,588.3 | 112,231.0 | 2.02x |
| find nullable prefix | 30,615.8 | 39,189.6 | 1.28x |
| find identifier | 50,473.8 | 107,327.3 | 2.13x |
| find thousands | 38,830.2 | 115,749.0 | 2.98x |
| find domain | 32,947.1 | 125,288.3 | 3.80x |
| find percent | 31,956.3 | 125,080.8 | 3.91x |
| find time | 45,696.9 | 109,449.6 | 2.40x |
| find end-anchored word | 14,428.8 | 32,370.8 | 2.24x |
| find UUID | 30,088.8 | 66,705.2 | 2.22x |
| find semver | 85,423.3 | 97,917.3 | 1.15x |
| find email TLD | 13,682.5 | 23,921.2 | 1.75x |
| find CIDR | 72,489.0 | 134,814.8 | 1.86x |
| find line full | 2,155.4 | 13,769.0 | 6.39x |
| find optional prefix run | 108,912.3 | 191,940.2 | 1.76x |
| find repeated literal group | 104,484.2 | 139,985.4 | 1.34x |
| find camelCase | 77,858.3 | 101,450.6 | 1.30x |
| find key-value | 88,820.6 | 210,315.6 | 2.37x |
| find IP port | 93,405.0 | 149,805.8 | 1.60x |
| split whitespace (22 KiB) | 17,381.5 | 79,052.9 | 4.55x |
| split commas (29 KiB) | 16,844.2 | 54,646.7 | 3.24x |
| fullmatch literal | 1.8 | 9.7 | 5.39x |
| fullmatch class | 5.2 | 33.6 | 6.46x |
| fullmatch xDS-like | 10.2 | 33.7 | 3.30x |
| replaceAll a+ -> x | 21,994.2 | 102,619.0 | 4.67x |
| replaceAll \A|\z -> X | 2,976.0 | 8,078.1 | 2.71x |
| RegexSet 9 no-match patterns | 1,906.9 | 38,480.2 | 20.18x |

regexz is faster on all 52 measured cases. The ranges are 13.57x on
tokenizer compilation, 8.01x on a small-pattern compile, 1.35–1.72x on
tokenizer scans and match iteration, 1.15–3.77x on search scans, 3.40–4.49x
on splits, 3.15–6.04x on full-match calls, 4.69x on a set-run replacement,
3.61x on a capture replacement, 2.72x on a zero-width replacement and 19.53x
on the nine-pattern set. The thinnest margin is the semver scan at 1.15x.

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
the unbounded chain skips the first run after a failed start (semver, 1.15x).

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
