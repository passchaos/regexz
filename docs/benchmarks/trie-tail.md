# Ordered tail reuse during UTF-8 trie construction

Baseline: `c0bd8b5`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The UTF-8 builder stores child edges in a linked list, appended in strictly
increasing `lo` order. Its previous child lookup searched from the first edge
even when range emission reused the last prefix or added a new range after
every existing edge. Wide Unicode sets therefore repeated scans of earlier
prefixes during construction.

Child lookup now checks the existing tail edge first. An exact tail range
reuses its child immediately. A requested lower byte beyond the tail cannot
name an existing edge, so it goes directly to the original append path.
Earlier prefixes retain the complete linked-list lookup. The original
append-order assertion, owner reload after reallocations and allocation
rollback remain.

No lookup cache or allocation is added. Compact and dense finishes consume
the same builder, keeping state numbers, edge ordering, accepts and table
rows unchanged. Matching and table lookup loops are unchanged.

## Measurement method

The fixed baseline is an exact `git archive` of `c0bd8b5`; benchmark sources
are byte-for-byte identical. Startup workloads retain explicit Greek, Han
and wide-letter table construction, cold and warmed searches, prefix filters,
ASCII controls and capture cases. The capture suite reads all returned slots
into each pass checksum. Runtime input-pointer barriers remain.

Each executable reports medians of five batches, with phase-specific startup
lengths and 100 iterations per capture batch. Three frozen-executable rounds
alternate before/after, after/before, before/after under the shared build
guard. Construction and first-find allocation counters, requested bytes and
workspace sizes are recorded separately. Raw samples and executable SHA-256
identities are in [`trie-tail.json`](trie-tail.json).

## Validation

```sh
zig build test-lib -Dtest-filter='utf8 builder' -Dtest-filter='utf8 automaton matches' -Dtest-filter='utf8 automaton rejects' -Dtest-filter='utf8 automaton construction' -Dtest-filter='expanded UTF8' --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter='utf8 builder' -Dtest-filter='utf8 automaton matches' -Dtest-filter='utf8 automaton rejects' -Dtest-filter='utf8 automaton construction' -Dtest-filter='expanded UTF8' -Dtest-filter='deferred search' -Dtest-filter='deferred workspace' -Dtest-filter='deferred run' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/utf8_set.zig
```

The new structural check reuses both the tail and earlier prefixes and
verifies no duplicate nodes/edges are created. Independent membership checks
enumerate every codepoint through ASCII, Han and UTF-8 segment-boundary sets;
their reference is the original range list rather than another builder
finish. Expanded rows remain compared with compact transitions for every
state/byte. Malformed encodings, compact/dense allocation rollback and
full-match/search preparation and failure fallback remain covered.
