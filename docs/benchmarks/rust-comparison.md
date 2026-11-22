# Comparison with Rust's `regex`

Linux x86_64 (Intel Raptor Lake), Zig 0.16.0 ReleaseFast, Rust `regex`
1.13.2, November 2026. The harnesses live in [`tools/compare`](../tools/compare):
`zig_regex.zig` runs regexz and `rust_regex` runs the same inputs and patterns
through Rust's `regex` crate. Both report the median of five batches per case.
A companion [PCRE2 comparison](pcre2-comparison.md) covers the same search,
split, replace and full-match workloads against PCRE2 10.42 with JIT.

Method: the current sweep executed the two binaries alternately, eight times
(four rounds in each order), with both processes pinned to CPU 0 with
`taskset`. The table reports medians across those executions. The suite now
covers 101 cases, including markdown headings/list markers, escaped strings,
HTTP/SQL keywords, emails, blank lines, floats, currency, CSS
units/selectors, HTML comments, query parameters, JSON keys, hashtags and
mentions, MAC addresses, base64, markdown links and images, YAML/TOML config,
templates, Windows paths, slash dates, HTTP request lines, IPv6 addresses,
C comments, HTML tag names, shell variables, and single-byte split
delimiters.

Inputs match the microbenchmarks: 22 KiB ASCII tokenizer text, 191 KiB CJK
tokenizer text, 82 KiB HTML, 95 KiB URL text, 12 KiB JSON, 44 KiB JSON number
text, 96 KiB word text, 29 KiB comma-separated text, a 24 KiB replacement
text, a 39 KiB signed-number text, a 53 KiB HTML attribute text, a 47 KiB
markdown text, an 82 KiB prefix-alternation text, a 70 KiB mixed-alternation
text, and small full-match subjects.

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 11,374.4 | 714,325.1 | 62.80x |
| compile xDS-like | 5,780.1 | 31,644.4 | 5.47x |
| find Qwen tokenizer | 49,760.6 | 106,195.8 | 2.13x |
| findAll Qwen (borrowed) | 58,364.1 | 105,801.2 | 1.81x |
| findAll Qwen (owning) | 58,294.2 | 105,031.1 | 1.80x |
| find CJK tokenizer | 219,859.6 | 475,876.2 | 2.16x |
| find HTML tag | 140,280.2 | 177,613.0 | 1.27x |
| find URL | 71,244.1 | 162,265.9 | 2.28x |
| find JSON string literal | 14,645.4 | 22,634.2 | 1.55x |
| find JSON number | 73,100.4 | 95,869.9 | 1.31x |
| find word boundary | 194,004.0 | 204,714.0 | 1.06x |
| find (?i) literal | 64,300.0 | 168,154.4 | 2.62x |
| find alternation (5 words) | 95,165.9 | 233,935.3 | 2.46x |
| find (?i) alternation | 87,331.4 | 301,250.0 | 3.45x |
| find 10-word alternation | 210,514.9 | 380,838.2 | 1.81x |
| find Greek class | 96,581.9 | 146,396.9 | 1.52x |
| find prefix+suffix | 15,135.2 | 47,467.6 | 3.14x |
| replaceAll email captures | 33,607.4 | 114,097.6 | 3.40x |
| find IPv4 | 111,652.0 | 201,673.1 | 1.81x |
| find date | 87,442.8 | 201,369.8 | 2.30x |
| find 20-word alternation | 210,473.0 | 362,190.5 | 1.72x |
| find anchored line | 4,275.5 | 38,792.6 | 9.07x |
| find (?i) Unicode literal | 118,104.6 | 208,458.4 | 1.77x |
| find shared-prefix alternation | 44,731.1 | 53,015.1 | 1.19x |
| find one-char alternation | 12,761.6 | 11,192.6 | 0.88x |
| find hex color | 81,907.2 | 119,080.2 | 1.45x |
| find version | 100,185.1 | 171,599.9 | 1.71x |
| find nullable prefix | 19,634.2 | 69,912.3 | 3.56x |
| find identifier | 123,234.1 | 160,841.5 | 1.31x |
| find thousands | 83,480.8 | 179,046.0 | 2.14x |
| find domain | 62,422.4 | 206,117.7 | 3.30x |
| find percent | 73,855.4 | 183,484.0 | 2.48x |
| find time | 86,274.5 | 173,984.1 | 2.02x |
| find end-anchored word | 17,644.3 | 38,031.8 | 2.16x |
| find UUID | 54,211.6 | 154,599.0 | 2.85x |
| find semver | 103,528.4 | 164,147.2 | 1.59x |
| find email TLD | 16,533.3 | 34,816.6 | 2.11x |
| find CIDR | 114,439.9 | 201,303.2 | 1.76x |
| find line full | 4,173.7 | 43,227.9 | 10.36x |
| find optional prefix run | 56,597.6 | 293,055.6 | 5.18x |
| find repeated literal group | 116,694.5 | 196,681.6 | 1.69x |
| find camelCase | 110,426.2 | 155,200.5 | 1.41x |
| find key-value | 161,920.2 | 319,866.2 | 1.98x |
| find IP port | 132,890.7 | 235,101.5 | 1.77x |
| find (?i) class | 48,776.9 | 65,777.0 | 1.35x |
| find prefix alternation | 200,639.0 | 225,899.0 | 1.13x |
| find signed number | 93,700.2 | 96,100.2 | 1.03x |
| find html attribute | 87,506.1 | 151,685.7 | 1.73x |
| find markdown heading | 71,222.2 | 104,135.1 | 1.46x |
| find mixed alternation | 449,617.1 | 483,240.0 | 1.07x |
| find capitalized words | 4,942.3 | 140,318.0 | 28.39x |
| find markdown list | 4,916.4 | 41,381.8 | 8.42x |
| find JSON escaped string | 17,421.3 | 22,508.3 | 1.29x |
| find double spaces | 10,252.3 | 42,050.1 | 4.10x |
| find log level | 1,574.8 | 3,081.5 | 1.96x |
| find markdown heading ws | 71,242.0 | 104,201.1 | 1.46x |
| find markdown list ws | 4,927.6 | 72,432.2 | 14.70x |
| find escaped string loop | 17,421.0 | 22,409.3 | 1.29x |
| find HTTP methods | 1,435.3 | 2,347.4 | 1.64x |
| find full email | 19,654.9 | 46,114.5 | 2.35x |
| find blank lines | 1,148.2 | 38,056.8 | 33.15x |
| find floats | 76,393.2 | 95,239.7 | 1.25x |
| find currency | 321.8 | 295.5 | 0.92x |
| find ISO timestamp | 73,464.1 | 183,866.2 | 2.50x |
| find JSON key | 15,810.8 | 19,579.2 | 1.24x |
| find HTML comment | 1,173.0 | 2,193.7 | 1.87x |
| find hashtag | 1,445.1 | 1,673.0 | 1.16x |
| find mention | 1,435.5 | 1,672.1 | 1.16x |
| find CSS unit | 49,371.9 | 103,511.6 | 2.10x |
| find function call | 117,103.0 | 193,827.8 | 1.66x |
| find SQL keyword | 1,073.7 | 2,352.1 | 2.19x |
| find JSON literal | 542.2 | 879.5 | 1.62x |
| find blockquote | 370.3 | 394.9 | 1.07x |
| find ordered list | 369.9 | 387.4 | 1.05x |
| find query param | 26,005.0 | 31,433.7 | 1.21x |
| find MAC address | 65,829.9 | 98,758.4 | 1.50x |
| find base64 run | 79,394.7 | 232,329.0 | 2.93x |
| find markdown link | 361.1 | 410.9 | 1.14x |
| find YAML key | 33,916.1 | 59,097.1 | 1.74x |
| find TOML table | 33,913.7 | 47,849.8 | 1.41x |
| find template | 68,075.2 | 98,036.4 | 1.44x |
| find Windows path | 46,889.6 | 175,300.0 | 3.74x |
| find CSS selector | 81,833.0 | 86,363.8 | 1.06x |
| find slash date | 85,908.8 | 189,194.4 | 2.20x |
| find HTTP request | 807.6 | 1,771.8 | 2.19x |
| find IPv6 | 83,384.1 | 109,750.3 | 1.32x |
| find C comment | 85,927.3 | 121,603.0 | 1.42x |
| find markdown image | 385.6 | 805.6 | 2.09x |
| find HTML tag name | 125,400.0 | 150,357.5 | 1.20x |
| find shell var | 121,435.4 | 173,716.0 | 1.43x |
| split whitespace (22 KiB) | 31,598.6 | 137,633.5 | 4.36x |
| split commas (29 KiB) | 24,883.5 | 63,820.9 | 2.56x |
| split lines | 1,291.8 | 3,046.2 | 2.36x |
| split semicolons | 21,550.0 | 51,170.9 | 2.37x |
| fullmatch literal | 3.5 | 13.7 | 3.86x |
| fullmatch class | 9.9 | 57.5 | 5.78x |
| fullmatch xDS-like | 18.8 | 68.8 | 3.66x |
| replaceAll a+ -> x | 32,388.5 | 161,784.9 | 5.00x |
| replaceAll \A\|\z -> X | 1,001.1 | 39,044.7 | 39.00x |
| replaceAll digits -> N | 55,767.2 | 328,652.6 | 5.89x |
| RegexSet 9 no-match patterns | 2,953.4 | 47,889.6 | 16.22x |

