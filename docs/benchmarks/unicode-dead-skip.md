# Skipping rejected UTF-8 sequences in set-run searches

Baseline: `a123291`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`findPrepared` probes the next candidate byte with the first filter and then
walks the UTF-8 automaton. When a rune was rejected (for example a punctuation
rune between Han runs), the scan advanced one byte at a time, so the two
continuation bytes of the rejected rune were probed again.

A rejected byte now skips its whole continuation run: continuation bytes
cannot start a rune, and a following non-continuation byte is still probed
normally. This removes the repeated probes over punctuation between Han runs.

## Measurements

The `bench` executable was compiled for both trees with
`zig build-exe -O ReleaseFast --dep regexz -Mroot=tools/bench/main.zig
-Mregexz=src/root.zig`. Five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`unicode-dead-skip.json`](unicode-dead-skip.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| find Han class scan | 148,715.0 | 122,356.7 | 1.22x |
| find CJK tokenizer control | 194,965.8 | 180,610.8 | 1.08x |
| find CJK tokenizer no-lookahead control | 181,351.7 | 192,711.7 | 0.94x |
| stream Han chain control | 175,100.0 | 193,804.2 | 0.90x |

The controls exercise the fast-branch and streaming paths, which do not call
`findPrepared`; their spread is host noise. Across the 66 control cases the
median speedup is 1.00x and the geometric mean 0.997x.

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/run.py --cases 200 --seed 911
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/utf8_run_search.zig
```

The engine fuzzer covers Han text mixed with punctuation and Latin letters;
the full suite covers the prepared and unprepared set-run paths.
