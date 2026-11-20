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

## Word boundaries

The same plan accepts ASCII `\b` and `\B` (the UCP and UAX #29 variants use
Unicode word sets and stay on the general engine). Word paths enumerate the
positions where the byte-level word-ness changes (or stays the same), walking
by rune length so the candidate positions match the interpreter's search
starts. Paths are evaluated word-first and every scan is bounded by the best
candidate found so far, which keeps a dense boundary scan from re-walking the
input for a line-assertion alternative; ties are resolved by the plan order,
which is the alternation order. Paths made only of `start_text`, `end_text` or
`end_text_or_newline` use an O(1) candidate set (text start, final-newline
start, text end) instead of a line scan, and word-only paths skip the full
position computation.

Measured against `4f6674c` with the same method (five interleaved executions;
raw samples in [`zero-width-words.json`](zero-width-words.json)):

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| word boundary (`\b` → `|`), SMP | 544,245.0 | 313,647.5 | 1.74x |
| word boundary (`\b` → `|`), page | 545,178.3 | 331,691.0 | 1.64x |
| not word boundary (`\B` → `|`), page | 542,079.0 | 294,381.9 | 1.84x |
| not word boundary (`\B` → `|`), SMP | 539,046.3 | 327,467.5 | 1.65x |
| boundary or end (`\b|$` → `|`), SMP | 713,109.6 | 364,909.4 | 1.95x |
| boundary or end (`\b|$` → `|`), page | 662,637.1 | 365,272.3 | 1.81x |
| zero width control (`^|$`) | 4,004.8 | 3,343.5 | 1.20x |
| captures control | 324,858.3 | 331,140.6 | 0.98x |
| shrink control | 57,377.9 | 63,465.0 | 0.90x |

Same-host Rust `regex` 1.13.1 takes about 581 us for `\b`, 536 us for `\B`
and 479 us for `\b|$` on the same 32 KiB subject, so the word paths are now
ahead of the reference as well. The controls do not use the new path; their
spread is host noise.

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
interpreter at every offset for thirteen edge-assertion patterns over thirteen
subjects (empty, final newlines, LF and CRLF line breaks, Unicode) and for
eleven word-boundary patterns over fifteen subjects (word runs, separators,
Unicode neighbours, empty input), compare `replaceAll` output for empty-match
iteration, and check that the empty-match restrictions and UCP word
boundaries keep the general engine.
