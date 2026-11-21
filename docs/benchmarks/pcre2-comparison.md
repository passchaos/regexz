# Comparison with PCRE2

Linux x86_64 (Intel Raptor Lake), Zig 0.16.0 ReleaseFast, PCRE2 10.42 with
JIT, November 2026. The harness is
[`tools/compare/pcre2_regex.zig`](../tools/compare/pcre2_regex.zig); it drives
the system PCRE2 library through its C API and mirrors the find, split,
replace and full-match cases in
[the Rust comparison](rust-comparison.md). PCRE2 is compiled with UTF support
and JIT. Matching uses `PCRE2_NO_UTF_CHECK` because every subject is already
valid UTF-8; without it PCRE2 revalidates the whole subject on every
`pcre2_match` call, which turns a find loop into quadratic work. UCP is left
off so `\b` and `\w` stay ASCII like the Rust `(?-u:...)` comparison case.

Method: three interleaved executions (regexz then PCRE2 each round), with
both processes pinned to CPU 0 with `taskset`; the table reports medians.
The suite covers 100 cases: the same cases as the Rust comparison minus the
`RegexSet` row, because PCRE2 has no combined-set API. The compile rows
measure PCRE2's compile plus JIT compilation against regexz's compile. Raw
samples and executable identities are in
[`pcre2-comparison-current.json`](pcre2-comparison-current.json).

| Case | regexz, ns/iter | PCRE2, ns/iter | PCRE2 / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 106,280.3 | 34,119.1 | 0.32x |
| compile xDS-like | 24,374.5 | 14,389.4 | 0.59x |
| find Qwen tokenizer | 113,257.7 | 359,440.7 | 3.17x |
| findAll Qwen (borrowed) | 123,653.7 | 360,448.7 | 2.91x |
| findAll Qwen (owning) | 123,009.8 | 358,330.3 | 2.91x |
| find CJK tokenizer | 465,237.8 | 1,086,520.0 | 2.34x |
| find HTML tag | 397,088.8 | 398,396.6 | 1.00x |
| find URL | 145,577.0 | 207,006.1 | 1.42x |
| find JSON string literal | 29,818.0 | 59,499.5 | 2.00x |
| find JSON number | 148,023.6 | 274,995.7 | 1.86x |
| find word boundary | 387,658.4 | 776,666.3 | 2.00x |
| find (?i) literal | 144,022.7 | 147,783.3 | 1.03x |
| find alternation (5 words) | 185,200.7 | 448,318.5 | 2.42x |
| find (?i) alternation | 180,612.3 | 324,500.2 | 1.80x |
| find 10-word alternation | 420,631.0 | 666,880.0 | 1.59x |
| find Greek class | 193,197.4 | 354,693.2 | 1.84x |
| find prefix+suffix | 30,115.9 | 51,965.9 | 1.73x |
| replaceAll email captures | 63,532.0 | 83,820.9 | 1.32x |
| find IPv4 | 233,882.1 | 330,400.8 | 1.41x |
| find date | 176,986.9 | 303,225.2 | 1.71x |
| find 20-word alternation | 420,666.8 | 666,860.5 | 1.59x |
| find anchored line | 4,307.2 | 5,823.4 | 1.35x |
| find (?i) Unicode literal | 245,974.4 | 274,414.1 | 1.12x |
| find shared-prefix alternation | 89,917.1 | 152,971.3 | 1.70x |
| find one-char alternation | 27,544.5 | 68,661.0 | 2.49x |
| find hex color | 155,458.1 | 295,861.6 | 1.90x |
| find version | 205,265.1 | 303,089.8 | 1.48x |
| find nullable prefix | 35,114.2 | 83,132.4 | 2.37x |
| find identifier | 243,063.4 | 474,739.4 | 1.95x |
| find thousands | 158,528.1 | 299,865.5 | 1.89x |
| find domain | 122,172.9 | 273,937.8 | 2.24x |
| find percent | 149,060.3 | 294,828.9 | 1.98x |
| find time | 175,697.3 | 294,481.6 | 1.68x |
| find end-anchored word | 32,685.4 | 35,377.5 | 1.08x |
| find UUID | 94,640.2 | 155,316.3 | 1.64x |
| find semver | 207,505.2 | 262,460.7 | 1.26x |
| find email TLD | 33,124.2 | 58,694.4 | 1.77x |
| find CIDR | 238,894.3 | 329,415.1 | 1.38x |
| find line full | 4,178.7 | 31,419.0 | 7.52x |
| find optional prefix run | 116,237.3 | 1,101,827.9 | 9.48x |
| find repeated literal group | 236,732.1 | 388,153.3 | 1.64x |
| find camelCase | 215,353.2 | 423,482.5 | 1.97x |
| find key-value | 331,851.1 | 483,830.1 | 1.46x |
| find IP port | 268,202.6 | 331,537.0 | 1.24x |
| find (?i) class | 93,821.7 | 171,566.0 | 1.83x |
| find prefix alternation | 396,160.5 | 447,964.4 | 1.13x |
| find signed number | 183,304.2 | 296,489.7 | 1.62x |
| find html attribute | 172,928.7 | 233,542.7 | 1.35x |
| find markdown heading | 146,222.0 | 217,846.0 | 1.49x |
| find mixed alternation | 903,940.0 | 1,068,817.4 | 1.18x |
| find capitalized words | 5,057.7 | 53,498.3 | 10.58x |
| find markdown list | 4,973.1 | 59,022.5 | 11.87x |
| find JSON escaped string | 32,316.9 | 64,793.4 | 2.00x |
| find double spaces | 24,220.4 | 30,766.8 | 1.27x |
| find log level | 3,002.9 | 34,793.9 | 11.59x |
| find markdown heading ws | 146,175.1 | 241,004.4 | 1.65x |
| find markdown list ws | 5,000.0 | 55,610.3 | 11.12x |
| find escaped string loop | 32,240.9 | 60,842.3 | 1.89x |
| find HTTP methods | 1,444.3 | 32,952.7 | 22.82x |
| find full email | 34,527.7 | 64,039.2 | 1.85x |
| find blank lines | 1,160.1 | 1,551.1 | 1.34x |
| find floats | 151,324.5 | 275,826.2 | 1.82x |
| find currency | 318.9 | 929.3 | 2.91x |
| find ISO timestamp | 148,724.3 | 217,817.0 | 1.46x |
| find JSON key | 30,750.2 | 38,000.0 | 1.24x |
| find HTML comment | 1,173.5 | 2,079.8 | 1.77x |
| find hashtag | 1,195.7 | 1,530.2 | 1.28x |
| find mention | 1,095.5 | 1,548.3 | 1.41x |
| find CSS unit | 94,476.0 | 364,419.4 | 3.86x |
| find function call | 234,266.6 | 327,111.3 | 1.40x |
| find SQL keyword | 1,063.1 | 53,307.6 | 50.14x |
| find JSON literal | 549.3 | 26,408.7 | 48.08x |
| find blockquote | 369.9 | 1,180.5 | 3.19x |
| find ordered list | 369.4 | 1,176.1 | 3.18x |
| find query param | 55,231.9 | 81,981.3 | 1.48x |
| find MAC address | 126,095.0 | 243,239.6 | 1.93x |
| find base64 run | 154,866.3 | 239,595.9 | 1.55x |
| find markdown link | 371.8 | 1,176.3 | 3.16x |
| find YAML key | 63,848.8 | 141,847.4 | 2.22x |
| find TOML table | 63,595.2 | 98,957.8 | 1.56x |
| find template | 156,615.4 | 234,381.4 | 1.50x |
| find Windows path | 91,545.6 | 219,789.2 | 2.40x |
| find CSS selector | 173,813.8 | 214,200.0 | 1.23x |
| find slash date | 175,736.2 | 300,339.3 | 1.71x |
| find HTTP request | 807.6 | 1,149.1 | 1.42x |
| find IPv6 | 217,018.5 | 185,593.8 | 0.86x |
| find C comment | 176,694.1 | 266,643.8 | 1.51x |
| find markdown image | 370.2 | 1,289.3 | 3.48x |
| find HTML tag name | 289,114.4 | 403,067.6 | 1.39x |
| find shell var | 240,927.2 | 413,004.2 | 1.71x |
| split whitespace (22 KiB) | 61,619.5 | 227,798.8 | 3.70x |
| split commas (29 KiB) | 49,563.6 | 298,122.8 | 6.01x |
| split lines | 1,299.0 | 5,369.8 | 4.13x |
| split semicolons | 41,379.8 | 242,686.6 | 5.86x |
| fullmatch literal | 3.5 | 39.5 | 11.29x |
| fullmatch class | 20.0 | 58.2 | 2.91x |
| fullmatch xDS-like | 33.8 | 57.6 | 1.70x |
| replaceAll a+ -> x | 60,220.7 | 265,651.7 | 4.41x |
| replaceAll \A\|\z -> X | 1,026.9 | 57,648.6 | 56.14x |
| replaceAll digits -> N | 116,053.8 | 626,438.1 | 5.40x |

