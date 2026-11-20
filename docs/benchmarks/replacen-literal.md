# Limited replacement over a literal pattern

Baseline: `264c29f`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replacen` searched for one match per occurrence and expanded the substitution
for each, even for a pure literal pattern with a literal substitution. The
unlimited `replaceAll` already fuses that case; `replacen` now shares the same
scanner with a match limit.

`Workspace.replaceLiteral` takes a limit and is used by both APIs: occurrences
are found with the literal search (`memchr`/`memmem`), each gap and the fixed
substitution are appended directly, and the tail is appended once the limit is
reached. Substitutions with `$` or `\`, case-insensitive literals and other
program shapes keep the general `replaceAllWith` path.

## Measurements

`bench` replaces `,` with `;` over the 29 KiB comma-separated text (6,000
occurrences) with a limit above the match count. Each executable reports its
own medians; five executions were interleaved before/after, after/before,
alternating. The table reports medians across those executions; raw samples
and executable SHA-256 identities are in
[`replacen-literal.json`](replacen-literal.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replacen `,` → `;` (limit 10000) | 61,710.2 | 41,983.1 | 1.47x |
| replaceAll `,` → `;` control | 39,721.5 | 43,293.5 | 0.92x |
| replaceAll `a+` control | 26,749.0 | 26,928.1 | 0.99x |
| split whitespace control | 20,979.4 | 20,274.0 | 1.03x |
| split commas control | 34,988.1 | 34,611.3 | 1.01x |

The limited replacement improves in every round. The unlimited literal
replacement already used the fused scanner in both binaries; its 0.92x sample
and the other controls' 0.99–1.03x spread are the shared host's run-to-run
noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replacement' -Dtest-filter='replacen' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/api_tests.zig tools/bench/main.zig
```

The replacen tests cover limits 0, 1, 2 and above the match count, including
the literal fast path and the general expansion path.
