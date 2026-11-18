# regexz roadmap: from bounded xDS matcher to a top-tier regex engine

This document records the current audit, the measured gaps, and the
highest-leverage work remaining. It is deliberately concrete: each item names
the owning file and the expected effect.

## 1. Current position

regexz now has two execution engines:

- **Linear mode** (`execute.zig`, `pike.zig`, `search_dfa.zig`): Thompson NFA,
  bounded lazy full-match DFA, a priority-annotated lazy search DFA for
  leftmost-first search (capture programs reuse its bounds and replay the
  matched slice for slots), exact-literal fast path, single-rune literal
  instructions, greedy single-set loop instructions, compile-time first-byte
  summaries, a compile-time required-literal prefilter, and a capture-aware
  Pike VM for linear-time fallback search. Used for RE2-compatible patterns.
- **Extended mode** (`backtrack.zig`): bounded backtracking VM with general
  lookaround, backreferences, atomic groups, possessive quantifiers,
  conditionals, recursion/subroutine calls, `\K`, `\G`, UCP word boundaries,
  and full capture slots. Used automatically when a pattern needs one of
  those features.

Implemented functionality:

- General lookahead/lookbehind, including variable-length lookbehind, PCRE2
  alphabetic assertion names (`(*pla:)`, `(*nla:)`, `(*plb:)`, `(*nlb:)`),
  and non-atomic positive lookaround `(?*...)`/`(?<*...)`
  (`(*napla:)`/`(*naplb:)`).
- Numeric/named backreferences.
- Named captures and group-name lookup; duplicate names with `(?J)`.
- Atomic groups and possessive quantifiers.
- Conditionals on group participation, assertions, recursion (`(?(R))`,
  `(?(R1))`, `(?(R&name))`), and `(?(DEFINE)...)` definition blocks.
- Branch reset `(?|...)`.
- Recursion `(?R)`, `(?0)`, `(?1)`, `(?+1)`, `(?-1)`, `(?&name)`,
  `(?P>name)`, `\g<name>` with a depth limit.
- Leftmost-longest (POSIX) search/replace via `Limits.longest`.
- `\X` extended grapheme clusters using UAX #29 and Unicode 17.0.0 data.
- `\K`, `\G`, `\Z`, `\R`, `\N`, `\h`, `\H`.
- Backtracking control verbs `(*FAIL)`, `(*ACCEPT)`, `(*PRUNE)`,
  `(*SKIP)`/`(*SKIP:name)`, `(*COMMIT)`, `(*THEN)`; `(*MARK:name)` is
  recorded and exposed through `Match.mark`; `(*UCP)`/`(*UTF)` directives are
  accepted.
- Numeric and string callouts `(?C...)` through `Limits.callout`, plus
  `Limits.auto_callout` (callout 255 before consuming atoms).
- Extended mode `(?x)`, ungreedy mode `(?U)`, no-auto-capture `(?n)`, and
  `(?#...)` comments.
