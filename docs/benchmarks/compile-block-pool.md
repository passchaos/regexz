# Reusing the compile block

Baseline: `6547622`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.init` compiles short patterns inside a fixed 16 KiB block. With the
page allocator each block is a separate `mmap`/`munmap`, so compiling many
small patterns pays two syscalls per compile even though the block contents
are disposable after `deinit`.

`Regex.init` now takes the block from a process-wide pool when the caller uses
the page allocator; `Regex.deinit` returns it. The pool holds up to eight
16 KiB blocks, is mutex-protected, and only serves the page allocator (the SMP
allocator already caches small allocations, so its path is unchanged). A
taken block is private to the regex until `deinit`; the fixed-buffer allocator
overwrites it on the next compile. Other allocators keep the direct
allocate/free path, preserving caller leak tracking.

## Measurements

`bench` compiles the 40-byte xDS pattern and the 150-byte Qwen tokenizer
pattern. Each executable reports its own medians; five executions were
interleaved before/after, after/before, alternating. The table reports medians
across those executions; raw samples and executable SHA-256 identities are in
[`compile-block-pool.json`](compile-block-pool.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| compile xDS-like, page | 5,150.4 | 2,493.9 | 2.07x |
| compile xDS-like, SMP control | 2,320.9 | 2,426.6 | 0.96x |
| compile Qwen tokenizer, page control | 58,683.7 | 55,753.7 | 1.05x |
| compile Qwen tokenizer, SMP control | 51,113.9 | 52,935.4 | 0.97x |
| find Qwen tokenizer control | 44,769.2 | 45,671.7 | 0.98x |
| findAll Qwen, owning control | 50,030.8 | 50,715.8 | 0.99x |
| Workspace.init Qwen control | 64.9 | 65.8 | 0.99x |

The page xDS compile improves in every round by avoiding the per-compile
mmap/munmap. The SMP compile keeps its direct path; its 0.96x sample and the
Qwen/search controls' 0.97–1.05x spread are the shared host's run-to-run
noise. The Qwen pattern is above the arena cutoff from the previous change,
so its compile path does not use the block.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='compile' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig
```

The suite covers both compile paths and the testing allocator's direct
allocate/free behavior (the pool only serves the page allocator).
