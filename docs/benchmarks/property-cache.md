# Per-compile Unicode property cache

Baseline: `025cfd6`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`escape.property` allocated and copied the property's range table for every
`\p{...}` occurrence, and the class parser normalized each occurrence again.
Tokenizer patterns reference `\p{L}`, `\p{M}` and `\p{N}` more than once, so
the same hundreds of ranges were copied and merged repeatedly.

The parser now keeps an 8-entry cache of materialized property sets keyed by
the property name, negation and fold mode. `ParsedSet` carries an optional
`materialized` set: a standalone property returns it directly, and a class
element reuses it when the class needs no additional fold (the property's own
negation is already applied). Entries store slices owned by the compile
arena, so a cache hit shares the ranges instead of copying them.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| compile Qwen tokenizer (page) | 38,992.7 | 34,601.9 | 1.13x |
| compile Qwen tokenizer (smp) | 52,940.3 | 41,178.7 | 1.29x |
| compile xDS-like control | 2,736.7 | 2,689.3 | 1.02x |
| compile long literal control | 10,172.5 | 10,258.5 | 0.99x |

Across the 65 control cases the median speedup is 1.02x; the only sub-0.90
row is an unchanged replacement case. Raw samples and executable SHA-256
identities are in [`property-cache.json`](property-cache.json).

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/run.py --cases 500 --seed 77
python3 tools/fuzz/replace.py --cases 300 --seed 77
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/escape.zig src/regex/parse.zig src/regex/model.zig
```

The engine fuzzer covers properties, scripts, aliases, folds and negated
classes; the full suite covers cached and uncached property paths.
