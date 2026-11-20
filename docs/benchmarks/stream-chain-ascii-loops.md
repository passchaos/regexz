# Tight streaming chain phase loops

Baseline: `cb27451`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The streaming chain path (`setA+ literal setB+`) switched on the phase for
every byte, even though the phase only changes at run boundaries. On the
216 KiB `[a-z]+ [a-z]+` stream the per-byte switch and its branch were a large
share of the scan.

For ASCII chains the scanner now consumes all bytes that keep the current
phase in a tight loop before handling the boundary: idle skips non-members,
`run_a` and `run_b` consume their member runs. The phase switch and the
boundary logic run once per transition instead of once per byte. Non-ASCII
bytes still leave the tight loop immediately and take the existing generic
path, so Unicode chains and their chunk-boundary handling are unchanged.

## Measurements

`bench` streams a 216 KiB text through 4 KiB chunks. Each executable reports
its own medians; five executions were interleaved before/after, after/before,
alternating. The table reports medians across those executions; raw samples
and executable SHA-256 identities are in
[`stream-chain-ascii-loops.json`](stream-chain-ascii-loops.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| stream `[a-z]+ [a-z]+` | 373,097.9 | 236,689.6 | 1.58x |
| stream `[a-z]+` control | 223,789.6 | 222,220.9 | 1.01x |
| stream `[a-z]*` control | 270,506.3 | 284,831.3 | 0.95x |
| stream Han chain control | 225,816.7 | 231,797.9 | 0.97x |
| find Qwen tokenizer control | 63,895.8 | 65,443.3 | 0.98x |

The chain case improves in every round. The single-set streams and the Han
chain do not take the changed loop, and the search control does not use the
scanner; their 0.95–1.01x spread is the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='stream' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/stream.zig
```

The stream tests feed ASCII and Han chains, single runs and stars at chunk
sizes 1, 2, 3, 4, 5 and 8, and compare the scanner against `find`.
