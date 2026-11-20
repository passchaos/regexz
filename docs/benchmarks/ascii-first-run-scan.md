# ASCII-first dominant run scan

Baseline: `7624f7e`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The fast branch's dominant run (`[\p{L}\p{M}]+` in the Qwen tokenizer)
prepares a UTF-8 automaton table after enough Unicode probes. Once prepared,
`runEnd` sent every byte through the state-indexed table, including ASCII
letters, where each load depends on the state produced by the previous byte.
The 256-entry ASCII table answers the same question with independent loads.

`Run.runEndAsciiFirst` scans ASCII members through the ASCII table first and
hands the scan to the prepared UTF-8 table only at the first non-ASCII byte.
The first byte is checked before touching the ASCII table, so a non-ASCII run
start costs one compare instead of a wasted table load. The method is used
only by the fast branch's dominant run; other `runEnd` callers keep the
original order.

## Measurements

A focused harness over the 22 KiB tokenizer text, seven alternating rounds:

| Row | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find Qwen tokenizer | 41,619.6 | 39,850.4 | 1.04x |
| find CJK tokenizer control | 161,049.2 | 160,372.5 | 1.00x |

The full 67-case interleave is in
[`ascii-first-run-scan.json`](ascii-first-run-scan.json):

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find Qwen tokenizer | 41,473.3 | 39,332.5 | 1.05x |
| find CJK tokenizer control | 159,908.3 | 164,704.2 | 0.97x |
| find word boundary control | 60,342.7 | 62,954.4 | 0.96x |

Across all 67 cases the median is 1.00x. The two untouched control rows move
0.96-0.97x in this binary pair, within the host's layout and ordering noise
(the focused CJK control reads 1.00x). The comparison against Rust's `regex`
moves `find Qwen tokenizer` from 1.52x to 1.67x (see the
[comparison](rust-comparison.md)).

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/run.py --cases 500 --seed 20261122
python3 tools/fuzz/replace.py --cases 400 --seed 20261121
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/deferred_utf8_run.zig src/regex/replace.zig
```

The engine fuzzer passes 500 patterns and 44,052 comparisons; five
replacement seeds pass.
