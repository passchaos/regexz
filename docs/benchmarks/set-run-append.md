# Capacity-guaranteed appends in set-run replacement

Baseline: `789ad2a`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceSetRun` reserved `input.len` bytes and then used the growing
`appendSlice` for every gap and substitution. A zero- or one-byte
substitution never grows the output, because each matched run removes at
least one byte, so the reservation always suffices. Those appends now use the
assume-capacity variants, dropping the per-run capacity check and error
union.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `a+` -> `x` | 24,960.4 | 20,643.8 | 1.21x |
| replacen `a+` -> `x` (limit 10000) | 24,536.9 | 20,810.6 | 1.18x |
| replaceAllLen `a+` control | 10,346.5 | 10,140.6 | 1.02x |
| replaceAllInto `a+` control | 18,915.4 | 18,312.7 | 1.03x |

Across the 65 control cases the median speedup is 1.01x; the only sub-0.90
row is an unchanged length writer. Raw samples and executable SHA-256
identities are in [`set-run-append.json`](set-run-append.json).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replace' --summary all
python3 tools/fuzz/replace.py --cases 300 --seed 733
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig
```
