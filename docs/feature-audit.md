# Feature audit against PCRE2 10.45

This document records the feature-completeness audit requested after the
performance campaign. The baseline is **PCRE2 10.45**, the release whose
feature level the parser targets, not Rust `regex` (which deliberately omits
lookaround, backreferences, recursion, and conditionals).

## Method

The audit is differential, not a checklist:

- `tools/compare/pcre2_diff.zig` links regexz and a locally built PCRE2 10.45
  and runs the same curated battery through both engines.
- For every case it compares compile success, the first-match span, every
  capture slot, the last `(*MARK)` name, and (for `findAll` rows) the whole
  span sequence.
- PCRE2 is compiled with `PCRE2_UTF`; UCP is enabled with inline `(*UCP)`.
  UTS#18 class-set rows add `PCRE2_ALT_EXTENDED_CLASS`, which is how PCRE2
  10.45 enables that syntax.
- Rows are classified as **match**, **extension** (regexz accepts a construct
  PCRE2 rejects or interprets differently by design), or **limit**
  (configurable resource cap).

Build the oracle and run the battery:

```sh
curl -L -o /tmp/pcre2-10.45.tar.gz \
  https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.gz
tar -C /tmp -xzf /tmp/pcre2-10.45.tar.gz
cd /tmp/pcre2-10.45 && ./configure --prefix=/tmp/pcre2-10.45-install \
  --enable-jit --enable-pcre2-8 --disable-shared --disable-pcre2-16 \
  --disable-pcre2-32 && make -j"$(nproc)" && make install
cd /home/passchaos/project-z/regexz
zig build-exe -O ReleaseFast -lc \
  -I/tmp/pcre2-10.45-install/include \
  -L/tmp/pcre2-10.45-install/lib -lpcre2-8 \
  --dep regexz -Mroot=tools/compare/pcre2_diff.zig -Mregexz=src/root.zig \
  -femit-bin=/tmp/regexz-pcre2-diff
/tmp/regexz-pcre2-diff
```

## Result (2026-11-22)

```
=== 398 cases: 379 ok, 17 extensions, 2 limits,
    compile 0, span 0, captures 0, mark 0, findAll 0
```

The battery covers every section of the PCRE2 pattern documentation:
escapes, Perl/POSIX/property classes, quantifiers, groups and captures,
assertions (including non-atomic, script-run, and scan-substring), backrefs,
conditionals, recursion/subroutines, control verbs, newline conventions,
option letters, anchors, dot/`\N`, start-of-pattern directives, `findAll`,
full matching, and invalid-syntax agreement.

## Gaps found and fixed

The first run exposed real incompatibilities; all were fixed:

| Gap | Fix |
| --- | --- |
| `\p{L&}` alias rejected | `propertyAlias` maps `L&` to `Cased_Letter`/`LC` |
| `\p{ ^L }` whitespace before `^` rejected | trim the property name before and after `^` |
| `a{,3}` parsed as literals | `{,n}` is `{0,n}` (PCRE2 10.43+) |
| `a{ 2, 3 }` whitespace rejected | space/tab allowed just inside quantifier braces |
| `\x{ 41 }`, `\o{ 101 }` whitespace rejected | brace-space skipping in both parsers |
| `\g{ 1 }`, `\k{ x }`, `\N{ U+41 }` whitespace rejected | trim only the brace forms, matching PCRE2 |
| `a{1001}` rejected as invalid syntax | absolute bound is 65535; the default `max_repeat=1000` now reports `RegexLimitExceeded` and can be raised |
| Subroutine/recursion captures kept call values | captures set during a call revert on return, as PCRE2 documents |
| `(?(DEFINE)...)` group leaked a capture | fixed by the subroutine capture restoration |
| `(*ACCEPT)` left group 0/group ends unset | open captures are closed at the accepted position |
| `(*ACCEPT)` in a subroutine ended the whole match | it ends the subroutine and continues after the call |
| `(*ACCEPT)` could not be quantified | `(*ACCEPT)??` etc. compile and act on backtracking |
| `(?r)` disabled all non-ASCII folding | ASCII and non-ASCII case pairs stay separate (`é`/`É` fold, `k`/Kelvin do not) |
| `(?i)\p{Lt}` did not act as `LC` | caseless `Lu`/`Ll`/`Lt` use `LC` (PCRE2 10.45) |
| `(?[...])` Perl extended classes rejected | full expression parser with `!`, `&`, `\|`/`+`, `-`, `^`, grouping, and precedence |
| `\|\|` class union treated as literals | `\|\|` is union, like PCRE2's UTS#18 mode |
| `[[:<:]]`/`[[:>:]]` rejected | POSIX.2 word-start/end assertions |
| CRLF-mode `.`/`\N` matched the LF of a CRLF pair | lone CR/LF still match; paired CRLF does not |
| `(*UTF8)` alias rejected | accepted alongside `(*UTF)` |
| `(*NO_START_OPT)` was a no-op; `(*COMMIT)` still skipped start positions | start-literal analysis sees through leading verbs, and `(*NO_START_OPT)` bypasses the prefilters |
| Replacement `\g<name>`/`\g<number>` unsupported | added to validation and expansion |

