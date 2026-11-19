# Borrowed full-match DFA construction scratch

Baseline: `eeff739`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The full-match workspace already owns six instruction-list/stack views and
five NFA visit views in one allocation. Its lazy DFA previously allocated
another two instruction-sized `u32` arrays for canonical state keys and visit
epochs. That allocation duplicated storage already available between NFA calls.

The DFA now borrows `storage[n..2n]` for canonical keys and `seen[0..n]` for
closure visits. These views are disjoint from the DFA's live list at
`storage[0..n]` and stack at `storage[5n..6n]`. Accepted DFA states and hash keys
still copy their instructions into the DFA arena; no cache key retains a
mutable scratch view.

NFA execution marks the shared visits invalid before clearing or writing them.
The next uncached DFA transition or initial closure clears those visits before
using its own generation. Epoch wrap also clears them. Cached transitions do
not consult visits and retain their existing scan. Budget failures before NFA
storage is touched need no invalidation; cancellation after writing the buffer
retains the invalid marker for the next DFA closure.

The DFA releases its owned state arrays, hash index, transition cache and
arena. The parent workspace remains the sole owner of the borrowed buffers and
frees them after DFA deinitialization. Their backing allocation remains stable
when the workspace value moves.

## Measurement method

The fixed baseline is a `git archive` of `eeff739`; both snapshots use the
same existing `tools/bench/startup.zig`. The `dfa_cold` phase constructs a
workspace and makes three calls, triggering lazy construction for small
subjects. Other phases retain workspace initialization, first calls and warmed
matching controls. Each phase reports a median of five batches; three
executions alternate before/after, after/before, before/after. Raw samples,
allocation counters and executable SHA-256 identities are in
[`dfa-scratch.json`](dfa-scratch.json).

## Measurements

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| ASCII alternation / DFA construction | 920.3 | 923.3 | 1.00x |
| xDS path / DFA construction | 1,869.3 | 1,899.0 | 0.98x |
| Mixed Unicode / DFA construction | 557.0 | 574.6 | 0.97x |
| Unicode pattern, ASCII input / DFA construction | 864.0 | 890.9 | 0.97x |
| Varied Unicode / first call | 96,093.8 | 85,546.9 | 1.12x |
| Varied Unicode / three cold calls | 136,364.6 | 120,104.1 | 1.14x |
| Unicode collisions / DFA construction | 83,140.6 | 87,760.5 | 0.95x |
| ASCII alternation / warmed match | 5.7 | 5.4 | 1.06x |
| xDS path / warmed match | 8.7 | 8.0 | 1.09x |
| Mixed Unicode / warmed match | 12.8 | 12.2 | 1.05x |
| Varied Unicode / warmed match | 17,709.0 | 14,133.2 | 1.25x |

Every DFA construction drops one allocation and `8 * instruction_count`
requested bytes. The ASCII alternation goes from nine post-initialization
allocations and 20,358 requested bytes to eight allocations and 20,254 bytes
(104 bytes saved). The xDS path goes from 13 allocations and 46,644 bytes to
12 allocations and 46,404 bytes (240 bytes saved). Mixed Unicode goes from
seven allocations and 7,142 bytes to six allocations and 7,070 bytes
(72 bytes saved). Long varied Unicode drops from seven allocations and
68,582 bytes to six allocations and 68,510 bytes.

Initialization and Unicode-cache capacities retain their previous counts.
Workspace value size stays 1,280 bytes, including the visit invalidation flag.
The tables and cache keys retain their owned storage; the existing NFA buffers
serve both engines without another allocation.

The qualified benefit is allocation and temporary-storage reduction. Small
DFA construction timings ranged from nearly unchanged to about 3.2% slower,
so these samples do not establish a construction-latency gain. Long varied
Unicode and collision phases showed larger shared-host variation, including
a 25% warmed change; unchanged startup controls also varied. These samples do
not establish a general warmed-throughput gain. Explicit NFA evaluation marks
visits invalid, and the next uncached DFA closure clears them once.

## Validation

```sh
zig build test-lib -Dtest-filter='DFA borrowed' -Dtest-filter='DFA construction allocation' -Dtest-filter='DFA omits' -Dtest-filter='Unicode DFA' -Dtest-filter='lazy DFA falls back' -Dtest-filter='expired and interrupted' --summary all
zig build test-lib -Dtest-filter='DFA borrowed' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/execute.zig src/regex/dfa_scratch_tests.zig src/root.zig
```

Scoped checks cover borrowed-buffer boundaries, clobbered visit generations,
wraparound, DFA/NFA alternation, partial matching, strict budgets, cancellation
after NFA writes, optional allocation failures and full cleanup. Existing
Unicode promotion and randomized DFA-versus-NFA checks retain varied transition
and cache-state coverage.

The 13 integrated scoped tests and the subsequent six-test borrowed-buffer
run passed, including the added mid-evaluation cancellation case. The V8
harness passed 8,808 comparisons, the 56-case performance gate passed, and
formatting checks passed. Three complete alternating rounds covered 75 phases
in each executable. Allocation reductions and executable identities were
verified across all rounds.
