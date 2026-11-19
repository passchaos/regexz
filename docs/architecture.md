# Architecture

This document maps the modules, the compilation pipeline, and the engine
selection rules. For feature coverage see `docs/roadmap.md`; for measured
performance see the table in the same file and `tools/bench/`.

## Pipeline

```
pattern ──parse.zig──▶ model.Node AST
                          │
        analysis (compile time, all conservative):
        required_literals.zig  start_literals.zig
        fast_branch.zig        shapes.zig
                          │
                    compile.zig ──▶ Program
                          │           (instructions, first-byte summary,
                          │            literal/prefix, dispatch tables,
                          │            start literals, fast branch)
                          │
        ┌─────────────────┴──────────────────┐
        ▼                                    ▼
  linear engines                      extended engine
  execute.zig   (boolean full match)  backtrack.zig (bounded VM)
  search_dfa.zig (leftmost search)
  pike.zig      (capture fallback)
  replace.zig   (find + replace fast paths)
  stream.zig    (streaming scanner)
  set_dfa.zig   (RegexSet)
```

`Program` is the boundary between compilation and execution. It is plain
data: a caller-allocated instruction slice plus summaries. `Program.serialize`
/ `deserialize` round-trips it through a versioned byte format for
cross-process caches and build-time codegen.

## Module map

### Front end

| File | Responsibility |
| --- | --- |
| `parse.zig` | Pattern grammar (PCRE2-compatible subset plus extended constructs), inline flags, verbs, callouts. Produces the `model.Node` AST. |
| `escape.zig` | Escape decoding, `\N{NAME}` named characters, algorithmic names. |
| `classes.zig` | Class canonicalization: merge/sort ranges, negation, simple case folding (including Turkish), ASCII Perl/POSIX classes. |
| `unicode.zig` | Generated Unicode 17 tables: scripts, binary properties, case-fold peers, grapheme/word/sentence segmentation data. |

### Compile-time analysis

All analyses are conservative: a false negative only costs performance, a
false positive would change semantics, so every extractor bails out on
anything it cannot prove.

| File | Responsibility |
| --- | --- |
| `required_literals.zig` | Literals every match must contain (`[a-z]*(?:foo|bar)`). Drives absence prefilters. |
| `start_literals.zig` | Literal-alternation start sets; only fixed-length left sides concatenate. |
| `fast_branch.zig` | Dominant `set? setB+` alternation branch plus the first-byte union of earlier branches. |
| `shapes.zig` | Deterministic shapes: `set+` runs, `setA+ sep setB+ tail` chains, `(?:setA+ setB)+` loops. Shared by the search engine and the streaming scanner. |

### Compilation

| File | Responsibility |
| --- | --- |
| `compile.zig` | Thompson construction. Emits instructions, first-byte summaries, required/start literals, dispatch tables, literal fast paths, and the extended flag. |
| `serialize.zig` | Versioned `Program` serialization; rejects incompatible versions and out-of-range data. |

### Engines

| File | Responsibility |
| --- | --- |
| `execute.zig` | Boolean full match: Thompson NFA, lazy full-match DFA, `set+` / `(?:setA+ setB)+` byte-table fast paths, partial matching. |
| `rune_cache.zig` | Full-match Unicode DFA transition cache: short-input construction starts at 4 KiB and promotes to 64 KiB after collisions; long-input construction starts at full capacity. Failed optional promotion retains exact small-cache lookups. |
| `search_cache.zig` | Rune-search Unicode caches: workspaces borrow shared empty front rows until a non-ASCII cache miss; a cold initializer atomically replaces them with owned front rows and a 96 KiB global cache. ASCII searches retain no owned Unicode cache storage. |
| `search_graph.zig` | One temporary DFS allocation for search-DFA priority assignment and eligibility analysis. Byte visit epochs preserve walk order and reuse storage; the buffer is released before execution tables are built. |
| `search_dfa.zig` | Leftmost-first search DFA with priority-annotated accepts. Two constructions: rune-level (lookaheads, tokenizers) and byte-level (UTF-8 automata for non-ASCII sets, `\C`). Includes the per-state rune-transition front cache. |
| `pike.zig` | Capture-aware Pike VM; the linear-time fallback when the backtracking budget is exhausted. |
| `capture_run.zig` | Recognizes `set+` programs with fixed capture saves when the workspace is initialized. ASCII scans use byte tables; Unicode scans use materialized rune sets and retain literal prefixes. Both write slots without DFA construction or capture trails and retain strict replay budgets. |
| `deferred_utf8_run.zig` | Dominant-branch sets scan inline ASCII tables immediately. Short Unicode probes start with exact scalar membership; repeated probes or long matching runs prepare the existing UTF-8 tables. Failed optional preparation retains scalar matching. |
| `byte_table.zig` | Expands materialized membership bitmaps and Latin-1 ranges into fixed byte tables. Shared by full-match, search and streaming workspace initialization. |
| `utf8_set.zig`, `utf8_run.zig` | Construct compact UTF-8 tries using shared build arrays, then expand disjoint edge intervals into byte transition rows. The same tables serve full-match and search set runs. |
| `backtrack.zig` | Extended mode: general lookaround, backrefs, atomic/possessive, conditionals, recursion, `\K`, callouts, `(*MARK)`, verbs. Bounded by step/choice/trail/depth limits and fails closed. |
| `replace.zig` | `ReplaceWorkspace`: leftmost-first `find`, replacement entry points, and the deterministic fast paths (`set+` runs, chains, dominant branch, anchored runs) that bypass the DFA. |
| `substitution.zig` | Substitution syntax: `$1`, `$<name>`, `${name}`, `$&`, `$$`, `` $` ``, `$'`, `$+`, `$_`, `\1`..`\9`, and `\U \L \E \u \l` case transforms. Pure functions; no engine state. |
| `stream.zig` | `StreamScanner`: persistent NFA state across chunks, rune-safe boundaries, chain fast path. |
| `set.zig`, `set_dfa.zig` | `RegexSet`: one unanchored subset construction over all patterns; per-pattern engines remain for assertions and extended patterns. |

