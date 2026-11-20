# Decode rejected Unicode capture candidates once

Baseline: `8d6a04e`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The fixed-save Unicode capture scanner previously called `Set.matchAdvance`
at each candidate start. On a miss it decoded that same candidate again to
distinguish a valid nonmember rune from malformed input and choose the next
search position. Mixed-script gaps therefore paid for two UTF-8 decodes per
rejected rune.

`capture_run.findUnicode` now decodes each candidate once and retains its
width while testing the existing materialized set. A valid nonmember advances
by that width. An invalid lead, incomplete sequence, overlong encoding,
surrogate or out-of-range value advances one byte. ASCII candidates use their
byte value directly. The consuming run retains its existing `matchAdvance`
loop and rune-count budget checks. Capture saves, eligibility, folded and
negated set membership, literal prefixes and allocation ownership are
unchanged.

## Measurement method

The fixed baseline is a `git archive` of `8d6a04e` with the identical updated
`tools/bench/capture.zig` copied into it. Existing capture and interpreter
controls remain, and seven cases measure mixed-script misses, sparse Han
captures, a continuous Han run, an ASCII miss and matches after long rejected
prefixes. The mixed-script subjects contain two-, three- and four-byte
characters. Every pass reads every returned capture slot into its checksum,
and runtime pointer barriers retain subject loads.

Each executable reports a median of five batches of 100 passes. Three
executions alternate before/after, after/before, before/after. A separate
fresh-workspace probe records initialization and first-find allocations,
cumulative requested bytes and interpreter record capacities. Input lengths,
raw timings, counters and executable SHA-256 identities are in
[`capture-decode.json`](capture-decode.json).

## Measurements

| Case | Input bytes | Before, us/pass | After, us/pass | Speedup |
| --- | ---: | ---: | ---: | ---: |
| Han mixed-script miss | 78,000 | 262.319 | 161.265 | 1.63x |
| Greek mixed-script miss | 60,000 | 184.134 | 117.218 | 1.57x |
| Han sparse captures | 64,000 | 231.466 | 160.101 | 1.45x |
| Han after long prefix | 78,010 | 255.603 | 157.454 | 1.62x |
| Greek after long prefix | 60,004 | 182.627 | 111.978 | 1.63x |
| Han capture | 28,000 | 93.992 | 64.503 | 1.46x |
| Han long capture | 14,000 | 21.978 | 22.729 | 0.97x |
| Han ASCII miss | 32,000 | 0.322 | 0.313 | 1.03x |
| Unicode letters capture | 28,000 | 117.272 | 121.100 | 0.97x |

All allocation and capacity counters are identical before and after in all
three rounds. The new Unicode cases make no first-find allocation and retain
zero trail/choice capacity. Ordinary single captures initialize one 64-byte
capture block; the sparse empty-save case initializes one 128-byte block.

The measured gain covers rejected Unicode candidates: pure misses and long
rejected prefixes improve 1.57-1.63x, sparse Han captures improve 1.45x and the
existing mixed-script Han capture improves 1.46x. The continuous Han capture
is 3% slower, and the Unicode-letter control is also 3% slower. Other controls
range from about 7% slower to 11% faster on the shared host. These small
control changes do not establish a universal throughput gain.

## Validation

```sh
zig build test-lib -Dtest-filter='capture run' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/capture_run.zig src/regex/capture_run_tests.zig tools/bench/capture.zig
```

Native checks compare complete capture slots with a forced interpreter at
every tested byte offset. Fixtures include folded/negated sets, Unicode
digits, supplementary letters and Han, malformed encodings, truncated tails
and starts inside codepoints. Budget checks include four-byte nonmembers
before four-byte matching letters, with strict errors and linear fallback.
The rejected-prefix allocation fixture fails any allocation after the one
required capture block and verifies nested empty saves, repeated searches,
zero trail/choice capacity and no search-DFA workspace. Existing eligibility,
serialization and capture-count boundary tests remain in the scoped suite.

V8 seeds cover Unicode letter, Han, Greek, digit and nonletter capture runs
over mixed scripts and long rejected prefixes. The existing explicit
Unicode-caseless Qwen probe retains its long-s restriction.

All 11 scoped tests, 8,988 V8 comparisons, the 56-case performance gate and
formatting checks passed. Three complete alternating rounds covered 24
capture cases per executable. Initialization, first-find allocation and
interpreter-capacity counters were checked across every round and remain
identical before and after.
