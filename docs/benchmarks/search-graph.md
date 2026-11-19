# Reused search-DFA construction walks

Baseline: `dabfc95`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Search-DFA initialization repeatedly allocated visit arrays and DFS stacks
for priority assignment, loop reachability, loop masks and safe-exit checks.
Optional chains and tokenizer patterns multiplied this allocator work.

`search_graph.Walk` now supplies one temporary allocation for all those walks.
The byte visit epochs clear on rollover; every reset otherwise reuses the same
storage. Nodes are marked when popped, preserving the left-first priority
assignment's original order. With at most two successors per visited node,
the pending stack is bounded by instruction count plus one. The temporary
allocation is freed after graph analysis, before UTF-8 automata and execution
buffers are constructed. All eligibility checks and interpreter fallbacks
retain their original conditions.

## Measurements

Both snapshots use the same expanded `bench-search_startup` cases. Each phase
reports the median of five batches. Three executions were interleaved
before/after, after/before, before/after. Raw samples, executable identities
and allocation counters are in [`search-graph.json`](search-graph.json).
Counters measure direct DFA initialization, separately from its first search,
and were identical across all executions and modes.

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| optional chain / initialization | 807.1 | 559.0 | 1.44x |
| optional chain / initialization and first DFA search | 2,917.0 | 1,926.8 | 1.51x |
| optional chain / complete fresh API search | 2,880.3 | 2,415.0 | 1.19x |
| Qwen / DFA initialization | 756.5 | 579.5 | 1.31x |
| greedy capture chain / complete fresh API search | 1,810.1 | 1,485.8 | 1.22x |
| rejected mixed lazy loops / initialization | 190.6 | 109.0 | 1.75x |
| ASCII alternatives / warmed API | 13.4 | 13.4 | 1.00x |
| Unicode lookahead / warmed API | 22.5 | 21.8 | 1.03x |
| Qwen / complete fresh API search | 878,163.8 | 892,228.5 | 0.98x |

Optional-chain construction drops from 34 to 12 allocations and from 6,643
to 4,931 cumulative requested bytes. Qwen DFA construction drops from 36 to
12 allocations and from 13,928 to 11,624 requested bytes. Rejecting the mixed
lazy-loop pattern drops from 18 to five allocations and from 1,112 to 132
requested bytes. First-search allocation counts and bytes remain unchanged
for every benchmark case.

The measured benefit is graph construction and eligibility rejection.
Warmed controls varied by small amounts on the shared host. Complete Qwen
workspace setup is about 0.88 ms and is dominated by the dominant branch's
eager UTF-8 tables; graph construction is only a small part of that cost.
The Qwen API row above does not establish a startup gain for that path.

An initial variant also requested exact capacities for the three execution
work arrays. Six interleaved executions found a repeatable Unicode warmed-API
slowdown (21.8 to 25.4 ns). The final implementation retains standard
`ArrayList` growth. These negative samples are archived in
[`search-graph-tight.json`](search-graph-tight.json).

## Validation

```sh
zig build test-lib -Dtest-filter='search graph' -Dtest-filter='search DFA' -Dtest-filter='lazy loops' -Dtest-filter='unbounded repeats' -Dtest-filter='branch reset' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/search_graph.zig src/regex/search_graph_tests.zig src/regex/search_dfa.zig src/root.zig tools/bench/search_startup.zig
zig build bench-search_startup -Doptimize=ReleaseFast
```

All 16 scoped tests, 8,400 V8 comparisons, the 56-case performance gate and
formatting checks passed. Tests cover epoch rollover, bounded cyclic walks
with no further allocation, exact spans and captures, eligible optional
chains, rejected loop shapes, and cleanup at every induced allocation failure.