### Prefilters (`prefilter.zig`)

| Filter | Used for |
| --- | --- |
| `FirstFilter` | SIMD 16-byte first-byte scan (byte splats or up to four ranges). Cached per workspace. |
| `MultiFilter` | SIMD two-byte prefixes for shared-first-byte literal sets. Checks the shared byte once per block and verifies only candidate lanes; dense collisions retain a scalar verification pass. |
| `PairSet` | Exact two-byte bitmap for wide start-literal alternations. AArch64 NEON uses `nibble_filter.zig` to select candidate lanes for dense first-byte sets, then verifies complete literals in position order; all-candidate blocks fall back to scalar scanning. Returns the first occurrence so the DFA can start there. |
| `FoldFilter` | Case-folded whole-pattern literals: SIMD scan for the rarest folded pair; non-ASCII bytes stay conservative, and candidate starts are clamped to the caller's requested offset. |

### Compile-time engine

`comptime_regex.zig` is a separate, allocation-free engine that parses and
generates matcher code inside the comptime evaluator (ctregex.zig
construction style). It shares no runtime code with the engines above: the
generated matcher uses continuation-passing backtracking over the AST.
Supported syntax is a deliberate subset (see the file header).

## Engine selection

`Regex`/`ReplaceWorkspace` pick a path in this order (first match wins):

1. **Literal** — the whole pattern is one literal: `memcmp`.
2. **`set+` run** — `shapes.setRun`; ASCII sets scan a byte table, non-ASCII
   sets walk an expanded UTF-8 automaton.
   `capture_run.Plan` also handles ASCII/Unicode runs with capture saves before/after
   the run, including nested captures and adjacent empty groups.
3. **Dominant branch** — `fast_branch.zig`: when the byte at the search start
   cannot begin an earlier branch, the `set? setB+` branch decides the match.
4. **Chain** — `shapes.chain`: `setA+ sep setB+ tail`, scanned through
   per-workspace byte tables.
5. **Anchored run** — `set+` followed by a line/text-end assertion.
6. **Absence prefilters** — required literal, start-literal pair set,
   case-folded pair; a miss returns before the DFA.
7. **Search DFA** — priority-annotated lazy DFA (rune or byte construction).
8. **Interpreter** — the NFA simulation with its own literal prefilters.
9. **Pike** — capture programs whose backtracking budget is exhausted.
10. **Extended VM** — `Program.extended` programs.

The order is chosen so that a cheaper exact check precedes a more general
engine; every step is exact (no step can skip a real match), and steps 1-6
fall through when their preconditions are not provable.

## Design decisions

- **Linear core, bounded extended mode.** RE2-style programs never backtrack
  without a budget; extended constructs run on a VM with explicit
  step/choice/trail/depth limits and fail closed.
- **Prefilters are exact.** A prefilter may only prove absence; it never
  guesses a match. This keeps `find` semantics identical across engines and
  makes every optimization differentially testable.
- **Shape fast paths over general DFA.** Tokenizer and log-scanning shapes
  (`set+`, chains, dominant branches) get dedicated scans; the DFA remains
  the correctness reference and the fallback.
- **Capture strategy.** Backtracking first (fast on short matches), Pike VM
  as the linear fallback, and DFA bounds with path replay for large capture
  searches.
- **Workspace ownership.** A workspace is bound to one `Program` and is not
  thread-safe; `Program` itself is immutable and shareable.
  Full-match workspaces for exact whole-pattern literals use empty NFA scratch
  views and require no allocation; budget and partial-match semantics remain
  on the literal path.

## Testing and gates

- `zig build test` — 215+ unit tests across `*_tests.zig` files.
- `tools/fuzz/run.py`, `extended.py`, `rust.py`, `replace.py` — differential
  harnesses against V8, Node, and Rust `regex` (captures, spans, replacement
  output).
- `tools/bench/check.py` — 40-case benchmark gate against
  `tools/bench/baseline.json` with a 1.80x tolerance.
- `tools/check.py` — full local gate (fmt, tests, codegen drift, fuzz).
- `.github/workflows/ci.yml` — format, tests, bench smoke, fuzz smoke.
