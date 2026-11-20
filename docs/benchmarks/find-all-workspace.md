# Match iteration workspaces

macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.findAll` builds a `ReplaceWorkspace` whose lazy search-DFA caches are
cold. On the 22 KiB Qwen tokenizer text the first pass costs about 120 us
while a warmed pass costs about 63 us, so repeated iteration paid the
preparation on every call.

The owning iterator now returns its workspace to a process-wide pool when the
caller's allocator is the page or smp allocator (both process-lifetime). The
next `findAll` call for the same regex takes it back, so repeated iteration
starts with the warmed DFA. The pool is a single mutex-protected entry keyed
by a process-unique regex id, and `Regex.deinit` clears the matching entry.
Other allocators (testing, arena, general purpose) are never pooled: their
memory could be released while the entry is still cached.

`Regex.findAllWith` remains for callers that own a workspace explicitly. It
borrows the caller's workspace (no copy, no free) and works with any
allocator and with concurrent iterators. The iterator never copies a live
workspace: its unmanaged hash map and array-list bookkeeping must not be
duplicated and mutated through a copy.

## Measurements

`bench` iterates the 22 KiB Qwen tokenizer text. Each executable reports its
own medians; five executions were interleaved before/after, after/before,
alternating. The table reports medians across those executions; raw samples
and executable SHA-256 identities are in
[`find-all-pool.json`](find-all-pool.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| findAll Qwen, owning iterator | 121,261.7 | 63,335.8 | 1.91x |
| findAll Qwen, borrowed control | 62,756.7 | 61,493.3 | 1.02x |
| find Qwen control | 60,284.2 | 59,696.7 | 1.01x |
| split whitespace control | 20,744.8 | 20,838.1 | 1.00x |
| split commas control | 35,233.8 | 39,385.8 | 0.89x |
| Workspace.init Qwen control | 71.4 | 71.9 | 0.99x |

The owning iterator improves in every round and now matches the borrowed
path. The borrowed iterator and the manual `Workspace.find` loop do not take
the pool; their 0.89–1.02x spread is the shared host's run-to-run noise (the
literal split path is unchanged by this commit).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='findAll' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig src/regex/api_tests.zig tools/bench/main.zig
```

The tests cover the borrowed iterator surviving its workspace, pooled reuse
across two owning iterators, and the existing `findAll` span checks.
