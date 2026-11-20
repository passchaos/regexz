# Split over set runs

Baseline: `e3818bd`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.split` and `Regex.splitn` created a `ReplaceWorkspace` and searched for
one match per part. For a pure ASCII `set+` pattern (`\s+`, `[0-9]+`, ...) the
matches are exactly the maximal runs, so the search machinery is unnecessary:
the whole input can be partitioned in one pass.

`split` and `splitn` now detect the `setRun` shape up front and scan the input
with the set's byte table, appending the gap before each maximal run. The parts
list reserves `input.len / 8` entries, bounded by 4096 and by the requested
limit, which removes most growth copies on separator-dense input while keeping
the temporary allocation bounded. Other patterns, including Unicode sets and
`set*`, keep the general `findAll` path.

## Measurements

`bench` splits a 22 KiB text with `\s+` (about 3,800 parts). Each executable
reports its own medians; five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`split-set-runs.json`](split-set-runs.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| split whitespace (22 KiB) | 51,853.5 | 23,549.6 | 2.20x |
| find Qwen tokenizer control | 67,348.3 | 66,245.8 | 1.02x |
| replaceAll `a+` control | 45,999.6 | 42,970.8 | 1.07x |
| Workspace.init Qwen control | 74.8 | 72.2 | 1.04x |

The split case improves in every round. The controls do not use the split
path and stay within the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='split' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig src/regex/api_tests.zig
```

The split tests cover leading, trailing and empty separators, `splitn` limits
including zero, and empty input; the full suite keeps the general `findAll`
split path covered.
