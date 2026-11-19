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
- PCRE2 script-run assertions `(*sr:...)`/`(*asr:...)` with UTS #39 script
  sets, Han virtual scripts, and the decimal-digit-set rule.
- PCRE2 scan-substring assertions `(*scs:...)`/`(*scan_substring:...)`.
- Newline conventions `(*CR)`, `(*LF)`, `(*CRLF)`, `(*ANYCRLF)`, `(*ANY)`,
  and `(*NUL)` for `^`, `$`, `\Z`, dot, and `\N`; `(*BSR_ANYCRLF)` /
  `(*BSR_UNICODE)` control `\R`.
- Empty-match locks `(*NOTEMPTY)`/`(*NOTEMPTY_ATSTART)` across full-match,
  search, replace, and streaming paths.
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
- `\K`, `\G`, `\Z`, `\R`, `\N`, `\h`, `\H`. A non-multiline `$`
  follows PCRE2 and matches before a final newline; `Limits.dollar_endonly`
  selects `PCRE2_DOLLAR_ENDONLY` for strict end-of-input semantics.
- Backtracking control verbs `(*FAIL)`, `(*ACCEPT)`, `(*PRUNE)`,
  `(*SKIP)`/`(*SKIP:name)`, `(*COMMIT)`, `(*THEN)`; `(*MARK:name)` is
  recorded and exposed through `Match.mark`, and named
  `(*PRUNE:name)`/`(*THEN:name)`/`(*COMMIT:name)`/`(*ACCEPT:name)` verbs
  record their name as the current mark like PCRE2; `(*UCP)`/`(*UTF)`
  directives are accepted.
- Numeric and string callouts `(?C...)` through `Limits.callout`, plus
  `Limits.auto_callout` (callout 255 before consuming atoms).
- Extended mode `(?x)`, extended-more `(?xx)`, ungreedy mode `(?U)`,
  no-auto-capture `(?n)`, ASCII option letters, `(?r)` caseless-restrict,
  `(?^)` option reset, `(*NO_START_OPT)`/`(*NO_AUTO_POSSESS)`/
  `(*NO_DOTSTAR_ANCHOR)` start-up directives, and `(?#...)` comments.
- UCP `\d`/`\w`/`\s` and Unicode `\b`/`\B`; POSIX classes follow PCRE2
  UCP replacements (`(?aP)`/`(?aT)` restore ASCII); `Bidi_Class`
  (`\p{BC:AL}`); property aliases
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
- 209 tests, including recursion, branch reset, conditional assertions,
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
- Unicode data and property tables are generated from Unicode 17.0.0 UCD data
  (emoji sequences from 16.0).

## 2. Remaining feature gaps

