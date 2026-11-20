# Deferred fast-branch table threshold

Baseline: `217569e`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The fast branch of a tokenizer pattern uses the union of the Unicode letter
and mark classes as its run set. That set has about 1,000 ranges, and its
UTF-8 automaton is 937,472 `u16` entries (1.87 MB); building it costs about
175 us. The deferred run prepared it as soon as a long input reached one
non-ASCII rune (`input.len - end >= 64`), so any long mixed text paid the
build once per workspace even when it contained only a handful of accented or
CJK characters. The Qwen tokenizer text probes Unicode 1,200 times per pass,
so every fresh `findAll` pass paid the build.

The fast-branch `Run` now counts Unicode probes in a `u16` and prepares the
table only after 2,048 probes. Sparse mixed text stays on the range binary
search (a few probes per line); dense Unicode text reaches the threshold
early in its first pass and keeps the table for the rest of the scan. The
search `CompactRun` keeps its previous early-preparation policy, so set-run
searches and their tests are unchanged.

## Measurements

`bench` runs the Qwen tokenizer over the 22 KiB mixed text. Each executable
reports its own medians; five executions were interleaved before/after,
after/before, alternating. The table reports medians across those executions;
raw samples and executable SHA-256 identities are in
[`deferred-fast-branch-threshold.json`](deferred-fast-branch-threshold.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| findAll Qwen, fresh workspace | 301,762.5 | 124,939.2 | 2.42x |
| find Qwen control | 59,573.3 | 60,393.3 | 0.99x |
| findAll Qwen, borrowed control | 59,975.0 | 63,465.0 | 0.95x |
| find CJK control | 195,812.5 | 193,210.0 | 1.01x |
| find Han class control | 129,767.5 | 146,214.2 | 0.89x |
| stream Han chain control | 204,762.5 | 194,745.8 | 1.05x |
| compile Qwen (page) control | 63,493.5 | 61,758.6 | 1.03x |

The fresh iterator improves in every round. The warm scans build the table in
their warmup passes, so their timed medians are unchanged; the controls do not
use the fast-branch `Run`. Their 0.89–1.05x spread is the shared host's
run-to-run noise (the Han class path uses the search `CompactRun`, which this
change does not touch).

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='deferred' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/deferred_utf8_run.zig src/regex/deferred_run_tests.zig
```

The deferred tests cover sparse input that must stay scalar, long Unicode
runs that must prepare, allocation failures that must fall back to scalar
matching, malformed input that must not warm the table, and NFA agreement
before and after preparation.
