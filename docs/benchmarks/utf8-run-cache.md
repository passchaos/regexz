# Bounded cache for prepared UTF-8 run tables

Baseline: `de7d2f8`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Utf8Run.init` rebuilds the UTF-8 transition table for every workspace or
scanner that needs a set. A broad class table costs tens of microseconds to
build, and streaming scanners are created per stream; the Han table has 260
rows (about 133 KiB) and costs about 15.5 us.

Prepared tables are immutable and depend only on the set. Process-lifetime
allocators (page and smp) now share tables through a bounded process cache:
8 slots, 4 MB total, entries up to 256 KiB, exact range verification behind a
spinlock. Tracking allocators bypass the cache, so leak checks still see
every allocation, and a full cache simply leaves the table owned by its
caller.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| stream Han chain (191 KiB, 4 KiB chunks) | 163,458.4 | 151,079.2 | 1.08x |
| find CJK tokenizer control | 181,753.3 | 179,890.0 | 1.01x |
| compile Qwen tokenizer (page) control | 43,563.0 | 42,382.9 | 1.03x |

Across the 66 control cases the median is 1.01x; the sub-0.90 rows are
sub-30 ns cases. Raw samples and executable SHA-256 identities are in
[`utf8-run-cache.json`](utf8-run-cache.json).

Caching the multi-megabyte Qwen workspace tables as well was screened and
rejected: it slowed the CJK tokenizer by about 10% (shared-table placement),
so entries above 256 KiB are left to their workspaces.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='utf8' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 953
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/utf8_run.zig
```
