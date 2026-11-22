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
10-50% when one case's code changed. The `find` rows use the per-position
match loop on both sides; PCRE2 has no iterator API, so the `findAll` rows use
its natural match loop while regexz uses `findAllWith`. The suite covers 100
cases: the same
cases as the Rust comparison minus the `RegexSet` row, because PCRE2 has no
combined-set API. The compile rows measure PCRE2's compile plus JIT
compilation against regexz's compile. Raw samples and executable identities
for the same isolated sweep are in
[`pcre2-comparison-current.json`](pcre2-comparison-current.json).

| Case | regexz, ns/iter | PCRE2, ns/iter | PCRE2 / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 11,435.2 | 16,170.4 | 1.41x |
| compile xDS-like | 5,816.8 | 7,207.9 | 1.24x |
| find Qwen tokenizer | 56,045.8 | 181,555.1 | 3.24x |
| findAll Qwen (borrowed) | 56,329.5 | 180,759.4 | 3.21x |
| findAll Qwen (owning) | 56,034.8 | 181,845.3 | 3.25x |
| find CJK tokenizer | 219,085.3 | 561,502.4 | 2.56x |
| find HTML tag | 91,587.1 | 197,415.4 | 2.16x |
| find URL | 70,617.7 | 103,497.8 | 1.47x |
| find JSON string literal | 15,047.0 | 27,232.6 | 1.81x |
| find JSON number | 74,461.9 | 123,429.7 | 1.66x |
| find word boundary | 189,440.6 | 381,938.9 | 2.02x |
| find (?i) literal | 65,778.2 | 63,588.1 | 0.97x |
| find alternation (5 words) | 95,379.0 | 211,841.6 | 2.22x |
| find (?i) alternation | 87,516.6 | 153,303.8 | 1.75x |
| find 10-word alternation | 210,308.8 | 287,684.0 | 1.37x |
| find Greek class | 103,462.0 | 167,940.2 | 1.62x |
| find prefix+suffix | 14,069.4 | 22,704.2 | 1.61x |
| replaceAll email captures | 33,687.3 | 39,918.3 | 1.18x |
| find IPv4 | 96,425.6 | 166,571.2 | 1.73x |
| find date | 87,964.9 | 142,757.6 | 1.62x |
| find 20-word alternation | 211,120.5 | 288,205.8 | 1.37x |
| find anchored line | 4,279.4 | 5,675.2 | 1.33x |
| find (?i) Unicode literal | 121,000.9 | 117,351.2 | 0.97x |
| find shared-prefix alternation | 45,095.5 | 78,312.3 | 1.74x |
| find one-char alternation | 12,822.8 | 35,507.2 | 2.77x |
| find hex color | 79,679.9 | 127,145.0 | 1.60x |
| find version | 98,701.5 | 140,113.1 | 1.42x |
| find nullable prefix | 19,828.5 | 38,764.1 | 1.95x |
| find identifier | 125,570.5 | 202,834.6 | 1.62x |
| find thousands | 82,777.1 | 147,618.3 | 1.78x |
| find domain | 61,140.6 | 135,728.5 | 2.22x |
| find percent | 69,385.7 | 132,090.7 | 1.90x |
| find time | 82,680.6 | 134,824.0 | 1.63x |
| find end-anchored word | 2,528.5 | 20,561.6 | 8.13x |
| find UUID | 56,515.7 | 81,402.5 | 1.44x |
| find semver | 102,077.5 | 128,799.3 | 1.26x |
| find email TLD | 18,627.9 | 29,236.3 | 1.57x |
| find CIDR | 100,196.2 | 165,776.7 | 1.65x |
| find line full | 4,172.6 | 16,669.4 | 3.99x |
| find optional prefix run | 60,608.3 | 476,179.9 | 7.86x |
| find repeated literal group | 118,521.6 | 169,578.9 | 1.43x |
| find camelCase | 110,175.9 | 187,019.4 | 1.70x |
| find key-value | 165,328.4 | 245,896.6 | 1.49x |
| find IP port | 122,495.6 | 162,445.6 | 1.33x |
| find (?i) class | 49,197.5 | 79,479.8 | 1.62x |
| find prefix alternation | 200,642.6 | 196,264.5 | 0.98x |
| find signed number | 93,348.9 | 129,343.2 | 1.39x |
| find html attribute | 85,238.8 | 114,327.0 | 1.34x |
| find markdown heading | 72,319.5 | 106,850.1 | 1.48x |
| find mixed alternation | 382,236.7 | 455,332.4 | 1.19x |
| find capitalized words | 4,988.6 | 23,679.4 | 4.75x |
| find markdown list | 4,948.4 | 29,123.4 | 5.89x |
| find JSON escaped string | 17,626.2 | 34,671.2 | 1.97x |
| find double spaces | 8,946.9 | 16,359.9 | 1.83x |
| find log level | 1,566.8 | 19,934.6 | 12.72x |
| find markdown heading ws | 72,351.0 | 126,299.7 | 1.75x |
| find markdown list ws | 4,924.6 | 25,760.7 | 5.23x |
| find escaped string loop | 17,610.8 | 30,293.1 | 1.72x |
| find HTTP methods | 1,428.1 | 18,124.9 | 12.69x |
| find full email | 19,625.3 | 34,309.5 | 1.75x |
| find blank lines | 1,153.4 | 1,559.0 | 1.35x |
| find floats | 75,587.9 | 121,968.9 | 1.61x |
| find currency | 347.1 | 930.4 | 2.68x |
| find ISO timestamp | 73,595.3 | 107,938.6 | 1.47x |
| find JSON key | 15,770.9 | 22,681.6 | 1.44x |
| find HTML comment | 1,173.3 | 2,080.7 | 1.77x |
| find hashtag | 1,282.0 | 1,531.4 | 1.19x |
| find mention | 1,297.8 | 1,553.4 | 1.20x |
| find CSS unit | 49,781.0 | 165,366.7 | 3.32x |
| find function call | 114,254.0 | 160,206.5 | 1.40x |
| find SQL keyword | 1,065.7 | 23,609.5 | 22.15x |
| find JSON literal | 554.4 | 11,430.2 | 20.62x |
| find blockquote | 376.6 | 1,174.1 | 3.12x |
| find ordered list | 375.4 | 1,175.2 | 3.13x |
| find query param | 25,590.1 | 34,394.4 | 1.34x |
| find MAC address | 64,998.9 | 122,353.4 | 1.88x |
| find base64 run | 80,000.9 | 120,096.1 | 1.50x |
| find markdown link | 377.4 | 1,224.8 | 3.25x |
| find YAML key | 33,801.0 | 67,689.9 | 2.00x |
| find TOML table | 33,749.8 | 49,878.5 | 1.48x |
| find template | 69,139.1 | 115,476.4 | 1.67x |
| find Windows path | 46,479.9 | 112,836.9 | 2.43x |
| find CSS selector | 84,047.2 | 101,898.0 | 1.21x |
| find slash date | 80,056.9 | 136,495.9 | 1.70x |
| find HTTP request | 825.4 | 1,179.2 | 1.43x |
| find IPv6 | 73,283.5 | 96,023.3 | 1.31x |
| find C comment | 86,892.4 | 133,767.9 | 1.54x |
| find markdown image | 378.5 | 1,360.6 | 3.59x |
| find HTML tag name | 126,814.5 | 202,811.2 | 1.60x |
| find shell var | 120,906.5 | 203,786.4 | 1.69x |
| split whitespace (22 KiB) | 30,939.6 | 103,584.9 | 3.35x |
| split commas (29 KiB) | 24,330.8 | 134,415.3 | 5.52x |
| split lines | 1,304.3 | 4,720.3 | 3.62x |
| split semicolons | 21,504.0 | 118,342.5 | 5.50x |
| fullmatch literal | 3.6 | 19.5 | 5.42x |
| fullmatch class | 9.9 | 25.4 | 2.57x |
| fullmatch xDS-like | 19.2 | 24.6 | 1.28x |
| replaceAll a+ -> x | 28,917.9 | 121,096.0 | 4.19x |
| replaceAll \A\|\z -> X | 1,021.5 | 27,895.4 | 27.31x |
| replaceAll digits -> N | 62,553.8 | 284,495.2 | 4.55x |

