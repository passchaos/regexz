# Per-pattern scans for separator sets

Baseline: `8f8b28a`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`RegexSet` always built a combined DFA and scanned the input once for all
patterns. That wins when the patterns have broad first sets, but it is the
wrong tool for `set+ literal` families such as `[a-z]+@`, `[a-z]+#`, ...:
each pattern's own chain scan jumps between separator occurrences with a
vector search, while the combined DFA walks every input byte and pays a
dependent table load per byte.

`RegexSet.init` now checks whether every pattern's search is decided by a
separator/delimiter scan (`Workspace.usesSeparatorScan`). Such a set does not
build the combined DFA at all, and `matchesAt` searches each pattern with its
own workspace. Other sets keep the combined DFA and its fallback behavior.

## Measurements

`bench` runs the 9-pattern `[a-z]+<punctuation>` set over a 22 KiB text. Each
executable reports its own medians; five executions were interleaved
before/after, after/before, alternating. The table reports medians across those
executions; raw samples and executable SHA-256 identities are in
[`set-individual-scans.json`](set-individual-scans.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| RegexSet 9 no-match patterns | 57,040.0 | 12,736.0 | 4.48x |
| find Qwen tokenizer control | 73,878.3 | 66,648.3 | 1.11x |
| split whitespace control | 25,310.8 | 24,990.0 | 1.01x |
| stream `[a-z]+` control | 243,716.7 | 236,768.8 | 1.03x |
| stream Han chain control | 236,402.1 | 229,262.5 | 1.03x |

The set case improves in every round. The controls do not build or use a
`RegexSet`; their 1.01–1.11x spread is the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='set' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/set.zig src/regex/replace.zig
```

The set tests cover overlapping patterns, absent and present matches, the
combined-DFA path, per-pattern fallback and `matchesAt` offsets.
