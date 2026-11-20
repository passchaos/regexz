# Full-match DFA transition masks

Baseline: `b53e9f7`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The lazy full-match DFA caches (state, rune) transitions in a direct-mapped
cache. On a miss it walks the state's consuming instructions, tests each set
or literal, runs the epsilon closure and interns the resulting state. Inputs
with many distinct runes (varied Han text) or runes that evict each other in
the direct-mapped cache therefore repeat the walk and the interning work even
though the resulting state is unchanged.

A state's transition depends only on which of its consuming instructions
match, not on the rune. States with at most four consuming instructions now
carry `1 << k` target slots appended to their arena instruction block. On a
rune-cache miss the transition tests the sets and literals once, builds the
match mask, and reuses the memoized target for that mask; the closure and
interning run only for a new mask. The mask scan visits the same sorted
instruction list as the general walk, so the key order is deterministic.
States with more than four consuming instructions and ASCII-only DFAs keep the
existing walk, and ASCII transitions keep the per-byte table, which already
deduplicates them. The state record stays 24 bytes and the target slots share
the instruction allocation, so workspace size and allocation counts are
unchanged.

## Measurements

`bench-startup` separates compilation plus first match, workspace
initialization, first match, three matches that construct a fresh DFA, and
warmed matching. Each executable reports the median of five batches. Five
executions were interleaved before/after, after/before, alternating. The table
reports medians across those executions; raw samples and executable SHA-256
identities are in [`dfa-mask-cache.json`](dfa-mask-cache.json).

| Case / mode | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| 4,096 distinct Han runes / cold | 85,843.8 | 36,505.3 | 2.35x |
| 4,096 distinct Han runes / compile_first | 89,109.4 | 38,651.0 | 2.31x |
| 4,096 distinct Han runes / dfa_cold | 116,255.3 | 66,203.1 | 1.76x |
| Unicode slot collisions / warm | 21,281.5 | 7,440.4 | 2.86x |
| Unicode slot collisions / dfa_cold | 88,661.4 | 76,026.0 | 1.17x |
| Unicode slot collisions / cold | 30,739.5 | 30,656.3 | 1.00x |
| 4,096 distinct Han runes / warm | 13,965.8 | 14,721.3 | 0.95x |
| ASCII class / dfa_cold | 79.1 | 79.1 | 1.00x |
| fragmented class / dfa_cold | 85.0 | 88.6 | 0.96x |
| ASCII loop / dfa_cold | 449.4 | 432.2 | 1.04x |
| alternation / dfa_cold | 975.2 | 968.2 | 1.01x |
| xDS path / dfa_cold | 1,966.1 | 1,998.0 | 0.98x |
| mixed Unicode / dfa_cold | 574.0 | 582.2 | 0.99x |
| Unicode letters / dfa_cold | 153.6 | 151.5 | 1.01x |

The shared host was noisy; an A/A run of the same executable differed by up
to 20% on the long Han case. The two large Han gains repeat in every round
(cold: 80-93 us before, 30-51 us after; collision warm: 19.7-20.8 us before,
6.7-9.0 us after). Small ASCII controls stay within the observed spread. The
collision cold path is dominated by DFA construction rather than the scan, so
it is unchanged.

## Validation

```sh
zig build test-lib -Dtest-filter=DFA -Dtest-filter='rune cache' -Dtest-filter=borrowed -Dtest-filter='expired and interrupted' -Dtest-filter=literal --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter=DFA -Dtest-filter='rune cache' -Dtest-filter=borrowed -Dtest-filter='expired and interrupted' -Dtest-filter=literal --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/execute.zig
zig build bench-startup -Doptimize=ReleaseFast
```

The scoped DFA tests cover promotion, surviving entries, cached dead
transitions, optional allocation failure at every allocation index,
malformed/truncated UTF-8, and randomized Unicode DFA/NFA comparisons; the
V8 driver compares each linear program's cold full match with reused-workspace
calls.