- UCP `\d`/`\w`/`\s` and Unicode `\b`/`\B`; property aliases
  (`Script=`, `sc=`, `gc=`, `General_Category=`, `Is...`), long
  General_Category names (`Letter`, `Uppercase_Letter`, `Decimal_Number`,
  `Cased_Letter`), ISO 15924 script codes (`Grek`), case/separator-insensitive
  names, `Script_Extensions`
  (`scx=`/`Script_Extensions=`, long names or ISO 15924 codes, including the
  Unicode 16/17 scripts missing from RE2's pinned tables), 63 binary Unicode
  properties (`Alphabetic`, `White_Space`, `Emoji`, `Extended_Pictographic`,
  `Lowercase`, `Hex_Digit`, `ID_Start`, ...), `\p{ASCII}`, `\p{Cn}`,
  `\p{Assigned}`, Unicode 16 case-fold supplements, Unicode blocks (`In...`/
  `Block=...`), PCRE2 `Xan`/`Xwd`/`Xps`/`Xsp`/`Xuc`, and the Unicode string
  properties `\p{RGI_Emoji}`, `\p{Basic_Emoji}`, `\p{Emoji_Keycap_Sequence}`,
  `\p{RGI_Emoji_Flag_Sequence}`, `\p{RGI_Emoji_Tag_Sequence}`,
  `\p{RGI_Emoji_Modifier_Sequence}`, and `\p{RGI_Emoji_ZWJ_Sequence}`.
- PCRE2 `\v`/`\V` vertical whitespace via `Limits.pcre_vertical_whitespace`.
- Character-class set operations `&&`, `--`, and `~~`, including nested
  classes such as `[a-z&&[^aeiou]]`.
- Numeric/relative backreferences and subroutine calls via `\g{1}`,
  `\g{-1}`, `\g<1>`, `\g<-1>`, and `\g<+1>`.
- `\N{U+hhhh}` explicit code points, `\N{NAME}` Unicode character names,
  `\cX` control characters, `\o{...}` octal code points, and class-aware
  `\Q...\E` quoting.
- UAX #29 boundary assertions: grapheme clusters `\b{gcb}` / `\B{gcb}`
  (alias `\b{g}`), word boundaries `\b{wb}` / `\B{wb}`, sentence
  boundaries `\b{sb}` / `\B{sb}`, and Oniguruma/Java word-start/end
  variants `\b{start}` / `\b{end}` / `\b{startend}`.
- `Limits.capture_reset` (JavaScript capture reset) and
  `Limits.unset_backref_empty` (PCRE2 `PCRE2_MATCH_UNSET_BACKREF`).
- Search API: `isMatch`, `find`, `findFrom`, `findAll`, `split`, `replaceAll`,
  callback replacement, and `RegexSet` multi-pattern matching with a
  single-pass combined DFA for eligible patterns.
- `StreamScanner`: persistent streaming NFA with captures, lookahead,
  assertions, UTF-8 chunk boundaries, and bounded memory.
- Versioned `Program.serialize`/`deserialize` with index/slot validation for
  cross-process compiled-pattern caches.
- Replacement syntax: `\0`..`\9`, `$0`..`$99`, `$&`, `$$`, `${name}`,
  case transforms `\U`/`\L`/`\E`/`\u`/`\l` (simple Unicode by default;
  `Limits.full_case_mapping` enables full SpecialCasing), and callback
  replacement via `replaceAllWithFn`.
- 141 tests, including recursion, branch reset, conditional assertions,
  grapheme clusters, binary properties, Unicode blocks, partial matching,
  control verbs, thread safety, allocation-failure, and differential coverage
  against V8 for the supported subset.

Strengths:

- The linear paths retain the original bounded, allocation-light design.
- Non-extended patterns keep the linear-time guarantee by default: the
  capture-aware Pike fallback (`linear_fallback = true`) resolves searches
  whose backtracking budget is exhausted.
- Extended features are fail-closed: step, choice, capture-trail, and
  recursion-depth limits produce `error.RegexLimitExceeded`.
- Compile-time materialization of `(?i)` folding and negation keeps set
  matching to one binary search.
- Unicode data and property tables are generated from a pinned RE2 revision.

## 2. Remaining feature gaps

| Capability | regexz | PCRE2 | Rust `regex` | Node/V8 |
| --- | --- | --- | --- | --- |
| General lookaround | yes (extended) | yes | no | yes |
| Non-atomic lookaround `(?*...)`/`(?<*...)` | yes (extended) | yes (10.43+) | no | no |
| Script runs `(*sr:...)`/`(*asr:...)` | yes (extended) | yes (10.43+) | no | no |
| Backreferences | yes (extended) | yes | no | yes |
| Atomic/possessive | yes (extended) | yes | no | no |
| Conditionals | group + assertion + `(?(R1))`/`(?(R&name))` + DEFINE | full | no | no |
| Branch reset `(?|...)` | yes | yes | no | no |
| Recursion/subroutines | yes (extended) | yes | no | no |
| Named captures | yes | yes | yes | yes |
| Duplicate group names | yes (`(?J)`) | yes | no | no |
| Ungreedy `(?U)` | yes | yes | no | no |
| No-auto-capture `(?n)` | yes | yes | no | no |
| Class set ops `&&`/`--`/`~~` | yes | partial (10.45+) | yes | no |
| Relative subroutines `(?+1)`/`(?-1)` | yes | yes | no | no |
| `(?(R))` recursion condition | yes | yes | no | no |
| `\X` grapheme cluster | yes (extended) | yes | no | no |
| `\b{gcb}` / `\b{wb}` / `\b{sb}` | yes (extended) | no | no | no |
| `\b{start}` / `\b{end}` variants | yes (extended) | no | no | no |
| Backtracking verbs | yes (subset) | yes | no | no |
| Callouts / `(*THEN)` | numeric + string + auto callouts, `(*THEN)`, MARK | yes | no | no |
| `\N{NAME}` named characters | yes (explicit + algorithmic) | no | no | no |
| Full SpecialCasing | optional (`full_case_mapping`) | no | no | no |
| `\p{Xan}`/`\p{Xwd}` specials | yes | yes | no | no |
| `\p{Xuc}` | yes | yes | no | no |
| Binary Unicode properties | yes (63) | yes | partial | yes |
| Unicode string properties | 7 properties | yes (10.43+) | no | no |
| Leftmost-longest mode | yes | partial | yes | no |
| Partial match (prefix) | yes (linear + extended, conservative) | yes | yes | yes |
| True streaming scanner | yes (linear, rune-based) | partial | partial | yes |
| Multi-pattern `RegexSet` | yes | no (separate calls) | yes | no |
| `\C` in DFA/Pike | fallback only | yes | no | no |

## 3. Performance gaps

Measured on an Apple Silicon macOS host. "Before" is the initial commit state;
"after" is the current linear path.

| Case | Before | After | Rust `regex` 1.13 | Node 26 |
| --- | ---: | ---: | ---: | ---: |
| Full match, 13-byte literal | ~3.6 µs | ~1.6 ns | ~10 ns | ~10 ns |
| Full match, class pattern (one-shot) | ~3.7 µs | ~9 ns | ~10 ns | ~14 ns |
| Full match, class pattern (reused workspace) | ~171 ns | ~8 ns | ~10 ns | ~14 ns |
| Full match, xDS-like (reused) | ~233 ns | ~15–17 ns | ~11 ns | ~11 ns |
| Full match, Unicode (reused) | ~64 ns | ~12 ns | ~8 ns | ~13 ns |
| Qwen tokenizer search, 22 KiB | ~842 µs | ~95 µs (250 MiB/s) | ~67 µs* | ~195 µs |
| `find` selective pattern (`\p{N}`) | — | ~36 ns/piece | — | — |
| `find` multi-literal after a 4 KiB prefix | ~2.0 µs | ~0.22 µs | — | — |
| `find` capture email tokens, 18 KiB | ~161 µs | ~68 µs | — | — |
| `find` capture no-match scan, 23 KiB | ~617 µs | ~84 µs | — | — |
| `find` loop-exit no-match, 23 KiB | ~120 µs | ~4.7 µs | ~31.8 µs | — |
| `find` suffix no-match, 23 KiB | ~238 µs | ~14 µs | ~155 µs | — |
| `find` extended no-match, 23 KiB | ~275 µs | ~2.5 µs | — | — |
| `RegexSet`, 9 no-match patterns, 23 KiB | ~1.7 ms | ~63 µs | ~104 µs | — |
| `replaceAll` `a+`, 32 KiB | ~265 µs | ~64 µs (480 MiB/s) | ~91 µs | ~47 µs |
| Compile xDS-like pattern | ~2.9 µs | ~3.1–3.9 µs | ~10.8 µs | ~61 ns† |
| Compile xDS-like (smp allocator) | — | ~1.5 µs | — | — |

\* Rust baseline omits the `\s+(?!\S)` branch because Rust `regex` has no
lookaround; the Node baseline uses the full pattern.

† Node's repeated `new RegExp` benchmark likely benefits from V8's compile
cache for identical sources.

Where the remaining time goes:

- **One-shot boolean match** now reuses a persistent workspace/DFA, but the
  lazy DFA still starts cold for each new `Regex`. Precomputing a DFA for
  small programs would remove the first-call construction cost.
- **Search** uses the priority search DFA for linear programs (Qwen now
  exceeds 200 MiB/s). Capture programs take DFA bounds and replay only the
  matched slice, which removes the failed-start scans that dominated patterns
  like `(\w+)@(\w+)`. Interpreter fallbacks with a multi-byte required
  literal run one literal prefilter, so no-match scans of patterns like
  `[a-z]*(?:foo|bar)` are ~25x faster. Loops whose exits can compete with
  later choices still use the interpreter; a fully dynamic leftmost-first DFA
  (iteration-aware priorities) is the next large step.
- **Replacement** uses budgeted backtracking first and a capture-aware Pike
  VM when the budget is exhausted (`linear_fallback`, default true). The Pike
  VM returns exact captures in linear time; routing every capture program to
  it directly would cost 3–5× on short matches, so the backtracking fast path
  stays in front.
- **Extended patterns** are not performance targets; they are feature
  targets. The VM is bounded but can be slower than PCRE2's JIT.

## 4. Prioritized roadmap

### P0 — remaining high-value functionality

1. ~~**Callouts `(?C...)`, `(*THEN)`, and mark retrieval**~~: done. Numeric
   and string callouts, `(*THEN)`, and `(*MARK:name)` via `Match.mark`.
2. ~~**True streaming scanner**~~: done. `StreamScanner` persists NFA state
   across chunks for non-extended, rune-based programs.
3. **`\C` in DFA/Pike**: intentionally documented as a fallback; `\C`
   programs use the NFA/backtracking paths, while the DFA/Pike fast paths
   stay rune-oriented.

### P0 — largest linear performance gaps

5. ~~**Capture-aware Pike VM** (`pike.zig`)~~: done. Threads carry capture
   slots, so `linear_fallback` (default true) resolves ordinary capture
   programs in linear time with exact group boundaries.
6. **DFA-backed leftmost search** (`execute.zig`, `compile.zig`): the
   priority-annotated lazy search DFA (`search_dfa.zig`) now covers linear
   programs including capture programs (bounds from the DFA, slots replayed
   on the matched slice) and lifted Qwen tokenizer search from ~123 MiB/s to
   ~215 MiB/s. Remaining: iteration-aware priorities for loops whose exits
   compete with later choices, and closing the gap to Rust's ~330 MiB/s. An
   ordered-subset DFA prototype was evaluated and reverted: list position
   captures loop-iteration order but cannot compare an accept with an earlier
   accept from a different branch. A sound solution needs tagged priorities
   (rank tuples) or the forward+reverse DFA pair.
7. **First-call DFA latency** (`compile.zig`): precompute or persist a DFA
   for small programs so even the first `matches` call avoids construction.
   `Regex` already caches a persistent workspace/DFA after the first use.

Completed: greedy single-set loops (`.star`), compile-time first-byte
summaries for alternation skipping and search prefilters, literal prefix and
`memchr` prefilters, persistent workspace/DFA, ASCII bitmaps, a SIMD
first-byte prefilter for small selective sets, pointer payload dispatch in the
VMs, the capture-aware Pike fallback, no-backtrack marks on stars whose
continuation always accepts, and the priority-annotated search DFA for
capture-free alternation/optional/simple-loop/set-lookahead programs. A multi-way
alternation dispatch table was implemented and benchmarked but is disabled
(`alternation_dispatch = false`): the split + first-byte-skip chain is faster
on the tokenizer and xDS workloads.

### P1 — API and semantics

9. ~~**Capture semantics controls**~~: done. `Limits.capture_reset` selects
   JavaScript-style reset between iterations; the default remains
   PCRE2/Rust/Perl semantics.
10. **`Program` ownership**: add `Program.deinit` or encode the arena
    requirement in the type system.

### P2 — performance and process

11. ~~`u32` workspace instruction/epoch arrays~~: done, reducing the linear
    full-match workspace to 44 bytes/instruction. 256-byte lookup tables for
    mixed sets remain.
12. SIMD prefilters: the first-byte vector prefilter for small selective sets
    is done and its byte table is cached per workspace; Teddy-style
    multi-byte/multi-literal filtering remains.
13. One-pass NFA/bitstate for small capture programs.
14. ~~Program serialization for cross-process caches~~: done.
    `Program.serialize`/`deserialize` with a validated versioned format.
15. Differential fuzzing: seeded V8 harnesses cover the linear engine
    (`tools/fuzz/run.py`, 37,800 comparisons) and the extended engine
    (`tools/fuzz/extended.py`, 28,500 comparisons) including captures,
    `capture_reset`, and `unset_backref_empty`. A three-way Rust `regex`
    1.13 / Node / regexz harness (`tools/fuzz/rust.py`) adds 54,000
    comparisons; Node is the semantic arbiter for the few ambiguous
    alternation cases where Rust's DFA differs from PCRE2/Perl. Benchmark
    regression gating is in place via `tools/bench/check.py` against
    `tools/bench/baseline.json`. Extending to PCRE2 and RE2 remains.
16. ~~**`RegexSet` single-pass DFA**~~: done (`set_dfa.zig`). Patterns without
    assertions or extended features share one unanchored subset construction;
    the rest stay on their per-pattern engines.

## 5. Target metrics

For the workloads in `tools/bench/main.zig`, on an idle host:

- Full match, short literal/class/xDS patterns: **≤ 40 ns** one-shot
  (achieved: ~8–17 ns).
- Full match, reused workspace: **≤ 20 ns** for ASCII class patterns
  (achieved: ~8 ns).
- Qwen tokenizer search: **≥ 200 MiB/s** (achieved: ~250 MiB/s).
- `replaceAll` `a+`: **≥ 400 MiB/s** (achieved: ~450–480 MiB/s).
- Compile xDS-like pattern: **≤ 2 µs** (achieved: ~1.5 µs with
  `std.heap.smp_allocator`; ~3.1–3.9 µs with `page_allocator`).
- Workspace memory: **≤ 48 bytes/instruction** (achieved: 44).
- Linear mode: **O(input × program)**; extended mode: bounded by the
  configured step/choice/trail/depth limits.

## 6. Non-goals for the linear engine

Backreferences, general lookaround, recursion, atomic groups, and possessive
quantifiers are non-goals for the linear engine because they break the
linear-time guarantee. They are supported only in the extended backtracking
mode, which is explicitly bounded and fail-closed.
reak the
linear-time guarantee. They are supported only in the extended backtracking
mode, which is explicitly bounded and fail-closed.
