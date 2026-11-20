# Arena compilation for long patterns

Baseline: `648f767`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.init` compiled every pattern inside a fixed 16 KiB block first, falling
back to an arena only when the block was exhausted. The block avoids the
arena's multiple page allocations for small patterns, but long patterns grow
several parse and compile lists whose reallocations inside the fixed block
copy the whole list. A scoped comparison showed the arena winning for long
inputs: the Qwen tokenizer pattern compiled in 53.6–58.6 us with the block and
50.1–50.8 us in the arena, and a 100-byte literal took 20.4–20.9 us versus
16.0–16.4 us. Short patterns kept the block's advantage (40-byte xDS:
3.8–4.4 us versus 5.7–5.9 us; 55-byte email class: 3.1–3.5 us versus
3.2–3.8 us).

`Regex.init` now compiles patterns longer than 64 bytes in an arena directly
and keeps the fixed block for shorter patterns. The cutoff is a heuristic: it
sits above the short class patterns that benefit from the block and below the
tokenizer-sized patterns that benefit from arena growth.

## Measurements

`bench` compiles the 150-byte Qwen tokenizer pattern and the 40-byte xDS
pattern. Each executable reports its own medians; five executions were
interleaved before/after, after/before, alternating. The table reports medians
across those executions; raw samples and executable SHA-256 identities are in
[`compile-arena-long-patterns.json`](compile-arena-long-patterns.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer, page | 58,224.0 | 55,795.3 | 1.04x |
| compile Qwen tokenizer, SMP | 53,033.0 | 50,427.7 | 1.05x |
| compile xDS-like, page control | 4,377.5 | 4,574.1 | 0.96x |
| compile xDS-like, SMP control | 2,331.8 | 2,337.3 | 1.00x |
| find Qwen tokenizer control | 47,130.0 | 48,536.7 | 0.97x |
| findAll Qwen, owning control | 49,619.2 | 48,494.2 | 1.02x |

The Qwen compile cases improve in every round. The xDS pattern stays below
the cutoff and keeps the block; its 0.96x page sample and the search controls'
0.95–1.02x spread are the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='compile' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig
```

The full suite covers both compilation paths, including the block-to-arena
fallback when a short pattern exceeds the fixed block.
