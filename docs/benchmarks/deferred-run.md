# Deferred UTF-8 tables for dominant branches

Baseline: `1579f7c`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

Qwen's dominant `set? setB+` branch previously built expanded UTF-8 tables
for both sets during `ReplaceWorkspace.init`. Even an ASCII-only first token
therefore paid about 0.88 ms of setup and 46 allocations.

`deferred_utf8_run.Run` keeps the materialized set and an inline ASCII byte
table. ASCII probes and runs scan that table immediately. Valid Unicode
probes, including misses, use scalar set membership until four probes request
the expanded table. A matching Unicode run with at least 64 input bytes
remaining requests it immediately. Cached Unicode probes and runs retain the
original UTF-8 table scans. Allocation failure disables further preparation
attempts and preserves exact scalar matching; malformed and truncated UTF-8
never become set members.

The earlier-branch first-byte union and greedy optional-prefix ordering retain
their original checks. Program sets remain immutable borrowed views. The
workspaces own prepared UTF-8 tables and free them during deinitialization.

## Measurements

The before and candidate snapshots both use the unmodified sources from
`1579f7c`, apart from the deferred-run change and its tests. The same new
`bench-branch_startup` source is compiled for both. Subjects are heap-backed.
Each phase reports the median of five batches; three executions alternate
before/after, after/before, before/after. The main tokenizer benchmark is also
compared in three alternating executions. Raw samples, counters and executable
SHA-256 identities are in [`deferred-run.json`](deferred-run.json).

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| ASCII token / initialization | 886,032.9 | 514.2 | 1,723x |
| ASCII token / first match | 886,328.8 | 476.7 | 1,859x |
| Unicode token / first match | 881,532.1 | 484.2 | 1,821x |
| complete ASCII text / cold pass | 901,273.0 | 45,148.0 | 19.96x |
| complete mixed text / cold pass | 905,395.9 | 484,858.4 | 1.87x |
| complete CJK text / cold pass | 1,119,254.2 | 1,096,812.5 | 1.02x |
| ASCII token / warmed first match | 5.5 | 7.0 | 0.79x |
| Unicode token / warmed first match | 6.0 | 7.3 | 0.82x |
| ASCII text / warmed pass | 37,437.0 | 39,894.3 | 0.94x |
| mixed text / warmed pass | 36,676.0 | 36,954.7 | 0.99x |
| CJK text / warmed pass | 165,606.8 | 173,245.3 | 0.96x |
| main Qwen tokenizer / warmed pass | 50,823.3 | 52,046.7 | 0.98x |
| main CJK tokenizer / warmed pass | 172,155.0 | 179,635.0 | 0.96x |

Qwen initialization drops from 46 allocations and 3,466,208 cumulative
requested bytes to two allocations and 32 requested bytes. Complete ASCII
scanning drops from 69 to 25 allocations, with cumulative requests falling
from 3,496,848 to 30,672 bytes. Complete CJK scanning still makes 68
allocations and requests 3,588,064 bytes: the expanded tables are prepared
during that pass. The change postpones work when Unicode needs it and avoids
it for ASCII subjects.

The measured benefit is first-token latency and ASCII cold scanning.
Short warmed tokens were 1.3–1.5 ns slower; complete warmed passes varied by
2–9% on the shared host, including unchanged controls. These samples do not
establish a warmed-throughput gain. Workspace value size increases from 5,920
to 6,544 bytes (624 bytes) to hold ASCII tables and deferred state. Repeated
or long Unicode input pays a one-time preparation cost during matching.

An initial candidate counted only Unicode set hits. Common misses in Qwen's
optional prefix then stayed on scalar membership and slowed warmed Unicode
tokens. Counting valid misses too, retaining the cached probe inside the
public hot path, and moving unprepared scans into separate functions are
included in the measurements above.

## Validation

```sh
zig build test-lib -Dtest-filter='deferred run' -Dtest-filter=dominant -Dtest-filter='set lookahead' -Dtest-filter='front cache' -Dtest-filter='linear fallback rolls back' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig build bench-branch_startup -Doptimize=ReleaseFast
zig fmt --check build.zig src/root.zig src/regex/replace.zig src/regex/deferred_utf8_run.zig src/regex/deferred_run_tests.zig tools/bench/branch_startup.zig
```

All 12 integrated scoped tests, 8,703 V8 comparisons and the 56-case
performance gate passed. The integrated startup check confirmed two
allocations and 32 requested initialization bytes in every subject.
Tests cover ASCII allocation avoidance, Unicode prefix/run initialization,
exact interpreter bounds at every byte offset, malformed/truncated UTF-8,
warming on valid misses, and allocation-failure cleanup with scalar fallback.
The V8 seed uses a Unicode-caseless Qwen shape; long-s input is restricted to
that Unicode seed to retain the reference engine's legacy `/i` semantics.
