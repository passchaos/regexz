# Compile block tiers

Baseline: `2e290fb`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.init` previously chose between one 16 KiB block and the arena. A scoped
parse+compile comparison showed the required storage varies widely: the Qwen
tokenizer pattern needs more than 128 KiB but fits in 256 KiB (43.5 us versus
58.7 us in the arena), a 100-byte literal needs more than 16 KiB but fits in
64 KiB (8.9 us versus 18.4 us in the arena), and the 40-byte xDS pattern fits
the 16 KiB block.

`Regex.init` now selects a block tier:

- 16 KiB for patterns up to 64 bytes;
- 64 KiB for longer patterns without Unicode property references;
- 256 KiB for patterns containing `\p` or `\P`;
- the arena for patterns longer than 1024 bytes.

If the chosen block runs out during parse or compile, the work falls back to
the arena as before. The page-allocator block pool serves all three sizes
under a 512 KiB total cap; the SMP and other allocators keep direct
allocate/free (their allocators already cache small blocks, and leak tracking
must still see the caller's allocator).

## Measurements

`bench` compiles the Qwen tokenizer pattern, a 100-byte literal and the
40-byte xDS pattern. Each executable reports its own medians; five executions
were interleaved before/after, after/before, alternating. The table reports
medians across those executions; raw samples and executable SHA-256 identities
are in [`compile-block-tiers.json`](compile-block-tiers.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer, page | 55,083.6 | 40,525.4 | 1.36x |
| compile long literal | 18,270.4 | 10,861.6 | 1.68x |
| compile Qwen tokenizer, SMP control | 51,527.6 | 52,192.2 | 0.99x |
| compile xDS-like, page control | 3,488.5 | 2,689.8 | 1.30x |
| compile xDS-like, SMP control | 3,404.2 | 2,638.8 | 1.29x |
| find Qwen tokenizer control | 49,158.3 | 47,750.8 | 1.03x |
| findAll Qwen, owning control | 50,315.8 | 45,238.3 | 1.11x |
| Workspace.init Qwen control | 67.5 | 65.8 | 1.03x |

The page Qwen and long-literal compiles improve in every round. The SMP Qwen
path allocates the 256 KiB block directly each time; its arena was already
fast, so the sample is neutral. The xDS path is unchanged (16 KiB block in
both binaries); its 1.29–1.30x samples reflect the host running the before
side above its usual 2.4–2.7 us range, so they are noise rather than an
effect of this change.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='compile' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig tools/bench/main.zig
```

The suite covers both block paths, the arena fallback when a short pattern
exceeds its block, and the testing allocator's direct allocate/free behavior
(the pool only serves the page allocator).