regexz is faster or at parity on 97 of the 100 measured cases, with a
geometric-mean PCRE2/regexz ratio of 2.21x. The three rows below 1.00x are
within host noise:

- `find prefix alternation` (0.98x), `find (?i) Unicode literal` (0.97x) and
  `find (?i) literal` (0.97x): parity within host noise.

Compile Qwen is now 1.41x ahead of PCRE2, up from a 0.69x ratio: PCRE2 parses
the pattern and stores property references, while regexz materializes the
Unicode property sets at compile time so searches can use range lists
directly. The compile rows include PCRE2's JIT pass, while regexz has no JIT.
Compile xDS-like is 1.24x ahead; HTML tags are 2.16x ahead after the
wrapped-run probes, and end-anchored word scans are 8.13x ahead after the
line-end scan.

The largest leads are on literal-heavy scans and alternations: the nibble
filter, required-literal prefilters and counted split paths avoid PCRE2's
byte-at-a-time interpreter/JIT loop. Representative rows: `replaceAll
\A\|\z -> X` 27.31x, `find SQL keyword` 22.15x, `find JSON literal`
20.62x, `find log level` 12.72x, `find HTTP methods` 12.69x, `find
end-anchored word` 8.13x, `find optional prefix run` 7.86x, `find markdown
list` 5.89x, and `split commas` 5.52x. The absolute times are from a shared
host; the interleaved medians are more reliable than any single run.

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
