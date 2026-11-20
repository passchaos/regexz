# Optimization audit — 2026-11-19

Source baseline: `a2d8a85`. Reviewed the compilation and execution pipeline,
workspace ownership, search prefilters, capture replay, replacement output,
and benchmark coverage.

## Replacement output allocation

The output-owning replacement APIs used an empty `ArrayList` and grew it
incrementally. Repeated replacements in long input therefore incurred output
reallocations and copies in addition to matching and expansion work.

On the first successful match, reserve at least
`input.len - (match.end - match.start)` bytes. This estimates the unchanged
input remaining after that replacement. Use the list's normal growth policy
to retain headroom for small expansions. Subsequent expansion still grows the
buffer as necessary. A whole-input replacement starts with zero reserved
bytes; a no-match result follows its original path. The length
and caller-buffer APIs do not reserve output storage.

This is a capacity estimate: many shrinking matches can leave spare capacity
until the result is converted to an owned slice. It avoids a second search
pass, which would repeat matching work and callout side effects.

Use the scoped benchmark to measure both allocators and inspect output
allocation counts:

```sh
zig build bench-replace -Doptimize=ReleaseFast
```

It warms the engine, takes the median of five batches of 200 replacements,
then separately counts allocations and cumulative requested bytes in one
replacement. Callback counts include the callback-owned replacement strings.
Cases cover shrinking, growing, captures, no match, zero-width matches,
limited replacement, callbacks, and whole-input deletion.

## Measurements

Same shared macOS ARM64 host, 32,000-byte input. Run the compiled before and
after executables in `before/after`, `after/before`, `before/after` order.
Times below are medians of those three executions; each execution reports
its own median of five batches. Allocation counts and requested-byte totals
were identical in all three runs. Raw samples are in
[`benchmarks/replacement-allocation.json`](benchmarks/replacement-allocation.json).

| Case | Page time, us (before -> after) | SMP time, us (before -> after) | Page allocations | SMP allocations | SMP cumulative requested bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| shrink | 54.96 -> 54.02 | 51.82 -> 53.55 | 3 -> 1 | 10 -> 2 | 107,134 -> 72,123 |
| grow | 69.44 -> 54.95 | 66.12 -> 58.30 | 5 -> 2 | 11 -> 2 | 222,115 -> 120,446 |
| captures | 473.48 -> 423.78 | 413.81 -> 404.35 | 4 -> 1 | 10 -> 1 | 132,255 -> 48,123 |
| no match | 3.90 -> 3.64 | 4.92 -> 4.46 | 1 -> 1 | 2 -> 2 | 80,128 -> 80,128 |
| zero width | 540.06 -> 545.34 | 572.76 -> 530.12 | 2 -> 1 | 3 -> 2 | 80,260 -> 80,130 |
| limited | 5.00 -> 3.02 | 4.12 -> 3.57 | 2 -> 1 | 3 -> 2 | 80,252 -> 80,121 |
| callback | 7016.00 -> 6844.79 | 67.67 -> 67.18 | 4003 -> 4001 | 4010 -> 4002 | 111,134 -> 76,123 |
| delete whole input | 9.20 -> 9.12 | 9.51 -> 9.16 | 0 -> 0 | 0 -> 0 | 0 -> 0 |

The most repeatable benefit is less allocator work: SMP capture replacement
uses one allocation instead of ten, with 64% fewer cumulative requested
bytes. Growing and limited replacements also improved in these samples.
Shrinking SMP throughput was 3% slower, while the unchanged no-match path
varied by 7-10%; small timing differences need a quieter host to attribute
confidently. This change does not establish a universal throughput win.

Validation:

```sh
zig build test-lib -Dtest-filter=replacement -Dtest-filter=replacen -Dtest-filter='notempty affects replacement' -Dtest-filter='full Unicode case mapping' -Dtest-filter='substitution supports' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
zig fmt --check build.zig tools/bench/replace.zig src/regex/replace.zig src/regex/replace_tests.zig
```

All 26 scoped tests and 1,900 V8 comparisons passed. The replacement fuzzer
now compiles and executes in separate steps so compiler/wrapper diagnostics
cannot contaminate the comparison protocol.