## Intentional extensions over PCRE2 10.45

These rows are counted as extensions, not gaps:

- `\p{General_Category=...}`, `\p{Uppercase_Letter}` (long GC names),
  `\p{Assigned}`, `\p{Is...}`, and Unicode blocks
  (`\p{InBasic_Latin}`, `\p{Block=...}`) are accepted; PCRE2 rejects them.
- Unbounded lookbehind (`(?<=a*)`) and `\K`/`\C` inside lookaround compile;
  PCRE2 10.45 rejects them.
- UAX #29 assertions (`\b{gcb}`, `\b{wb}`, `\b{sb}`) and the
  `\b{start}`/`\b{end}` variants.
- Unicode character names (`\N{NAME}`) and Unicode string properties
  (`\p{RGI_Emoji}`, ...).
- Numeric `\k<1>`/`\k{1}` backreferences (Oniguruma/Java style; PCRE2 only
  accepts names there).
- Class set operations are always enabled in ordinary `[...]` classes;
  PCRE2 requires `PCRE2_ALT_EXTENDED_CLASS` and rejects mixing explicit
  operators. regexz applies the operators left-to-right.
- Nested classes inside `(?[...])` use regexz's nested-class parser, so a
  literal `[` or `&&` inside such a nested class is interpreted as a nested
  class or an operator; PCRE2 treats nested classes as ordinary classes.
- `\p{...}` names are case- and separator-insensitive.

## Remaining differences

None of these are missing pattern-language features:

- `Limits.max_repeat` defaults to 1000 (RE2 compatibility) while PCRE2 allows
  65535. Raise it to 65535 for full PCRE2 quantifier range.
- Pattern/instruction/state limits (`max_pattern_bytes`, `max_instructions`,
  `max_ranges`, ...) are configurable resource caps.
- The library is UTF-8-only and has no JIT, 16/32-bit code-unit modes, locale
  tables, or `PCRE2_MATCH_INVALID_UTF`.
- PCRE2's `pcre2_set_offset_limit` (bound the end of the search window) has
  no direct equivalent; `findFrom` supplies only the start offset.
- Substitution treats an unset group as empty (PCRE2's
  `PCRE2_SUBSTITUTE_UNSET_EMPTY`) rather than erroring by default.
- PCRE2's `(*LIMIT_HEAP=...)` is approximated by the choice/capture-trail
  budget rather than a byte-exact heap limit.
- `(*NO_AUTO_POSSESS)` and `(*NO_DOTSTAR_ANCHOR)` are accepted but do not
  change regexz's own optimizations; `(*NO_START_OPT)` is implemented because
  it changes results observable through control verbs.

## Cross-checks

- `zig build test`: 392 tests.
- `python3 tools/check.py --fuzz 400 --skip-codegen`: V8, extended, replace,
  and Rust differential fuzzers.
- Start-literal extraction now looks through zero-width verbs
  (`(*COMMIT)`, `(*PRUNE)`, `(*SKIP)`, `(*MARK)`, callouts, `\K`), so the
  default search skips to the first literal occurrence like PCRE2's
  start-of-match optimization. `(*NO_START_OPT)` disables that skip.
- The existing performance campaign remains documented in
  `docs/optimization-audit.md`; the parser changes here do not touch the
  linear fast paths except for the new CRLF dot/`\N` shape and one assertion
  variant.
