# Comparison with Rust's `regex`

Linux x86_64 (Intel Raptor Lake), Zig 0.16.0 ReleaseFast, Rust `regex`
1.13.2, November 2026. The harnesses live in [`tools/compare`](../tools/compare):
`zig_regex.zig` runs regexz and `rust_regex` runs the same inputs and patterns
through Rust's `regex` crate. Both report the median of five batches per case.
A companion [PCRE2 comparison](pcre2-comparison.md) covers the same search,
split, replace and full-match workloads against PCRE2 10.42 with JIT.

Method: each case runs in a fresh process for both binaries, five interleaved
rounds, with every process pinned to CPU 0 with `taskset`. The table reports
medians. One case per process removes cross-case heap and code-layout
interference: in the earlier single-process sweep, unrelated rows moved by
10-50% when one case's code changed. The suite covers 101 cases, including
markdown headings/list markers, escaped strings,
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
| compile Qwen tokenizer | 11,428.8 | 720,848.3 | 63.07x |
| compile xDS-like | 5,852.0 | 31,746.7 | 5.42x |
| find Qwen tokenizer | 56,469.6 | 99,285.5 | 1.76x |
| findAll Qwen (borrowed) | 55,777.6 | 99,069.5 | 1.78x |
| findAll Qwen (owning) | 55,832.4 | 98,887.3 | 1.77x |
| find CJK tokenizer | 216,811.9 | 387,253.7 | 1.79x |
| find HTML tag | 91,409.2 | 177,757.4 | 1.94x |
| find URL | 71,011.7 | 134,602.8 | 1.90x |
| find JSON string literal | 15,038.3 | 22,750.4 | 1.51x |
| find JSON number | 74,348.2 | 95,043.2 | 1.28x |
| find word boundary | 192,874.5 | 202,221.7 | 1.05x |
| find (?i) literal | 64,685.4 | 138,864.4 | 2.15x |
| find alternation (5 words) | 95,442.2 | 234,203.9 | 2.45x |
| find (?i) alternation | 87,241.6 | 304,464.6 | 3.49x |
| find 10-word alternation | 210,661.8 | 381,788.2 | 1.81x |
| find Greek class | 103,060.0 | 144,152.6 | 1.40x |
| find prefix+suffix | 15,269.0 | 47,626.1 | 3.12x |
| replaceAll email captures | 33,917.3 | 113,913.2 | 3.36x |
| find IPv4 | 96,518.9 | 202,833.8 | 2.10x |
| find date | 82,260.1 | 201,346.3 | 2.45x |
| find 20-word alternation | 210,402.1 | 367,257.1 | 1.75x |
| find anchored line | 4,191.1 | 43,003.4 | 10.26x |
| find (?i) Unicode literal | 121,477.0 | 208,665.0 | 1.72x |
| find shared-prefix alternation | 46,802.2 | 53,061.6 | 1.13x |
| find one-char alternation | 12,824.9 | 11,190.3 | 0.87x |
| find hex color | 79,065.3 | 120,087.7 | 1.52x |
| find version | 98,730.1 | 168,590.4 | 1.71x |
| find nullable prefix | 19,720.9 | 65,791.7 | 3.34x |
| find identifier | 125,544.0 | 160,091.8 | 1.28x |
| find thousands | 83,431.0 | 178,816.4 | 2.14x |
| find domain | 62,510.6 | 201,321.9 | 3.22x |
| find percent | 69,504.8 | 177,439.5 | 2.55x |
| find time | 84,074.0 | 170,600.5 | 2.03x |
| find end-anchored word | 2,567.8 | 38,059.5 | 14.82x |
| find UUID | 56,613.8 | 155,251.8 | 2.74x |
| find semver | 101,425.4 | 164,844.6 | 1.63x |
| find email TLD | 18,458.2 | 35,095.0 | 1.90x |
| find CIDR | 100,115.9 | 202,591.7 | 2.02x |
| find line full | 4,127.0 | 43,231.7 | 10.48x |
| find optional prefix run | 60,864.2 | 291,510.9 | 4.79x |
| find repeated literal group | 118,200.4 | 199,016.8 | 1.68x |
| find camelCase | 110,745.1 | 155,822.4 | 1.41x |
| find key-value | 165,034.1 | 321,011.0 | 1.95x |
| find IP port | 122,096.5 | 235,897.9 | 1.93x |
| find (?i) class | 49,184.5 | 64,587.8 | 1.31x |
| find prefix alternation | 206,712.6 | 226,071.3 | 1.09x |
| find signed number | 92,789.8 | 96,551.8 | 1.04x |
| find html attribute | 85,048.7 | 152,146.5 | 1.79x |
| find markdown heading | 72,255.5 | 105,847.2 | 1.46x |
| find mixed alternation | 382,281.7 | 485,667.6 | 1.27x |
| find capitalized words | 4,958.9 | 140,410.1 | 28.31x |
| find markdown list | 4,921.9 | 38,362.9 | 7.79x |
| find JSON escaped string | 17,645.4 | 22,832.9 | 1.29x |
| find double spaces | 8,913.3 | 42,786.8 | 4.80x |
| find log level | 1,468.8 | 3,086.9 | 2.10x |
| find markdown heading ws | 72,407.5 | 105,524.0 | 1.46x |
| find markdown list ws | 4,913.9 | 72,500.0 | 14.75x |
| find escaped string loop | 17,648.4 | 22,822.4 | 1.29x |
| find HTTP methods | 1,410.3 | 2,356.6 | 1.67x |
| find full email | 19,608.0 | 46,357.3 | 2.36x |
| find blank lines | 1,153.0 | 38,107.9 | 33.05x |
| find floats | 76,445.4 | 94,776.1 | 1.24x |
| find currency | 299.4 | 288.6 | 0.96x |
| find ISO timestamp | 69,458.4 | 185,845.5 | 2.68x |
| find JSON key | 15,855.6 | 19,621.1 | 1.24x |
| find HTML comment | 1,187.6 | 2,172.8 | 1.83x |
| find hashtag | 1,311.4 | 1,605.5 | 1.22x |
| find mention | 1,317.2 | 1,601.7 | 1.22x |
| find CSS unit | 49,720.2 | 105,239.1 | 2.12x |
| find function call | 114,155.1 | 188,603.9 | 1.65x |
| find SQL keyword | 1,089.0 | 2,332.1 | 2.14x |
| find JSON literal | 547.5 | 875.5 | 1.60x |
| find blockquote | 375.5 | 398.8 | 1.06x |
| find ordered list | 375.7 | 386.0 | 1.03x |
| find query param | 25,225.0 | 31,868.1 | 1.26x |
| find MAC address | 66,618.3 | 99,196.2 | 1.49x |
| find base64 run | 80,537.7 | 234,300.5 | 2.91x |
| find markdown link | 367.4 | 398.8 | 1.09x |
| find YAML key | 33,549.0 | 58,602.4 | 1.75x |
| find TOML table | 32,285.1 | 47,791.1 | 1.48x |
| find template | 69,196.5 | 98,436.5 | 1.42x |
| find Windows path | 46,593.8 | 167,178.1 | 3.59x |
| find CSS selector | 83,621.9 | 86,805.4 | 1.04x |
| find slash date | 79,928.4 | 190,074.1 | 2.38x |
| find HTTP request | 809.9 | 1,771.8 | 2.19x |
| find IPv6 | 73,211.7 | 110,660.1 | 1.51x |
| find C comment | 87,057.6 | 122,425.0 | 1.41x |
| find markdown image | 378.6 | 831.4 | 2.20x |
| find HTML tag name | 126,883.3 | 155,598.4 | 1.23x |
| find shell var | 120,841.4 | 175,276.7 | 1.45x |
| split whitespace (22 KiB) | 30,961.3 | 138,267.1 | 4.47x |
| split commas (29 KiB) | 24,329.3 | 62,721.6 | 2.58x |
| split lines | 1,285.5 | 2,901.5 | 2.26x |
| split semicolons | 21,414.7 | 49,686.4 | 2.32x |
| fullmatch literal | 3.6 | 14.2 | 3.94x |
| fullmatch class | 9.9 | 58.5 | 5.91x |
| fullmatch xDS-like | 19.0 | 69.2 | 3.64x |
| replaceAll a+ -> x | 28,758.6 | 167,007.0 | 5.81x |
| replaceAll \A\|\z -> X | 1,026.7 | 38,898.0 | 37.89x |
| replaceAll digits -> N | 63,033.8 | 332,877.0 | 5.28x |
| RegexSet 9 no-match patterns | 2,942.9 | 47,980.9 | 16.30x |

regexz is faster on 99 of the 101 measured cases. The two remaining losses
are the one-character alternation (`a|b|c`, 0.87x) and currency
(`\$\d+(?:\.\d{2})?`, 0.96x). The largest leads are compile time (63.07x),
`replaceAll` with edge assertions (37.89x), blank-line scans (33.05x),
capitalized-word scans (28.31x), `RegexSet` no-match scans (16.30x) and
end-anchored word scans (14.82x); the tokenizer searches are 1.76x and 1.79x
ahead. The geometric-mean ratio is 2.40x. The currency row is a small
absolute gap (about 11 ns); the one-character alternation is dominated by the
per-match dispatch call.

All rows use the same isolated per-case method. The companion JSON holds the
same sweep.

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
- Mixed-length literal alternations compare 1-3 byte branches directly
  instead of dispatching through `eql`, cutting `a|bb|ccc` by about 15%.

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