## Next candidates

The compile-time comparison now uses heap-backed runtime subjects and input
barriers; generated code was inspected to confirm input loads and comparisons.
`bench-startup` separates compilation, workspace construction, cold matching
and warmed matching. See [benchmark calibration](benchmarks/calibration.md).

| Priority | Owning code | Evidence and next measurement |
| --- | --- | --- |
| 1 | `execute.zig`, `search_dfa.zig`, `tools/bench/startup.zig` | Startup measurements now separate construction from matching. [Unicode initialization](benchmarks/unicode-init.md) is down from about 48 us to 13 us; [shared byte-table construction](benchmarks/byte-table.md) reduces ASCII class setup from about 151 ns to 62 ns, and [range masks](benchmarks/range-mask.md) reduce class compile-plus-first-match cost by about 20%. [ASCII DFA setup](benchmarks/dfa-init.md) omits a 64 KiB unused cache. [Adaptive Unicode full-match caching](benchmarks/rune-cache.md) cuts small-input DFA construction by 8.90x and keeps 4 KiB instead of 64 KiB. [Deferred search caches](benchmarks/search-cache.md) eliminate 96 KiB of per-workspace Unicode storage on ASCII subjects and improve complete first searches 4.83–6.91x. [Literal workspaces](benchmarks/literal-workspace.md) now require no allocation and initialize 1.78x faster. [Shared graph walks](benchmarks/search-graph.md) cut optional-chain construction allocations from 34 to 12 and Qwen DFA setup from 36 to 12. [Deferred dominant-branch tables](benchmarks/deferred-run.md) now cut Qwen first-token setup from about 0.88 ms to 0.48 us and its complete ASCII cold pass by 19.96x; repeated Unicode prepares the original tables on demand. [Deferred full-match tables](benchmarks/deferred-workspace.md) now reduce Unicode letters first matches by about 1,003–1,030x and Han first matches by 164x, with one scratch allocation at construction. [Deferred ordinary search tables](benchmarks/deferred-search.md) now cut Unicode letters first searches by about 358–365x, complete ASCII cold passes by 19.39x, and long ASCII absence scanning by 23.17x. Prepared-state dispatch retains the byte scanner. [Shared range identity](benchmarks/set-identity.md) now avoids repeated comparisons of immutable range arrays, improving wide Unicode full-match initialization 4.70–5.18x and search initialization 2.62–2.93x with allocation counts unchanged. [Borrowed full-match DFA scratch](benchmarks/dfa-scratch.md) now removes one allocation and eight requested bytes per instruction from lazy DFA construction, reusing NFA buffers with visit invalidation on engine switches. Timing samples do not establish a latency gain. [Combined capture storage](benchmarks/capture-storage.md) now retains independent active and longest-match backup views in one allocation, reducing every measured search workspace initialization from two allocations to one with requested bytes unchanged. Construction-latency gains are not established. Persisted small DFAs and remaining construction scratch remain candidates for fresh measurements. |
| 2 | `prefilter.zig`: `PairSet.indexOfAny` | The [NEON nibble prefilter](benchmarks/nibble-prefilter.md) now scans dense first-byte sets in 16-position blocks: wide-set misses improved 4.34x and complete Regex searches improved 2.00x. [Lane masks and weighted buckets](benchmarks/nibble-buckets.md) bit-pack candidate iteration and place literals to minimize expected bucket collisions, improving collision-heavy wide alternations 2.44–2.47x and the complete 24-literal search 2.26x; the 56-case gate reports 7,971.0 -> 2,210.2 ns. [Third-byte filtering](benchmarks/prefix-third-byte.md) rejects candidates that diverge after the shared prefix, improving shared-prefix collision searches 5.06–7.03x, dense controls 40–42x and the wide 24-literal search another 1.33–1.35x. Exact pair and literal verification preserve earliest-match ordering. Target-specific paths remain. |
| 3 | `capture_run.zig`, `utf8_run_search.zig` | Fixed ASCII and [Unicode capture runs](benchmarks/unicode-capture.md) scan directly; [decode reuse](benchmarks/capture-decode.md) and [capture lead filters](benchmarks/utf8-prefix.md) improve rejected-candidate scanning. [Ordinary search prefixes](benchmarks/search-prefix.md) now route selective valid misses to existing first-filter vectors and advance valid rejected runes once. Greek CJK cold/warm misses improve about 18x, Han rejected-prefix first searches about 13-14x, and their extra table allocations fall from 11/15 to zero. Wide-set misses and successful probes retain byte-table preparation. ASCII members enter their direct scan before filtering. Workspace size stays unchanged. Long matching-run acceleration remains a candidate. |
| 4 | `capture_replay.zig` | [Adjacent disjoint capture replay](benchmarks/adjacent-replay.md) avoids capture trails and backtracking choices. [Nullable greedy replay](benchmarks/nullable-replay.md) now extends the cached proof through nullable greedy continuations, with 1.66-1.79x complete-pass gains over ASCII, 1.22x for Unicode nullable prefixes and 1.43x for optional Unicode captures. First-find allocations fall by two or three, with workspace size unchanged. The one-time graph walk remains separate from warmed dispatch. Cold-start latency gains are not established. Bounded optional branches still require interpreter replay; measure their record cost before widening the proof. |
| 5 | `replace.zig` | Deterministic capture replay now lives in a separate module with explicit borrowed slots and execution counters. The remaining API, search dispatch, deterministic scanners and interpreter occupy roughly 1,900 lines. Extract a cohesive scanner module when changing those paths; keep budget and capture state ownership explicit. |

