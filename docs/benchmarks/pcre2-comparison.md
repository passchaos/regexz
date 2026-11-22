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

Method: each case runs in a fresh process for both binaries, five interleaved
rounds, with every process pinned to CPU 0 with `taskset`; the table reports
medians. One case per process removes cross-case heap and code-layout
interference: in the earlier single-process sweep, unrelated rows moved by
10-50% when one case's code changed. The suite covers 100 cases: the same
cases as the Rust comparison minus the `RegexSet` row, because PCRE2 has no
combined-set API. The compile rows measure PCRE2's compile plus JIT
compilation against regexz's compile. Raw samples and executable identities
for the same isolated sweep are in
[`pcre2-comparison-current.json`](pcre2-comparison-current.json).

| Case | regexz, ns/iter | PCRE2, ns/iter | PCRE2 / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 11,428.8 | 16,195.8 | 1.42x |
| compile xDS-like | 5,852.0 | 7,189.3 | 1.23x |
| find Qwen tokenizer | 56,469.6 | 182,949.0 | 3.24x |
| findAll Qwen (borrowed) | 55,777.6 | 181,035.5 | 3.25x |
| findAll Qwen (owning) | 55,832.4 | 181,922.2 | 3.26x |
| find CJK tokenizer | 216,811.9 | 561,470.0 | 2.59x |
| find HTML tag | 91,409.2 | 197,440.8 | 2.16x |
| find URL | 71,011.7 | 103,152.5 | 1.45x |
| find JSON string literal | 15,038.3 | 27,091.0 | 1.80x |
| find JSON number | 74,348.2 | 122,011.7 | 1.64x |
| find word boundary | 192,874.5 | 382,150.7 | 1.98x |
| find (?i) literal | 64,685.4 | 63,885.8 | 0.99x |
| find alternation (5 words) | 95,442.2 | 211,862.2 | 2.22x |
| find (?i) alternation | 87,241.6 | 153,445.6 | 1.76x |
| find 10-word alternation | 210,661.8 | 288,001.4 | 1.37x |
| find Greek class | 103,060.0 | 167,472.2 | 1.62x |
| find prefix+suffix | 15,269.0 | 22,737.4 | 1.49x |
| replaceAll email captures | 33,917.3 | 39,831.9 | 1.17x |
| find IPv4 | 96,518.9 | 166,862.0 | 1.73x |
| find date | 82,260.1 | 142,881.8 | 1.74x |
| find 20-word alternation | 210,402.1 | 287,826.7 | 1.37x |
| find anchored line | 4,191.1 | 5,677.2 | 1.35x |
| find (?i) Unicode literal | 121,477.0 | 117,174.3 | 0.96x |
| find shared-prefix alternation | 46,802.2 | 77,903.9 | 1.66x |
| find one-char alternation | 12,824.9 | 35,597.9 | 2.78x |
| find hex color | 79,065.3 | 127,184.7 | 1.61x |
| find version | 98,730.1 | 140,922.1 | 1.43x |
| find nullable prefix | 19,720.9 | 38,856.2 | 1.97x |
| find identifier | 125,544.0 | 204,059.1 | 1.63x |
| find thousands | 83,431.0 | 146,999.2 | 1.76x |
| find domain | 62,510.6 | 136,228.7 | 2.18x |
| find percent | 69,504.8 | 133,135.4 | 1.92x |
| find time | 84,074.0 | 135,058.0 | 1.61x |
| find end-anchored word | 2,567.8 | 20,347.1 | 7.92x |
| find UUID | 56,613.8 | 81,424.0 | 1.44x |
| find semver | 101,425.4 | 129,134.3 | 1.27x |
| find email TLD | 18,458.2 | 28,865.7 | 1.56x |
| find CIDR | 100,115.9 | 165,518.3 | 1.65x |
| find line full | 4,127.0 | 16,592.3 | 4.02x |
| find optional prefix run | 60,864.2 | 462,952.8 | 7.61x |
| find repeated literal group | 118,200.4 | 168,891.9 | 1.43x |
| find camelCase | 110,745.1 | 188,042.6 | 1.70x |
| find key-value | 165,034.1 | 240,265.6 | 1.46x |
| find IP port | 122,096.5 | 162,864.0 | 1.33x |
| find (?i) class | 49,184.5 | 79,680.0 | 1.62x |
| find prefix alternation | 206,712.6 | 196,408.5 | 0.95x |
| find signed number | 92,789.8 | 129,053.0 | 1.39x |
| find html attribute | 85,048.7 | 113,795.2 | 1.34x |
| find markdown heading | 72,255.5 | 107,620.2 | 1.49x |
| find mixed alternation | 382,281.7 | 449,255.0 | 1.18x |
| find capitalized words | 4,958.9 | 23,666.0 | 4.77x |
| find markdown list | 4,921.9 | 29,132.9 | 5.92x |
| find JSON escaped string | 17,645.4 | 34,482.2 | 1.95x |
| find double spaces | 8,913.3 | 16,443.0 | 1.84x |
| find log level | 1,468.8 | 19,962.7 | 13.59x |
| find markdown heading ws | 72,407.5 | 125,885.3 | 1.74x |
| find markdown list ws | 4,913.9 | 25,755.1 | 5.24x |
| find escaped string loop | 17,648.4 | 30,255.6 | 1.71x |
| find HTTP methods | 1,410.3 | 18,000.7 | 12.76x |
| find full email | 19,608.0 | 34,088.2 | 1.74x |
| find blank lines | 1,153.0 | 1,562.7 | 1.36x |
| find floats | 76,445.4 | 121,468.5 | 1.59x |
| find currency | 299.4 | 931.0 | 3.11x |
| find ISO timestamp | 69,458.4 | 108,372.8 | 1.56x |
| find JSON key | 15,855.6 | 22,714.1 | 1.43x |
| find HTML comment | 1,187.6 | 2,139.5 | 1.80x |
| find hashtag | 1,311.4 | 1,533.7 | 1.17x |
| find mention | 1,317.2 | 1,549.3 | 1.18x |
| find CSS unit | 49,720.2 | 166,712.6 | 3.35x |
| find function call | 114,155.1 | 160,882.1 | 1.41x |
| find SQL keyword | 1,089.0 | 23,601.6 | 21.67x |
| find JSON literal | 547.5 | 11,430.1 | 20.88x |
| find blockquote | 375.5 | 1,176.0 | 3.13x |
| find ordered list | 375.7 | 1,176.0 | 3.13x |
| find query param | 25,225.0 | 34,527.9 | 1.37x |
| find MAC address | 66,618.3 | 121,875.9 | 1.83x |
| find base64 run | 80,537.7 | 120,374.1 | 1.49x |
| find markdown link | 367.4 | 1,178.8 | 3.21x |
| find YAML key | 33,549.0 | 66,937.8 | 2.00x |
| find TOML table | 32,285.1 | 49,877.1 | 1.54x |
| find template | 69,196.5 | 116,720.6 | 1.69x |
| find Windows path | 46,593.8 | 111,216.7 | 2.39x |
| find CSS selector | 83,621.9 | 102,458.7 | 1.23x |
| find slash date | 79,928.4 | 136,483.0 | 1.71x |
| find HTTP request | 809.9 | 1,176.3 | 1.45x |
| find IPv6 | 73,211.7 | 96,267.5 | 1.31x |
| find C comment | 87,057.6 | 133,739.1 | 1.54x |
| find markdown image | 378.6 | 1,383.8 | 3.66x |
| find HTML tag name | 126,883.3 | 202,116.6 | 1.59x |
| find shell var | 120,841.4 | 202,852.8 | 1.68x |
| split whitespace (22 KiB) | 30,961.3 | 103,721.9 | 3.35x |
| split commas (29 KiB) | 24,329.3 | 134,235.6 | 5.52x |
| split lines | 1,285.5 | 4,702.7 | 3.66x |
| split semicolons | 21,414.7 | 114,873.2 | 5.36x |
| fullmatch literal | 3.6 | 19.4 | 5.39x |
| fullmatch class | 9.9 | 25.1 | 2.54x |
| fullmatch xDS-like | 19.0 | 24.7 | 1.30x |
| replaceAll a+ -> x | 28,758.6 | 120,964.9 | 4.21x |
| replaceAll \A\|\z -> X | 1,026.7 | 27,857.4 | 27.13x |
| replaceAll digits -> N | 63,033.8 | 284,751.2 | 4.52x |

