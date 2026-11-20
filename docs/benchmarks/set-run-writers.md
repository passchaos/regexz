# Set-run limited replacement and writers

Baseline: `4161f5b`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The unlimited `replaceAll` already fused an ASCII `set+` pattern with a
literal substitution into one table scan. `replacen`, `replaceAllLen` and
`replaceAllInto` still ran the general pass, searching per match and expanding
the substitution through a counting or caller-buffer writer.

`replaceSetRun` now takes a match limit and is shared by `replaceAll` and
`replacen`. `replaceSetRunLen` counts runs and run bytes in one scan and
computes `input.len - run_bytes + runs * substitution.len` (checked for
overflow). `replaceSetRunInto` fills the caller buffer directly with the same
scan and returns `error.RegexLimitExceeded` as soon as the buffer is too small.
Substitutions with `$` or `\` and other program shapes keep the general path.

## Measurements

`bench` runs the writers over the 24 KiB `a+` text (4,000 runs). Each
executable reports its own medians; five executions were interleaved
before/after, after/before, alternating. The table reports medians across those
executions; raw samples and executable SHA-256 identities are in
[`set-run-writers.json`](set-run-writers.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replacen `a+` → `x` (limit 10000) | 37,468.8 | 24,493.3 | 1.53x |
| replaceAllLen `a+` (24 KiB) | 26,634.4 | 10,607.5 | 2.51x |
| replaceAllInto `a+` (24 KiB) | 33,179.8 | 19,145.0 | 1.73x |
| replaceAll `a+` → `x` control | 24,879.0 | 25,384.0 | 0.98x |
| replacen `,` → `;` control | 39,253.5 | 38,217.7 | 1.03x |
| replaceAllLen `,` control | 20,222.7 | 21,131.9 | 0.96x |
| replaceAllInto `,` control | 31,984.8 | 32,589.2 | 0.98x |
| split whitespace control | 18,669.4 | 19,019.0 | 0.98x |

The three set-run writers improve in every round. The literal writers and the
other controls do not take the changed paths; their 0.96–1.03x spread is the
shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='set-run' -Dtest-filter='replacement' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/replace_tests.zig tools/bench/main.zig
```

The set-run test checks limits 0, 1 and 2, the exact length, an exact-size
caller buffer, a short buffer that must fail closed, and a no-match input.
