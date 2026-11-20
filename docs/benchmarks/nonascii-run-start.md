# Direct run scan for non-ASCII fast-branch starts

Baseline: `1eb3a8c`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`findFastBranch` validated the first rune of the dominant branch with
`runeAt` and then scanned the same rune again inside `runEnd`. For non-ASCII
runes that validation walks the UTF-8 table, so the run start was walked
twice on every token.

Non-ASCII positions now call `runEnd` directly and use its "no progress"
result as the `setB+` non-empty check. ASCII keeps the cheap table gate, so a
failed optional-prefix attempt still does not enter the run scan.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after:

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find CJK tokenizer | 178,195.8 | 161,431.7 | 1.10x |
| find CJK tokenizer (no lookahead) | 174,987.5 | 169,249.2 | 1.03x |
| find Qwen tokenizer control | 43,725.8 | 42,517.5 | 1.03x |
| find Han class scan control | 113,885.0 | 120,214.2 | 0.95x |

The CJK tokenizer is faster in four of five rounds and the no-lookahead
variant in all five. The 63 control cases keep a 0.98x median with a slight
downward host drift; the sub-0.90 rows are sub-10 ns cases. Raw samples and
executable SHA-256 identities are in
[`nonascii-run-start.json`](nonascii-run-start.json).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='fast branch' --summary all
python3 tools/fuzz/run.py --cases 200 --seed 811
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig
```
