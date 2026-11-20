# Single-allocation stream scanner storage

Baseline: `7305c07`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`StreamScanner.init` allocated seven arrays: the raw and terminal thread
lists, their slot storage, the scratch and best-slot buffers and the seen
epoch table. With the page allocator each array is a separate mmap/munmap
pair, and a scanner is created per stream, so the setup cost is paid on every
pass.

`init` now carves all seven views from one `[]u64` allocation and `deinit`
frees that block. The views stay 8-byte aligned and keep their existing
types.

## Measurements

Scanner creation and destruction, 100,000 iterations:

| Before | After | Speedup |
| ---: | ---: | ---: |
| 6,312–6,575 ns | 1,925–2,229 ns | 3.0–3.4x |

A focused stream pass (`[a-z]+`, 216 KiB, 4 KiB chunks, 1,000 passes per
execution) was alternated before/after three times:

| Run | Before, ns/pass | After, ns/pass |
| --- | ---: | ---: |
| 1 | 178,755.0 | 172,241.9 |
| 2 | 189,992.7 | 185,411.2 |
| 3 | 189,189.6 | 180,068.8 |

The after side is faster in every paired run (1.05x median). The full 67-case
interleave is in [`scanner-storage.json`](scanner-storage.json): the four
stream cases measure 0.99x, 0.99x, 1.08x and 1.03x because the 2–4 us saving
sits at the host's noise floor, while the 63 control cases keep a 1.02x
median.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='stream' --summary all
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/stream.zig
```
