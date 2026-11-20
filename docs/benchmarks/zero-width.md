# Zero-width edge-assertion scan

Baseline: `bed42eb`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Patterns made only of edge assertions (`^|$`, `(?m)^`, `$`, `\A\z`, ...)
compile to assertion-only programs. The priority search DFA is ineligible
because of the assertions, so the interpreter restarted at every offset: on a
32 KiB single-line subject it probed all 32,768 positions to find the two
matches, costing about 0.5–0.7 ms per replacement pass. The same-host Rust
`regex` reference finishes the same replacement in about 13 us.

`zero_width.analyze` now runs at compile time and walks the parsed pattern,
collecting alternation paths of the allowed edge assertions (`start_text`,
`start_line`, `end_text`, `end_text_or_newline`, `end_line`) together with the
capture slots saved along each path. Any other node (consuming atoms, repeats,
lookaround, word or grapheme boundaries) rejects the plan, and so does the
`(*ANY)` newline convention because its multi-byte Unicode breaks need
rune-level scanning. The plan lives in the program, is not serialized, and
deserialized programs simply skip the optimization.

At search time the allowed assertions can only hold at the search offset, the
text edges, or next to a line break. The scan enumerates those positions in
order — the search offset, each break start and the position after the break,
then the text end — using the SIMD byte search for the newline bytes of the
program's convention. Each candidate is checked against every path's
conjunction with the engine's own `position`/`allows` helpers, so the
semantics stay identical; the first matching path fills its capture slots and
the whole-match slots with the offset. Empty-match restrictions
(`(*NOTEMPTY)`, `(*NOTEMPTY_ATSTART)`) and `Limits.longest` keep the general
engine.

## Measurements

`bench-replace` replaces over a 32 KiB subject (`^|$` → `!`). Each executable
reports the median of five batches of 200 replacements. Five executions were
interleaved before/after, after/before, alternating. The table reports medians
across those executions; raw samples and executable SHA-256 identities are in
[`zero-width.json`](zero-width.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| zero width (`^|$` → `!`), page allocator | 650,196.5 | 4,678.3 | 138.98x |
| zero width (`^|$` → `!`), SMP allocator | 695,292.1 | 5,329.6 | 130.46x |
| no match control | 5,175.2 | 3,790.8 | 1.37x |
| limited control | 3,247.9 | 3,239.0 | 1.00x |
| shrink control | 55,398.5 | 60,611.5 | 0.91x |
| captures control | 311,384.8 | 355,990.2 | 0.87x |
| delete whole input | 8,546.7 | 8,965.4 | 0.95x |

The zero-width gain repeats in every round and is three orders of magnitude
larger than the host's spread. The other cases do not use the new path; their
0.87–1.37x spread is the shared host's run-to-run noise (the SMP captures
control, for example, moved 0.99x while the page allocator sample moved
0.87x).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='zero-width' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/zero_width.zig src/regex/zero_width_tests.zig src/regex/replace.zig src/regex/compile.zig
```

The new tests compare the fast path with the same program pinned to the
interpreter at every offset for thirteen assertion patterns over thirteen
subjects (empty, final newlines, LF and CRLF line breaks, Unicode), compare
`replaceAll` output for empty-match iteration, and check that the empty-match
restrictions keep the general engine.
