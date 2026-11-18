# regexz

Bounded regular-expression engine with a **linear RE2-style core** and an
**extended PCRE-style backtracking mode**. Extracted from the xDS safe-regex
implementation in `netz` so it can be reused independently of gRPC/xDS.

The engine picks the execution strategy automatically:

- **Linear mode** for RE2-compatible patterns: Thompson NFA, lazy full-match
  DFA, a priority-annotated lazy search DFA for capture-free alternation/
  optional/lookahead programs, exact literal fast path, and a capture-aware
  Pike VM for linear-time fallback searches.
- **Extended mode** for patterns using general lookaround, backreferences,
  atomic groups, possessive quantifiers, conditionals, recursion, `\K`, `\G`,
  or UCP word boundaries: bounded backtracking VM with step, choice, trail,
  and recursion-depth limits.

## Features

- RE2-style syntax subset with explicit limits for program size, states,
  instructions, and replacement expansion.
- Linear-time boolean full matching:
  - Thompson NFA with deduplicated epsilon closures.
  - Exact-literal fast path (`Program.literal`) for plain literal patterns.
  - Single-rune literal instructions for ASCII and non-ASCII literals.
  - Greedy single-set loops compile to a counting `star` instruction, so
    runs backtrack by position instead of storing one choice per character.
  - Compile-time first-byte summaries skip impossible alternation branches
    and impossible search start positions.
  - SIMD first-byte prefilter for small selective start sets (multi-literal
    alternations), with the bitmap byte loop as fallback.
  - Compile-time required-literal extraction: patterns whose every match must
    contain a multi-byte literal (for example `[a-z]*(?:foo|bar)`) scan for
    that literal before entering the VM, turning no-match scans into one
    literal pass.
  - Bounded lazy DFA cache for repeated matching of programs without
    assertions, lookahead, or `\C`.
  - Priority-annotated search DFA for leftmost-first search. It handles
    alternation, optional, simple greedy loops, set-lookahead, and capture
    programs (the DFA locates bounds; the winning path is replayed on the
    matched slice to fill slots). Loops whose exits can compete with later
    choices (including lazy loops with consuming exits) stay on the
    interpreter, which guarantees identical semantics.
- Compile-time materialization of `(?i)` folding and set negation, so runtime
  set membership is one binary search.
- Set-lookahead `(?=set)` / `(?!set)` stays on the linear path when the body is
  a single set atom.
