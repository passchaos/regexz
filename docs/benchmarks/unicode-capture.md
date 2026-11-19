# Direct Unicode capture-run search

Baseline: `605d52b`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The fixed-save capture plan now recognizes Unicode sets and rune literals.
ASCII plans keep their byte-table path. Unicode plans scan with the already
materialized set, count complete codepoints and fill fixed start/end saves
without allocating a DFA, trail or additional UTF-8 transition table.
Existing literal prefixes are retained for singleton-rune search.

UTF-8 decoding and search advancement preserve the general engine's behavior,
including invalid bytes and starts inside a codepoint. Strict budgets count
consumed runes, not bytes. Positive, negated and case-folded sets share the
same fixed-save eligibility; alternatives, lazy/nullable loops and captures
inside a repeated body continue using their existing engines.

## Measurements

Subjects contain 32,000 bytes for ASCII and 28,000 bytes for mixed Chinese,
Greek and ASCII. Every pass reads all capture slots into a checksum. Each
executable reports medians of five batches of 100 passes; the table takes
medians of three interleaved before/after, after/before, before/after runs.
Raw samples are in [`unicode-capture.json`](unicode-capture.json).

| Case | Before, us/pass | After, us/pass | Speedup | First-find allocations |
| --- | ---: | ---: | ---: | ---: |
| Unicode letters capture | 170.748 | 126.046 | 1.35x | 1 -> 0 |
| Unicode nested capture | 181.690 | 123.507 | 1.47x | 1 -> 0 |
| Han capture | 166.088 | 90.894 | 1.83x | 1 -> 0 |
| Unicode literal capture | 34.758 | 22.663 | 1.53x | 33 -> 0 |
| word capture | 62.876 | 63.456 | 0.99x | 0 -> 0 |
| literal capture | 34.878 | 35.542 | 0.98x | 0 -> 0 |
| adjacent run control | 64.380 | 64.309 | 1.00x | 0 -> 0 |
| capture-free control | 27.317 | 27.389 | 1.00x | 0 -> 0 |
| no-match control | 0.613 | 0.618 | 0.99x | 0 -> 0 |

The gain covers repeated capture searches and avoids a cold transition-table
construction cost. Tiny timing changes in controls remain host-sensitive.

## Validation

```sh
zig build test-lib -Dtest-filter=Unicode -Dtest-filter='capture run' -Dtest-filter='regex replacement' --summary all
zig build test-lib -Dtest-filter='capture run' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-capture -Doptimize=ReleaseFast
```

All 39 Unicode/capture/replacement tests, ten final capture-run tests, 6,900 V8
comparisons and the 56-case performance gate passed. Tests compare all byte
start offsets with the original capture path, including malformed/truncated
UTF-8, Latin/Greek/Han/negated sets, Kelvin-sign folding, nested/empty captures,
and strict rune-count budgets. Existing allocation and serialization boundaries
remain covered.