regexz is faster on 99 of the 101 measured cases. The two remaining losses
are the one-character alternation (`a|b|c`, 0.88x) and currency
(`\$\d+(?:\.\d{2})?`, 0.92x); IPv6 is at parity (1.01x). The largest leads
are `replaceAll` with edge assertions (39.00x), blank-line scans (33.15x),
capitalized-word scans (28.39x), `RegexSet` no-match scans (16.22x) and
compile time (62.80x); the tokenizer searches are 2.13x and 2.16x ahead.
The geometric-mean ratio is 2.33x. The currency row is a small absolute gap
(about 39 ns); the one-character alternation is dominated by the per-match
dispatch call.

The compile rows were re-measured after the class-sort, workspace-pointer,
complement-fill, in-place-operand, precomputed-union, direct-negation and
direct-union-append and coalesced-skip changes, the class-construction
changes listed below, the `find log level`, `find (?i) alternation` and
`find (?i) literal` rows after the 32-lane caseless scans, and the HTML-tag
and template rows after the wrapped-run probes below, and the HTML-tag-name
row after the short `<` probe below; the materialized sets are identical, so
the other search rows are unchanged. The companion JSON
holds the latest full sweep; its search rows differ from the table only by
shared-host noise.

The compile path gained four more class-construction changes:

- Materialized sets are built from a sorted-range entry point that stops
  filling the ASCII bitmap at the first non-ASCII range. Unsorted callers
  keep the general builder.
- The parser sorts a short out-of-order literal prefix (for example `\r\n`)
  before merging a precomputed property union, instead of appending the union
  and block-sorting the combined list; the sortedness scan is skipped when
  the parser already vouches for the operand order.
- Adjacent positive property atoms stay unmaterialized until a precomputed
  union misses, and canonical property tables are validated in place rather
  than copied through `normalize`.
- A negated class made of a property union plus a short prefix emits its
  complement directly from the union table, without materializing the union
  range list first.
- Precomputed unions are generated as static `Range` arrays instead of a
  packed binary blob, so a positive union class references the table without
  copying and the merge/complement loops load ranges directly.
- General-category groups stay deferred too: a buffered `\p{...}` atom is
  expanded only when no precomputed union matches, so tokenizer classes never
  copy the individual group ranges.
- Single ASCII literals under simple folding build their case peers directly
  instead of walking the fold table and sorting the result.

The search paths gained two contained changes:

- Short wrapped runs (`<[^>]+>`, `\$\{[^}]+\}`) probe the current open byte
  and a 16-byte close window scalar before falling back to the vector byte
  scanners, which dominates tag-like inputs with short bodies.
- A whole-pattern ASCII set with at most 64 single-byte members reuses the
  literal-byte fast path (`[abc]`, `[0-9]`, `[a-z]`), bypassing the general VM
  per match while keeping the set's range-based first-byte scan.
- Tag-name scans probe an 8-byte window for the next `<` before the vector
  byte scanner, cutting `</?([a-z][a-z0-9]*)\b` by about 12%.

## What changed in this round

The previous sweep on macOS ARM64 already used a two-byte nibble filter for
word alternations. This round makes the same filter useful on x86_64 and
widens the hot scans:

- The nibble filter now emits VEX-encoded `vpshufb` on x86_64. The legacy
  SSE form follows 256-bit VEX instructions and costs a transition penalty
  on P-cores; the VEX form brought the word-alternation scans back to parity
  and then ahead.
- AVX2 hosts run the nibble filter 32 lanes at a time. Both 128-bit lanes
  hold the same nibble tables, so one `vpshufb` covers two chunks per table.
  `findWordAlternation` walks 32-byte windows, then falls back to the 16-lane
  and scalar tails.
- Long single-byte and small first-byte scans use 32-byte compares and clear
  the upper YMM state with `vzeroupper` before returning to the engine. This
  keeps later legacy SSE code out of the transition-penalty path.
- Candidate lanes are walked inside one vector chunk for word alternations,
  sparse pair sets (`GET|POST` prefixes) and single-byte prefix runs
  (`#\w+`, `@\w+`). A failed candidate resumes at the next lane instead of
  restarting the vector scan.
