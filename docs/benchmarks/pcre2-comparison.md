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

Method: seven interleaved executions (regexz then PCRE2 each round), with
both processes pinned to CPU 0 with `taskset`; the table reports medians.
The suite covers 100 cases: the same cases as the Rust comparison minus the
`RegexSet` row, because PCRE2 has no combined-set API. The compile rows
measure PCRE2's compile plus JIT compilation against regexz's compile. The
compile rows were re-measured after the class-sort, workspace-pointer,
complement-fill, in-place-operand, precomputed-union, direct-negation,
direct-union-append and coalesced-skip changes, the class-construction and
wrapped-run changes listed in the [Rust comparison](rust-comparison.md), and
the `find log level` and `find (?i) literal` rows after the 32-lane caseless
scans; the materialized sets are identical, so the other search rows are
unchanged. Raw samples and executable identities for the latest full sweep
are in
[`pcre2-comparison-current.json`](pcre2-comparison-current.json); its search
rows differ from the table only by shared-host noise.

| Case | regexz, ns/iter | PCRE2, ns/iter | PCRE2 / regexz |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer | 11,342.9 | 16,133.7 | 1.42x |
| compile xDS-like | 5,769.1 | 7,168.0 | 1.24x |
| find Qwen tokenizer | 49,740.3 | 177,575.5 | 3.57x |
| findAll Qwen (borrowed) | 58,493.8 | 177,547.2 | 3.04x |
| findAll Qwen (owning) | 58,303.3 | 177,425.6 | 3.04x |
| find CJK tokenizer | 227,278.7 | 540,483.3 | 2.38x |
| find HTML tag | 90,920.5 | 190,702.5 | 2.10x |
| find URL | 71,148.4 | 101,895.0 | 1.43x |
| find JSON string literal | 13,975.4 | 26,930.7 | 1.93x |
| find JSON number | 74,288.9 | 122,707.2 | 1.65x |
| find word boundary | 188,732.6 | 378,293.8 | 2.00x |
| find (?i) literal | 64,300.0 | 63,794.0 | 0.99x |
| find alternation (5 words) | 95,071.2 | 217,215.1 | 2.28x |
| find (?i) alternation | 87,331.4 | 154,895.2 | 1.77x |
| find 10-word alternation | 210,593.9 | 289,826.0 | 1.38x |
| find Greek class | 101,317.0 | 165,249.0 | 1.63x |
| find prefix+suffix | 13,829.0 | 22,051.8 | 1.59x |
| replaceAll email captures | 33,935.4 | 41,160.9 | 1.21x |
| find IPv4 | 110,204.3 | 163,687.9 | 1.49x |
| find date | 81,108.8 | 145,224.7 | 1.79x |
| find 20-word alternation | 210,769.0 | 291,075.0 | 1.38x |
| find anchored line | 4,223.2 | 5,680.8 | 1.35x |
| find (?i) Unicode literal | 118,532.3 | 119,057.9 | 1.00x |
| find shared-prefix alternation | 45,887.5 | 78,105.8 | 1.70x |
| find one-char alternation | 12,928.7 | 34,793.0 | 2.69x |
| find hex color | 79,752.1 | 128,031.5 | 1.61x |
| find version | 100,837.7 | 141,858.5 | 1.41x |
| find nullable prefix | 19,642.4 | 38,575.2 | 1.96x |
| find identifier | 124,834.8 | 198,086.4 | 1.59x |
| find thousands | 82,028.2 | 146,426.4 | 1.79x |
| find domain | 60,311.2 | 135,538.4 | 2.25x |
| find percent | 69,596.1 | 134,054.5 | 1.93x |
| find time | 85,545.7 | 134,111.1 | 1.57x |
| find end-anchored word | 17,606.1 | 20,029.2 | 1.14x |
| find UUID | 54,149.1 | 80,119.7 | 1.48x |
| find semver | 102,769.8 | 127,662.3 | 1.24x |
| find email TLD | 16,555.6 | 28,345.7 | 1.71x |
| find CIDR | 112,835.0 | 162,563.6 | 1.44x |
| find line full | 4,116.8 | 16,416.6 | 3.99x |
| find optional prefix run | 56,638.0 | 486,941.1 | 8.60x |
| find repeated literal group | 118,510.6 | 194,690.2 | 1.64x |
| find camelCase | 111,118.6 | 213,825.4 | 1.92x |
| find key-value | 162,075.3 | 244,105.6 | 1.51x |
| find IP port | 133,025.1 | 167,027.0 | 1.26x |
| find (?i) class | 49,353.1 | 81,749.9 | 1.66x |
| find prefix alternation | 206,668.1 | 223,921.7 | 1.08x |
| find signed number | 91,890.3 | 146,588.1 | 1.60x |
| find html attribute | 87,362.2 | 112,752.4 | 1.29x |
| find markdown heading | 72,026.4 | 112,803.8 | 1.57x |
| find mixed alternation | 380,000.0 | 520,858.3 | 1.37x |
| find capitalized words | 4,935.8 | 23,594.9 | 4.78x |
| find markdown list | 4,922.7 | 29,112.5 | 5.91x |
| find JSON escaped string | 17,605.3 | 34,025.0 | 1.93x |
| find double spaces | 10,206.9 | 16,012.6 | 1.57x |
| find log level | 1,574.8 | 20,000.8 | 12.70x |
| find markdown heading ws | 72,105.9 | 121,794.1 | 1.69x |
| find markdown list ws | 4,927.8 | 25,763.4 | 5.23x |
| find escaped string loop | 17,637.5 | 30,834.9 | 1.75x |
| find HTTP methods | 1,462.9 | 18,042.9 | 12.33x |
| find full email | 19,458.3 | 33,961.3 | 1.75x |
| find blank lines | 1,148.8 | 1,555.2 | 1.35x |
| find floats | 75,096.3 | 139,369.1 | 1.86x |
| find currency | 321.9 | 928.3 | 2.88x |
| find ISO timestamp | 68,710.1 | 108,909.2 | 1.59x |
| find JSON key | 16,317.7 | 22,545.8 | 1.38x |
| find HTML comment | 1,172.6 | 2,081.3 | 1.77x |
| find hashtag | 1,425.9 | 1,529.7 | 1.07x |
| find mention | 1,420.5 | 1,532.2 | 1.08x |
| find CSS unit | 50,155.4 | 164,589.8 | 3.28x |
| find function call | 116,370.9 | 158,003.5 | 1.36x |
| find SQL keyword | 1,072.0 | 23,330.7 | 21.76x |
| find JSON literal | 542.2 | 11,404.9 | 21.03x |
| find blockquote | 370.0 | 1,175.7 | 3.18x |
| find ordered list | 370.8 | 1,175.8 | 3.17x |
| find query param | 25,457.0 | 33,827.9 | 1.33x |
| find MAC address | 64,317.3 | 121,926.5 | 1.90x |
| find base64 run | 78,651.1 | 119,647.9 | 1.52x |
| find markdown link | 361.4 | 1,175.3 | 3.25x |
| find YAML key | 33,449.6 | 66,457.8 | 1.99x |
| find TOML table | 32,113.0 | 49,837.8 | 1.55x |
| find template | 69,259.8 | 114,534.9 | 1.65x |
| find Windows path | 46,065.4 | 112,768.1 | 2.45x |
| find CSS selector | 80,985.7 | 103,253.9 | 1.27x |
| find slash date | 79,495.9 | 137,677.4 | 1.73x |
| find HTTP request | 807.8 | 1,146.8 | 1.42x |
| find IPv6 | 82,914.7 | 95,547.0 | 1.15x |
| find C comment | 86,418.2 | 131,103.6 | 1.52x |
| find markdown image | 369.5 | 1,324.9 | 3.59x |
| find HTML tag name | 124,905.5 | 200,851.2 | 1.61x |
| find shell var | 122,632.5 | 201,145.6 | 1.64x |
| split whitespace (22 KiB) | 31,459.2 | 106,576.3 | 3.39x |
| split commas (29 KiB) | 24,831.8 | 139,232.7 | 5.61x |
| split lines | 1,289.6 | 4,753.1 | 3.69x |
| split semicolons | 21,640.8 | 119,786.3 | 5.54x |
| fullmatch literal | 3.5 | 23.6 | 6.74x |
| fullmatch class | 9.8 | 27.5 | 2.81x |
| fullmatch xDS-like | 18.8 | 26.8 | 1.43x |
| replaceAll a+ -> x | 32,089.2 | 128,872.0 | 4.02x |
| replaceAll \A\|\z -> X | 1,007.0 | 27,559.6 | 27.37x |
| replaceAll digits -> N | 54,994.1 | 307,631.7 | 5.59x |

