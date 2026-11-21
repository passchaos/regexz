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
all 20 measured cases: 11.62x on tokenizer compilation, 8.46x on a
small-pattern compile, 1.30–1.51x on tokenizer scans and match iteration,
2.13–2.63x on search scans, 1.66–3.93x on splits, 3.11–6.32x on full-match
calls, 3.69x on a set-run replacement, 1.50x on a zero-width replacement and
4.21x on the nine-pattern set. The owning `findAll` iterator reuses a process
workspace pool and is 1.51x ahead of Rust's `find_iter`. See
[comparison with Rust's regex](benchmarks/rust-comparison.md).

The fast-branch deferred run now counts Unicode probes and materializes its
UTF-8 table only after 2,048 probes. The old remaining-input check built the
1.87 MB Latin-plus-Mark table on the first non-ASCII rune of any long mixed
text; the Qwen tokenizer text probes 1,200 times per pass, so every fresh
`findAll` pass paid the build. The fresh pass improves 2.42x (302 → 125 us)
and the fresh `findAll` gap against Rust narrows from 0.25x to 0.64x; warm
scans, CJK and the controls stay within host noise. See
[deferred fast-branch table threshold](benchmarks/deferred-fast-branch-threshold.md).

`Regex.findAll` now returns its owning workspace to a process-wide pool when
the caller uses the page or smp allocator, so repeated iteration starts with
warmed search caches; other allocators are never pooled, avoiding
caller-owned memory that could be released while cached. `Regex.findAllWith`
remains the explicit caller-workspace form for any allocator and concurrent
iterators. The owning iterator improves 1.91x (121 → 63 us) and matches the
borrowed path; the pool is a single mutex-protected entry keyed by a
process-unique regex id and cleared by `Regex.deinit`. See
[match iteration workspaces](benchmarks/find-all-workspace.md).

The tokenizer fast branch now also scans the following digit (`\p{N}`) and
punctuation (` ?[^\s\p{L}\p{M}\p{N}]+[\r\n]*`) branches directly after the
dominant branch fails. The analysis stops at the first branch it cannot scan,
so Qwen's whitespace branches, including the `\s+(?!\S)` backtracking
lookahead, stay on the DFA; a first-byte bitmap skips the plans for bytes they
cannot start. Qwen find improves 1.31x in the microbenchmark (1.56x against
Rust), the owning/borrowed iterators 1.17–1.19x, and the CJK cases pay a small
first-byte check (0.93–0.97x relative) while staying 1.42x ahead of Rust. A
differential test compares every byte offset against the DFA. See
[fast-branch later plans](benchmarks/fast-branch-later-plans.md).

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

Extending the later plans to `set* set+` branches (a leading newline run) was
screened and reverted: Qwen find measured 0.96–0.98x and the CJK scans 1.01x,
so the DFA's single-newline handling is already as cheap as the direct scan.
See [star-run screen](benchmarks/fast-branch-star-run.json).

Restructuring `find`/`findOnce` so `.none` programs skip the fast-kind switch
was screened and reverted: Qwen find measured 1.00x, the borrowed iterator
0.94x and the CJK scans 0.96x, so the switch is not a bottleneck. See
[find dispatch screen](benchmarks/find-dispatch-screen.json).

Raising the split parts reservation from `input.len / 8` to `input.len / 4`
was neutral across two interleaved runs (1.05x then 0.99x on the whitespace
split), so the extra temporary memory was not justified. See
[split reserve screen](benchmarks/split-reserve-screen.json).

Calling the fast branch directly from `Matches.next` to skip the public find
dispatch was screened and reverted: the borrowed iterator measured 0.97x and
the owning iterator 0.95x, so the iterator is not dispatch-bound. See
[iterator shortcut screen](benchmarks/find-all-fast-branch.json).

`Regex.init` now compiles patterns longer than 64 bytes in an arena instead of
the fixed 16 KiB block. Long patterns grow several parse lists, and
reallocating inside the block copies; the arena grows them with its chunk
policy. Qwen tokenizer compilation improves 1.04–1.05x, while the 40-byte xDS
pattern keeps the block (0.96x page control, host noise). See
[arena compilation for long patterns](benchmarks/compile-arena-long-patterns.md).

`Regex.init` now reuses its 16 KiB compile block from a process-wide pool
when the caller uses the page allocator; `Regex.deinit` returns the block.
The xDS-like compile improves 2.07x (5.15 → 2.49 us) by avoiding the
per-compile mmap/munmap. The SMP allocator bypasses the pool and is unchanged;
other allocators keep direct allocate/free so leak tracking still works. See
[reusing the compile block](benchmarks/compile-block-pool.md).

Compilation now selects a block tier: 16 KiB up to 64 bytes, 64 KiB for
longer patterns without Unicode property references, 256 KiB for patterns
containing `\p`/`\P`, and the arena above 1024 bytes. The page block pool
serves all three sizes under a 512 KiB cap. The Qwen tokenizer compile
improves 1.36x (55.1 → 40.5 us) and a 100-byte literal 1.68x (18.3 → 10.9 us);
the SMP Qwen path is neutral and xDS keeps its 16 KiB block. See
[compile block tiers](benchmarks/compile-block-tiers.md).

`RegexSet` now scans all simple chain separators (`set+ sep` with a
single-byte literal separator) in one vector pass instead of once per
pattern. A nibble-table candidate filter finds the separator bytes 64 bytes
at a time, and each candidate checks the `set_a` run before it. The
nine-pattern set improves 4.77x (9.5 → 2.0 us); the other 66 benchmark cases
are neutral (median 1.00x). See
[combined separator scan](benchmarks/set-combined-separators.md).

Prefiltering each separator candidate by a vectorized "predecessor in
`set_a`" test was screened and reverted: the extra lookups per chunk cost
more than the rejected scalar candidates saved (2.57 us versus 1.99 us on
the nine-pattern set).

Single-byte literal replacement now translates in 16-byte vectors when the
substitution is also one byte, so the output length is unchanged and the pass
avoids one search plus two small copies per occurrence. `replaceAllLen` counts
with a vector popcount, and `replacen` uses the translate path when its limit
covers every occurrence. The 29 KiB comma replacement improves 9.80–64.96x
across the four replacement entry points. Single-byte splits probe 16 bytes
scalar before the generic search, improving the comma split 1.72x. See
[literal byte paths](benchmarks/literal-byte-paths.md).

Scanning delimiters with a 16-byte vector compare instead of the existing
scalar-then-vector probe was screened and reverted: tags and quoted strings
start within one or two bytes of the previous match, so the vector setup made
`find HTML tag` 2.3x slower and the JSON string scan 2.2x slower.

Unicode set-run searches now skip the continuation bytes of a rejected UTF-8
sequence instead of probing each byte again. Punctuation between Han runs was
the main beneficiary: `find Han class scan` improves 1.22x (148.7 → 122.4 us)
while the 66 control cases stay at a 1.00x median. See
[skipping rejected UTF-8 sequences](benchmarks/unicode-dead-skip.md).

`replacen` for a one-byte literal and substitution no longer counts every
occurrence before translating: whole vector blocks are translated while at
least 16 replacements remain and the scalar tail applies the exact limit. The
29 KiB comma `replacen` improves 1.16x with a neutral control median. See
[literal byte paths](benchmarks/literal-byte-paths.md).

`StreamScanner.init` now carves its thread lists, slot storage and epoch
table from one allocation instead of seven; with the page allocator each
array was an mmap/munmap pair. Scanner creation and destruction drops from
6.3–6.6 us to 1.9–2.2 us (3.0–3.4x), and a focused 216 KiB stream pass is
faster in every paired run (1.05x median). See
[single-allocation scanner storage](benchmarks/scanner-storage.md).

Streaming chains whose two runs use the same set (`\p{Han}+，\p{Han}+`) now
build one UTF-8 transition table instead of two. The table has 260 rows and
costs about 15.5 us to build; scanners are created per stream. The stream Han
chain improves 1.09x (185.8 -> 170.9 us) and the focused pass 1.13x, with the
other 66 cases at a 1.02x median. See
[shared chain table](benchmarks/shared-chain-table.md).

Replacing the class-union comparison sort with a three-pass radix sort or a
pairwise merge of the concatenated sorted runs was screened and reverted:
compile Qwen measured 15-20% slower with the radix sort and neutral with the
pairwise merge, so the existing sort is not the compile bottleneck it
appeared to be in the call-graph sample.

Direct single-byte stores in the set-run replacement writers, and dropping
the redundant `runeAt` check before `runEnd` in the fast branch, were both
screened and reverted: the replacement writers were neutral across the four
`a+` cases, and Qwen find/findAll measured 1.01x/0.99x.

`replaceAll` for an edge-only zero-width plan (`\A|\z`, `$`) now computes the
exact output length and writes into one allocation instead of growing an
ArrayList through several reallocations. A controlled fixed-workspace harness
measures 1.10x (3,825 -> 3,487 ns); the comparison harness is
allocation-noise-dominated for this case (0.86-1.44x across runs). Plans that
include line edges keep the general writer. See
[edge-only zero-width replacement](benchmarks/edge-zero-replace.md).

The stream scanner's ASCII `set+` and `set*` paths now consume member and
non-member runs in tight loops instead of checking the pending-match state on
every byte; the star path emits its empty matches inside the non-member loop.
`stream [a-z]+` improves 1.31x (183.8 -> 140.3 us) and `stream [a-z]*` 1.40x
(223.9 -> 160.1 us), with the other 65 cases at a 1.00x median. See
[tight ASCII run loops](benchmarks/stream-ascii-runs.md).

Non-ASCII fast-branch starts now call `runEnd` directly instead of validating
the first rune with `runeAt` and then scanning it again; ASCII keeps the
cheap gate so failed optional-prefix attempts stay out of the run scan. The
CJK tokenizer improves 1.10x (178.2 -> 161.4 us) and the no-lookahead variant
1.03x, with Qwen neutral and the control median at 0.98x. See
[direct non-ASCII run starts](benchmarks/nonascii-run-start.md).

A BMP membership bitmap for the UTF-8 run scan was screened and reverted:
decode plus bit test measured 1.6x slower than the byte automaton (178 ->
286 us on the CJK tokenizer), because the three dependent table loads
pipeline better than the branchy decoder. A prefix lead-byte filter in the
fast branch was also reverted (5% slower), as were a 3-byte rune fast path
and short-separator `mem.eql` replacement in the stream chain (both neutral).

`replaceSetRun` now appends gaps and a zero- or one-byte substitution with
the assume-capacity variants: the output cannot exceed the reserved
`input.len` because every matched run removes at least one byte. The 24 KiB
`a+` replacement improves 1.21x (25.0 -> 20.6 us) and `replacen` 1.18x, with
the 65 control cases at a 1.01x median. See
[capacity-guaranteed appends](benchmarks/set-run-append.md).

`splitAsciiSet` and `splitLiteral` now reserve `input.len / 4 + 1` parts
(capped at 8192) and append with the assume-capacity variants, removing the
growth copy and the per-part capacity check for dense separators. The 22 KiB
whitespace split improves 1.10x (20.0 -> 18.2 us) and the 29 KiB comma split
1.16x (19.8 -> 17.1 us), with the 65 control cases at a 1.00x median. See
[capacity-guaranteed split appends](benchmarks/split-appends.md).

`replaceLiteral` appends gaps and a substitution no longer than the literal
with the assume-capacity variants, since the output cannot exceed the
reserved `input.len`. Replacing `the` with `X` on the 216 KiB word text
improves 1.08x (75.3 -> 69.5 us). See
[literal replacement appends](benchmarks/literal-replace-appends.md).

Prepared UTF-8 run tables are now shared through a bounded process cache
(8 slots, 4 MB, entries up to 256 KiB) for process-lifetime allocators; the
stream Han chain improves 1.08x (163.5 -> 151.1 us) because scanners are
created per stream and the Han table costs about 15.5 us to build. Tracking
allocators bypass the cache so leak checks still see every allocation.
Caching the multi-megabyte Qwen workspace tables was screened and rejected:
it slowed the CJK tokenizer by about 10%. See
[bounded UTF-8 run cache](benchmarks/utf8-run-cache.md).

The tokenizer's trailing `\s*[\r\n]+`, `\s+(?!\S)` and `\s+` branches are now
recognized as one exact `whitespace` later plan instead of falling back to
the search DFA per whitespace token. `find Qwen tokenizer` improves 1.05x
(42.7 -> 40.8 us); the `findAll` rows are noise-dominated (40-48 us per
round) and the control median is 1.00x. The lookahead form is accepted only
when its set is exactly the complement of the run set. See
[exact whitespace later plan](benchmarks/whitespace-later-plan.md).

Several further candidates were screened and reverted this round. A SIMD
range scan for the full-match set loop (`(?:[a-z0-9]+[ \n])+`) lowered 4.4x
slower than the byte table (78 -> 348 us on the 216 KiB case), matching the
earlier delimiter-scan result: vector range comparisons and lane masks lower
poorly for these short runs. Letting the punctuation later plan accept
non-ASCII runes was retried together with a direct `runEnd` (no first-rune
re-walk); it still lost to the search DFA by about 2% on the CJK tokenizer,
so the CJK punctuation token stays on the DFA. Inlining the deferred run
`runeAt`/`runEnd` wrappers, an input-sized reserve in the general
`replaceAll` writer, and a short scalar probe in `indexOfLiteral` were all
neutral (within 1-2%).

Unicode set searches whose first-byte summary is a plain non-ASCII set
(`\p{Han}+`) now accept a non-ASCII byte directly instead of calling the
first filter that would return the same offset. A focused `\p{Han}+` harness
improves 1.06x (125.1 -> 118.2 us per 191 KiB pass) and the full bench's
`find Han class scan` 1.02x, with the 66 control cases at a 1.01x median.
Prepared rune prefixes keep the filter call. See
[skipping the first filter](benchmarks/han-filter-skip.md).

A two-entry rune cache on the fast branch's non-ASCII prefix check was
screened and reverted: tokenizer text alternates a line-start letter and a
punctuation prefix, but the `mem.eql` verification on every miss cost more
than the table walk it saved (CJK tokenizer 166 -> 217 us). A two-byte
prefix bitmap was analyzed and not implemented: Han text accepts 14 runes per
2 rejected punctuation runes, so the extra check would be paid on every
accepted rune and could not replace any of the automaton's three loads.

Unicode property escapes now materialize once per compile: an 8-entry parser
cache keyed by name, negation and fold shares the set, and a `materialized`
field on `ParsedSet` lets standalone properties and unfold classes reuse it
without another normalize. Compile Qwen improves 1.13x on the page allocator
(39.0 -> 34.6 us) and 1.29x on smp (52.9 -> 41.2 us), with the 65 control
cases at a 1.02x median. See
[per-compile Unicode property cache](benchmarks/property-cache.md).

The compile-block pool now serves the smp allocator and its cap rises to
768 KiB. The earlier decision to keep smp on direct allocate/free was
retested after the Unicode property cache made compile faster: the 256 KiB
block allocation became a visible share, and the 512 KiB cap also prevented
the Qwen smp block from staying pooled once the xDS and long-literal blocks
were present. Compile Qwen (smp) improves 1.31x (44.1 -> 33.5 us) with the
page path and other compile controls at 0.98-0.99x. Tracking allocators stay
excluded. See [SMP compile-block pooling](benchmarks/smp-compile-pool.md).

Two more compile/stream candidates were screened and reverted. The pairwise
merge of class-union runs was retested after the property cache with
instrumentation confirming it ran (runs of 2-4 per union): it stayed about 5%
slower than the comparison sort (33.5-33.9 -> 35.1-35.5 us), so the sort
remains. Inlining `emitStarEmpty` into the streaming star loop to hoist the
empty-match suppression flags was neutral against the unchanged `[a-z]+`
control (0.94x versus 0.96x under the same host drift).

The streaming scanner's ASCII tight loops dropped their redundant
`items[scan] < 0x80` guards. The byte tables are only built for `ascii_only`
sets and leave every byte >= 0x80 false, so a high byte already stops a
member scan and is always a non-member; idle stretches now consume high bytes
byte-wise instead of handing each rune back to the decoder. A first screen
that changed only `skipNonMembers` was neutral (focused plus 0.98x), so the
member-run loop was included: a focused ten-round harness improves
`[a-z]+` 1.08x, `[a-z]*` 1.04x, and `[a-z]+ [a-z]+` 1.02x, and the fresh
67-case interleave reads 1.07x, 1.02x, and 1.03x with the 63 controls at a
1.01x median. Two earlier interleaves of the split variant reported the
untouched `[a-z]*` path at 0.88x, which identifies that row in those binaries
as layout noise rather than a code effect. See
[high-byte checks in stream loops](benchmarks/stream-high-byte-checks.md).

Replacement fuzzing (seed 20261121) exposed a wrong match in the literal-run
fast path: `b{1,2}[a-c]+` on ` 1abb2bbc` reported only `[6..9]`, missing
`[3..5]`, because the scanner consumes the optional literal greedily and
never retries without it while the optional `b` is also the first byte of the
trailing `[a-c]+` run. The detector now rejects a shape when the optional
literal is a run member with an empty middle, or when the optional byte
repeats the first middle byte; those programs use the general search. A
focused URL harness for the other literal-run shape (`https?://[^\s]+`)
stays at 0.99-1.01x, the replacement fuzzer passes on five seeds, and
regression tests cover both overlapping shapes.

`Regex.replaceAll` and `Regex.replacen` now take their workspace from the
same process slot that `Regex.findAll` already uses. The workspace is only
taken when the program id and the allocator vtable match (page and smp are
stateless, their `ptr` is undefined), and fresh workspaces are returned too,
so the pool warms after the first call. A focused harness improves
`Regex.replaceAll` 1.48x (5.3 -> 3.6 us) while the warm-workspace control is
0.99x; the comparison harness reads 1.11x on `a+` and 1.86x on `\A|\z` with
the 17 other cases at a 1.02x median. Evicting a workspace from another
program used to deinit it but leave the slot pointing at it, so a later take
could return freed memory; the slot is now cleared and a `findAll` eviction
test covers it. See
[pooled replacement workspaces](benchmarks/replace-workspace-pool.md).

Three CJK tokenizer scanner candidates were screened and reverted. A dense
3-byte range fast path (an arithmetic decode for covered ranges such as
`\u{4E00}`-`\u{9FFF}` instead of three dependent automaton loads) lowered
`find CJK tokenizer` from 166 us to 213-269 us depending on where the check
sat: the byte automaton already overlaps the independent loads of consecutive
runes, and the extra per-rune branch plus the larger `Utf8Run` struct cost
more than the saved loads. Removing the `runeAt` gate before `runEnd` also
lost, because `runeAt` is the cheaper rejection at non-member starts
(no-punctuation CJK text 128 -> 142 us). Reordering the dominant branch to
scan the run before the optional prefix for disjoint ASCII sets regressed
`find Qwen tokenizer` from 42.5-47.0 us to 49.7-60.5 us over five alternating
rounds. The prepared byte automaton and the greedy prefix probe stay as they
are; the remaining CJK time is mostly the run scan and the per-token prefix
probe, and both resist these micro-reorders.

The replacement workspace pool now holds a pointer instead of a value.
`ReplaceWorkspace` is 7.8 KiB because it inlines the byte tables and search
state, so every owning `findAll` and every pooled `replaceAll` moved it into
and out of the iterator. The pool allocates the workspace once per program,
`Matches` shrinks from 7,856 to 56 bytes, and the comparison harness improves
owning `findAll` 1.06x (45.3 -> 42.7 us) while the borrowed control stays at
1.00x; `replaceAll a+` improves 1.08x and `\A|\z` 1.29x with the other 15
cases at a 1.00x median. Owning `findAll` now matches the borrowed form
(1.52x ahead of Rust) and the zero-width replacement reaches 2.66x. See
[pooled replacement workspaces](benchmarks/replace-workspace-pool.md).

The fast branch's dominant run now scans ASCII members with the byte table
before handing the rest of the run to the prepared UTF-8 automaton. Once the
automaton table is prepared, ASCII letters were paying its state-indexed
dependency chain even though the ASCII table answers the same question with
independent loads. The new `Run.runEndAsciiFirst` is used only by the fast
branch, and its first-byte check keeps non-ASCII run starts (CJK) at the old
cost. `find Qwen tokenizer` improves 1.04x in a focused seven-round harness
and 1.05x in the full 67-case interleave with the 67-case median at 1.00x;
the comparison against Rust moves from 1.52x to 1.67x. See
[ASCII-first run scan](benchmarks/ascii-first-run-scan.md).

Three further tokenizer candidates were screened and reverted. Letting the
punctuation later plan scan non-ASCII runs directly (`。\n` in the CJK
tokenizer) measured within 1% of the search-DFA fallback in a focused
seven-round harness, and adding a two-entry positive rune cache to avoid the
automaton loads made it 2-3% slower: the DFA's four-byte scan is already
cheaper than the membership check plus tail scan. A vectorized 12-byte
dense-range scan (`@Vector(16, u8)` lane checks for Han) did not beat the
scalar automaton loop once the tail runes it skipped were accounted for.
Dropping the redundant previous-byte boundary check in `findWordRun`
regressed `find word boundary` 0.97x and `find word space word` 0.92x,
because the extra start comparison cost more than the load it saved. The CJK
time stays split between the run scan (about half, at the automaton's
throughput limit) and the per-token prefix probe plus DFA fallback.

Two whole-pattern literal shapes now bypass the search DFA. A `(?i)` literal
verifies ASCII candidate windows with a byte-wise fold and falls back to the
DFA only when a window contains a non-ASCII byte (Unicode simple folding);
a whole-pattern alternation of exact literals is recorded at compile time and
verified in source order at the first candidate. The multi-literal pair
filter was generalized to distinct first bytes and precomputes its lane
splats. The two new comparison cases, `(?i)alpha` and a five-word alternation
over the 96 KiB word text, had been 1.47x and 1.53x slower than Rust; they are
now 1.85x and 1.12x faster (2.83x and 1.77x internal speedups), and all 21
comparison cases are ahead. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Two more literal shapes gained direct paths after the expanded comparison
found them behind Rust. `set+ literal` with the literal's first byte outside
the set (`\w+@example\.com`) now searches the required literal and scans back
the maximal ASCII run; the chain detector rejects this shape because the
separator is too long, so it had been on the DFA. It is selected only when no
chain applies, so `[a-z]+@` keeps the chain path and the `RegexSet` separator
filter. The email case improves 5.6x internally and 3.43x ahead of Rust. For
literal alternations, the multi-literal filter is now built only for sets
with at most eight distinct first bytes; wider sets use the `PairSet`
nibble-table candidate filter, improving the 10-word alternation 1.17x
(1.20x ahead). The comparison now covers 26 cases: caseless literal and
alternation, 10-word alternation, Greek class, prefix+suffix and capture
replacement were added, and all 26 are faster than Rust. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Fixed-width concatenations of single-rune sets and literal bytes
(`\d{4}-\d{2}-\d{2}`) now have a direct path. The chain and run shapes only
cover variable-width runs, so dates had been running the search DFA at about
41 ns per match. The new `fixed_sequence` kind records the element sequence,
deduplicates the ASCII set tables, and verifies each candidate with byte
tables and literal compares; variable-width runs (`\d+`, `\d{1,3}`), captures,
non-ASCII sets and all-literal patterns keep their existing paths. The date
case improves 6.4x internally (252.2 -> 39.1 us) and moves from 1.9x behind
Rust to 3.53x ahead. The comparison now covers 30 cases (IPv4, date, 20-word
alternation and a multiline anchored line scan were added); all 30 are faster,
with the anchored line scan the thinnest at 1.09x. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Multiline line-start runs (`(?m)^\w+`) now have a direct path. The shape is a
start-line assertion followed by a run, which none of the existing run shapes
covered, so every line start went through the search DFA. The
`line_start_run` kind is selected for that exact instruction sequence in LF
newline mode with an ASCII-only set: a match can only start at a line start,
so each line start needs just the maximal run scan and lines beginning
outside the set are skipped with a newline search. The anchored line case
improves 3.5x internally (8.2 -> 2.2 us) and moves from 1.09x to 4.23x ahead
of Rust. End-line variants, non-ASCII sets and other newline modes stay on
the general engine. All 30 comparison cases remain faster, with variable
width IPv4 and the five-word alternation the thinnest at 1.16x. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Bounded set-run concatenations (`\d{1,3}(?:\.\d{1,3}){3}`) now have a
compile-time shape and a direct matcher. The compiler records the element
sequence when the whole pattern is a concatenation of ASCII sets with bounded
repetitions and at least one variable-width run; fixed repeats of a sequence
expand, while lazy/possessive repeats, captures, unbounded runs and non-ASCII
sets keep their existing paths. The matcher first tries a flat greedy walk,
which decides unambiguous candidates, and falls back to a step-bounded
backtracking matcher when a shorter run could succeed. IPv4 improves 1.78x
internally (119.8 -> 67.2 us) and moves from 1.16x to 2.12x ahead of Rust.
All 30 comparison cases remain faster, with the five-word alternation the
thinnest at 1.18x. See [literal fast paths](benchmarks/literal-fast-paths.md).

Unbounded run chains (`v?\d+\.\d+\.\d+`) now have a compile-time shape and a
direct flat walk. The chain detector only covers one separator, so these
patterns had been on the search DFA. The compiler records the sequence when
the whole pattern is ASCII `set+` runs separated by literal bytes with an
optional one-byte leading literal; each separator's first byte must be
outside the preceding run set and skipping the optional must not help, so the
walk needs no backtracking. Adjacent runs, non-ASCII sets and ambiguous
optionals fall back. The version case improves 1.74x internally (91.0 ->
52.3 us) and moves from 1.17x to 2.00x ahead of Rust. The comparison now
covers 35 cases (Unicode caseless literal, shared-prefix and one-char
alternations, hex color, version were added); all 35 are faster, with the
five-word and shared-prefix alternations the thinnest at 1.13-1.14x. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Four run-anchored shapes that had been on the search DFA now have direct
scans. `set* literal` (`.*test`) was the worst case: a nullable first set
made the DFA restart at every position, costing 1.98 ms on 22 KiB. The star
now consumes the maximal member run with the UTF-8 run scan (invalid bytes
stop it exactly as the engine does) and backtracks to the last literal
occurrence inside the run; a first-byte scalar scan beats a reverse memmem
for the occurrence search. It falls to about 30 us (65x) and is 1.25x ahead
of Rust. A single set byte then a greedy run (`[A-Za-z_]\w*`) improves 4.2x
(2.01x ahead), a run then a greedy `separator run` repetition
(`[a-z0-9-]+(?:\.[a-z0-9-]+)+`) improves 5.1x (3.51x ahead), and a run with
an optional `separator run` group before a literal (`\d+(?:\.\d+)?%`)
improves 4.9x (3.77x ahead). All are gated on ASCII-only sets and
separator/run disjointness so the flat walks need no backtracking. The
comparison now covers 41 cases and all are faster, with the five-word
alternation the thinnest at 1.19x. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Two more common shapes were fixed after the expanded comparison found them
behind. A literal alternation at the end of an unbounded chain
(`\w+@\w+\.(?:com|org|net)`) now becomes a chain element with branches stored
and checked in source order; the email-TLD case improves 2.6x and is 1.22x
ahead. The anchored-run path (`(?m)\w+$`) now uses a byte table for ASCII
anchor sets and only consults the newline mode when a run ends at a newline
or the text end; the end-anchored word case improves 2.4x and is 2.29x
ahead. The comparison now covers 47 cases and all are faster, with the
semver scan the thinnest at 1.01x. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Three sequence shapes were added after the expanded comparison found them
behind. `x? set+` with `x` in the set (`v?\w+`) matches the same spans as
`set+` and now takes the plain set-run path (2.7x, 1.83x ahead). The
unbounded chain now accepts adjacent runs with disjoint sets and `set*` runs
with a zero minimum, covering key-value scans (`\w+\s*=\s*\w+`, 3.5x, 2.48x
ahead), and a single member of a multi-member ASCII set is a chain element,
covering camelCase (`[a-z]+[A-Z][a-z]+`, 4.0x, 1.37x ahead). Overlapping
adjacent runs, ambiguous optionals and non-ASCII sets fall back. The
comparison now covers 52 cases and all are faster, with the semver scan the
thinnest at 1.01x. See [literal fast paths](benchmarks/literal-fast-paths.md).

Three refinements followed the expanded comparison. The bounded sequence now
accepts a trailing optional `separator set{min,max}` group, covering CIDR
forms (`\d{1,3}(?:\.\d{1,3}){3}(?:/\d{1,2})?`, 1.6x, 1.86x ahead). A new
bounded loop shape covers a bounded run followed by a greedy repetition of a
bounded `separator run` group (`\d{1,3}(?:,\d{3})+`, 2.9x, 2.98x ahead). The
unbounded chain skips the whole first run after a failed start, since every
start inside it shares the same run end and remaining input (semver, 1.1x,
1.15x ahead). All 52 comparison cases are faster, with the semver scan the
thinnest at 1.15x. See
[literal fast paths](benchmarks/literal-fast-paths.md).

Five shapes from the expanded comparison now have direct scans. Signed
numbers (`[+-]?\d+(?:\.\d+)?`) are detected from the AST with a sign set
disjoint from the digits (4.3x, 1.48x ahead). Markdown headings
(`(?m)^#{1,6} .*$`) get a line-heading scan that shortens the heading run
until the space matches and requires the body run to reach the line end
(3.8x, 1.22x ahead). Unbounded chains accept non-ASCII runs through the UTF-8
run scan, covering negated-class chains such as `\w+="[^"]*"` (2.1x, 1.98x
ahead). The UTF-8 run search skips short ASCII gaps with the state-0 row,
lifting the case-insensitive class scan 1.9x (1.66x ahead). The
literal-alternation extractor distributes literal prefixes and suffixes over
branches, so `(?:pre|post)fix` uses the literal-set filter (1.24x, 1.27x
ahead). Literal-alternation searches now return the matching branch from the
candidate filter, single-byte sets accept the first-byte hit directly, and
the prefix-run scan packs its membership sets into 64 bytes of bits, removing
a cache-set aliasing cliff that could make `[A-Za-z_]\w*` 3.5x slower. The
alternation cases improve 1.05-1.22x. Repeated fixed literal groups
(`(?:ab)+`) are scanned as greedy repetitions (2.8x, 3.04x ahead), markdown
heading scans skip the line-start search when the previous match ended at a
line break (2.02x ahead), candidate filters skip the three bytes they already
checked and drop the third-byte stage for distinct pairs (shared-prefix
1.32x, 10-word 1.45x), and chain walks compare single-byte separators
directly (semver 11% faster). Whole-pattern case-folded literal
alternations (`(?i)alpha|gamma`) now scan folded lanes and return the
matching branch, improving 1.58x (2.34x ahead). The caseless detector now
requires both ASCII cases per letter, which also fixes a pre-existing false
positive for case-sensitive scopes inside a caseless pattern (`(?i:ab)c`
must not match `ABC`). Dot-star literals find the line end with a vector scan that stops at the
first line break or non-ASCII byte, moving the nullable-prefix case from
1.30x to 3.83x. A CJK-specific three-byte shortcut in the fast-branch run
scan was measured and reverted: branchy per-rune checks were 62% slower than
the UTF-8 automaton's hot table lookup. Unbounded run chains now scan
contiguous ASCII runs with a range check instead of a byte table and dispatch
run/literal elements before the rare optional and alternation cases; the
semver, camelCase, IP-port and key-value scans improve 4-7%. Distinct-first
literal sets with four or more branches use the two-byte nibble filter,
improving the five-word alternation 16% (1.43x ahead). The tokenizer fast
branch scans four three-byte Han groups per vector iteration when the run set
covers U+4E00-U+9FFF, with the scalar UTF-8 scan resuming at the first
non-conforming group; a focused before/after run measured the CJK tokenizer
13% faster. The 58-case comparison table was not refreshed this turn because
the shared host was saturated (load average above 20); the last quiet-window
table remains in the comparison page. Unbounded run chains now record the
first run's end while scanning and reuse it for the failed-start skip instead
of rescanning the run, and they fuse a following single-byte literal into the
same iteration when at least two fused pairs exist. The fused state takes its
own `fast_kind` slot, so chains without fusion (camelCase, key-value) keep
the original walk and pay no per-search branch; a single fused pair stays
unfused because it measured slower. An order-balanced sweep measured semver
1.16x, email TLD 1.14x, IP-port 1.13x and HTML-attribute 1.07x faster, with
an A/A control spread of 0.90-1.05x on unrelated cases. The folded-literal
scan now separates a definitive ASCII miss from a non-ASCII fold-peer
window, so `(?i)` literal misses no longer fall through to a second generic
scan and the interpreter; the 23 KiB `(?i)STRASSE` no-match returns from
2.8 us to 1.6 us, matching the benchmark baseline. `Workspace.find` is now a
small entry point that forces the `set+` scanner inline and tries a `.none`
program's dominant branch, then delegates every other shape to a
never-inlined `findDispatch`; heavy literal and anchored scanners are no
longer inline, keeping the dispatch prologue lean. LLVM inlines the small
entry into caller match loops, so match-dense scans stop paying a call plus a
`Match` copy per match. An order-balanced sweep measured optional-prefix run
2.57x, Qwen find/findAll 1.24-1.26x, signed number 1.22x, line full 1.21x,
percent 1.10x, one-char alternation 1.10x and word boundary 1.09x faster;
unrelated non-`find` cases moved 1.10-1.26x in the same noisy sweep, and
unbounded-chain shapes pay the one dispatch call (1.06-1.10x) while staying
ahead of Rust. Whole-pattern literal alternations now split the distinct-first
kind from the shared-first kind at construction, so the dispatch no longer
tests `shared_first` per search; the distinct, pair-set, single-byte and
case-folded scanners return a `bool` after writing the slots and the dispatch
builds the `Match` directly, removing a stack temporary and a ~56-byte copy
per match. An order-balanced sweep measured the 5-word alternation 1.17x,
10-word 1.13x, 20-word 1.13x, `(?i)` alternation 1.12x, shared-prefix 1.08x
and one-char 1.06x faster; unrelated non-scanner cases moved up to 1.09x in
the same noisy sweep. See
[literal-set scanner spans](benchmarks/literal-set-spans.md),
[find hot-path dispatch](benchmarks/find-hot-dispatch.md),
[unbounded chain fusion](benchmarks/unbounded-chain-fusion.md) and
[literal fast paths](benchmarks/literal-fast-paths.md).

The camelCase chain (`[a-z]+[A-Z][a-z]+`) now has a dedicated walk. The
unbounded sequence recognizes exactly three elements whose first and third
are the same contiguous ASCII run with minimum one and whose middle is one
disjoint contiguous ASCII set. The walk scans the lower run, tests one upper
byte with a range check, requires a lower byte and extends the second run;
failed starts still skip the whole first run. An order-balanced sweep
measured the camelCase case 1.25x faster (87.2 us -> 69.6 us), with unrelated
non-camel cases moving up to 1.25x in the same noisy sweep. See
[camelCase dedicated walk](benchmarks/camel-walk.md).

Run-first unbounded chains now peel the first element out of the generic
element loop: the walk scans the run/run_range, keeps its end for the
failed-start skip, and starts the loop at the next element, dropping the
`index == 0` check from every element. Isolated order-balanced runs measured
semver 1.14x and email TLD 1.14x faster, and an order-balanced comparison
batch measured semver 1.08x, email TLD 1.12x and IP port 1.07x faster. See
[unbounded chain fusion](benchmarks/unbounded-chain-fusion.md).

A differential-fuzz mismatch exposed two fast-branch plan bugs. `laterPlan`
treated `A?\s+(?!\S)` as `A?\s+`, dropping the lookahead, and the collapsed
whitespace plan assumed a bare `\s+` fallback that may not exist, so a
single space before text (and a newline-only plan without a newline) wrongly
matched. Lookaround-containing branches are now left to the engine, the plan
records whether a bare `\s+` follows, and the scanner tries the newline,
lookahead and bare branches in source order. The failing fuzz seed and the
extended fuzzer pass, and a regression test compares the fast plan against
the engine for these shapes.

Five literal-set verification refinements were screened and reverted. A
distinct-first first-byte index and a length-specialized tail compare were
neutral (the 20-literal set shares `e`/`t` first bytes, and the compiler
already specializes short tails). Replacing the pair bitmap with a 64-entry
pair hash table was 1.30-1.33x slower on the 10/20-word alternations: the
small literal loop and hot pair bitmap beat a dependent hash probe. Inlining
the pair scanner into the dispatch regressed the 10/20-word scans 6-7% by
inflating the dispatch prologue. A vectorized contiguous-range run scan was
2.4x slower on short runs (version, IP-port) because the 16-byte setup
dominates two-to-four-byte runs. The alternation scanners keep their current
shape; the profile attributes about 28% of the 20-word scan to `matchesAt`
and 34% to the nibble scan, so a bucket-bit candidate dispatch remains the
next candidate.

Three further refinements were screened and reverted. A Greek-block vector
scan cannot be exact: `\p{Script=Greek}` excludes Common codepoints inside
U+0370-U+03FF (U+037E, U+0387) and its per-lead continuation sets are
non-contiguous, so a block or rectangle check would overmatch, and the exact
256-entry automaton cannot be vectorized with NEON `tbl`. Splitting
`findOnce` into a tiny entry plus a never-inlined one-shot dispatcher changed
the `findAll` Qwen cases by only 0.98-0.99x with mixed find-case movements in
the same noisy batch, so the duplicate switch stays. Forwarding the literal
scanner return slot with `@call(.always_tail)` is rejected by LLVM ("musttail
call must precede a ret") for Zig error-union returns, so the ~56-byte
`Match` copy at the dispatch boundary remains.

Two dispatch-entry refinements were screened and reverted. Adding a
whole-pattern literal-set branch to the small `find` entry (a dedicated
never-inlined `findLiteralSet`) regressed the alternation scans 1.10-1.11x
and `\d+` 1.16x: the extra branch pushes the entry past the inliner's
threshold, so the per-call inlining that the `set+` and tokenizer paths rely
on is lost. Moving the general prefilter/DFA tail out of `findDispatch` into
a never-inlined `findGeneric` shrank the dispatch frame by 80 bytes but
measured neutral across the isolated cases (alternation 10/20-word 0.97-0.98x,
shared-prefix 1.03x, version 1.04x), so the tail stays inline. The small
`find` entry and the dispatch shape remain unchanged.

A first-byte SIMD byte scan for shared-prefix `MultiFilter`s (one splat
followed by per-candidate verification) was screened and reverted: the
shared-prefix alternation regressed 1.39x because the four-splat block
filter amortizes across the 16-byte block while the byte scan re-scans
overlapping regions at every hit. The shared-prefix block filter stays.

Inlining the literal-set scan loops into the scanner functions (removing one
call per match) measured 0.97-0.99x on the 10/20-word alternations and 0.95x
on shared-prefix in one isolated batch, but 0.99-1.01x with shared-prefix
1.05x in the comparison harness, while unrelated cases moved by up to 1.13x.
The effect is below the shared host's noise floor and the change is
reverted; the scan loops stay as separate functions.

An expanded 63-case comparison suite exposed four common real-world patterns
that were behind Rust. Whole-pattern `set{min,}` with an unbounded maximum
now has an AST-detected `set_run_min` scanner (`\s{2,}` 5.0x, from 0.24x to
1.63x of Rust). A line-marker shape scans `(?m)^space* marker literal`
(`(?m)^\s*[-*+] ` 5.8x, 0.30x to 1.61x). An escaped-delimited shape scans
`quote(?:\\.|[^"\\])*quote` while honoring escapes and UTF-8
(`"(?:\\.|[^"\\])*"` 6.5x, 0.33x to 2.15x). Distinct-first alternations
with three pairs now use the nibble pair filter instead of splats, cutting
the case-insensitive three-literal no-match scan from 5.7 us to 2.2 us
(0.36x to 0.93x). A two-byte SIMD pair filter then took runs of two or more
spaces from 10.4 us to 4.9 us (2.1x, 0.86x to about 1.9x). All 63 cases
were ahead in that sweep; the case-insensitive log level was at parity within
host noise (1.08x). See
[Rust comparison](benchmarks/rust-comparison.md).

An expanded 71-case comparison suite exposed eight real-world patterns.
Markdown headings and list markers now accept a greedy `set+` separator in
the line shapes, so `(?m)^#{1,6}\s+.*$` and `(?m)^\s*[-*+] ` use the line
scanners (heading 249.1 us -> 37.7 us, list 106.5 us -> 2.6 us). The
escaped-delimited detector also recognizes the loop form
`quote body* (?: escape any body* )* quote`, sharing the escape-aware scanner
with the alternate form (JSON loop strings 36.4 us -> 9.1 us, 1.87x ahead of
Rust). A bounded word alternation with ASCII word boundaries
(`\b(?:get|post|put|delete)\b`) scans a case-folded two-byte pair filter in
one 32-byte-unrolled pass and verifies the boundaries and alternatives
locally; verification accepts the non-ASCII simple-fold peers U+017F and
U+212A, and a literal with a peer in its first two bytes falls back to the
engine because the pair filter folds ASCII only (HTTP methods 22.5 us ->
1.8 us, 0.97x of Rust, from 0.07x). Full email addresses scan around each
`@`: the local run starts at the first boundary inside it and the domain
walks dots from the end, mirroring the greedy `domain+ \.` backtracking
(50.4 us -> 14.0 us, 1.78x ahead). The number shape now covers an optional
exponent (`\d+(?:\.\d+)?(?:[eE][+-]?\d+)?`, 168.5 us -> 38.5 us, 1.59x
ahead), `(?m)^\s*$` scans line runs directly (1.83x ahead), and the
single-byte prefilter scans 64 bytes per iteration (currency no-match 679 ns
-> 342 ns, parity with Rust). The Zig loop-form harness pattern had one less
backslash level than the Rust pattern; the escaping is fixed so both sides
benchmark the same regex.

Three refinements were screened and reverted. A third-byte lane filter for
word alternations rejects pair collisions before verification, but the extra
vector compares and the per-chunk optional check made the HTTP-method scan
2.2x slower (1.75 us -> 3.8 us), so the pair filter stays. A first-byte
candidate scan built on `FirstFilter` measured 8.8 us on the 25 KiB text
because every hit restarts the 16-byte filter loop; the single-pass nibble
pair scan is retained.

The latest six-execution interleaved sweep covers 71 cases: 69 are ahead,
the case-insensitive log level and HTTP methods are at parity within host
noise (1.00x and 0.97x), and the geometric-mean ratio is 2.63x. See
[Rust comparison](benchmarks/rust-comparison.md).

A second expansion brought the comparison suite to 83 cases. Hashtags and
mentions already used the prefix-run shape, but its first-byte scan was a
byte loop; a vector `FirstFilter` (with a scalar probe retained for dense
sets) moved `#\w+` and `@\w+` from 0.26x and 0.21x to 1.30x and 1.31x. CSS
units (`\d+(?:px|em|rem|%)`) now scan a digit run and check the literal
alternation, skipping the run when no suffix follows, and probe scalar before
the vector filter because unit runs sit a few bytes apart (0.29x to 1.11x).
HTML comments (`<!--[\s\S]*?-->`) scan a literal prefix and the first close
after it (0.04x to 2.57x). Multi-byte needles now anchor on their rarest byte
(by text commonness) and verify the full window, so the `<!--` no-match scan
runs at single-byte speed instead of two-byte-pair speed. Query parameters
(`[?&]\w+=`) scan a prefix set, a word run and the literal (0.58x to 1.52x).
JSON keys (`"[^"]+"\s*:`) scan the quoted run, the closing quote, optional
spaces and the colon (0.87x to 1.51x). A case-insensitive word alternation
with a non-ASCII fold peer in its first two bytes now keeps the pair filter:
the detector adds folded peer variants (`s` -> `0xE5 0xBF`, `k` -> `0xE2 0x84
0xAA`) to the candidate literals while verification uses the canonical form,
and the scalar pair fallback now folds with `| 0x20` like the SIMD lane.
`(?i)\b(?:select|from|where|join)\b` moved from 0.03x to parity. The
single-byte prefilter scans 128 bytes per iteration and the pair prefilter 64
bytes; currency moved from 0.49x to 1.06x and ordered lists from 0.97x to
1.02x, and the identifier case rose to 1.93x.

A 64-byte unroll of the word-alternation scan was screened and reverted: the
four-chunk candidate table and loop made the HTTP-method scan 1.6x slower
(1.7 us to 2.7-2.9 us), so the two-chunk loop stays. The third-byte lane
filter remains rejected (see the previous section). The latest six-execution
interleaved sweep covers 83 cases: 78 are faster, log level, SQL keywords,
blank lines and blockquotes are at parity within host noise (0.98x, 1.00x,
0.95x and 0.91x), HTTP methods measured 0.81x after 1.03x in the previous
sweep (about 25% host variance at this scale), and the geometric-mean ratio
is 2.38x. See [Rust comparison](benchmarks/rust-comparison.md).

A third expansion brought the suite to 93 cases. Markdown links
(`\[[^\]]+\]\([^)]+\)`) get a paired-delimiter scanner that walks the
bracket body, the `](` pair and the paren body (0.03x to 1.10x). Template
interpolation (`\$\{[^}]+\}`) gets a multi-byte open/run/close wrapper
(0.90x to 1.48x). YAML keys and TOML tables scan for their `:` or `[`
literal and verify the surrounding line context instead of walking every
line, so the key and space runs can cross line breaks without a per-line
scan (YAML 0.26x to 1.66x, TOML 0.40x to 1.40x). Windows paths scan for the
colon and check the drive letter and separator before consuming the run
(0.49x to 2.99x). MAC addresses, base64 runs, slash dates and HTTP request
lines already used existing walks and are 1.50x, 1.89x, 2.98x and 1.63x
ahead; CSS selectors are 1.14x ahead.

The single-byte prefilter was split by gap length. A 128-byte unroll helps
one-shot scans over large inputs, but it regressed short line-walk gaps
(blank lines 3.5 us to 7.5 us) because the larger hot loop no longer inlined.
Long scans now use the 128-byte loop, short scans keep the 64-byte loop, and
the width dispatch is inline, so `nextLineStart` keeps its small loop. Blank
lines moved from 0.87x to 1.94x and currency reached 1.03x. A 64-byte unroll
of the word-alternation scan remains rejected (see the previous section).

The latest six-execution interleaved sweep covers 93 cases: 89 are faster,
HTTP methods, hashtags and mentions are at parity within host noise
(0.95x, 0.94x and 0.95x), and the case-insensitive log level measured 3.17 us
in this batch versus about 2.1 us in isolation, so its 0.68x is a host
outlier. The geometric-mean ratio is 2.21x. See
[Rust comparison](benchmarks/rust-comparison.md).

A fourth expansion brought the suite to 101 cases (IPv6, C comments,
markdown images, HTML tag names, shell variables, and split lines and
semicolons) and moved the measured host to Linux x86_64 (Intel Raptor
Lake). The two-byte nibble filter now emits VEX-encoded `vpshufb` on x86_64
and runs 32 lanes at a time on AVX2, with `vzeroupper` before returning to
legacy SSE code. Candidate lanes are walked inside a chunk for word
alternations, sparse pair sets and single-byte prefix runs; first-byte scans
use `@ctz` of the lane mask; the pair filter keeps its third-byte check for
small allowed sets; and single-byte splits always use the counted mask
fill. CSS units take a direct dispatch path in `find`, and the suffix table
maps a first byte to one literal. Class normalization sorts ranges by start
only, removing a mispredicting end tie-break on the many equal starts from
Unicode property unions. Caseless literal alternations reuse the 32-lane
nibble scan, improving `(?i)error|warn|info` about 1.9x. Persistent
workspaces moved behind pointers, shrinking `Regex` from about 33 KiB to
3 KiB and cutting xDS-like compile 2.1x and Qwen 1.16x. The parser's class
operand is normalized in place, avoiding a copy before the sort. Adjacent
positive `\p{...}` atoms use precomputed sorted unions (L+M, L+N, L+M+N),
keeping the operand sorted so `normalize` skips its sort. Non-negated
classes return the normalized set directly; negated classes complement the
normalized ranges without a copy. Precomputed unions are merged directly
from the generated table without an intermediate set, and coalesced range
lists skip the merge loop. Case-folded literal filters use a 32-lane pair
scan on AVX2 hosts. The latest eight-execution order-balanced
sweep covers 101 cases: 98 are faster, IPv6 is at parity (1.01x), and the
remaining losses are the one-character alternation (0.88x), currency (0.92x)
and HTML tags (0.92x). The geometric-mean ratio is 2.30x. See
[Rust comparison](benchmarks/rust-comparison.md).

The same 100-case workload (minus `RegexSet`) was also run against PCRE2
10.42 with JIT on the same host. regexz is faster or at parity on 98 of 100
cases, with a geometric-mean PCRE2/regexz ratio of 2.13x. PCRE2 wins compile
Qwen (0.69x); the small ASCII case-insensitive literal is at parity (0.99x).
regexz now also wins compile xDS-like (1.21x). regexz materializes Unicode
property sets at compile time, while PCRE2 defers them. See
[PCRE2 comparison](benchmarks/pcre2-comparison.md).
