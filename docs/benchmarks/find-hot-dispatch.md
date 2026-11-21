# Find hot-path dispatch

Baseline: `703af19`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Workspace.find` grew one switch arm per deterministic shape. LLVM's inliner
eventually stopped inlining the small hot scanners (`findSetRun`,
`findLineRun`, `findWordRun`, `findNumberRun`) into it, so each match paid a
call plus a stack temporary and a 64-byte copy of the returned `Match`. On
match-dense input that per-call cost dominates: since `e0e4b69` the `\d+`
scan had regressed from about 26 us to 45 us on 54 KiB, `[a-z]+` from 16 us to
21 us and `(?m)^.*$` from 1.8 us to 2.2 us in an isolated benchmark.

## Change

`find` is now a small entry point:

- the `set+` scanner is forced inline (`inline fn findSetRun`), so the most
  common deterministic shape runs without a call;
- a `.none` program first tries its dominant fast branch, matching the
  previous behavior for tokenizer shapes;
- everything else is delegated to `findDispatch` with
  `@call(.never_inline, ...)`, so the dispatch switch never merges back into
  the entry.

`findDispatch` no longer retries the fast branch for `.none` (the entry
already did) and its heavy literal/anchored scanners are no longer `inline`,
which keeps its prologue lean for the remaining shapes. `findOnce` keeps the
full switch for the iterator and replacement paths.

Because the entry stays small, LLVM inlines `find` into a caller's match
loop, removing the per-match call and stack copy entirely. This is the main
source of the gains below; it also makes the hot path independent of the
inlining budget of the full dispatch.

## Measurements

The comparison harness runs the same workloads as
[the Rust comparison](rust-comparison.md). Six executions were interleaved in
alternating order (three rounds `before, after` and three rounds `after,
before`); the table reports medians across those executions. Raw samples and
executable SHA-256 identities are in
[`find-hot-dispatch.json`](find-hot-dispatch.json).

| Case | Before, ns/iter | After, ns/iter | Change |
| --- | ---: | ---: | ---: |
| find optional prefix run | 109,583.2 | 42,641.3 | 2.57x faster |
| findAll Qwen (borrowed) | 46,137.5 | 36,686.7 | 1.26x faster |
| findAll Qwen (owning) | 45,595.8 | 36,331.2 | 1.25x faster |
| find Qwen tokenizer | 46,667.9 | 37,766.2 | 1.24x faster |
| find signed number | 45,075.0 | 36,832.0 | 1.22x faster |
| find line full | 2,298.9 | 1,895.0 | 1.21x faster |
| find percent | 33,114.6 | 29,977.9 | 1.10x faster |
| find one-char alternation | 13,696.4 | 12,486.0 | 1.10x faster |
| find word boundary | 82,467.2 | 75,708.9 | 1.09x faster |

An isolated benchmark that only times `find` loops shows the same mechanism
on match-dense input: `\d+` 2.3x faster, `[a-z]+` 1.47x faster, `(?m)^.*$`
1.19x faster and `\b\w+\b` 1.09x faster.

The host was shared and noisy. Cases that do not call `find` at all moved by
1.10-1.26x in the same sweep (`fullmatch xDS-like`, `fullmatch literal`,
`replaceAll \A|\z`, `split whitespace`), which bounds the noise floor.
Unbounded-chain shapes now pay the one `findDispatch` call and measured
1.06-1.10x slower than the previous commit; they remain far ahead of the
Rust reference.

## Validation

```sh
zig build test-lib
python3 tools/fuzz/run.py --cases 400 --seed 20261123
python3 tools/fuzz/replace.py --cases 200 --seed 20261123
python3 tools/bench/check.py --runs 2
```

The full test suite, both differential fuzzers and the 67-case benchmark gate
pass.
