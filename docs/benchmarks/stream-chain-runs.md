# Streaming chain runs through the UTF-8 automaton

Baseline: `34b2df0`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The streaming scanner's deterministic chain path (`setA+ literal setB+`) walked
non-ASCII runs one rune at a time: decode and validate the UTF-8 sequence, then
binary-search the run set's ranges. On the 191 KiB Han chain
(`\p{Han}+，\p{Han}+` in 4 KiB chunks) that per-rune work dominated the pass.

The scanner now builds a `utf8_run.Utf8Run` automaton for each non-ASCII run
set on the first non-ASCII scan and consumes whole member runs with one table
load per byte. `Utf8Run.runEndStatus` reports both the run end and whether the
buffer ended inside a rune, so a chunk boundary keeps the partial rune for the
next feed instead of ending the run. The idle phase, ASCII chains, the byte
tables and the general NFA path are unchanged; ASCII-only streams never build
the automaton.

## Measurements

`bench` streams the same 191 KiB Han input through 4 KiB chunks. Each
executable reports its own medians; five executions were interleaved
before/after, after/before, alternating. The table reports medians across those
executions; raw samples and executable SHA-256 identities are in
[`stream-chain-runs.json`](stream-chain-runs.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| stream Han chain, 4 KiB chunks | 518,633.4 | 216,520.9 | 2.40x |
| stream `[a-z]+` control | 205,918.8 | 209,752.1 | 0.98x |
| stream `[a-z]*` control | 253,900.0 | 244,435.4 | 1.04x |
| stream `[a-z]+ [a-z]+` control | 369,756.3 | 357,687.5 | 1.03x |
| find CJK tokenizer control | 228,375.8 | 209,441.7 | 1.09x |
| find Han class control | 157,152.5 | 148,689.2 | 1.06x |
| find Qwen tokenizer control | 63,091.7 | 65,721.7 | 0.96x |

The Han chain improves in every round. The ASCII chains keep their byte-table
path, and the search controls do not use the scanner; their 0.96–1.09x spread
is the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='stream' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/stream.zig src/regex/utf8_run.zig
```

The stream tests feed the Han chain and the `\p{Han}+`/`\p{Han}*` shapes at
chunk sizes 1, 2, 3, 4, 5 and 8, and compare the scanner against `find` across
all supported shapes.
