# Combined active and longest-match capture storage

Baseline: `b339f67`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

`ReplaceWorkspace.init` previously allocated active capture slots and
longest-match backup slots separately. Both buffers have the same fixed slot
count and remain alive for the workspace's entire lifetime.

Initialization now allocates one `usize` array, clears it once, and exposes
two disjoint views. The active slots begin at the allocation base; the backup
starts immediately after them. Deinitialization frees the full allocation
once. A construction failure also frees that one block through `errdefer`.

Both views retain their previous capacity even when longest mode is disabled.
Capture saves, backtracking trails, longest winner restoration, extended-mode
delegation and returned `Match.slots` continue using their original views.
The complete backup remains independent from active slots, so backtracking
cannot overwrite a saved longest winner.

## Measurement method

The fixed baseline is a `git archive` of `b339f67` with the same updated
`tools/bench/branch_startup.zig` benchmark copied into it. The benchmark retains
Qwen and ordinary set-run controls, adds Unicode capture, nested capture and
ASCII word-capture cases, and reads every returned capture slot into its pass
checksum. Subjects remain heap-backed and runtime input barriers remain.

Each phase reports a median of five batches; three executions alternate
before/after, after/before, before/after. Phases separate initialization, first
searches, complete cold passes and warmed calls. Raw samples, allocation
counters and executable SHA-256 identities are in
[`capture-storage.json`](capture-storage.json).

## Measurements

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| Qwen ASCII token / initialization | 441.3 | 449.2 | 0.98x |
| Letters search / initialization | 369.6 | 386.7 | 0.96x |
| Unicode capture / initialization | 355.8 | 377.5 | 0.94x |
| Nested Unicode capture / initialization | 323.8 | 355.0 | 0.91x |
| Word capture / initialization | 331.3 | 318.3 | 1.04x |
| Unicode capture / warmed first search | 24.4 | 23.2 | 1.05x |
| Nested Unicode capture / warmed first search | 23.8 | 24.9 | 0.96x |
| Word capture / warmed first search | 7.8 | 7.8 | 1.00x |
| Letters ASCII text / warmed pass | 18,995.8 | 17,897.4 | 1.06x |
| Letters mixed text / warmed pass | 19,208.9 | 19,570.3 | 0.98x |

All 80 phases in every round reduce initialization allocations from two to
one. Cumulative requested initialization bytes and workspace value size remain
identical. Capture-free cases request 32 bytes, ordinary single captures
request 64 bytes, and nested captures request 96 bytes. Workspace value size
remains 6,592 bytes. The allocation combines the existing two views and
retains the full longest-match backup.

The qualified benefit is one fewer allocation and free per workspace lifetime.
Timing samples do not establish a general construction-latency gain: the
three capture cases ranged from about 4% faster to about 10% slower. Their
warmed first searches were within 1.2 ns of the baseline, and other warmed
controls also varied on the shared host. These samples do not establish a
capture-throughput gain. The benchmark now reads every capture slot, and
those identical updated workload sources are used in both snapshots.

## Validation

```sh
zig build test-lib -Dtest-filter='capture storage' -Dtest-filter='leftmost-longest' -Dtest-filter='capture run' -Dtest-filter='deferred search' -Dtest-filter='deferred run' -Dtest-filter='replacement output allocation' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/replace.zig src/regex/capture_storage_tests.zig src/regex/deferred_search_tests.zig src/regex/deferred_run_tests.zig src/regex/capture_run_tests.zig src/root.zig tools/bench/branch_startup.zig
```

Scoped tests verify independent active/backup writes and equal capacities in
ordinary and longest modes, longest winners across repeated backtracking,
required allocation failure, capture slot reuse, Unicode cache preparation and
failure fallback, replacement allocation rollback and complete cleanup. The
existing no-additional-allocation fixtures now fail immediately after the one
required capture block, preserving their earlier allocation-avoidance contract.

All 26 scoped tests passed, including ordinary and longest captures,
backtracking restoration, allocation failure and cleanup. The V8 harness
passed 8,808 comparisons; the 56-case performance gate and formatting checks
passed. Three complete alternating rounds covered 80 phases per executable.
Allocation counts and executable identities were verified across every round.