regexz is faster or at parity on 97 of the 100 measured cases, with a
geometric-mean PCRE2/regexz ratio of 2.21x. The three rows below 1.00x are
within host noise:

- `find prefix alternation` (0.95x), `find (?i) Unicode literal` (0.96x) and
  `find (?i) literal` (0.99x): parity within host noise.

Compile Qwen is now 1.42x ahead of PCRE2, up from a 0.69x ratio: PCRE2 parses
the pattern and stores property references, while regexz materializes the
Unicode property sets at compile time so searches can use range lists
directly. The compile rows include PCRE2's JIT pass, while regexz has no JIT.
Compile xDS-like is 1.23x ahead; HTML tags are 2.16x ahead after the
wrapped-run probes, and end-anchored word scans are 7.92x ahead after the
line-end scan.

The largest leads are on literal-heavy scans and alternations: the nibble
filter, required-literal prefilters and counted split paths avoid PCRE2's
byte-at-a-time interpreter/JIT loop. Representative rows: `replaceAll
\A\|\z -> X` 27.13x, `find SQL keyword` 21.67x, `find JSON literal`
20.88x, `find log level` 13.59x, `find HTTP methods` 12.76x, `find
end-anchored word` 7.92x, `find optional prefix run` 7.61x, and `split
commas` 5.52x. The absolute times are from a shared host; the interleaved
medians are more reliable than any single run.

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