| Capability | regexz | PCRE2 | Rust `regex` | Node/V8 |
| --- | --- | --- | --- | --- |
| General lookaround | yes (extended) | yes | no | yes |
| Non-atomic lookaround `(?*...)`/`(?<*...)` | yes (extended) | yes (10.43+) | no | no |
| Script runs `(*sr:...)`/`(*asr:...)` | yes (extended) | yes (10.43+) | no | no |
| Scan substring `(*scs:...)` | yes (extended) | yes (10.43+) | no | no |
| Backreferences | yes (extended) | yes | no | yes |
| Forward back/subroutine/condition references | yes | yes | no | no |
| Atomic/possessive | yes (extended) | yes | no | no |
| Conditionals | group + assertion + `(?(R1))`/`(?(R&name))` + DEFINE | full | no | no |
| Branch reset `(?|...)` | yes | yes | no | no |
| Recursion/subroutines | yes (extended) | yes | no | no |
| Named captures (incl. Unicode names and `(?'name'...)`) | yes | yes | yes | yes |
| Duplicate group names | yes (`(?J)`) | yes | no | no |
| Ungreedy `(?U)` | yes | yes | no | no |
| No-auto-capture `(?n)` | yes | yes | no | no |
| Class set ops `&&`/`--`/`~~` | yes | partial (10.45+) | yes | no |
| Relative subroutines `(?+1)`/`(?-1)` | yes | yes | no | no |
| `(?(R))` recursion condition | yes | yes | no | no |
| `\X` grapheme cluster | yes (extended) | yes | no | no |
| `\b{gcb}` / `\b{wb}` / `\b{sb}` | yes (extended) | no | no | no |
| `\b{start}` / `\b{end}` variants | yes (extended) | no | no | no |
| Backtracking verbs | all; named verbs record MARK | yes | no | no |
| Callouts / `(*THEN)` | numeric + string + auto callouts, `(*THEN)`, MARK | yes | no | no |
| `\N{NAME}` named characters | yes (explicit + algorithmic) | no | no | no |
| Full SpecialCasing | optional (`full_case_mapping`) | no | no | no |
| `\p{Xan}`/`\p{Xwd}` specials | yes | yes | no | no |
| `\p{Xuc}` | yes | yes | no | no |
| Binary Unicode properties | yes (63) | yes | partial | yes |
| POSIX classes under UCP | yes (PCRE2 replacements) | yes | no | no |
| `Bidi_Class` properties | yes (23 classes) | yes | no | no |
| Unicode string properties | 7 properties | yes (10.43+) | no | no |
| Leftmost-longest mode | yes | partial | yes | no |
| Partial match (prefix) | yes (linear + extended, conservative) | yes | yes | yes |
| True streaming scanner | yes (linear, rune-based) | partial | partial | yes |
| Multi-pattern `RegexSet` | yes | no (separate calls) | yes | no |
| `\C` in DFA/Pike | yes (byte mode) | yes | no | no |
| Newline conventions `(*CR)`/`(*CRLF)`/`(*ANY)`/`(*NUL)` | yes | yes | no | no |
| `(?r)`/`(*CASELESS_RESTRICT)` caseless-restrict | yes | yes | no | no |
| `(?aD)`/`(?aS)`/`(?aW)`/`(?aP)`/`(?aT)` | yes | yes | no | no |
| `(?xx)` extended-more | yes | yes | no | no |
| `(*NOTEMPTY)`/`(*NOTEMPTY_ATSTART)` | yes | yes | no | no |
| `(*LIMIT_MATCH/DEPTH/HEAP=...)` | yes (heap is a choice/trail proxy) | yes | no | no |
| Turkish/Azeri casing `(*TURKISH_CASING)` | yes | yes (10.45+) | no | no |
| Compile-time regex construction | yes (`comptime_regex`, codegen subset, captures) | no | no | no |

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
| Qwen tokenizer search, 22 KiB | ~842 µs | ~47 µs (~508 MiB/s) | ~59 µs* (~400 MiB/s) | ~195 µs |
| CJK tokenizer search, 191 KiB | — | ~164 µs (~1.1 GiB/s) | ~200–216 µs* (864–933 MiB/s) | — |
| Han class scan, 191 KiB | — | ~125 µs (1.5 GiB/s) | ~157–169 µs (1104 MiB/s) | — |
| Full match, Han loop `(?:\p{Han}+\n)+`, 191 KiB | — | ~54 µs (~3.4 GiB/s) | ~213 µs | — |
| Full match, ASCII class, 216 KiB | — | ~52 µs (~4.0 GiB/s) | ~54 µs | — |
| Full match, ASCII loop, 216 KiB | — | ~79 µs (~2.6 GiB/s) | ~273 µs | — |
| Full match, backref `(a)\1` (reuse) | ~5.5 µs | ~17 ns | — | — |
| Full match, atomic `(?>a+)a` (reuse) | ~5.2 µs | ~23 ns | — | — |
| `StreamScanner` `[a-z]+`, 216 KiB in 4 KiB chunks | ~31 ms | ~0.16 ms (1.3 GiB/s) | — | — |
| `StreamScanner` `[a-z]+ [a-z]+`, 216 KiB in 4 KiB chunks | — | ~0.28 ms (757 MiB/s) | — | — |
| `StreamScanner` Han chain `\p{Han}+，\p{Han}+`, 191 KiB in 4 KiB chunks | — | ~0.39 ms (478 MiB/s) | — | — |
| `StreamScanner` `\w+@`, 18 KiB in 4 KiB chunks | ~2.9 ms | ~0.032 ms (517 MiB/s) | — | — |
| Byte escape scan `\C+`, 23 KiB | — | ~8 ns/pass (one full-span match) | not supported | — |
| Shared-prefix alternation no-match, 23 KiB | — | ~1.55 µs (15.5 GiB/s) | ~2.1 µs (11.4 GiB/s) | — |
| `find` selective pattern (`\p{N}`) | — | ~36 ns/piece | — | — |
| `find` multi-literal after a 4 KiB prefix | ~2.0 µs | ~0.28 µs (14 GiB/s) | — | — |
| `find` capture email tokens, 18 KiB | ~161 µs | ~10.5 µs (~1.6 GiB/s) | ~29 µs | — |
| `find` capture no-match scan, 23 KiB | ~617 µs | ~2.2 µs | ~2.0 µs | — |
| `find` `.*foo` no-match, 23 KiB | ~3.1 ms | ~0.8 µs | ~31 µs | — |
| `find` `[A-Z]+` no-match, 216 KiB | ~88 µs | ~4 µs | ~53 µs | — |
| `find` `\d{3}-\d{4}` no-match, 23 KiB | ~19 µs | ~2.0 µs | ~1.9 µs | — |
| `find` `(?m)^\w+`, 23 KiB | ~161 µs | ~7.3 µs | ~8.1 µs | — |
| `find` `(?m)\w+$` no-match, 23 KiB | ~490 µs | ~30 µs | ~31 µs | — |
| `find` `\w+\s+\w+`, 23 KiB | ~128 µs | ~20 µs (1.2 GiB/s) | ~27 µs | — |
| `find` large alternation (24 literals) no-match, 23 KiB | ~48 µs | ~7.4 µs (3.0 GiB/s) | ~11 µs | — |
| `find` `(?i)STRASSE` no-match, 23 KiB | ~15 µs | ~1.4 µs (16.2 GiB/s) | ~2.3 µs | — |
| `find` loop-exit no-match, 23 KiB | ~120 µs | ~4.7 µs | ~31.8 µs | — |
| `find` suffix no-match, 23 KiB | ~238 µs | ~14 µs | ~155 µs | — |
| `find` extended no-match, 23 KiB | ~275 µs | ~2.5 µs | — | — |
| `RegexSet`, 9 no-match patterns, 23 KiB | ~1.7 ms | ~40 µs | ~38 µs | — |
| `replaceAll` `a+`, 32 KiB | ~265 µs | ~64 µs (480 MiB/s) | ~96 µs | ~47 µs |
| `replaceAll` capture email `$2 <$1>`, 18 KiB | — | ~39 µs (~430 MiB/s) | ~84 µs (~200 MiB/s) | — |
| `replaceAll` word capture `[$1]`, 23 KiB | — | ~209 µs (~115 MiB/s) | ~723 µs (~33 MiB/s) | — |
| Compile xDS-like pattern | ~2.9 µs | ~3.1–3.9 µs | ~10.8 µs | ~61 ns† |
| Compile xDS-like (smp allocator) | — | ~1.5 µs | — | — |

