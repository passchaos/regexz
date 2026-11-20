# Split over a literal separator

Baseline: `d988085`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.split` and `Regex.splitn` created a `ReplaceWorkspace` and searched for
one match per part. For a pure literal pattern (`,`, `::`, a fixed delimiter)
the matches are exactly the literal occurrences, so the workspace and search
machinery are unnecessary.

`split` and `splitn` now detect `Program.literal` up front and scan with
`std.mem.indexOfScalarPos` for one-byte separators or `std.mem.indexOfPos` for
longer ones, appending the gaps between occurrences. The parts list uses the
same bounded reservation as the set-run split. Case-insensitive literals,
empty patterns and every other program shape keep the general `findAll` path.

## Measurements

`bench` splits a 29 KiB comma-separated text (6,000 separators). Each
executable reports its own medians; five executions were interleaved
before/after, after/before, alternating. The table reports medians across those
executions; raw samples and executable SHA-256 identities are in
[`split-literal.json`](split-literal.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| split commas (29 KiB) | 86,545.8 | 32,582.9 | 2.66x |
| split whitespace control | 20,116.9 | 18,635.6 | 1.08x |
| find Qwen tokenizer control | 54,025.8 | 56,526.7 | 0.96x |
| findAll Qwen (fresh) control | 250,663.3 | 247,527.5 | 1.01x |

The literal split improves in every round. The whitespace split uses the
set-run path, and the search controls do not split; their 0.96–1.08x spread is
the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='split' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig src/regex/api_tests.zig tools/bench/main.zig
```

The split tests cover single-byte and multi-byte literals, adjacent and empty
parts, `splitn` limits including zero, and empty input.