Dense UTF-8 run tables now use the [direct builder finish](benchmarks/dense-utf8.md),
omitting two temporary compact arrays and their copies. Per-construction
requested bytes fall by 1,484 for Greek, 3,116 for Han and 31,436 for letters,
with the final row layout and workspace size unchanged. Construction timing
gains are not established. Remaining linked-builder growth and row-allocation
costs need separate measurements.

Nibble-filter candidate lanes are now bit-packed once per 16-byte block and
walked with `@ctz`, removing the select plus reduce-min round trip that
`std.simd.firstTrue` paid per candidate. Bucket bits are no longer assigned by
literal position: `Filter.init` places literals greedily by English byte
frequency and hill-climbs single moves against the expected false-positive
weight (distinct first-byte weight times distinct second-byte weight per
bucket). The search is deterministic, allocation-free and runs once per
construction. Collision-heavy wide alternations improve 2.44–2.47x and the
complete 24-literal search 2.26x; MultiFilter collision scans improve 1.26x.
Absent scans and the dense scalar fallback are unchanged within host noise.
See [nibble filter lane masks and weighted buckets](benchmarks/nibble-buckets.md).

Multi-literal verification now stops at the third byte. `PairSet` and
`MultiFilter` compare the 16-lane third-byte window against their distinct
literal third bytes before extracting candidates (when every literal has a
third byte), and the per-candidate checks test the second and third bytes
before the full comparison. Shared-prefix collision searches improve
5.06–7.03x, the dense all-candidate controls 40–42x, and the wide 24-literal
search another 1.33–1.35x. Blocks at the end without a third-byte lane skip
the filter stage, which only leaves more candidates for exact verification.
See [third-byte filtering](benchmarks/prefix-third-byte.md).

Full-match DFA transitions now memoize the target by match mask. A state's
transition depends only on which consuming instructions match a rune, so
states with at most four consuming instructions carry `1 << k` target slots
in their arena instruction block; a rune-cache miss tests the sets once,
builds the mask and reuses the memoized target instead of walking
instructions, running the closure and interning the state again. ASCII
transitions keep the per-byte table and the general walk, ASCII-only DFAs
allocate no slots, and the state record and workspace size are unchanged.
Varied Han first matches improve 1.76–2.35x and direct-mapped slot-collision
warm scans 2.86x; ASCII controls stay within host noise. See
[DFA transition masks](benchmarks/dfa-mask-cache.md).