regexz is faster or at parity on 99 of the 100 measured cases, with a
geometric-mean PCRE2/regexz ratio of 2.17x. The remaining row below 1.00x is
within host noise:

- `find (?i) literal` (0.99x): parity within host noise after the 32-lane
  case-folded scan.

Compile Qwen is now 1.42x ahead of PCRE2, up from a 0.69x ratio: PCRE2 parses
the pattern and stores property references, while regexz materializes the
Unicode property sets at compile time so searches can use range lists
directly. The compile rows include PCRE2's JIT pass, while regexz has no JIT.
Compile xDS-like is 1.24x ahead; HTML tags are 2.10x ahead after the
wrapped-run probes, and the case-insensitive Unicode literal is at parity
(1.00x).

The largest leads are on literal-heavy scans and alternations: the nibble
filter, required-literal prefilters and counted split paths avoid PCRE2's
byte-at-a-time interpreter/JIT loop. Representative rows: `replaceAll
\A\|\z -> X` 27.37x, `find SQL keyword` 21.76x, `find JSON literal`
21.03x, `find HTTP methods` 12.33x, `find optional prefix run` 8.60x,
`find log level` 12.70x, and `split commas` 5.61x. The absolute times are
from a shared host; the interleaved medians are more reliable than any single
run.

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
