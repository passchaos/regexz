# Literal-prefix runs

Baseline: `4591c37`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`https?://[^\s]+` had no deterministic shape: the search found the fixed
`http` prefix with a vector scan, then ran the byte DFA over each candidate.
The DFA advances one byte per dependent table load, which dominates a short
URL tail.

`shapes.literalRun` recognizes a fixed ASCII prefix, at most one optional
literal, a fixed middle and a trailing `set+` run
(`prefix [optional] middle set+`). `Workspace.findLiteralRun` scans for the
prefix with `indexOfLiteral`, verifies the optional byte and middle, then
consumes the maximal run with the set's ASCII membership table; a non-ASCII
byte switches to the deferred UTF-8 run scan. The whole match is reported from
the prefix start, and failed candidates resume one byte after the prefix.

## Measurements

`bench` finds URLs in a 95 KiB text (1,500 URLs). Each executable reports its
own medians; five executions were interleaved before/after, after/before,
alternating. The table reports medians across those executions; raw samples
and executable SHA-256 identities are in
[`literal-run-url.json`](literal-run-url.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find URL | 115,499.4 | 41,725.2 | 2.77x |
| find Qwen tokenizer control | 62,445.0 | 63,911.7 | 0.98x |
| find HTML tag control | 55,843.3 | 54,894.4 | 1.02x |
| find JSON string literal control | 8,719.0 | 8,574.8 | 1.02x |
| find key-value key control | 47,337.1 | 43,846.9 | 1.08x |
| find JSON number control | 32,997.3 | 34,689.0 | 0.95x |
| compile Qwen tokenizer, page | 77,445.1 | 73,634.0 | 1.05x |

The URL case improves in every round. The controls do not match the new shape
and stay within the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='literal-run' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/shapes.zig src/regex/replace.zig src/regex/tests.zig
```

The fast-path test covers both optional forms, an invalid optional byte,
empty runs, multiple matches and the shape assertion.