Shape detection now compares ASCII bitmap words instead of probing 128
memberships per set. The `(?:setA+ setB)+` disjointness check and the
dot/except predicates use the authoritative ASCII bitmap directly; the
non-ASCII range checks are unchanged. Workspace initialization for the ASCII
loop shape improves 6.47x, its cold first match 6.34x and its fresh-DFA
three-match mode 5.76x; other shapes are unchanged. See
[shape detection from ASCII bitmaps](benchmarks/shape-init.md).

Search workspaces now build their first-byte filter from the ASCII bitmap:
one `@ctz` walk of the two words collects the candidate bytes and closes
contiguous runs, replacing two 128-value probe loops. Search-DFA workspace
initialization improves 1.33–1.67x, the first search 1.11–1.24x and the
one-shot API first search 1.19–1.35x; literal and ineligible controls and
warmed calls are unchanged. See
[first-byte filter construction](benchmarks/first-filter-init.md).

Captured run chains now scan directly. `shapes.runChain` recognizes
`(setA*)(setB*)...(setZ*)` when every group is one unbounded run or an empty
capture and the sets are pairwise disjoint; the scan jumps to the next anchor
rune with a prepared UTF-8 candidate-byte filter, extends the maximal run and
walks backward over the prefixes and forward over the trailing nullable runs
to place every capture boundary without DFA state, choices or trails. Lazy
`set*?` groups and fully nullable chains are accepted too: with disjoint sets
the greedy boundaries are forced, and a chain with no mandatory run matches at
the search offset. Overlapping sets use a forward scan when the first run is
mandatory and every mandatory run's set is disjoint from all preceding sets,
which makes the greedy maxima complete. Plans with non-ASCII run sets carry a
64-entry rune membership cache (rune → set bitmask) so repeated boundary
probes skip the range binary search; all-ASCII plans keep the direct calls
through a comptime specialization. Starts inside a run, malformed UTF-8 and
failed mandatory prefixes fall back to the general engine. Covered capture
searches improve 1.32–2.43x, the lazy case 1.64x, the nullable chains
1.42–2.03x, the overlapping case 1.67x and the cached Unicode chains another
1.18–1.21x; controls stay within host noise. See
[captured run chains](benchmarks/run-chain.md).

The `RegexSet` combined DFA now stores pre-multiplied row offsets in its
packed ASCII transition entries, so the hot scan indexes `row + byte` without
a shift on the dependent-load chain; the cold path shifts the row back to a
state id. The nine-pattern no-match median improves 8%, but the host spread
overlaps and an untouched control moved 10%, so the sample is consistent with
the expected effect rather than proof. See
[set DFA row offsets](benchmarks/set-dfa-rows.md).

Zero-width edge-assertion patterns (`^|$`, `(?m)^`, `$`, `\A\z`) now scan
directly. `zero_width.analyze` collects alternation paths of edge assertions
and their capture slots at compile time; the search enumerates the search
offset, line-break boundaries (SIMD byte search per newline convention) and
the text end, and checks each path with the engine's own position helpers.
ASCII `\b`/`\B` paths enumerate word-run edges by rune length, evaluate
word-first with scans bounded by the best candidate, and text-edge-only paths
use an O(1) candidate set. Other assertion kinds, `(*NOTEMPTY)` restrictions
and `Limits.longest` keep the general engine. The `^|$` replacement over
32 KiB improves 130–139x and is now about 3x faster than the same-host Rust
reference; `\b`/`\B`/`\b|$` replacements improve 1.64–1.95x and are ahead of
Rust as well. See [zero-width edge assertions](benchmarks/zero-width.md).

Replacement now parses the substitution once per pass into a fixed 16-segment
stack template (literal slices, resolved groups, whole-input specials).
Substitutions with backslash escapes or case transforms, and those needing
more segments, keep the general per-match expansion. The 32 KiB `(\w+)` →
`[$1]` capture replacement improves 1.85–1.88x with unchanged allocation
counts; see [parsed substitution templates](benchmarks/substitution-template.md).

