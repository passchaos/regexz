# SMP compile-block pooling

Baseline: `ec82c22`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.init` reuses 16/64/256 KiB compile blocks from a process pool only for
the page allocator; the smp allocator allocated and freed the block on every
compile. With the Unicode property cache compile itself became faster, so the
256 KiB block allocation is now a visible share: a focused harness compiling
the Qwen pattern with `std.heap.smp_allocator` measured 45.4 -> 36.5 us when
the block came from the pool.

The pool now also serves `std.heap.smp_allocator` (entries already record
their allocator and are only taken by a matching vtable), and the total cap
rises from 512 KiB to 768 KiB so the Qwen page and smp blocks fit alongside
the xDS and long-literal blocks that earlier cases leave pooled.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer (smp) | 44,102.2 | 33,538.9 | 1.31x |
| compile Qwen tokenizer (page) control | 34,283.5 | 35,051.9 | 0.98x |
| compile xDS-like (smp) control | 2,685.9 | 2,730.5 | 0.98x |
| compile long literal control | 10,436.3 | 10,491.1 | 0.99x |

Across the 66 control cases the median is 1.01x. Raw samples and executable
SHA-256 identities are in [`smp-compile-pool.json`](smp-compile-pool.json).

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/run.py --cases 100 --seed 131
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig
```

Tracking allocators (including `std.testing.allocator`) remain excluded from
the pool, so leak checks still see every block.