- Extended features:
  - General lookahead and lookbehind: `(?=...)`, `(?!...)`, `(?<=...)`,
    `(?<!...)` (variable-length lookbehind is supported and budgeted), with
    PCRE2 alphabetic synonyms `(*pla:...)`, `(*nla:...)`, `(*plb:...)`, and
    `(*nlb:...)`.
  - Non-atomic positive lookaround `(?*...)` and `(?<*...)` (also
    `(*napla:...)`/`(*naplb:...)`): the engine can backtrack into the
    assertion when the continuation fails.
  - Script-run assertions `(*sr:...)`/`(*script_run:...)` and atomic
    `(*asr:...)`/`(*atomic_script_run:...)`, following UAX #24/UTS #39:
    `Script_Extensions` intersection, Han virtual scripts, and a single
    decimal-digit set.
  - Scan-substring assertions `(*scs:(list)...)`/`(*scan_substring:...)`:
    match a subpattern against the first participating group in the list,
    anchored at the substring start with the subject end temporarily reset.
  - Numeric and named backreferences: `\1`..`\99`, `\k<name>`, `\k'name'`,
    `\k{name}`, `\g{name}`, `\g{1}`, relative `\g{-1}`, `(?P=name)`;
    backreferences follow the caseless flag active at the reference site.
    Forward references resolve against the final group count, as in PCRE2.
  - Subroutine calls by number, name, and relative offset: `(?1)`, `(?+1)`,
    `(?-1)`, `\g<1>`, `\g<-1>`, `\g<+1>`, `\g<name>`, `(?&name)`,
    `(?P>name)`. Named calls may refer to groups defined later.
  - Named captures: `(?P<name>...)`, `(?<name>...)`, `(?'name'...)`;
    UTF-mode names may use Unicode letters and digits. Query them with
    `Program.groupIndex`/`groupName` and `Regex.groupIndex`/`groupName`.
  - Atomic groups `(?>...)` and possessive quantifiers `*+`, `++`, `?+`,
    `{n,m}+`.
  - Conditionals on group participation or assertions:
    `(?(1)yes|no)`, `(?(<name>)yes|no)`, `(?(?=...)yes|no)`,
    `(?(?<=...)yes|no)`, recursion conditions `(?(R))`, `(?(R1))`,
    `(?(R&name))`, `(?(VERSION>=10.45)yes|no)`, undelimited `(?(name)...)`,
    and `(?(DEFINE)...)` definition blocks; duplicate names are tested in
    pattern order for backreferences and conditions.
  - Branch reset `(?|...)` with shared capture numbers across alternatives.
  - Duplicate group names with `(?J)`.
  - Recursion and subroutine calls: `(?R)`, `(?0)`, `(?1)`, `(?+1)`,
    `(?-1)`, `(?&name)`, `(?P>name)`, `\g<name>`, with a recursion-depth
    limit.
  - Leftmost-longest (POSIX) search/replace via `Limits.longest`.
  - `\X` extended grapheme clusters (UAX #29, Unicode 17.0.0 data).
  - `\K` (reset match start), `\G` (start of the current match attempt),
    `\Z` (end or before a final newline).
  - Backtracking control verbs: `(*FAIL)`, `(*ACCEPT)`, `(*PRUNE)`,
    `(*SKIP)`/`(*SKIP:name)` (resume at the last matching mark),
    `(*COMMIT)`, `(*THEN)`. `(*MARK:name)` records the last mark on
    the successful path and exposes it as `Match.mark`; `(*UCP)` and `(*UTF)`
    are accepted as directives.
  - Callouts `(?C)`, `(?C1)`..`(?C65535)`, `(?C"name")`, `(?C{name})`, and
    `(?C'name')` invoke `Limits.callout` with a `CalloutSpec` and the current
    byte offset; returning `.fail` abandons the current path.
  - `Limits.auto_callout` inserts callout 255 before consuming atoms
    (PCRE2-style auto-callouts; the compiler-level insertion is approximate
    for quantified atoms).
  - UAX #29 boundary assertions: grapheme cluster `\b{gcb}` / `\B{gcb}`
    (alias `\b{g}`), word boundaries `\b{wb}` / `\B{wb}`, and sentence
    boundaries `\b{sb}` / `\B{sb}`, evaluated by the extended engine.
    Oniguruma/Java-style word-start/end variants `\b{start}`, `\b{end}`, and
    `\b{startend}` are also supported (ASCII or UCP word sets).
  - `\R` (atomic newline sequence), `\N` (not newline), `\N{U+hhhh}`
    (explicit code point), `\N{NAME}` (Unicode character name; explicit names
    plus algorithmic CJK, Hangul, Tangut, Khitan, Nushu, Egyptian, and
    Anatolian names), `\h`/`\H` (horizontal whitespace), `\cX`
    (control characters), `\o{...}` (octal code points), and `[\b]`
    (backspace inside classes).
  - Extended mode `(?x)` with whitespace and `#` comments outside classes.
  - Ungreedy mode `(?U)` and no-auto-capture mode `(?n)`, including scoped
    `(?U:...)`, `(?-U:...)`, `(?n:...)`, and `(?-n:...)` forms.
  - PCRE2 `(?^)` option reset, plus the `(*NO_START_OPT)`,
    `(*NO_AUTO_POSSESS)`, and `(*NO_DOTSTAR_ANCHOR)` start-up directives.
  - `(?xx)` extended-more classes (space and tab ignored inside classes) and
    ASCII option letters `(?aD)`, `(?aS)`, `(?aW)`, `(?aP)`, `(?aT)`, and
    `(?a)` under UCP.
  - Newline conventions `(*CR)`, `(*LF)`, `(*CRLF)`, `(*ANYCRLF)`, `(*ANY)`,
    and `(*NUL)`, which drive `^`, `$`, `\Z`, dot, and bare `\N`; `\R` is
    controlled separately by `(*BSR_ANYCRLF)`/`(*BSR_UNICODE)`.
  - Empty-match locks `(*NOTEMPTY)` and `(*NOTEMPTY_ATSTART)`, and pattern
    resource caps `(*LIMIT_MATCH=...)`, `(*LIMIT_DEPTH=...)`
    (alias `(*LIMIT_RECURSION=...)`), and `(*LIMIT_HEAP=...)`.
  - Character-class set operations `&&`, `--`, and `~~`, including nested
    classes such as `[a-z&&[^aeiou]]`.
  - POSIX classes `[[:alpha:]]`, `[[:digit:]]`, `[[:word:]]`, ...; under UCP
    they follow PCRE2's Unicode replacements (including fullwidth `xdigit`),
    and `(?aP)`/`(?aT)` restore ASCII behavior.
  - UCP `\d`/`\w`/`\s` and Unicode `\b`/`\B` via
    `Limits.unicode_perl_classes`; property aliases such as
    `\p{Script=Greek}`, `\p{sc=Greek}`, `\p{gc=Nd}`, `\p{IsGreek}`,
    and `Script_Extensions` via `\p{scx=Hiragana}` or ISO codes such as
    `\p{scx=Hira}`.
  - `Bidi_Class` properties `\p{Bidi_Class:AL}`/`\p{BC:R}` with PCRE2's
    23 short class names.
  - 63 binary Unicode properties such as `\p{Alphabetic}`,
    `\p{White_Space}`, `\p{Emoji}`, `\p{Extended_Pictographic}`,
    `\p{Lowercase}`, `\p{Hex_Digit}`, `\p{ID_Start}`, plus PCRE2 special
    properties `\p{Xan}`, `\p{Xwd}`, `\p{Xps}`, `\p{Xsp}`, `\p{Xuc}`,
    plus `\p{ASCII}`, `\p{Cn}` (unassigned), and `\p{Assigned}`.
  - Case-insensitive matching uses simple Unicode case folding; Unicode 17
    `CaseFolding.txt` pairs missing from RE2's pinned tables are supplemented.
    `(?r)`/`(*CASELESS_RESTRICT)` restrict folding to ASCII, and `(*TURKISH_CASING)` enables
    Turkish/Azeri `i`/`İ` and `I`/`ı` pairing.
  - Unicode blocks: `\p{InBasic_Latin}`, `\p{InGreek}`, `\p{InEmoticons}`,
    `\p{Block=Basic_Latin}` (underscores are optional and case-insensitive).
  - Unicode string properties: `\p{RGI_Emoji}` (all RGI sequences) plus
    `\p{Basic_Emoji}`, `\p{Emoji_Keycap_Sequence}`,
    `\p{RGI_Emoji_Flag_Sequence}`, `\p{RGI_Emoji_Tag_Sequence}`,
    `\p{RGI_Emoji_Modifier_Sequence}`, and `\p{RGI_Emoji_ZWJ_Sequence}`.
    These are sequence atoms and run on the extended engine.
  - PCRE2 `\v`/`\V` vertical whitespace via
    `Limits.pcre_vertical_whitespace`; the default remains RE2/Go vertical
    tab for `\v`.
- Replacement:
  - Non-extended capture programs use a bounded backtracking VM first; when
    its work budget is exhausted they automatically retry on the
    capture-aware Pike VM (`Limits.linear_fallback`, default true). The Pike
    VM returns exact group boundaries in O(input × program) time, preserving
    the RE2-style linear-time guarantee.
  - Set `Limits.linear_fallback = false` to keep the backtracking budget
    fail-closed. Extended programs (lookaround, backreferences, ...) remain
    fail-closed in all configurations.
  - Substitution syntax supports both RE2 `\0`..`\9`/`\\` and `$0`..`$99`,
    `$&`, `$$`, `${name}`, `$<name>`, and PCRE2/Perl `$`` (before), `$'`
    (after), `$+` (highest captured group), `$_` (whole input), plus PCRE2
    case transforms `\U`, `\L`, `\E`,
    `\u`, and `\l` (simple Unicode case mapping by default). Set
    `Limits.full_case_mapping = true` to use full SpecialCasing mappings such
    as `ß` -> `SS` and `İ` -> `i̇`.
- API:
  - Full match: `Regex.matches`.
  - Partial match: `Regex.isMatch` and `Regex.partialMatch` (full/partial/
    none for both linear and extended programs; assertion-sensitive prefixes
    are approximated conservatively).
  - Capture-aware search: `Regex.find`/`findFrom` with a reusable `Captures`
    buffer.
  - Iteration and splitting: `Regex.findAll`, `Regex.split`, `Regex.splitn`
    (limited parts).
  - Multi-pattern matching: `RegexSet` compiles independent patterns and
    reports which match anywhere in the input via `matches`/`matchesAt`,
    `isMatch`, or `matchIndices`, and exposes the original patterns via
    `patterns`. Eligible patterns share one unanchored DFA
    scan; patterns with assertions or extended features stay on their
    per-pattern engines.
  - Replacement: `Regex.replaceAll`, `Regex.replacen` (limited matches),
    `Regex.expandMatch` (expand a template for one match), and
    `ReplaceWorkspace`. Dynamic
    replacement via `Regex.replaceAllWithFn` /
    `ReplaceWorkspace.replaceAllWithFn` passes each match and its capture
    slots to a callback that returns allocator-owned replacement bytes.
  - Streaming: `StreamScanner` feeds chunks and emits non-overlapping
    leftmost-first matches with absolute capture offsets. It persists NFA
    state across chunks, evaluates lookahead/assertions and UTF-8 boundaries
    exactly, and keeps memory bounded by the longest pending match.
  - Compiled-program serialization: `Program.serialize` /
    `Program.deserialize` use a versioned, validated binary format for
    cross-process caches. Deserialize into an arena and keep it alive for the
    program's lifetime.
  - Compile diagnostics: `diagnose` reports the byte offset and kind
    (`syntax`, `unsupported`, `limit`) where a pattern failed to compile.
  - Pattern escaping: `escape` turns a literal string into a pattern that
    matches it.
- Caller-owned compilation: `compile` writes into the allocator you provide;
  `Regex` keeps an internal arena.
- Reusable workspaces (`Workspace`, `ReplaceWorkspace`) for matching and
  substitution without per-call program compilation.
- Bounded Unicode class data generated from a pinned RE2 revision and
  Unicode 17.0.0 UCD files (`tools/codegen/generate.py`), including simple
  upper/lower case mappings.
- No dependency on `netz`; only the Zig standard library.

## Usage

```zig
const regexz = @import("regexz");

var value = try regexz.Regex.init(allocator, "a+b", .{});
defer value.deinit();
try std.testing.expect(try value.matches(allocator, "aaab"));
try std.testing.expect(try value.isMatch(allocator, "xxaaabyy"));

var workspace = try regexz.Workspace.init(allocator, value.program);
defer workspace.deinit();
try std.testing.expect(workspace.matches(value.program, "ab"));

// Allocation-free hot path for repeated matching.
try std.testing.expect(value.matchesWithWorkspace(&workspace, "ab"));
```

`matches` is a **full match**: the whole input must be consumed. Use
`isMatch`/`find`/`ReplaceWorkspace.find` for search.

Capture-aware search:

```zig
var value = try regexz.Regex.init(allocator, "(?P<year>\\d{4})-(?P<month>\\d{2})", .{});
defer value.deinit();
var captures = try regexz.Captures.init(allocator, value.program);
defer captures.deinit(allocator);
if (try value.find(allocator, "x2026-11y", &captures)) |match| {
    // match.group(input, 1) == "2026"
    // captures.group(input, 2) == "11"
}
```

Replacement:

```zig
var replace = try regexz.ReplaceWorkspace.init(allocator, value.program, .{});
defer replace.deinit();
const output = try replace.replaceAll("x2026-11y", "${month}/${year}");
defer allocator.free(output);
```

Streaming search:

```zig
fn emit(context: ?*anyopaque, match: regexz.StreamMatch) void {
    // match.start/end and match.slots are absolute stream offsets.
    _ = context;
}

var scanner = try regexz.StreamScanner.init(allocator, value.program, .{});
defer scanner.deinit();
try scanner.feed("Hello, ", null, emit);
try scanner.feed("world!", null, emit);
try scanner.finish(null, emit);
```

A `Workspace`/`ReplaceWorkspace`/`StreamScanner` is bound to the program it
was initialized with and must not be shared between threads. `Match.slots` points into the
workspace (or the caller's `Captures` buffer) and is valid until the next
find call.

## Build and test

```sh
python3 tools/check.py               # full local gate: fmt, tests, codegen, differential fuzz
python3 tools/check.py --bench       # also enforce the benchmark baseline
python3 tools/check.py --fuzz 100 --skip-codegen
zig build test
zig build test-lib -Dtest-filter="..."
zig build bench -Doptimize=ReleaseFast
python3 tools/bench/check.py         # compare against tools/bench/baseline.json (--update to refresh)
python3 tools/fuzz/run.py            # fuzz full match, find spans, and captures against V8
python3 tools/fuzz/extended.py       # fuzz lookaround/backref/capture semantics against V8
python3 tools/fuzz/replace.py        # fuzz replacement expansion against V8
python3 tools/fuzz/rust.py           # three-way Rust regex / Node / regexz differential
python3 tools/codegen/generate.py --verify
```

## Performance

`zig build bench -Doptimize=ReleaseFast` measures compile, full-match,
search, and replacement throughput. Representative relative results from a
busy Apple Silicon host (absolute numbers vary with load):

| Case | Before | After |
| --- | ---: | ---: |
| `Regex.matches`, 13-byte literal | ~3.6 µs | ~1.6 ns |
| `Regex.matches`, class pattern | ~3.7 µs | ~9 ns |
| `Regex.matches`, xDS-like pattern | ~3.6 µs | ~15 ns |
| Reused workspace, class pattern | ~171 ns | ~8 ns |
| Reused workspace, xDS-like pattern | ~233 ns | ~16 ns |
| Reused workspace, `(?i)` literal | ~72 ns | ~5 ns |
| Qwen tokenizer `find` (22 KiB) | ~842 µs | ~68 µs (350 MiB/s) |
| CJK tokenizer `find` (191 KiB) | — | ~200–230 µs (~850–980 MiB/s) |
| `\p{Han}+` class scan (191 KiB) | ~635 µs | ~173–200 µs (~940–1080 MiB/s) |
| Full match, Han class (191 KiB) | — | ~204 µs (~800 MiB/s) |
| Full match, ASCII class (216 KiB) | — | ~78 µs (~2.7 GiB/s) |
| Full match, ASCII loop (216 KiB) | — | ~376 µs (~555 MiB/s) |
| `replaceAll` `a+` (32 KiB) | ~265 µs | ~64 µs |
| `find` literal after a 4 KiB prefix | — | ~55 ns |
| `find` xDS-like after a 4 KiB prefix | — | ~94 ns |
| `find` multi-literal after a 4 KiB prefix | ~2.0 µs | ~0.22 µs |
| `find` capture email tokens (18 KiB) | ~161 µs | ~68 µs |
| `find` capture no-match scan (23 KiB) | ~617 µs | ~66 µs |
| `find` loop-exit no-match (23 KiB) | ~120 µs | ~4.7 µs |
| `find` suffix no-match (23 KiB) | ~238 µs | ~14 µs |
| `find` extended no-match (23 KiB) | ~275 µs | ~2.5 µs |
| `RegexSet`, 9 no-match patterns (23 KiB) | ~1.7 ms | ~63 µs |
| Compile xDS-like pattern | ~2.9 µs | ~3.1–3.9 µs |
| Compile xDS-like (smp allocator) | — | ~1.5 µs |

`Regex` now owns a persistent workspace and lazy-DFA cache (guarded by a
spin mutex), so repeated `matches`/`find`/`isMatch` calls do not rebuild
matching state. Small patterns compile into a single fixed block, avoiding
the arena's multiple page allocations. The linear full-match workspace uses
`u32` instruction/epoch arrays (44 bytes per instruction). Sets carry a 128-bit ASCII membership bitmap, the VM binds
instruction payloads by reference, greedy single-set loops scan without
per-character choice records, and search uses literal/prefix prefilters, a
workspace-cached SIMD first-byte prefilter for small selective sets, a
compile-time required-literal prefilter (also used by extended fallbacks),
and a `memchr`-based literal fast path. Capture programs use the same search DFA for match bounds and replay
only the matched slice to recover groups.

For external context on the same host and load, Rust `regex` 1.13 full-matches
these short patterns in ~8–11 ns and Node 26 in ~9–14 ns. The Qwen search
takes ~67 µs in Rust (without the lookahead branch) and ~195 µs in Node; the
`replaceAll` case takes ~91 µs in Rust and ~47 µs in Node. The remaining gap
to Rust is the fully dynamic leftmost-first DFA needed for loops whose exits
compete with later choices; capture programs use DFA bounds plus a short
replay (with backtracking/Pike fallback) and the Pike VM remains the
linear-time guarantee; see [docs/roadmap.md](docs/roadmap.md).

Extended patterns intentionally trade the linear guarantee for feature
coverage. They still have hard step, choice, capture-trail, and
recursion-depth limits and fail closed with `error.RegexLimitExceeded`.

## Limits and intentional omissions

- Backreferences and general lookaround are only available in extended mode;
  patterns using them cannot use the DFA/Pike linear paths.
- `StreamScanner` covers non-extended, rune-based programs. Extended
  patterns (lookaround, backreferences, ...) and `\C` return
  `UnsupportedRegexFeature`.
- `partialMatch` evaluates positive lookaheads at EOF as partial when a
  future rune could satisfy them; other zero-width assertions remain
  conservative.
- Character-class set operations follow the Rust `regex` spelling; patterns
  that use `&&`, `--`, or `~~` as literal class characters must escape them.
- `\v` defaults to vertical tab (RE2/Go compatibility); set
  `Limits.pcre_vertical_whitespace` for PCRE2 vertical-whitespace semantics.
- Replacement references groups `\0`..`\9` (RE2), `$0`..`$99`,
  `${name}`/`$<name>`, `$&`, `$$`, and the PCRE2/Perl `$+`, `$_`, `$``, `$'`
  forms.
- UCP applies to `\s` only when `unicode_perl_space` is set, or to
  `\d`/`\w`/`\s` and word boundaries when `unicode_perl_classes` is set.
- Invalid UTF-8 bytes are not decoded as U+FFFD; only `\C` can consume them.
- PCRE2 `(*NOTEMPTY)`/`(*NOTEMPTY_ATSTART)` are supported in full-match,
  search, replace, and streaming paths; `\C` still uses the interpreter.
- `(*LIMIT_HEAP=...)` is enforced as a cap on backtracking choices and
  capture-trail entries (64-byte units), not exact byte accounting.
- `\x{D800}`–`\x{DFFF}` parse but can never match, because inputs are decoded
  as Unicode scalar values.
- Lookbehind is evaluated by scanning start positions, so it is O(n) per
  position and bounded by the execution-step budget.
- Capture semantics for repeated groups keep the last participating value
  (PCRE2/Rust/Perl style) by default; set `Limits.capture_reset = true` for
  JavaScript-style reset-to-undefined between iterations.
- A backreference to an unset group fails by default (PCRE2/Perl/Rust); set
  `Limits.unset_backref_empty = true` for PCRE2's
  `PCRE2_MATCH_UNSET_BACKREF` / JavaScript behavior (empty match).
- `compile` has no `Program.deinit`; its `gpa` must be an arena (or outlive
  the program and be released as a whole). `Regex.init` manages its own arena.
  `Program.deserialize` follows the same arena contract.
- `\Q...\E` is handled before parsing; quoted class metacharacters
  (including `-`) are escaped.

## Provenance

The engine and Unicode scripts/categories were moved from `netz`
(`src/grpc/xds/routing/regex` and `src/grpc/xds/routing/regex.zig`). The
generated RE2 tables remain covered by the RE2 BSD license in
`src/regex/unicode/LICENSE.re2`. Grapheme-cluster, binary-property, and
script-run tables are generated from Unicode 17.0.0 UCD data (emoji sequence
data from 16.0) by `tools/codegen/generate.py`; the pinned source hashes are
recorded in `src/regex/unicode/source.json`.

## License

MIT. See `LICENSE`.
