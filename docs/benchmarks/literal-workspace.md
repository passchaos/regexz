# Allocation-free literal full-match workspaces

Baseline: `a933a4b`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Every full-match workspace previously allocated NFA scratch, including
programs with an exact whole-pattern literal. Literal matching, forced-NFA
matching and partial matching already returned from the literal check before
using those buffers. Initialization now returns empty scratch views for these
programs. The debug scratch-size assertion follows the literal check; request
budget checks still precede it. Nonliteral initialization retains its existing
allocation and error contract.

## Measurements

The isolated candidate changes only literal initialization and the scratch
assertion in `execute.zig`. Both snapshots use the same `bench-startup` source.
Three executions alternate before/after, after/before, before/after; each
reports the median of five batches. Raw samples, counters and executable
identities are in [`literal-workspace.json`](literal-workspace.json).

| Literal phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| workspace initialization | 49.4 | 27.8 | 1.78x |
| initialization and first match | 49.8 | 28.4 | 1.75x |
| initialization and three matches | 52.3 | 31.5 | 1.66x |
| warmed matching | 1.8 | 1.8 | 1.00x |
| compilation and first match | 1,395.2 | 1,419.2 | 0.98x |

Workspace allocations drop from one to zero, eliminating 792 scratch bytes
for the 13-byte benchmark literal. The eliminated scratch bytes scale with the literal's
instruction count. Compilation remains the dominant cost in the combined
phase, whose sample varied upward by 2% on the shared host. This change
targets workspace setup and allocation.

## Validation

```sh
zig build test-lib -Dtest-filter='literal workspace' -Dtest-filter='expired and interrupted' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
zig build bench-startup -Doptimize=ReleaseFast
zig fmt --check src/regex/execute.zig src/regex/literal_workspace_tests.zig src/root.zig
```

The isolated candidate and integrated workspace both passed all six scoped
tests. The integrated workspace also passed 8,100 V8 comparisons and formatting
checks; its startup check confirmed zero allocations and zero scratch bytes.
Coverage includes empty,
ASCII, Unicode and quoted literals; full matching and proper partial prefixes
(including a split UTF-8 sequence); zero allocation with a failing allocator;
timeouts and cancellation; and retained OOM behavior for nonliteral programs.
