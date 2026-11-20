# Short-span delimiter scans

Baseline: `f661ef8`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`o [^c]* c` and `o [^c]+ c` (`"[^"]*"`, `<[^>]+>`) use the delimited fast
path: find the next open byte, then the next close byte. Both searches used
`std.mem.indexOfScalarPos`, whose vector setup costs more than the scan when
the delimiter pair is a few bytes away. Tags and quoted keys are exactly that
case: the HTML benchmark averages about 10 bytes per tag.

`findDelimitedRun` now uses `indexOfDelimiter`: a scalar scan of the first 32
bytes at or after the start, falling back to the vector search only when the
delimiter is farther away. The returned offsets are identical, so the
`non_empty` retry and the reported spans are unchanged.

## Measurements

`bench` searches the 82 KiB HTML document (8,000 tags) and the 12 KiB JSON
document (400 strings). Each executable reports its own medians; five
executions were interleaved before/after, after/before, alternating. The table
reports medians across those executions; raw samples and executable SHA-256
identities are in
[`delimited-short-spans.json`](delimited-short-spans.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find JSON string literal | 19,733.3 | 7,908.3 | 2.50x |
| find HTML tag | 132,206.0 | 51,505.6 | 2.57x |
| find URL control | 96,957.5 | 98,543.5 | 0.98x |
| find key-value key control | 36,669.4 | 37,215.2 | 0.99x |
| find JSON number control | 30,431.0 | 30,195.4 | 1.01x |
| find word boundary control | 70,791.3 | 69,111.9 | 1.02x |

Both delimited cases improve in every round. The controls use other fast
paths and stay within the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='delimited' -Dtest-filter='string literal' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig
```

The delimited tests cover the `*` and `+` forms, empty inner runs and both
quote and angle-bracket delimiters; the V8 fuzzer compares 9,252 searches.
