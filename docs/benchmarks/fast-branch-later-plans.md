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
and the prior first-byte guard has ruled out every earlier branch; a
256-byte first-byte bitmap skips the plans for bytes they cannot start, so
non-ASCII punctuation and whitespace tokens go straight to the DFA.

## Measurements

`bench` runs the Qwen tokenizer over the 22 KiB mixed text. Each executable
reports its own medians; five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`fast-branch-later-plans.json`](fast-branch-later-plans.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find Qwen tokenizer | 64,046.7 | 49,056.7 | 1.31x |
| findAll Qwen, borrowed | 64,066.7 | 54,765.0 | 1.17x |
| findAll Qwen, owning | 65,755.0 | 55,284.2 | 1.19x |
| find capture email control | 15,685.0 | 15,896.3 | 0.99x |
| find CJK control | 213,029.2 | 220,455.8 | 0.97x |
| find CJK no-lookahead control | 203,211.7 | 218,334.2 | 0.93x |
| find Han class control | 152,824.2 | 149,885.8 | 1.02x |
| fullmatch Han class control | 69,690.8 | 73,285.0 | 0.95x |
| compile Qwen, page control | 74,305.7 | 73,873.4 | 1.01x |
| compile Qwen, SMP control | 66,831.4 | 66,693.5 | 1.00x |
| split whitespace control | 22,536.5 | 24,614.6 | 0.92x |
| split commas control | 39,101.9 | 37,946.9 | 1.03x |
| stream `[a-z]+` control | 212,506.3 | 215,941.7 | 0.98x |
| stream `[a-z]*` control | 282,597.9 | 260,597.9 | 1.08x |
| stream `[a-z]+ [a-z]+` control | 241,366.7 | 234,516.7 | 1.03x |
| stream Han chain control | 215,577.1 | 219,277.1 | 0.98x |

The tokenizer cases improve in every round. The CJK tokenizer pays one
first-byte bitmap check on its non-letter tokens (its punctuation is
non-ASCII and its newlines are not later-plan firsts), which is the visible
0.93–0.97x. The remaining controls do not enter `findFastBranch` and span
0.92–1.08x, the shared host's run-to-run noise. The compile controls include
the one-time plan analysis and its small later-plan allocation.

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
