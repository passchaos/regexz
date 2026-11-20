# Captured run chains

Baseline: `d523e88`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Multi-group capture patterns whose groups are adjacent greedy runs
(`([a-z]+)([0-9]+)([A-Z]+)`, `(\p{Greek}*)(\p{Nd}*)(\p{Han}+)`) had no
deterministic path: the search DFA located the bounds over UTF-8 bytes and the
winning path was replayed to fill the slots. Those cases were among the
slowest capture searches in the suite (124–155 MiB/s).

`shapes.runChain` now recognizes a chain of captured greedy runs when:

- every capture group is exactly one unbounded run (`set*`, a lazy `set*?`,
  or a mandatory `set{n}` prefix followed by `set*`) or an empty group,
- the run sets are pairwise disjoint,
- the last mandatory run anchors the match end (runs after it are nullable),
  and a chain with no mandatory run matches at the search offset.

The scan jumps to the next anchor rune with the anchor set's UTF-8
candidate-byte filter, extends the maximal anchor run, walks backward over the
preceding runs and forward over the trailing nullable runs to place every
capture boundary. A chain with no mandatory run skips the anchor search and
extends all runs from the search offset. Runs are maximal and the sets are
disjoint, so the greedy leftmost-first boundaries are forced; no DFA state,
choice or trail is recorded, and the deterministic scan does not consume the
interpreter step budget (matching the other shape scans). Starts inside a run,
malformed UTF-8 and a failed mandatory prefix fall back to the general engine,
so the fast path never changes semantics. Overlapping sets, fixed-count runs,
nested captures, non-captured runs and the empty-match restrictions
(`(*NOTEMPTY)`, `(*NOTEMPTY_ATSTART)`) on fully nullable chains reject the
shape, and `Limits.longest` disables it. The plan and anchor filter are
heap-allocated so workspaces without the shape keep their size.

## Measurements

The capture benchmark runs a full find loop over each subject and reads every
returned slot into a checksum. Each executable reports the median of five
batches of 100 passes. Five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`run-chain.json`](run-chain.json).

| Case | Before, ns/pass | After, ns/pass | Speedup |
| --- | ---: | ---: | ---: |
| nullable Unicode captures | 716,590.8 | 294,774.2 | 2.43x |
| disjoint Unicode captures | 282,804.2 | 124,431.3 | 2.27x |
| Unicode empty captures | 289,404.2 | 134,307.1 | 2.15x |
| Unicode optional captures | 563,395.4 | 278,397.9 | 2.02x |
| optional ASCII captures | 245,009.2 | 180,105.0 | 1.36x |
| disjoint ASCII captures | 131,895.4 | 100,252.9 | 1.32x |
| Han capture control | 29,064.6 | 29,036.7 | 1.00x |
| nullable greedy control | 163,329.6 | 160,947.5 | 1.01x |
| optional overlapping control | 246,842.1 | 241,819.2 | 1.02x |
| Han sparse captures | 96,457.9 | 98,583.8 | 0.98x |
| word capture control | 81,681.3 | 90,077.9 | 0.91x |

The shared host was noisy; an A/A run of the same executable differed by up to
10–20% on short cases, so the control differences (0.91–1.02x) are not
attributable. The covered cases improve in every round. The single-run capture
path keeps precedence, so `(\p{Han}+)`-style programs neither allocate the
run-chain state nor change their timings.

## Lazy nullable runs

A lazy `set*?` group compiles to a split whose exit is the group end save and
whose body consumes the set and loops back. With disjoint sets the lazy
capture expands to exactly the maximal run (the loop stops only where the next
run begins), so the same shape analysis and boundary walk apply. The detector
accepts that split form when the body loops back to the split; bounded lazy
forms (`??`, `{0,1}?`) still reject.

Measured separately against `9d7d5c9` with the same method (five interleaved
executions; raw samples in [`run-chain-lazy.json`](run-chain-lazy.json)):

| Case | Before, ns/pass | After, ns/pass | Speedup |
| --- | ---: | ---: | ---: |
| optional lazy control (`([a-z]+)([0-9]*?)([A-Z]+)`) | 228,332.1 | 139,357.5 | 1.64x |
| optional ASCII captures | 138,026.7 | 140,006.3 | 0.99x |
| nullable Unicode captures | 202,076.7 | 203,791.7 | 0.99x |
| Unicode optional captures | 200,290.4 | 193,759.6 | 1.03x |
| optional overlapping control | 168,810.8 | 170,061.7 | 0.99x |
| overlap mandatory control | 418,478.8 | 401,351.3 | 1.04x |
| Han capture control | 19,820.8 | 20,686.7 | 0.96x |