Replacement output appends now write straight into the capacity reserved before
the first match and fall back to `ArrayList` only when the list is full. The
32 KiB capture replacement improves another 1.15–1.16x, shrink/grow 1.15–1.20x
and the word-boundary replacements 1.10–1.16x with unchanged allocation counts;
literal and single-append controls stay within host noise. See
[inline reserved appends](benchmarks/inline-list-writer.md).

Case-fold expansion now binary-searches the sorted fold table per class range
instead of rescanning all 482 entries per range, and normalization skips the
comparison sort when the range list already arrives in order. Compiling the
Qwen tokenizer pattern improves 4.85–5.32x, with the compiled sets, runtime
paths and allocation counts unchanged; see
[targeted case-fold expansion](benchmarks/case-fold-scan.md).

The streaming chain fast path now consumes non-ASCII runs with a lazily built
UTF-8 automaton (one table load per byte) instead of decoding and
range-searching each rune, while a new run-end status preserves partial runes
across chunk boundaries. The 191 KiB Han chain improves 2.40x; ASCII chains
and the search controls stay within host noise. See
[streaming chain runs](benchmarks/stream-chain-runs.md).

The delimited fast path (`"[^"]*"`, `<[^>]+>`) now scans the first 32 bytes of
each delimiter search scalar-ly and falls back to the vector scan only for
longer gaps, where the SIMD setup no longer dominates. Short-span HTML tag
searches improve 2.57x and JSON string literals 2.50x; other fast-path
controls stay within host noise. See
[short-span delimiter scans](benchmarks/delimited-short-spans.md).

`split` and `splitn` now detect a pure ASCII `set+` program and partition the
input in one byte-table pass with a bounded parts reservation, instead of
building a workspace and searching once per part. The 22 KiB whitespace split
improves 2.20x; other patterns keep the general `findAll` path. See
[split over set runs](benchmarks/split-set-runs.md).

ASCII streaming chains now consume the bytes of each phase in a tight loop and
switch phase once per boundary instead of once per byte. The 216 KiB
`[a-z]+ [a-z]+` stream improves 1.58x; single-set streams, the Han chain and
the search controls stay within host noise. See
[tight streaming chain phase loops](benchmarks/stream-chain-ascii-loops.md).

`RegexSet` now skips the combined DFA when every pattern decides its search
with a separator/delimiter scan, searching each pattern with its own
memchr-driven workspace instead. The 9-pattern `[a-z]+<punctuation>` set
improves 4.48x; sets with other shapes keep the combined DFA. See
[per-pattern scans for separator sets](benchmarks/set-individual-scans.md).

`https?://[^\s]+`-style programs now have a literal-prefix run shape: a fixed
ASCII prefix, at most one optional literal, a fixed middle and a trailing
`set+`. The search anchors on the prefix, verifies the middle and scans the
run with a byte table (or the deferred UTF-8 run for non-ASCII bytes). URL
search improves 2.77x; other search shapes stay within host noise. See
[literal-prefix runs](benchmarks/literal-run-url.md).

`replaceAll` fuses the search and expansion when the program is an ASCII
`set+` and the substitution is literal: one byte-table scan appends each gap
and the fixed replacement. The 24 KiB `a+` → `x` replacement improves 1.34x;
substitutions with syntax and other patterns keep the general path. See
[replacement over set runs](benchmarks/replace-set-runs.md).

