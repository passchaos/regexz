# Replacement over a literal pattern

Baseline: `e905c45`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceAll` searched for one match per occurrence and expanded the
substitution for each. For a pure literal pattern (`,` → `;`) the matches are
exactly the literal occurrences and a literal substitution needs no
expansion, so the search machinery and per-match dispatch are unnecessary.

`Workspace.replaceAll` now detects `Program.literal` with a non-empty literal
and a substitution containing no `$` or `\`, scans occurrences with the
literal search (`memchr`/`memmem`), and appends each gap and the fixed
substitution directly. Case-insensitive literals, substitutions with syntax
and every other program shape keep the general `replaceAllWith` path.

## Measurements

`bench` replaces `,` with `;` over the 29 KiB comma-separated text (6,000
occurrences). Each executable reports its own medians; five executions were
interleaved before/after, after/before, alternating. The table reports medians
across those executions; raw samples and executable SHA-256 identities are in
[`replace-literal.json`](replace-literal.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `,` → `;` | 70,137.3 | 49,656.9 | 1.41x |
| replaceAll `a+` control | 31,738.8 | 31,549.2 | 1.01x |
| split whitespace control | 25,234.2 | 23,139.2 | 1.09x |
| split commas control | 44,035.8 | 39,865.6 | 1.10x |

The literal replacement improves in every round. The set-run replacement and
the split controls do not take the new path; their 1.01–1.10x spread is the
shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replacement' -Dtest-filter='literal replacement' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/replace_tests.zig tools/bench/main.zig
```

The new test covers single-byte and multi-byte literals, empty input, no
matches and a `$0` substitution that must stay on the general expansion path.
