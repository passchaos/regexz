# Reusing a workspace for match iteration

macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.findAll` builds a `ReplaceWorkspace` for each call and moves it into
the iterator. The workspace owns the lazy search-DFA caches, so the first
pass over a tokenizer-sized input spends most of its time building states and
ASCII transition rows; a reused workspace skips that work. On the 22 KiB Qwen
tokenizer text the first pass costs about 340 us while a warmed pass costs
about 64 us.

`Matches` now holds either an owned workspace (`Regex.findAll`) or a pointer
to a caller workspace (`Regex.findAllWith`). The borrowed form runs on the
caller's warmed caches and `deinit` leaves the workspace intact for the next
iteration. The iterator never copies a live workspace: its unmanaged hash map
and array-list bookkeeping must not be duplicated and mutated through a copy.

## Measurements

`bench` iterates the 22 KiB Qwen tokenizer text. Each executable reports its
own medians; five executions were run and the table reports medians across
them. The manual `Workspace.find` loop is the warmed control.

| Case | ns/iter | vs fresh |
| --- | ---: | ---: |
| findAll Qwen, borrowed workspace | 64,147.5 | 5.36x faster |
| findAll Qwen, fresh workspace | 343,610.0 | 1.00x |
| find Qwen, manual workspace loop | 64,403.3 | 5.34x faster |

The borrowed iterator matches the manual loop; the owning iterator pays the
lazy DFA preparation once per `findAll` call. For one-shot iteration over a
small input the cold cost is the price of the fresh workspace; for repeated
iteration or tokenization loops, `findAllWith` keeps the caches warm.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='findAll' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig src/regex/api_tests.zig tools/bench/main.zig
```

The `findAllWith` test iterates with a caller workspace, checks the spans,
destroys the iterator and then reuses the same workspace for another search.
