# Fast-branch later plans

Baseline: `bf464a0`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The tokenizer fast branch handled only the dominant `set? set+` branch; every
digit, punctuation and whitespace token fell through to the search DFA. The
branches after the dominant one are often simple enough to scan directly:
Qwen's `\p{N}` matches one digit, and ` ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*` matches
an optional space, a punctuation run and a newline tail.

`fast_branch.analyze` now collects the following branches, in order, into a
small later-plan list: a single set (`set`), a set run (`set+`), or an
optional prefix plus run plus optional tail (`set? set+ set*`). The chain stops
at the first branch that is not one of those shapes, so Qwen's whitespace
branches (including the `\s+(?!\S)` backtracking lookahead) stay on the DFA.
`findFastBranch` tries the later plans only after the dominant branch fails
and the prior first-byte guard has ruled out every earlier branch; the
workspace allocates one `LaterRun` per plan with the existing deferred UTF-8
run scans.

## Measurements

`bench` runs the Qwen tokenizer over the 22 KiB mixed text. Each executable
reports its own medians; seven executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`fast-branch-later-plans.json`](fast-branch-later-plans.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find Qwen tokenizer | 63,424.2 | 49,075.0 | 1.29x |
| findAll Qwen, borrowed | 63,381.7 | 52,676.7 | 1.20x |
| findAll Qwen, owning | 71,345.8 | 52,010.0 | 1.37x |
| find capture email control | 15,572.5 | 15,737.9 | 0.99x |
| find CJK control | 206,464.2 | 221,553.3 | 0.93x |
| find Han class control | 153,405.0 | 156,960.8 | 0.98x |
| fullmatch Han class control | 72,127.5 | 78,334.2 | 0.92x |
| compile Qwen, page control | 74,967.3 | 78,473.7 | 0.96x |
| compile Qwen, SMP control | 62,820.8 | 67,889.7 | 0.93x |
| split whitespace control | 22,585.2 | 22,191.9 | 1.02x |
| split commas control | 36,954.2 | 35,480.4 | 1.04x |
| stream `[a-z]+` control | 203,437.5 | 213,927.1 | 0.95x |
| stream `[a-z]*` control | 252,910.4 | 263,068.8 | 0.96x |
| stream `[a-z]+ [a-z]+` control | 226,633.4 | 229,975.0 | 0.99x |
| stream Han chain control | 217,891.7 | 229,404.2 | 0.95x |

The tokenizer cases improve in every round. The controls do not use the
later-plan scan (the CJK, fullmatch and streaming paths never enter
`findFastBranch`); their 0.92–1.04x spread is the shared host's run-to-run
noise, which has shown the same range on unchanged binaries. The compile
controls include the one-time plan analysis and its small later-plan
allocation.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='fast branch scans' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/fast_branch.zig src/regex/replace.zig src/regex/tests.zig
```

The differential test compares the fast path against the DFA (fast branch
disabled) at every byte offset for digits, punctuation runs, optional-space
prefixes, newline tails, mixed Unicode and whitespace inputs.
