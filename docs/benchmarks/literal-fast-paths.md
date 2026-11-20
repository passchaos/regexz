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

## Fixed-width sequences

`\d{4}-\d{2}-\d{2}` is a pure concatenation of single-rune sets and literal
bytes, but the chain and run shapes only cover variable-width runs, so it had
been running the search DFA. The new `fixed_sequence` kind records the
element sequence (deduplicating the ASCII set tables) and checks a candidate
directly: the first element drives the scan and the remaining bytes are byte
table and literal compares. Variable-width runs (`\d+`, `\d{1,3}`), captures,
non-ASCII sets and all-literal patterns stay on their existing paths.

The date-text case improves 6.4x internally (252,237.7 -> 39,146.7 ns) and is
3.53x ahead of Rust. The comparison also added an IPv4 case (`\d{1,3}` is
variable width and stays on the DFA, 1.16x ahead), a 20-word alternation
(1.49x), and a multiline anchored line scan (1.09x).

## Line-start runs

`(?m)^\w+` compiled to a start-line assertion followed by a run, which none
of the existing run shapes covered, so every line start was decided by the
search DFA. The new `line_start_run` kind is selected for
`save0 -> assertion(start_line) -> consume(set) -> star(set) -> save1` in LF
newline mode with an ASCII-only set. A match can only start at a line start,
so each line start needs just the maximal run scan, and lines that begin
outside the set are skipped with a newline search. A search offset inside a
line advances to the next line start, matching the engine.

The anchored line case improves 3.5x internally (8,154.0 -> 2,241.9 ns) and
moves from 1.09x to 4.23x ahead of Rust. End-line variants
(`(?m)^\w+$`), non-ASCII sets and other newline modes stay on the general
engine.

## Bounded set runs

`\d{1,3}(?:\.\d{1,3}){3}` is a concatenation of bounded set runs. The
compiler now records that shape (`bounded_sequence`) when the whole pattern
is a sequence of ASCII sets with bounded repetitions, at least one of which
is variable width; fixed repeats of a sequence expand, lazy/possessive
repeats, captures, unbounded runs and non-ASCII sets fall back. The workspace
deduplicates the set tables and first tries a flat greedy walk, which decides
every unambiguous candidate; only candidates where a shorter run could
succeed enter the backtracking matcher (bounded by a small step budget).

The IPv4 case improves 1.78x internally (119,776.9 -> 67,156.9 ns) and moves
from 1.16x to 2.12x ahead of Rust. Fixed-width programs such as
`\d{4}-\d{2}-\d{2}` keep the instruction-based `fixed_sequence` path.

## Unbounded run chains

`v?\d+\.\d+\.\d+` is a chain of unbounded runs separated by literals, but
the chain detector only covers a single separator, so it ran the search DFA.
The compiler now records `unbounded_sequence` for a whole pattern that is a
sequence of ASCII `set+` runs separated by literal bytes, optionally led by a
one-byte optional literal. The shape is accepted only when each separator's
first byte is outside the preceding run set (so the run ends exactly at the
separator and the flat walk needs no backtracking) and when skipping the
optional literal cannot help; adjacent runs and non-ASCII sets reject it.

The version case improves 1.74x internally (91,001.9 -> 52,292.3 ns) and moves
from 1.17x to 2.00x ahead of Rust. Single-separator chains such as `\w+=\w+`
keep the existing chain path.

## Run-anchored shapes

Four common run-anchored shapes had been on the search DFA and are now
scanned directly:

- `set* literal` (`.*test`, `[a-z]*test`): the greedy star consumes the
  maximal member run and backtracks to the last literal occurrence inside it,
  so a failed start skips the whole run. The star uses the UTF-8 run scan, so
  invalid bytes stop the run exactly as the engine does. `.*test` had been
  restarting the search DFA at every position: it moves from 1.98 ms to about
  30 us (65x) and is 1.25x ahead of Rust.
- one set byte then a greedy run (`[A-Za-z_]\w*`): the first set byte anchors
  the match and the run is maximal. It improves 4.2x and is 2.01x ahead.
- a run then a greedy repetition of `separator run`
  (`[a-z0-9-]+(?:\.[a-z0-9-]+)+`): the separator is disjoint from both run
  sets, so the walk needs no backtracking. It improves 5.1x and is 3.51x
  ahead.
- a run, an optional `separator run` group, then a literal
  (`\d+(?:\.\d+)?%`): the greedy group is tried first and skipped when its
  literal fails. It improves 4.9x and is 3.77x ahead.

Each shape is accepted only when its sets are ASCII-only and its separators
are disjoint from the runs; captures, assertions, lazy/possessive repeats and
ambiguous optional groups fall back to the general engine.

## Alternation elements and anchored runs

`\w+@\w+\.(?:com|org|net)` ends in a literal alternation, which the unbounded
chain walker rejected, so it ran the search DFA. Alternation branches that
are pure ASCII literal sequences are now a single chain element: the branches
are stored in source order, checked in order, and a preceding run may not
consume any branch's first byte. The email-TLD case improves 2.6x
(47,839.0 -> 18,733.5 ns) and is 1.22x ahead of Rust.

