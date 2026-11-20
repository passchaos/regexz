# Replacement over set runs

Baseline: `f996469`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceAll` searched for one match per run, expanded the substitution for
each match and appended through the writer. For a pure ASCII `set+` pattern
with a literal substitution (`a+` → `x`, `\s+` → `_`) both the search and the
expansion are unnecessary: the matches are exactly the maximal runs, and the
substitution is a fixed byte slice.

`Workspace.replaceAll` now detects `fast_kind == .set_run` with a substitution
that contains no `$` or `\`, reserves the output, scans the input once with the
set's byte table and appends each gap and the substitution directly.
Substitutions with syntax and every other pattern keep the general
`replaceAllWith` path, including template parsing and capture expansion.

## Measurements

`bench` replaces `a+` with `x` over a 24 KiB text (4,000 runs). Each
executable reports its own medians; five executions were interleaved
before/after, after/before, alternating. The table reports medians across those
executions; raw samples and executable SHA-256 identities are in
[`replace-set-runs.json`](replace-set-runs.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `a+` → `x` | 45,472.1 | 33,910.4 | 1.34x |
| find Qwen tokenizer control | 68,928.3 | 66,331.7 | 1.04x |
| find URL control | 43,914.6 | 40,038.1 | 1.10x |
| split whitespace control | 23,161.9 | 23,688.3 | 0.98x |
| Workspace.init Qwen control | 74.6 | 77.3 | 0.97x |

The replacement case improves in every round. The controls do not take the
fused path and stay within the shared host's run-to-run noise.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replacement' -Dtest-filter='replacen' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/replace_tests.zig
```

The new test covers empty input, no matches, whole-input runs, whitespace runs
and a `$0` substitution that must stay on the general expansion path.
