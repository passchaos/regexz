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
- the last non-empty run is mandatory and anchors the match end.

The scan jumps to the next anchor rune with the anchor set's UTF-8
candidate-byte filter, extends the maximal anchor run, and walks backward over
the preceding runs to place every capture boundary. Runs are maximal and the
sets are disjoint, so the greedy leftmost-first boundaries are forced; no DFA
state, choice or trail is recorded, and the deterministic scan does not consume
the interpreter step budget (matching the other shape scans). Starts inside a
run, malformed UTF-8 and a failed mandatory prefix fall back to the general
engine, so the fast path never changes semantics. Overlapping sets, nullable
anchors, fixed-count runs, nested captures and non-captured runs reject the
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
UTF-8, greedy and lazy run forms, and randomized differential comparison
against the same program pinned to the interpreter. The two capture replay
suites were updated: their disjoint-run cases now assert the run-chain path,
and their strict-budget cases pin both workspaces to the interpreter.