- First-byte scans return `@ctz` of the lane mask instead of rechecking bytes
  scalar. The mask is exact for the splat and range representations, so the
  scalar confirmation pass was redundant.
- The first-byte filter keeps ranges only when at least one range covers more
  than one byte. Isolated byte sets (`[?&]`, `[.#]`) now use one compare per
  byte instead of two range-bound compares.
- The pair filter's third-byte check is enabled for small allowed sets. It
  rejects pair collisions such as `er` inside `Numbers` without a wide
  third-byte compare tree.
- CSS units (`\d+(?:px|em|rem|%)`) take a direct dispatch path in
  `Workspace.find`, avoiding the large switch on a per-match hot path; the
  suffix table maps the first byte to one literal instead of scanning all
  alternatives.
- Single-byte splits always count the delimiter and fill the parts array in
  one mask pass. Sparse line delimiters no longer pay one filter setup per
  part; the comparison harness also uses the general-purpose `smp_allocator`
  instead of the page allocator, matching Rust's system allocator for the
  allocation-heavy split and replace cases.
- Wrapped runs whose body is every byte except a single-byte close
  (`<[^>]+>`, `${...}`) find the body end with the vector byte scanner
  instead of walking a membership table byte by byte. HTML tags improve
  about 4.5% and template interpolation about 6.5%.
- Class normalization sorts ranges by start only. The merge loop takes the
  maximum end of adjacent ranges with the same start, so the end tie-break
  was redundant; removing it avoids a mispredicting branch on the many equal
  starts produced by Unicode property unions. The complement list is sized
  once and filled without per-append capacity checks, and the parser's class
  operand is normalized in place instead of copied. Adjacent positive
  `\p{...}` atoms use precomputed sorted unions (L+M, L+N, L+M+N), so the
  operand stays sorted and `normalize` skips its sort. Non-negated classes
  return the already-normalized set directly, and negated classes complement
  the normalized ranges without a copy. Precomputed unions are merged
  directly from the generated table without an intermediate set. Coalesced
  range lists skip the merge loop's per-range writes. Qwen compile improves
  about 52% across these class-normalization changes.
- Caseless literal alternations use the same 32-lane nibble scan as word
  alternations, with `vzeroupper` before returning. `(?i)error|warn|info`
  improves about 1.9x in the comparison harness.
- Case-folded literals use a 32-lane pair scan on AVX2 hosts, with
  `vzeroupper` before returning. `(?i)alpha` improves about 5-8% in the
  comparison harness.

- Persistent workspaces moved behind pointers. `Regex` no longer carries a
  28.8 KiB `ReplaceWorkspace` inline, shrinking from about 33 KiB to 3 KiB
  and removing a 30 KiB copy per compile. xDS-like compile improves 2.1x and
  Qwen 1.16x.




Earlier rounds on macOS ARM64 brought the suite from 63 to 93 cases and added
the escaped-string, email, float, currency, CSS, HTML-comment, query-param,
JSON-key, hashtag/mention, MAC, base64, markdown-link, YAML/TOML, template,
Windows-path, slash-date and HTTP-request scanners described in the previous
revision of this document. The current numbers above are from the Linux
x86_64 host; the macOS ordering was the same in the earlier sweeps, but the
absolute times differ.

Caveats: the iteration APIs are the natural ones for each library
(`Workspace.find` in a loop versus `Regex::find_iter`), full match is
`Regex::find` plus a bounds check on the Rust side, the word-boundary case
uses `(?-u:\b\w+\b)` so both engines apply ASCII word rules, the split
comparison collects Rust's iterator into a `Vec` so both sides allocate the
parts array, and the allocators differ (regexz uses `std.heap.smp_allocator`,
Rust the system allocator; both are general-purpose, but allocation-heavy
cases remain sensitive to the choice). The tokenizer comparison uses Rust's
default Unicode classes with regexz's `unicode_perl_space` limit. The shared
host is noisy; single runs vary more than the interleaved medians above.
These numbers cover the listed workloads, not every regex feature: Rust
supports more Unicode word-boundary and property syntax, while regexz's
extended mode covers lookaround, backreferences and conditionals that Rust's
`regex` rejects.

Reproduce:

```sh
zig build-exe -O ReleaseFast --dep regexz \
    -Mroot=tools/compare/zig_regex.zig -Mregexz=src/root.zig \
    -femit-bin=/tmp/regexz-compare
/tmp/regexz-compare

cd tools/compare/rust_regex
cargo run --release
```