The lazy case now records no choices or trails; the other cases stay within
the host's spread.

## Nullable and trailing-nullable runs

The anchor rule was relaxed so that a mandatory run anchors the end and any
runs after it extend forward as greedy nullable runs; a chain with no
mandatory run matches at the search offset and extends every run from there.
Fully nullable chains skip the anchor search entirely. The empty-match
restrictions keep such programs on the general engine because their retry
loop owns the empty-match semantics.

Measured separately against `c6e9319` with the same method (five interleaved
executions; raw samples in
[`run-chain-nullable.json`](run-chain-nullable.json)):

| Case | Before, ns/pass | After, ns/pass | Speedup |
| --- | ---: | ---: | ---: |
| nullable greedy captures (`(a*)(b*)`) | 132,525.8 | 65,129.6 | 2.03x |
| trailing nullable capture (`(a+)(b*)`) | 74,049.6 | 42,145.4 | 1.76x |
| sandwiched nullable captures (`(a*)(b+)(c*)`) | 86,507.1 | 60,902.9 | 1.42x |
| overlap nullable control (`(a*)(a*)`) | 128,059.2 | 126,883.3 | 1.01x |
| optional ASCII captures | 154,466.7 | 159,285.8 | 0.97x |
| nullable Unicode captures | 234,589.6 | 239,144.2 | 0.98x |
| Unicode optional captures | 226,672.1 | 231,497.9 | 0.98x |
| Han capture control | 22,531.7 | 21,562.9 | 1.04x |

The nullable chains record no choices or trails; the remaining cases stay
within the host's spread. The fully nullable shape requires the benchmark
loop to advance one rune per empty match, which the capture tests mirror.

## Forward overlapping runs

Overlapping sets defeat the backward walk because the greedy order assigns
the overlap to the earlier run. They are accepted in a forward mode instead
when the first run is mandatory and every mandatory run's set is disjoint from
all preceding sets. Then the greedy maxima are complete: backtracking an
earlier run can only start a later run inside a set it cannot match, so a
failed mandatory run cannot be rescued by backtracking and the scan returns to
the general engine. The scan starts at the first first-run member and extends
every run forward; the control shapes that need backtracking
(`([a-z]+)([a-z]*)([a-z]+)`) reject the shape.

Measured separately against `7effba4` with the same method (five interleaved
executions; raw samples in
[`run-chain-forward.json`](run-chain-forward.json)):

| Case | Before, ns/pass | After, ns/pass | Speedup |
| --- | ---: | ---: | ---: |
| optional overlapping run (`([a-z]+)([a-z0-9]*)([A-Z]+)`) | 191,650.8 | 114,621.7 | 1.67x |
| overlap mandatory control (`([a-z]+)([a-z]*)([a-z]+)`) | 433,220.4 | 468,859.2 | 0.92x |
| optional ASCII captures | 153,247.1 | 163,688.3 | 0.94x |
| nullable greedy captures | 61,364.6 | 64,625.8 | 0.95x |
| overlap nullable control (`(a*)(a*)`) | 124,562.9 | 130,166.7 | 0.96x |
| Han capture control | 21,568.3 | 22,029.6 | 0.98x |
| trailing nullable capture | 42,014.6 | 40,801.3 | 1.03x |
| sandwiched nullable captures | 59,564.2 | 56,335.0 | 1.06x |

The overlapping case improves in every round. The mandatory-overlap control
is rejected by the detector and keeps the interpreter; its 0.92x median comes
from a single slow round and stays within the host's spread.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='run chain' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/shapes.zig src/regex/replace.zig src/regex/run_chain_tests.zig
```

The new tests cover detection, run and empty capture boundaries, malformed
UTF-8, greedy, lazy, fully nullable, trailing-nullable and forward overlapping
run forms (including empty-match iteration), and randomized differential
comparison against the same program pinned to the interpreter. The two capture
replay suites were updated: their disjoint-run cases now assert the run-chain
path, and their strict-budget cases pin both workspaces to the interpreter.
