# Shared range identity in deterministic shape recognition

Baseline: `4acd272`, macOS ARM64, Zig 0.16.0 ReleaseFast, SMP allocator.

The compiler's specialized greedy repeat emits a star and mandatory members
from the same materialized set. Their range slices share a pointer and length,
but shape detection previously compared every range in each equality check.
For a wide Unicode property such as `\p{L}`, this traversal remained visible
in workspace construction after UTF-8 table preparation was deferred.

`shapes.sameSet` now checks slice length, then returns immediately for a shared
pointer. Different pointers still compare each range's first and last fields.
`setRun` uses this helper in place of its duplicate equality loop. Recognition
still accepts separately stored equal ranges and rejects unequal ranges or
shared-pointer views with different lengths. Capture detection retains its
separate ASCII bitmap and eligibility checks.

No new cache, owned storage or program field is introduced. The comparison
continues to borrow immutable program ranges. Matching, search and streaming
use the same recognized shapes as before.

## Measurement method

The fixed baseline is a `git archive` of `4acd272`. Both snapshots compile the
same existing `bench-startup` and `bench-branch_startup` sources. Each phase
reports the median of five batches; three executions alternate before/after,
after/before, before/after. The suites cover full-match construction, first
matches and warmed matching, plus search construction, first searches and
complete cold/warmed passes. Raw samples, allocation counters and executable
SHA-256 identities are in [`set-identity.json`](set-identity.json).

## Measurements

| Case / phase | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| Full-match letters, ASCII input / initialization | 327.6 | 63.3 | 5.18x |
| Full-match letters, Unicode input / initialization | 309.7 | 65.9 | 4.70x |
| Full-match letters, ASCII input / first match | 339.1 | 65.6 | 5.17x |
| Full-match letters, Unicode input / first match | 360.8 | 95.4 | 3.78x |
| Letters search, ASCII token / initialization | 967.1 | 347.5 | 2.78x |
| Letters search, Unicode token / initialization | 945.8 | 360.8 | 2.62x |
| Letters search, mixed text / initialization | 938.8 | 320.4 | 2.93x |
| Letters search, ASCII token / first search | 940.8 | 341.3 | 2.76x |
| Letters search, Unicode token / first search | 947.1 | 351.3 | 2.70x |
| Full-match letters, ASCII input / warmed match | 5.7 | 5.7 | 1.00x |
| Full-match letters, Unicode input / warmed match | 3.6 | 3.5 | 1.03x |
| Letters search, ASCII text / warmed pass | 17,778.7 | 17,341.7 | 1.03x |
| Letters search, mixed text / warmed pass | 18,666.7 | 19,189.6 | 0.97x |

All allocation and workspace-size counters remain identical between the
before and candidate executables in every case and round. Full-match
letters initialization still makes one allocation and requests 308 bytes;
ordinary letters search initialization still makes two allocations and
requests 32 bytes. The saving removes range comparisons, not storage.

Warmed matching does not establish a general throughput gain. Full-match
letter timings were within 0.1 ns; tiny ordinary search passes were 0.1–0.4 ns
slower. Complete ASCII and mixed letters passes differed by about 2.5–2.8%,
while unchanged Qwen controls varied by up to about 10.3% on the shared host.
The qualified benefit is initialization and the associated first call for
wide, shared Unicode range sets. Small range sets show less benefit.

## Validation

```sh
zig build test-lib -Dtest-filter='set identity' -Dtest-filter='capture run detector' -Dtest-filter='set loop full' -Dtest-filter='chain search finds' -Dtest-filter='prefix loop requires' -Dtest-filter='non-ASCII set run scan' -Dtest-filter='stream scanner agrees' --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/shapes.zig src/regex/set_identity_tests.zig src/root.zig
```

Scoped tests exercise shared ranges, independently allocated equal ranges,
different range contents and lengths, empty views, copied compiled sets,
capture eligibility, loops, chains and streaming boundaries. The copied-set
fixture confirms the compiler's repeat shares its ranges, then substitutes a
distinct equal allocation before checking that differing members are rejected.

The candidate passed all 10 scoped tests, 8,808 V8 comparisons, the 56-case
performance gate and formatting checks. Three complete alternating rounds
covered 140 phases across the two suites in each executable.
