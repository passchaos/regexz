# Exact whitespace later plan

Baseline: `16ba8e2`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The tokenizer's trailing branches `\s*[\r\n]+`, `\s+(?!\S)` and `\s+` were
not scannable, so every whitespace token fell back to the search DFA (about
29 cycles per token).

The analyzer now recognizes the trailing triple and emits one `whitespace`
later plan. `findFastBranch` scans the maximal whitespace run once and
applies the branch order exactly:

- if the run contains `\r` or `\n`, the newline branch matches through the
  last newline in the run;
- otherwise, when the run is followed by text and has at least two bytes,
  the lookahead branch backtracks one space;
- otherwise the bare `\s+` takes the whole run.

The lookahead form is only accepted when its set is exactly the complement of
the run set, so other negative lookaheads stay on the general engine.

## Measurements

Five executions of the `bench` executable were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find Qwen tokenizer | 42,663.3 | 40,802.5 | 1.05x |
| findAll Qwen, borrowed workspace | 43,351.7 | 45,627.5 | 0.95x |
| findAll Qwen, owning iterator | 43,928.3 | 44,705.0 | 0.98x |
| find CJK tokenizer | 168,083.3 | 165,480.0 | 1.02x |

`find Qwen` is faster in four of five rounds. The two `findAll` rows use the
same find path but swing 40-48 us per round in this run; their medians are
noise. Across the 63 control cases the median is 1.00x. Raw samples and
executable SHA-256 identities are in
[`whitespace-later-plan.json`](whitespace-later-plan.json).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='fast branch' --summary all
python3 tools/fuzz/run.py --cases 400 --seed 5
python3 tools/fuzz/replace.py --cases 200 --seed 5
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/fast_branch.zig src/regex/replace.zig
```

The fast-branch differential test now covers newline runs, CRLF, trailing
spaces, tabs and non-ASCII punctuation at every start offset; the engine
fuzzer covers `\s+(?!\S)` directly.
