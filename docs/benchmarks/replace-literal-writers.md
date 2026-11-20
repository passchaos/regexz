# Literal length and caller-buffer replacement writers

Baseline: `621c5dc`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceAllLen` and `replaceAllInto` ran the general replacement pass with a
counting or caller-buffer writer, searching per match and expanding the
substitution. For a pure literal pattern with a literal substitution both
operations are simple: count the occurrences, or copy the gaps and the fixed
substitution into the caller's buffer.

`replaceAllLen` now counts occurrences with the literal search and computes
`input.len - matches * literal.len + matches * substitution.len` (checked for
overflow). `replaceAllInto` fills the caller buffer with the same scan and
returns `error.RegexLimitExceeded` as soon as the buffer is too small, keeping
the documented fail-closed behavior. Substitutions with `$` or `\` and other
program shapes keep the general writer path.

## Measurements

`bench` runs both writers over the 29 KiB comma-separated text (6,000
occurrences). Each executable reports its own medians; five executions were
interleaved before/after, after/before, alternating. The table reports medians
across those executions; raw samples and executable SHA-256 identities are in
[`replace-literal-writers.json`](replace-literal-writers.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAllLen `,` (29 KiB) | 44,468.8 | 21,630.0 | 2.06x |
| replaceAllInto `,` (29 KiB) | 53,846.3 | 34,949.0 | 1.54x |
| replaceAll `,` → `;` control | 42,764.4 | 44,548.1 | 0.96x |
| replacen `,` → `;` control | 40,242.7 | 45,202.5 | 0.89x |
| split whitespace control | 20,002.5 | 20,272.7 | 0.99x |
| split commas control | 33,513.5 | 33,316.5 | 1.01x |

Both writers improve in every round. The controls do not take the new paths;
their 0.89–1.01x spread is the shared host's run-to-run noise (the replacen
path is unchanged by this commit).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='literal length' -Dtest-filter='replacement' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/replace_tests.zig tools/bench/main.zig
```

The writer test checks the exact length, an exact-size caller buffer, a short
buffer that must fail closed, and a no-match input.
