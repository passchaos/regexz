# Comparison with Rust's `regex`

Linux x86_64 (Intel Raptor Lake), Zig 0.16.0 ReleaseFast, Rust `regex`
1.13.2, November 2026. The harnesses live in [`tools/compare`](../tools/compare):
`zig_regex.zig` runs regexz and `rust_regex` runs the same inputs and patterns
through Rust's `regex` crate. Both report the median of five batches per case.

Method: the current sweep executed the two binaries alternately, six times
(three rounds in each order), with both processes pinned to CPU 0 with
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
| compile Qwen tokenizer | 52,461.2 | 716,184.3 | 13.65x |
| compile xDS-like | 12,294.3 | 31,838.6 | 2.59x |
| find Qwen tokenizer | 53,068.2 | 106,738.0 | 2.01x |
| findAll Qwen (borrowed) | 63,475.9 | 105,099.5 | 1.66x |
| findAll Qwen (owning) | 63,460.5 | 105,796.9 | 1.67x |
| find CJK tokenizer | 220,389.2 | 478,034.2 | 2.17x |
| find HTML tag | 202,462.5 | 179,060.7 | 0.88x |
| find URL | 71,214.4 | 162,665.6 | 2.28x |
| find JSON string literal | 14,837.2 | 22,592.0 | 1.52x |
| find JSON number | 73,685.6 | 95,495.2 | 1.30x |
| find word boundary | 192,831.2 | 205,389.1 | 1.07x |
| find (?i) literal | 69,085.7 | 168,367.4 | 2.44x |
| find alternation (5 words) | 95,425.8 | 233,730.5 | 2.45x |
| find (?i) alternation | 90,685.1 | 301,614.9 | 3.33x |
| find 10-word alternation | 210,851.4 | 381,833.6 | 1.81x |
| find Greek class | 99,673.8 | 146,859.0 | 1.47x |
| find prefix+suffix | 15,204.2 | 47,542.8 | 3.13x |
| replaceAll email captures | 33,500.0 | 114,425.9 | 3.42x |
| find IPv4 | 115,390.4 | 201,778.8 | 1.75x |
| find date | 86,930.6 | 201,903.0 | 2.32x |
| find 20-word alternation | 211,129.8 | 362,698.2 | 1.72x |
| find anchored line | 4,283.7 | 38,925.2 | 9.09x |
| find (?i) Unicode literal | 125,737.2 | 209,272.5 | 1.66x |
| find shared-prefix alternation | 44,684.1 | 53,201.8 | 1.19x |
| find one-char alternation | 12,554.3 | 11,252.0 | 0.90x |
| find hex color | 80,517.4 | 119,759.0 | 1.49x |
| find version | 100,741.4 | 172,795.8 | 1.72x |
| find nullable prefix | 19,904.6 | 69,978.7 | 3.52x |
| find identifier | 123,208.4 | 162,262.3 | 1.32x |
| find thousands | 83,314.6 | 178,974.2 | 2.15x |
| find domain | 62,322.6 | 206,245.2 | 3.31x |
| find percent | 73,977.6 | 185,565.9 | 2.51x |
| find time | 86,315.5 | 175,536.9 | 2.03x |
| find end-anchored word | 17,772.1 | 38,040.3 | 2.14x |
| find UUID | 49,730.1 | 154,990.2 | 3.12x |
| find semver | 102,565.4 | 164,423.6 | 1.60x |
| find email TLD | 17,940.9 | 34,869.6 | 1.94x |
| find CIDR | 119,837.3 | 201,577.1 | 1.68x |
| find line full | 4,187.0 | 43,230.4 | 10.32x |
| find optional prefix run | 56,652.1 | 293,783.2 | 5.19x |
| find repeated literal group | 116,891.6 | 196,787.0 | 1.68x |
| find camelCase | 110,488.6 | 155,414.0 | 1.41x |
| find key-value | 165,733.9 | 320,268.4 | 1.93x |
| find IP port | 131,873.3 | 235,144.5 | 1.78x |
| find (?i) class | 48,857.1 | 65,800.6 | 1.35x |
| find prefix alternation | 203,276.0 | 226,055.7 | 1.11x |
| find signed number | 93,350.4 | 96,356.9 | 1.03x |
| find html attribute | 83,238.9 | 151,932.2 | 1.83x |
| find markdown heading | 71,748.4 | 104,650.8 | 1.46x |
| find mixed alternation | 457,681.5 | 484,820.5 | 1.06x |
| find capitalized words | 5,059.1 | 140,340.7 | 27.74x |
| find markdown list | 4,958.1 | 41,407.9 | 8.35x |
| find JSON escaped string | 17,590.7 | 22,706.5 | 1.29x |
| find double spaces | 9,617.7 | 42,161.5 | 4.38x |
| find log level | 3,009.2 | 3,089.3 | 1.03x |
| find markdown heading ws | 71,321.8 | 104,916.5 | 1.47x |
| find markdown list ws | 4,948.0 | 72,459.1 | 14.64x |
| find escaped string loop | 17,465.3 | 22,560.0 | 1.29x |
| find HTTP methods | 1,452.9 | 2,353.3 | 1.62x |
| find full email | 19,631.0 | 46,651.3 | 2.38x |
| find blank lines | 1,154.6 | 38,064.1 | 32.97x |
| find floats | 76,344.5 | 95,886.3 | 1.26x |
| find currency | 299.3 | 325.8 | 1.09x |
| find ISO timestamp | 73,795.8 | 184,185.0 | 2.50x |
| find JSON key | 15,797.8 | 19,577.7 | 1.24x |
| find HTML comment | 1,174.0 | 2,194.1 | 1.87x |
| find hashtag | 1,204.3 | 1,674.6 | 1.39x |
| find mention | 1,208.1 | 1,663.3 | 1.38x |
| find CSS unit | 50,825.4 | 104,118.8 | 2.05x |
| find function call | 113,911.4 | 194,325.7 | 1.71x |
| find SQL keyword | 1,063.0 | 2,353.4 | 2.21x |
| find JSON literal | 545.4 | 880.0 | 1.61x |
| find blockquote | 370.4 | 397.2 | 1.07x |
| find ordered list | 368.6 | 388.1 | 1.05x |
| find query param | 25,533.8 | 31,534.3 | 1.24x |
| find MAC address | 66,153.5 | 98,988.8 | 1.50x |
| find base64 run | 79,850.8 | 232,330.0 | 2.91x |
| find markdown link | 360.9 | 398.0 | 1.10x |
| find YAML key | 33,963.3 | 58,876.4 | 1.73x |
| find TOML table | 33,771.4 | 47,830.6 | 1.42x |
| find template | 81,181.7 | 97,995.7 | 1.21x |
| find Windows path | 46,597.1 | 175,237.2 | 3.76x |
| find CSS selector | 84,201.2 | 86,391.3 | 1.03x |
| find slash date | 85,898.1 | 189,267.5 | 2.20x |
| find HTTP request | 808.0 | 1,795.1 | 2.22x |
| find IPv6 | 109,140.8 | 109,947.4 | 1.01x |
| find C comment | 86,343.0 | 121,795.1 | 1.41x |
| find markdown image | 369.4 | 812.4 | 2.20x |
| find HTML tag name | 142,407.2 | 150,794.1 | 1.06x |
| find shell var | 121,235.8 | 174,377.0 | 1.44x |
| split whitespace (22 KiB) | 31,682.5 | 138,202.6 | 4.36x |
| split commas (29 KiB) | 25,025.8 | 64,006.1 | 2.56x |
| split lines | 1,290.9 | 3,034.9 | 2.35x |
| split semicolons | 21,764.6 | 51,320.6 | 2.36x |
| fullmatch literal | 3.6 | 13.8 | 3.82x |
| fullmatch class | 9.9 | 57.8 | 5.84x |
| fullmatch xDS-like | 18.9 | 68.4 | 3.63x |
| replaceAll a+ -> x | 30,501.6 | 162,234.5 | 5.32x |
| replaceAll \A\|\z -> X | 1,009.0 | 39,053.1 | 38.70x |
| replaceAll digits -> N | 56,271.8 | 329,421.9 | 5.85x |
| RegexSet 9 no-match patterns | 2,965.1 | 47,910.9 | 16.16x |

regexz is faster on 99 of the 101 measured cases. The two remaining losses are
HTML tags (`<[^>]+>`, 0.88x) and the one-character alternation (`a|b|c`,
0.90x); IPv6 is at parity (1.01x). The largest leads are compile time
(13.65x), `RegexSet` no-match scans (16.24x), `replaceAll` with edge
assertions (38.70x), the tokenizer searches (2.01x and 2.17x), and the
counted split paths (2.32x to 4.39x).

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