A reproducible comparison harness now runs the same workloads through regexz
and Rust's `regex` crate (`tools/compare`). On this host regexz is faster on
19 of the 20 measured cases: 7.77x on tokenizer compilation, 5.14x on a
small-pattern compile, 1.23–1.45x on tokenizer scans, 2.12–2.80x on search
scans, 1.62–4.13x on splits, 2.54–6.29x on full-match calls, 4.10x on a
set-run replacement, 1.63x on a zero-width replacement and 3.85x on the
nine-pattern set. The exception is a fresh `findAll` per call (0.64x), where
Rust's thread-local cache pool stays warm; `findAllWith` with a caller
workspace restores the lead (1.23x). See
[comparison with Rust's regex](benchmarks/rust-comparison.md).

The fast-branch deferred run now counts Unicode probes and materializes its
UTF-8 table only after 2,048 probes. The old remaining-input check built the
1.87 MB Latin-plus-Mark table on the first non-ASCII rune of any long mixed
text; the Qwen tokenizer text probes 1,200 times per pass, so every fresh
`findAll` pass paid the build. The fresh pass improves 2.42x (302 → 125 us)
and the fresh `findAll` gap against Rust narrows from 0.25x to 0.64x; warm
scans, CJK and the controls stay within host noise. See
[deferred fast-branch table threshold](benchmarks/deferred-fast-branch-threshold.md).

`Matches` now supports a caller-owned workspace: `Regex.findAllWith` iterates
on warmed search-DFA caches without copying or freeing the workspace, while
`Regex.findAll` keeps its owning behavior. The borrowed iterator matches a
manual `Workspace.find` loop (64 us) and is 5.36x faster than a fresh
`findAll` pass (344 us) on the Qwen tokenizer text, where the owning iterator
pays the lazy DFA preparation per call. See
[reusing a workspace for match iteration](benchmarks/find-all-workspace.md).

`split` and `splitn` now scan pure literal patterns (`,` or a fixed
delimiter) with memchr/memmem and append the gaps, instead of creating a
workspace and searching per part. The 29 KiB comma split improves 2.66x;
whitespace and other shapes keep their existing fast paths. See
[split over a literal separator](benchmarks/split-literal.md).

`replaceAll` now fuses a pure literal pattern with a literal substitution:
occurrences are found with the literal search and each gap and the fixed
substitution are appended directly. The 29 KiB `,` → `;` replacement improves
1.41x; substitutions with syntax and other patterns keep the general path.
See [replacement over a literal pattern](benchmarks/replace-literal.md).

`replacen` now shares the literal scanner with `replaceAll`: a literal
pattern, a literal substitution and a match limit scan occurrences directly.
The 29 KiB `,` → `;` limited replacement improves 1.47x; substitutions with
syntax and other patterns keep the general path. See
[limited replacement over a literal pattern](benchmarks/replacen-literal.md).

`replaceAllLen` and `replaceAllInto` now share the literal scan: the length
writer counts occurrences and computes the result size, and the caller-buffer
writer fills the buffer directly while still failing closed on a short buffer.
The 29 KiB `,` length and buffer writers improve 2.06x and 1.54x. See
[literal length and caller-buffer writers](benchmarks/replace-literal-writers.md).

The ASCII `set+` replacement scan now also serves `replacen`,
`replaceAllLen` and `replaceAllInto`: the limited form shares the run scan,
the length writer counts runs and run bytes, and the caller-buffer writer
fills directly while failing closed on a short buffer. The 24 KiB `a+`
replacen, length and buffer writers improve 1.53x, 2.51x and 1.73x. See
[set-run limited replacement and writers](benchmarks/set-run-writers.md).

Further work on these candidates needs fresh measurements before implementation.
Current warmed throughput does not establish their cold-start cost or the
benefit of replacing their fallback paths.

Packing the rune-mode search DFA's ASCII transitions into 16-bit entries with
an accept bit, shrinking the hot tables from 96 KiB to 16 KiB, was screened
and reverted: interleaved medians put `find Qwen tokenizer` at 0.97x and the
other rune-mode cases within host noise, so the extra masking did not pay for
itself. See [rune DFA ASCII packing screen](benchmarks/rune-dfa-ascii.json).

Growing the search DFA's Unicode cache from 256 to 4096 entries on collisions
was screened and reverted: the interleaved medians left the fresh `findAll`
pass at 1.03x and moved the CJK scans to 0.94–0.97x, so cache table size is
not the cold-start bottleneck. Filling a set-run replacement through an
exact-size second pass (0.72x) and skipping the fast branch's prefix probe
when its set is disjoint from the run (0.99–1.06x) were also neutral or
negative and reverted. See
[search cache growth](benchmarks/search-cache-growth.json),
[exact replacement fill](benchmarks/replace-exact-fill.json) and
[fast-branch prefix skip](benchmarks/fast-branch-prefix-skip.json).