\* Rust baseline omits the `\s+(?!\S)` branch because Rust `regex` has no
lookaround; the Node baseline uses the full pattern. The current same-host
Rust 1.13.1 reference for that branch-less equivalent is ~56 µs.

† Node's repeated `new RegExp` benchmark likely benefits from V8's compile
cache for identical sources.

Latest verification on a busy macOS host (2026-11): after flattening the
search-DFA transition tables, adding a capture-free `find` fast path,
replacing the Unicode hash map with a direct-mapped cache plus a fast UTF-8
decoder, adding a shared-prefix multi-literal prefilter, and determinizing
lookahead-free programs over UTF-8 bytes, full-pattern
Qwen search is ~47 µs (~508 MiB/s), CJK tokenizer search is ~164 µs
(~1.1 GiB/s) — both ahead of the same-host Rust reference — Han class scans
are ~125 µs (1.5 GiB/s, also ahead), greedy `\C+` scans collapse to a single full-span match (~8 ns), large
Unicode full matches scan at ~800 MiB/s, and extended full matches reuse a
persistent backtracking workspace (~17 ns for a backreference pattern), and
shared-prefix no-match scans are ~1.55 µs (15.5 GiB/s). A plain ASCII `set+`
search (`[a-z]+`, `\w+`, `\d+`, including single-rune sets like `a+`) now
scans runs directly instead of entering the DFA: ~18 µs on the 216 KiB Qwen
sample (1.3 GiB/s, 1.5× the DFA path and faster than the same-host Rust
reference at ~36 µs). The same shape full-matches through a 256-byte table:
ASCII class full matches run at ~4.0 GiB/s (~52 µs on 216 KiB, above the
same-host Rust reference at ~3.9 GiB/s) and short validation inputs pay ~7 ns
instead of a DFA call. Streaming runs stay deterministic: `[a-z]+` streams
at ~650 MiB/s, `[a-z]+ [a-z]+` at ~585 MiB/s, and the `set*` scan (which must
also report the empty matches between runs) at ~416 MiB/s, 6.9× faster than
the generic thread list. The streaming chain now shares the search-side
detector, so `set+ literal` shapes without a trailing run and multi-byte
separators stream directly: `\w+@` went from ~54 MiB/s to ~517 MiB/s and
`\w+ 12345` from ~53 MiB/s to ~532 MiB/s. The `RegexSet` DFA flattens its per-state ASCII
rows and accept masks into power-of-two-stride tables, taking the 9-pattern
no-match scan from ~63 µs to ~40 µs; up to 32 patterns also pack the
accept mask into the 64-bit transition entry, removing a dependent load.
Unbounded `x{min,}` repetitions with `min >= 1` now enter the loop body
directly instead of compiling a second mandatory copy, so programs are
smaller (`(?:[a-z0-9]+[ \n])+` 12 -> 9 instructions, `(?:foo|bar)+` 20 ->
13) and behaviorally equal DFA states stay merged (4 -> 3 for the ASCII
loop full match).
The bench gate now covers 37 cases;
`replaceAll` ~85 µs, compile ~1.5 µs with `smp_allocator`, and all
209 tests plus the V8/Rust/extended/replacement differential fuzzers pass. On the
feature side, PCRE2 forward numeric/named references, `\e` and isolated `\E`,
the full substitution reference syntax (`$<name>`, `$+`, `$_`, `` $` ``, `$'`),
`escape`/`splitn`/`replacen`, and compile diagnostics (`diagnose`) are covered.
Treat absolute numbers as host-noise-sensitive; the bench gate compares ratios
against `tools/bench/baseline.json`.

Where the remaining time goes:

- **Multi-literal prefilters**: wide start-literal alternations now use an
  exact two-byte absence bitmap (`PairSet`): the 24-literal sample dropped
  from ~48 µs to ~7.4 µs, ahead of the same-host Rust reference (~11 µs).
  The scan is still one byte at a time; a Teddy-style SIMD prefilter could
  reach the ~15 GiB/s of the first-byte path. Case-folded literals now use a
  SIMD scan for the rarest folded byte pair of the whole-pattern literal
  (`(?i)STRASSE` dropped from ~29 µs to ~1.4 µs on English text, ahead of
  the same-host Rust reference at ~2.3 µs); non-ASCII bytes stay
  conservative so Unicode fold peers like U+017F still verify through the
  engine.
- **One-shot boolean match** now reuses a persistent workspace/DFA, but the
  lazy DFA still starts cold for each new `Regex`. Precomputing a DFA for
  small programs would remove the first-call construction cost.
- **Search** uses the priority search DFA for linear programs (Qwen now
  exceeds 200 MiB/s). Lookahead-free programs are determinized over bytes:
  each rune set compiles to a UTF-8 automaton (`utf8_set.zig`) and a scan is
  one flat table lookup per byte, which removed the per-rune decode + binary
  search that dominated `\p{Han}+`. A dedicated `set+` fast path expands
  the same automaton into 256-entry transition rows, and a per-state front
  cache keeps the hot rune transitions in L1, so the Han class scan runs
  ahead of the same-host Rust reference. Tokenizer alternations get a
  dominant-branch scan (`fast_branch.zig`): when the byte at the search
  start cannot begin an earlier branch, the `set? setB+` branch alone
  decides the match and a dedicated UTF-8 run scan replaces the DFA. The
  Qwen and CJK tokenizer searches now run ahead of the same-host Rust
  reference (~508 MiB/s vs ~400 MiB/s and ~1.1 GiB/s vs ~900 MiB/s).
  Capture programs take DFA bounds and replay only the
  matched slice, which removes the failed-start scans that dominated patterns
  like `(\w+)@(\w+)`. Interpreter fallbacks with a multi-byte required
  literal run one literal prefilter, so no-match scans of patterns like
  `[a-z]*(?:foo|bar)` are ~25x faster. Running the required-literal absence
  check before the DFA was evaluated and reverted: it regressed shared-prefix
  scans (1.55 µs -> 19.7 µs) because the start-literal MultiFilter is cheaper,
  and it does not help when the literal occurs somewhere in the input. Loops whose exits can compete with
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
   across chunks for non-extended, rune-based programs. The simple set and
   chain paths now use 256-byte membership tables for ASCII sets ([a-z]+
   1.3 GiB/s, [a-z]* 1.1 GiB/s, chain 757 MiB/s). A UTF-8-automaton chain
   scan for non-ASCII runs (Han chain) was implemented and reverted: the
   per-rune automaton probe measured ~2.2x slower than decode + range
   search because the separator punctuation forces a full-rune skip that
   the automaton cannot reuse.
3. ~~**`\C` in DFA/Pike**~~: done. Programs with `\C` force the DFA byte
   construction, where the escape is an any-byte transition; the Pike VM
   steps one byte for `\C`, so capture programs keep the linear path.

### P0 — largest linear performance gaps

5. ~~**Capture-aware Pike VM** (`pike.zig`)~~: done. Threads carry capture
   slots, so `linear_fallback` (default true) resolves ordinary capture
   programs in linear time with exact group boundaries.
6. **DFA-backed leftmost search** (`execute.zig`, `compile.zig`): the
   priority-annotated lazy search DFA (`search_dfa.zig`) now covers linear
   programs including capture programs (bounds from the DFA, slots replayed
   on the matched slice). Flattening the state transition tables lifted Qwen
   tokenizer search to ~330 MiB/s, against a same-host Rust reference of
   ~427 MiB/s. Lookahead-free programs with non-ASCII sets are determinized
   over UTF-8 bytes (`utf8_set.zig`), taking `\p{Han}+` from ~635 µs to
   ~173–200 µs. A dedicated `set+` fast path now expands the same automaton
   into 256-entry transition rows and scans one table load per byte, which
   brought the Han class scan to ~125 µs, ahead of the same-host Rust
   reference (~157–169 µs). The CJK tokenizer is now ~1.05x the same-host
   Rust reference after the byte-keyed transition cache and inlined
   start-state lookup, so the remaining gap is per-transition cost rather
   than per-start restart overhead. Match-dense capture searches are no longer the largest gap:
   `(\w+)@(\w+)\.com` over repeated `user.name@example.com` runs scans for
   the separator and derives both run boundaries directly, at ~11 µs for the
   18 KiB sample against ~29 µs for the same-host Rust reference (2.6x
   faster), and the no-match form `(\p{L}+)@(\p{L}+)` is ~2.2 µs against
   ~2.0 µs. The shape detector (`shapes.zig`) recognizes
   `setA{min,} separator setB{min,} tail` (fixed counts such as
   `\d{3}-\d{4}` and set-run separators such as `\w+\s+\w+` included),
   requires the separator to end the first run and the tail to end the
   second, and reports the capture slots directly. The per-byte chain scans
   now use cached 256-byte membership tables instead of rune-range probes,
   so `\w+\s+\w+` went from ~128 µs to ~20 µs, ahead of the same-host Rust
   reference (~27 µs).
   The first-byte prefilter also matches contiguous ASCII ranges with vector
   compares (up to four runs), so class scans like `[A-Z]+` skip 16 bytes at
   a time: the no-match scan dropped from ~88 µs to ~4 µs, and `\d{3}-\d{4}`
   from ~19 µs to ~10 µs. The chain detector now also accepts
   `setA+ literal` without a trailing run (`\w+@`, `\d+-`, `\w+ 12345`),
   and a mandatory `\A`/`^` at the body start makes searches past offset zero
   return immediately (`^Hello` 3.8 µs -> 23 ns). Required-literal scans use
   the SIMD byte scan (`.*foo` 8.5 -> 4.1 µs, `\w*foo` 6.6 -> 4.2 µs), and
   two-byte literals use a SIMD pair scan (`((a)(b))+` no-match 4.5 us ->
   0.7 us, against ~0.5 us for the same-host Rust reference).
   `extractCaptures` also tries a deterministic replay for straight-line
   programs of saves, literals, and forced greedy runs, which took the email
   benchmark from ~68 µs to ~42 µs before the chain path; shapes that need
   backtracking (`(a+)ab`, adjacent runs, loops with competing exits) still
   use the VM. Nullable-prefix searches (`.*foo`, `.*?end`) used to restart
   the engine at every position: `.*foo` with the literal absent took
   ~3.1 ms on the 22 KiB sample. Two fixes: a required-literal absence scan
   now runs before the DFA when the first set covers most of the alphabet
   (`.*foo` -> ~8 µs, `\w*foo` -> ~7 µs), and a failed interpreter search
   over a single-set prefix loop advances to the run end instead of one
   rune (`.*?end` with the literal present but no match -> ~190 µs from
   ~6.9 ms; the Rust reference is ~31 µs because its unanchored DFA finds
   the end in one pass). Programs whose only unbounded loops are lazy now
   run on the search DFA with first-accept tie-breaking (greedy loops keep
   last-accept ties), so `.*?end` drops further to ~42 µs and `a.*?b` runs
   on the DFA as well. The full-match ASCII table now stores pre-multiplied row
   offsets (`state * 128`) instead of state ids, which removes the shift from
   the dependent-load address chain: `(?:[a-z0-9]+[ \n])+` went from ~373 µs
   to ~311 µs (1.40 ns/byte) against ~273 µs (1.25 ns/byte) for the
   same-host Rust reference, so the gap is ~1.12x. A flat probe confirms the
   row-offset form beats the state-id form (1.17 vs 1.41 ns/byte); the rest
   is engine selection, most likely Rust's one-pass DFA. Four further
   attempts to reach the probe's 1.17 ns/byte in the real DFA were measured
   and reverted: 16-bit table entries, a pre-reserved table with a cached
   base pointer, the canonical `while (...) : (offset += 1)` form, and
   splitting the sentinel path out of the inner loop. Each stayed at
   ~1.40 ns/byte, so the overhead is not the element width, pointer reload,
   loop shape, or the in-loop call. ASCII-only programs
   also use 256-entry rows with the high half pre-filled dead, so their scan
   needs no `byte < 0x80` branch or rune decoding: short full-match DFA
   inputs (`[A-Za-z0-9._-]+`, xDS-like) improved by ~8-10%. Applying the same
   row-offset encoding to the byte-mode *search* DFA was evaluated and
   reverted: the Han scan measured the same within noise and the table would
   double in size. ASCII byte classes for the rune-mode tables were also
   tried and reverted: the smaller rows did not pay for the extra class load
   and runtime row shift (Qwen ~8% slower, CJK ~20% slower). Two rune-DFA accept-path experiments were also reverted:
   a separate accept-flag table (no win, one extra load) and branchless
   accept recording with conditional moves (Qwen regressed ~7%, so the
   predictable accept branch is cheaper than per-byte cmovs). The Qwen scan
   is ~10 cycles/byte against ~9 for the same-host Rust reference, so the
   remaining gap is the dependent state chain rather than a specific load or
   branch. Remaining:
   byte-level lookahead gating (Qwen's `(?!\S)`), iteration-aware priorities
   for loops whose exits compete with later choices, and closing the last few
   percent. An
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
continuation always accepts, the priority-annotated search DFA for
capture-free alternation/optional/simple-loop/set-lookahead programs, the
UTF-8 byte determinization for lookahead-free non-ASCII programs, and the
single-record greedy `\C` loop scan. A multi-way
alternation dispatch table was implemented and benchmarked but is disabled
(`alternation_dispatch = false`): the split + first-byte-skip chain is faster
on the tokenizer and xDS workloads.

### P1 — API and semantics

9. ~~**Capture semantics controls**~~: done. `Limits.capture_reset` selects
   JavaScript-style reset between iterations; the default remains
   PCRE2/Rust/Perl semantics.
10. ~~**`Program` ownership**~~: done. `compileOwned` returns an
    `OwnedProgram` with an internal arena and a `deinit`; `compile` keeps the
    documented caller-arena contract.
11. ~~**Compile diagnostics**~~: done. `diagnose` reports the byte offset and
    kind (`syntax`, `unsupported`, `limit`) where a pattern failed to compile.

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
    (`tools/fuzz/run.py`) and the extended engine
    (`tools/fuzz/extended.py`) including captures, `capture_reset`, and
    `unset_backref_empty`. A three-way Rust `regex` 1.13 / Node / regexz
    harness (`tools/fuzz/rust.py`) adds tens of thousands of comparisons
    per run; Node is the semantic arbiter for the few ambiguous alternation
    cases where Rust's DFA differs from PCRE2/Perl. A replacement harness
    (`tools/fuzz/replace.py`) diffs `replaceAll` output against V8.
    Benchmark regression gating is in place via `tools/bench/check.py`
    against `tools/bench/baseline.json`, and
    `.github/workflows/ci.yml` runs format, tests, a bench smoke, and a
    fuzz smoke on every push. Extending to PCRE2 and RE2 remains (no PCRE2
    toolchain is available in the current environment).
16. ~~**`RegexSet` single-pass DFA**~~: done (`set_dfa.zig`). Patterns without
    assertions or extended features share one unanchored subset construction;
    the rest stay on their per-pattern engines.

## 5. Target metrics

For the workloads in `tools/bench/main.zig`, on an idle host:

- Full match, short literal/class/xDS patterns: **≤ 40 ns** one-shot
  (achieved: ~8–17 ns).
- Full match, reused workspace: **≤ 20 ns** for ASCII class patterns
  (achieved: ~8 ns).
- Qwen tokenizer search: **≥ 200 MiB/s** (achieved: ~508 MiB/s).
- `replaceAll` `a+`: **≥ 400 MiB/s** (achieved: ~442 MiB/s).
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
