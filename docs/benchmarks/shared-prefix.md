# Shared-prefix prefilter optimization

Baseline: `4ec5c3b`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

`MultiFilter` handles literals sharing a first byte. It previously compared
that same byte once per pair and, after any pair hit, verified all sixteen
positions in a block. The new scan compares the shared byte once, skips
second-byte work when it is absent, and verifies only SIMD candidate lanes.
Blocks in which every lane is a candidate retain the scalar verification
pass. Filter/workspace storage does not grow.

`FoldFilter` now takes the first candidate directly from the vector mask and
clamps its derived start to the caller's requested offset. In the old code,
`(?i)strasse` searched in `STRASSE` from offset 1 returned a match at offset 0:
the rare pair `ss` at position 4 was projected back to the literal start.
The baseline regression test reproduced this failure; the corrected search
returns no match. Unicode fold peers remain conservative candidates.

Empty first literals are rejected before indexing their first byte. Search
range checks also handle offsets beyond the input without addition overflow.

## Measurements

Each executable reports medians of five batches (2,000 microfilter searches
or 1,000 Regex searches per batch). The table takes medians of three
interleaved executions in before/after, after/before, before/after order.
Executables run sequentially. Raw samples are in
[`shared-prefix.json`](shared-prefix.json).

Absent scans use 32,768 bytes. Collision text contains 31,744 bytes of
`sell seed suit sail sooner see `; the late-hit fixture appends ` saturday`.
The dense candidate control contains 16,384 `s` bytes. Direct-filter input
is runtime allocated and filter state is passed through an optimization
barrier.

| Case | Before, us/search | After, us/search | Speedup |
| --- | ---: | ---: | ---: |
| three pairs absent | 2.4406 | 0.6164 | 3.96x |
| three pairs collisions | 94.8809 | 26.0980 | 3.64x |
| late complete literal | 94.9442 | 26.2699 | 3.61x |
| sixteen pairs absent | 10.7066 | 0.6123 | 17.49x |
| dense candidates control | 116.5251 | 117.3041 | 0.99x |
| short literal hit | 0.0120 | 0.0039 | 3.08x |
| regex prefix collisions | 103.9806 | 27.5040 | 3.78x |
| regex late literal | 104.3251 | 27.0021 | 3.86x |
| wide alternatives control | 11.4708 | 11.5966 | 0.99x |
| case-folded control | 1.9482 | 1.9558 | 1.00x |
| capture run control | 0.0078 | 0.0078 | 1.00x |

The shared-prefix Regex cases improved by about 3.8x. Dense collision, wide
alternation, folded-literal and capture-run controls stayed within 2% in this
run. Small differences remain sensitive to host load.

## Validation

```sh
zig build test-lib -Dtest-filter=MultiFilter -Dtest-filter=FoldFilter -Dtest-filter=FirstFilter -Dtest-filter='literal alternation start' -Dtest-filter='wide start alternation' -Dtest-filter='folded literal' -Dtest-filter='required literal prefilter' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
zig build bench-prefilter -Doptimize=ReleaseFast
```

All 13 scoped tests and 6,900 V8 full-match/search/capture comparisons passed.
Tests cover every search offset, block boundaries, overlapping prefixes,
dense candidates, random bytes, UTF-8 literals, empty/oversized literal sets,
and folded searches with ASCII and Unicode fold peers. The differential
fuzzer includes shared-prefix alternatives and actual matching words.
