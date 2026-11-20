# Direct scans for caseless literals and literal alternations

Baseline: `6b7922e`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Two whole-pattern literal shapes previously routed every candidate through the
search DFA. Both are now decided directly.

`(?i)alpha` has a case-folded pair filter that proposes the earliest possible
start, but each candidate still entered the DFA. The new `caseless_literal`
fast kind verifies the candidate window with a byte-wise ASCII fold and
returns the match itself. Windows containing a non-ASCII byte fall back to the
DFA so Unicode simple folding (for example `\u{017F}` -> `s`) keeps its exact
semantics; capture programs and `longest` mode stay on the general path.

`alpha|gamma|epsilon|zeta|theta` is a whole-pattern alternation of exact
literals. The compiler now records the alternatives in source order, and the
workspace verifies them directly at the first candidate. Leftmost-first is
preserved by checking alternatives in order at the earliest position. The
multi-literal pair filter was generalized to literals with distinct first
bytes (one lane splat per pair) and now precomputes its splats at init;
`search_dfa`'s shared-first use is unchanged.

## Measurements

The two new comparison cases, seven alternating rounds against Rust's
`regex`; raw samples and executable identities are in
[`literal-fast-paths.json`](literal-fast-paths.json):

| Case | regexz, ns/iter | Rust, ns/iter | Rust / regexz |
| --- | ---: | ---: | ---: |
| find `(?i)alpha` | 43,408.8 | 80,518.3 | 1.85x |
| find 5-word alternation | 149,139.2 | 167,154.6 | 1.12x |

Before these changes the same harness measured 127,418.8 ns for the caseless
literal (0.68x, i.e. 1.47x slower than Rust) and 254,602.9 ns for the
alternation (0.65x, 1.53x slower). The direct scans improve them 2.83x and
1.77x respectively. The other 19 comparison cases stay within host noise and
remain ahead (see the [comparison](rust-comparison.md)).

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/run.py --cases 500 --seed 20261122
python3 tools/fuzz/replace.py --cases 400 --seed 20261121
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/compile.zig src/regex/replace.zig src/regex/prefilter.zig
```

Four engine-fuzzer seeds (500 patterns, 44,052 comparisons each) and five
replacement-fuzzer seeds pass. New tests cover leftmost-first order, shared
prefixes, single-byte alternatives, non-ASCII literals, and rejection of
trailing context, captures and case-folded alternatives.

## Prefix + literal suffix

`\w+@example\.com` compiles to `consume(\w) -> star(\w) -> literal bytes`,
but the chain detector rejects it because the literal separator is longer
than its shape allows, so every position went through the search DFA. The new
`run_then_literal` kind searches the required literal directly and scans back
the maximal ASCII run. It is selected only when no chain applies, the run set
is ASCII-only, and the literal's first byte is outside the set, so the run
ends exactly at the literal. A search offset inside a run clamps the start,
which matches the engine's leftmost-first result.

The email-text case improves 5.6x internally (47,377.1 -> 8,578.3 ns) and is
3.43x ahead of Rust.

## Wider literal sets

The multi-literal pair filter handles sparse first-byte sets well, but for
wider sets its conservative pair mask produces many candidates. The
literal-set fast path now builds the multi-literal filter only when the
alternatives have at most eight distinct first bytes; wider sets use the
`PairSet` nibble-table candidate filter. The 10-word alternation improves
1.17x (289.1 -> 247.5 us) and is 1.20x ahead of Rust.
