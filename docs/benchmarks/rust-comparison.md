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
10-50% when one case's code changed. The `find` rows use each library's
per-position API (`find_at` for Rust, `Workspace.find` for regexz); the
`findAll` rows use each library's iterator (`find_iter`, `findAllWith`). An
earlier harness used `find_iter` for both, which credited Rust's iterator on
the per-position rows. The suite covers 101 cases, including
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
| compile Qwen tokenizer | 11,435.2 | 722,139.8 | 63.15x |
| compile xDS-like | 5,816.8 | 31,606.7 | 5.43x |
| find Qwen tokenizer | 56,045.8 | 250,556.8 | 4.47x |
| findAll Qwen (borrowed) | 56,329.5 | 108,792.5 | 1.93x |
| findAll Qwen (owning) | 56,034.8 | 107,573.7 | 1.92x |
| find CJK tokenizer | 219,085.3 | 995,747.4 | 4.55x |
| find HTML tag | 91,587.1 | 392,768.3 | 4.29x |
| find URL | 70,617.7 | 278,944.3 | 3.95x |
| find JSON string literal | 15,047.0 | 50,309.6 | 3.34x |
| find JSON number | 74,461.9 | 247,764.5 | 3.33x |
| find word boundary | 189,440.6 | 602,036.9 | 3.18x |
| find (?i) literal | 65,778.2 | 217,366.0 | 3.30x |
| find alternation (5 words) | 95,379.0 | 292,645.6 | 3.07x |
| find (?i) alternation | 87,516.6 | 445,256.7 | 5.09x |
| find 10-word alternation | 210,308.8 | 474,830.4 | 2.26x |
| find Greek class | 103,462.0 | 335,271.9 | 3.24x |
| find prefix+suffix | 14,069.4 | 53,388.3 | 3.79x |
| replaceAll email captures | 33,687.3 | 114,338.2 | 3.39x |
| find IPv4 | 96,425.6 | 363,519.4 | 3.77x |
| find date | 87,964.9 | 360,089.7 | 4.09x |
| find 20-word alternation | 211,120.5 | 465,731.5 | 2.21x |
| find anchored line | 4,279.4 | 45,286.5 | 10.58x |
| find (?i) Unicode literal | 121,000.9 | 373,253.4 | 3.08x |
| find shared-prefix alternation | 45,095.5 | 65,858.4 | 1.46x |
| find one-char alternation | 12,822.8 | 21,625.3 | 1.69x |
| find hex color | 79,679.9 | 277,939.1 | 3.49x |
| find version | 98,701.5 | 299,412.1 | 3.03x |
| find nullable prefix | 19,828.5 | 84,526.6 | 4.26x |
| find identifier | 125,570.5 | 393,785.6 | 3.14x |
| find thousands | 82,777.1 | 321,298.3 | 3.88x |
| find domain | 61,140.6 | 367,047.2 | 6.00x |
| find percent | 69,385.7 | 318,817.7 | 4.59x |
| find time | 82,680.6 | 306,012.4 | 3.70x |
| find end-anchored word | 2,528.5 | 38,057.6 | 15.05x |
| find UUID | 56,515.7 | 270,577.4 | 4.79x |
| find semver | 102,077.5 | 274,223.3 | 2.69x |
| find email TLD | 18,627.9 | 45,089.9 | 2.42x |
| find CIDR | 100,196.2 | 362,281.5 | 3.62x |
| find line full | 4,172.6 | 81,013.7 | 19.42x |
| find optional prefix run | 60,608.3 | 799,264.2 | 13.19x |
| find repeated literal group | 118,521.6 | 358,203.5 | 3.02x |
| find camelCase | 110,175.9 | 415,049.6 | 3.77x |
| find key-value | 165,328.4 | 568,784.5 | 3.44x |
| find IP port | 122,495.6 | 425,814.5 | 3.48x |
| find (?i) class | 49,197.5 | 153,247.3 | 3.11x |
| find prefix alternation | 200,642.6 | 281,655.6 | 1.40x |
| find signed number | 93,348.9 | 251,669.2 | 2.70x |
| find html attribute | 85,238.8 | 225,776.0 | 2.65x |
| find markdown heading | 72,319.5 | 222,540.6 | 3.08x |
| find mixed alternation | 382,236.7 | 639,944.8 | 1.67x |
| find capitalized words | 4,988.6 | 140,386.1 | 28.14x |
| find markdown list | 4,948.4 | 41,610.7 | 8.41x |
| find JSON escaped string | 17,626.2 | 50,488.2 | 2.86x |
| find double spaces | 8,946.9 | 46,660.4 | 5.22x |
| find log level | 1,566.8 | 3,092.4 | 1.97x |
| find markdown heading ws | 72,351.0 | 222,734.7 | 3.08x |
| find markdown list ws | 4,924.6 | 72,442.7 | 14.71x |
| find escaped string loop | 17,610.8 | 50,267.2 | 2.85x |
| find HTTP methods | 1,428.1 | 2,367.9 | 1.66x |
| find full email | 19,625.3 | 75,867.7 | 3.87x |
| find blank lines | 1,153.4 | 38,100.9 | 33.03x |
| find floats | 75,587.9 | 245,676.4 | 3.25x |
| find currency | 347.1 | 286.8 | 0.83x |
| find ISO timestamp | 73,595.3 | 317,953.9 | 4.32x |
| find JSON key | 15,770.9 | 39,760.6 | 2.52x |
| find HTML comment | 1,173.3 | 2,205.8 | 1.88x |
| find hashtag | 1,282.0 | 1,663.7 | 1.30x |
| find mention | 1,297.8 | 1,667.1 | 1.28x |
| find CSS unit | 49,781.0 | 304,330.4 | 6.11x |
| find function call | 114,254.0 | 241,777.8 | 2.12x |
| find SQL keyword | 1,065.7 | 2,357.1 | 2.21x |
| find JSON literal | 554.4 | 877.0 | 1.58x |
| find blockquote | 376.6 | 433.1 | 1.15x |
| find ordered list | 375.4 | 381.2 | 1.02x |
| find query param | 25,590.1 | 60,980.0 | 2.38x |
| find MAC address | 64,998.9 | 248,797.7 | 3.83x |
| find base64 run | 80,000.9 | 461,822.0 | 5.77x |
| find markdown link | 377.4 | 461.5 | 1.22x |
| find YAML key | 33,801.0 | 79,940.4 | 2.37x |
| find TOML table | 33,749.8 | 101,879.3 | 3.02x |
| find template | 69,139.1 | 214,386.4 | 3.10x |
| find Windows path | 46,479.9 | 184,437.3 | 3.97x |
| find CSS selector | 84,047.2 | 190,782.4 | 2.27x |
| find slash date | 80,056.9 | 343,000.2 | 4.28x |
| find HTTP request | 825.4 | 1,832.6 | 2.22x |
| find IPv6 | 73,283.5 | 257,220.2 | 3.51x |
| find C comment | 86,892.4 | 262,755.7 | 3.02x |
| find markdown image | 378.5 | 821.4 | 2.17x |
| find HTML tag name | 126,814.5 | 334,291.1 | 2.64x |
| find shell var | 120,906.5 | 362,741.1 | 3.00x |
| split whitespace (22 KiB) | 30,939.6 | 136,699.0 | 4.42x |
| split commas (29 KiB) | 24,330.8 | 62,751.1 | 2.58x |
| split lines | 1,304.3 | 2,927.1 | 2.24x |
| split semicolons | 21,504.0 | 50,240.6 | 2.34x |
| fullmatch literal | 3.6 | 15.0 | 4.17x |
| fullmatch class | 9.9 | 60.4 | 6.10x |
| fullmatch xDS-like | 19.2 | 74.4 | 3.88x |
| replaceAll a+ -> x | 28,917.9 | 163,952.3 | 5.67x |
| replaceAll \A\|\z -> X | 1,021.5 | 38,925.3 | 38.11x |
| replaceAll digits -> N | 62,553.8 | 331,749.5 | 5.30x |
| RegexSet 9 no-match patterns | 2,964.4 | 48,026.8 | 16.20x |

regexz is faster on 100 of the 101 measured cases. The remaining loss is
currency (`\$\d+(?:\.\d{2})?`, 0.83x). The largest leads are compile time
(63.15x), `replaceAll` with edge assertions (38.11x), blank-line scans
(33.03x), capitalized-word scans (28.14x), line-full scans (19.42x),
`RegexSet` no-match scans (16.20x) and end-anchored word scans (15.05x); the
tokenizer searches are 4.47x and 4.55x ahead. The geometric-mean ratio is
3.62x. The currency row is a small absolute gap (about 60 ns).

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

cd tools/compare/rust_regex
cargo build --release

# One fresh process per case, implementations interleaved.
python3 tools/compare/isolated_sweep.py --rounds 5 --out /tmp/compare.json
python3 tools/compare/isolated.py 5 "find IPv4" "find IPv6"
```
