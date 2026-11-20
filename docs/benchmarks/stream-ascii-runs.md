# Tight ASCII run loops in the stream scanner

Baseline: `3dc996c`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`processSimple` and `processStar` handled ASCII input one byte at a time and
checked the pending-match state on every byte. Both now consume member and
non-member runs in tight loops (`skipMembers`/`skipNonMembers`) and run the
state machine only at run boundaries. The star path emits its empty matches
inside the non-member loop, so a gap still produces one match per byte.

## Measurements

The standard `zig build bench` executable was compiled for both trees and
five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| stream `[a-z]+` (216 KiB, 4 KiB chunks) | 183,754.2 | 140,295.9 | 1.31x |
| stream `[a-z]*` (216 KiB, 4 KiB chunks) | 223,912.5 | 160,073.0 | 1.40x |
| stream `[a-z]+ [a-z]+` control | 194,487.5 | 209,227.1 | 0.93x |
| split commas control | 20,139.4 | 22,493.3 | 0.90x |

Both stream cases are faster in every round. The two controls do not use the
changed loops; their spread is host noise (the split samples improve in the
later rounds). Across the other 65 cases the median speedup is 1.00x. Raw
samples and executable SHA-256 identities are in
[`stream-ascii-runs.json`](stream-ascii-runs.json).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='stream' --summary all
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/stream.zig
```
