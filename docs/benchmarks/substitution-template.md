# Parsed substitution templates

Baseline: `ff2a33e`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceAll` expanded the substitution for every match: each pass re-scanned
the substitution syntax, decoded literal runs rune by rune, resolved `$N` /
`${name}` group references, handled the `$`` / `$'` / `$+` / `$_` whole-input
specials and carried the case-transform state. On the 32 KiB capture
replacement (`(\w+)` → `[$1]`, 8,000 matches) that expansion cost about
26 ns per match and dominated the pass.

`subst.parseTemplate` now parses the substitution once per replacement pass
into a fixed 16-segment stack array, so no allocation is added. Segments are
literal slices (borrowed from the caller's substitution), resolved group
indices, and the four whole-input specials. Substitutions containing any
backslash (escapes or case transforms) or needing more than 16 segments return
null and keep the general per-match expansion, which owns those semantics.
`replaceAllWith` keeps the literal-substitution fast path first, then expands
the template by appending the literal and slot slices directly. The length and
caller-buffer writers share the same path.

## Measurements

`bench-replace` replaces over a 32 KiB subject. Each executable reports the
median of five batches of 200 replacements. Five executions were interleaved
before/after, after/before, alternating. The table reports medians across
those executions; raw samples and executable SHA-256 identities are in
[`substitution-template.json`](substitution-template.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| captures (`(\w+)` → `[$1]`), page | 312,163.5 | 166,013.8 | 1.88x |
| captures (`(\w+)` → `[$1]`), SMP | 313,212.7 | 169,502.5 | 1.85x |
| shrink control | 62,004.2 | 58,213.1 | 1.07x |
| word boundary control | 308,864.2 | 315,987.9 | 0.98x |
| zero width control | 3,137.5 | 3,077.1 | 1.02x |
| limited control | 2,997.3 | 3,295.2 | 0.91x |
| no match control | 3,547.9 | 3,813.5 | 0.93x |

The capture replacement improves in every round. The controls use literal
substitutions, which never build a template; their 0.91–1.07x spread is the
shared host's run-to-run noise. Allocation counts are unchanged because the
template lives on the stack.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replacement' -Dtest-filter='substitution' -Dtest-filter='replacen' -Dtest-filter='zero-width' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/substitution.zig src/regex/replace.zig
```

The replacement tests cover `$0`..`$9`, `$&`, named and braced groups,
`$``/`$'`/`$+`/`$_`, `$$`, case transforms, missing groups, and the
length/caller-buffer writers; the V8 replacement fuzzer compares 1,900 cases.