regexz is faster on 97 of the 100 measured cases, with a geometric-mean
PCRE2/regexz ratio of 2.31x. The three PCRE2 wins are the two compile
rows and IPv6:

- `compile Qwen tokenizer` (0.32x):
  PCRE2 parses the pattern and stores property references; regexz
  materializes the Unicode property sets at compile time so searches can use
  range lists directly. The compile rows include PCRE2's JIT pass, while
  regexz has no JIT.
- `compile xDS-like` (0.59x):
  the same materialization tradeoff on a smaller pattern.
- `find IPv6` (0.86x): PCRE2's
  JIT keeps pace on the colon-heavy IPv6 text; most other search cases are
  clearly ahead of PCRE2.

The largest leads are on literal-heavy scans and alternations: the nibble
filter, required-literal prefilters and counted split paths avoid PCRE2's
byte-at-a-time interpreter/JIT loop. Representative rows: `find SQL keyword`
50.14x, `find JSON literal` 48.08x, `find HTTP methods` 22.82x, `find
markdown list` 11.87x, `find log level` 11.59x, `replaceAll \A\|\z -> X`
56.14x, and `split commas` 6.01x. The absolute times are from a shared host;
the interleaved medians are more reliable than any single run.

Caveats: the iteration APIs are the natural ones for each library, the split
comparison collects PCRE2's parts into an allocated slice so both sides
allocate the parts array, and the allocators differ (regexz uses
`std.heap.smp_allocator`, PCRE2 uses the system allocator). PCRE2's JIT
compilation is part of the compile rows and is also active in the search
rows. These numbers cover the listed workloads, not every regex feature:
PCRE2's extended mode covers many features that regexz's linear mode does
not, and vice versa.

Reproduce:

```sh
zig build-exe -O ReleaseFast -lc -lpcre2-8 \
    tools/compare/pcre2_regex.zig -femit-bin=/tmp/regexz-pcre2
/tmp/regexz-pcre2
```