`(?m)\w+$` used the anchored-run path, which tested membership through the
set bitmap and built a `Position` for every run. ASCII-only anchor sets now
use a byte table, and only runs ending at a newline or the text end consult
the newline mode. The end-anchored word case improves 2.4x
(33,525.4 -> 14,100.2 ns) and is 2.29x ahead.

## Optional prefixes, star runs and single-set elements

Three more sequence shapes were added to the unbounded chain walker:

- `x? set+` where `x` is a member of the set (`v?\w+`) matches exactly the
  same spans as `set+`, so the program takes the plain set-run path. The
  optional-prefix case improves 2.7x and is 1.83x ahead.
- Adjacent runs are accepted when their sets are disjoint (the first run ends
  at the first byte the second can consume), and `set*` runs with a minimum of
  zero are allowed. This covers `\w+\s*=\s*\w+`: 3.5x faster and 2.48x ahead.
- A single member of a multi-member ASCII set is a chain element
  (`[a-z]+[A-Z][a-z]+`): the run must be disjoint from the set, then one
  member is consumed and the next run continues. CamelCase scanning improves
  4.0x and is 1.37x ahead.

Overlapping adjacent runs, ambiguous optionals and non-ASCII sets still fall
back to the general engine.

## Bounded groups and failure skips

The bounded sequence accepts a trailing optional `separator set{min,max}`
group: the group is tried greedily and skipped when its separator or run does
not match. This covers CIDR forms (`\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?`),
which improve 1.6x and are 1.86x ahead.

A new bounded loop shape covers a bounded run followed by a greedy repetition
of a bounded `separator run` group (`\d{1,3}(?:,\d{3})+`): the first run's
width is tried greedily and shortened when the group cannot start. Thousands
separators improve 2.9x and are 2.98x ahead.

The unbounded chain skips the whole first run after a failed start, since
every start inside the run shares the same run end and remaining input. The
semver case improves 1.1x and is 1.15x ahead.

## Signed numbers, headings, negated runs and alternation products

Five more shapes were added after the expanded comparison found them on the
search DFA:

- A sign set followed by digits and an optional fraction
  (`[+-]?\d+(?:\\.\d+)?`) is detected from the AST and scanned directly. The
  sign is disjoint from the digits, so a failed digit run never retries
  without the sign. It improves 4.3x and is 1.48x ahead.
- A markdown heading (`(?m)^#{1,6} .*$`) gets a line-heading scan: the
  heading run is shortened until the space matches and the body run must
  reach the line end. It improves 3.8x and is 1.22x ahead.
- Unbounded chains accept non-ASCII runs through the UTF-8 run scan, so a
  negated-class chain (`\\w+="[^"]*"`) is walked directly. It improves 2.1x
  and is 1.98x ahead.
- The UTF-8 run search skips short ASCII gaps with the state-0 transition row
  instead of the filter setup, lifting the case-insensitive class scan
  (`(?i)[a-z]+`) 1.9x to 1.66x ahead.
- The literal-alternation extractor now distributes literal prefixes and
  suffixes over branches (`(?:pre|post)fix` becomes `prefix|postfix`), so
  such patterns use the literal-set filter. It improves 1.24x and is 1.27x
  ahead.

## Literal-alternation verification and packed prefix runs

The candidate filter for a whole-pattern literal alternation now reports
which branch matched, so the search returns the span without a second
verification pass. Single-byte branches accept the first-byte hit directly,
and wide alternations reuse the existing start-literal pair set instead of
allocating a second filter. The one-char alternation improves 1.22x and is
1.44x ahead; the five-word, 10-word and 20-word alternations improve 1.05x,
1.06x and 1.12x and are 1.20x, 1.29x and 1.57x ahead.

The prefix-run scan (`[A-Za-z_]\w*`) packs both membership sets into 64
bytes of bits instead of two 256-byte byte tables. Besides being smaller,
this removes a cache-set aliasing cliff: with the byte tables, a 30-byte
change in the caller's environment (the `PWD` length) shifted the workspace
tables and made the scan 3.5x slower; the packed bitsets keep the same speed
across stack layouts.

## Repeated literal groups and chain refinements

A whole-pattern repetition of a fixed literal sequence (`(?:ab)+`) is now
scanned directly: the first literal occurrence is found, then repetitions
are consumed greedily. The repeated-literal case improves 2.8x and is 3.04x
ahead of Rust.

Candidate filters no longer re-compare the three bytes they already checked,
and the third-byte stage is skipped when every two-byte pair is distinct:
shared-prefix alternations improve 1.23x (1.32x ahead) and the 10-word
alternation 1.13x (1.45x ahead). Markdown heading scans detect a match ending
exactly at a line break and skip the line-start search (2.02x ahead), and
chain walks compare single-byte separators directly, cutting the semver scan
11% to a statistical tie with Rust.

The comparison now covers 58 cases: regexz is faster on 57 and the semver
scan is a tie (0.98x here, 0.89-1.05x across runs).
