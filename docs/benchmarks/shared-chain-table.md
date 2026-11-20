# Shared UTF-8 table for stream chain runs

Baseline: `b852d9a`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The streaming scanner builds a UTF-8 transition table lazily for each
non-ASCII chain run. A chain such as `\p{Han}+，\p{Han}+` uses the same set
for both runs, so it built two identical tables per scanner. The Han table
has 260 rows (about 133 KiB) and costs about 15.5 us to build, and scanners
are created per stream.

`Scanner.init` now compares the two chain sets once with `shapes.sameSet`.
When they match, the second run reuses the first run's table, skipping the
second build, allocation and free.

## Measurements

A focused 191 KiB stream pass (`\p{Han}+，\p{Han}+`, 4 KiB chunks, 20,000
passes per execution) was alternated before/after three times:

| Run | Before, ns/pass | After, ns/pass |
| --- | ---: | ---: |
| 1 | 184,396.3 | 162,473.0 |
| 2 | 183,258.9 | 161,498.2 |
| 3 | 183,639.1 | 161,904.1 |

The after side is faster in every paired run (1.13x median). The full 67-case
interleave is in [`shared-chain-table.json`](shared-chain-table.json): the
stream Han chain improves 185,827.1 -> 170,854.2 ns (1.09x), while the other
66 cases keep a 1.02x median with none below 0.90x.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='stream' --summary all
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/stream.zig
```
