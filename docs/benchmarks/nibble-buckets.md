# Nibble filter lane masks and weighted bucket assignment

Baseline: `71355cb`, macOS ARM64 with NEON, Zig 0.16.0 ReleaseFast.

The wide multi-literal prefilter tests 16 input positions per block with four
nibble lookup tables. Two costs dominated its collision cases.

First, candidate lanes were extracted with `std.simd.firstTrue` per lane,
which lowers to a reduce-or plus a select and reduce-min round trip for every
candidate. `PairSet` and `MultiFilter` now bit-pack the block mask once
(`@bitCast` to `u16`) and walk set bits with `@ctz`, clearing each bit as it
is verified. The first-true-only scans (UTF-8 rune prefixes and case-folded
literals) use the same packing. A reduce-or still rejects absent blocks
before the mask is packed, so the common no-candidate path is unchanged.

Second, bucket bits were assigned by literal position (`index & 7`), so
first-byte and second-byte bucket sets collided arbitrarily. A lane is a
candidate when some literal's first byte and some literal's second byte share
a bucket. Under independent byte frequencies the expected false-positive
weight is the sum over buckets of distinct first-byte weight times distinct
second-byte weight, minus the true literal pairs, which do not depend on the
assignment. `Filter.init` now places literals greedily by English byte
frequency and then hill-climbs single moves until the cost stops improving.
The search is deterministic, allocates nothing, and runs once per filter
construction; bucket membership remains conservative because callers verify
exact prefixes.

## Measurements

Each executable reports the median of five batches: 2,000 searches for the
microfilter suite and 1,000 for the complete-search suite. Five executions
were interleaved before/after, after/before, alternating, with both suites
run sequentially. The table reports medians across those executions. Raw
samples and executable SHA-256 identities are in
[`nibble-buckets.json`](nibble-buckets.json).

| Case | Before, ns/search | After, ns/search | Speedup |
| --- | ---: | ---: | ---: |
| wide pairs collisions | 6,098.5 | 2,473.6 | 2.47x |
| wide pairs late literal | 5,924.7 | 2,428.1 | 2.44x |
| complete Regex wide alternatives | 5,879.8 | 2,603.6 | 2.26x |
| three pairs collisions | 30,646.5 | 24,247.2 | 1.26x |
| complete Regex late literal | 30,362.9 | 24,379.8 | 1.25x |
| complete Regex prefix collisions | 30,583.6 | 28,413.9 | 1.08x |
| short literal hit | 5.3 | 4.6 | 1.15x |
| dense candidates control | 143,852.4 | 137,381.8 | 1.05x |
| sixteen pairs absent | 709.4 | 674.5 | 1.05x |
| wide pairs absent | 2,673.5 | 2,578.5 | 1.04x |
| wide short control | 11.3 | 10.9 | 1.04x |
| wide dense control | 61,454.3 | 60,837.8 | 1.01x |
| three pairs absent | 678.0 | 669.6 | 1.01x |
| capture run control | 9.2 | 9.2 | 1.00x |
| case-folded control | 2,086.8 | 2,185.5 | 0.95x |

The shared host was busy during the runs. The collision and complete-search
gains repeat in every round; the dense controls, absent scans and
case-folded control moved by less than the observed run-to-run spread (for
example, case-folded before samples ranged 2,018-2,372 ns). The dense
controls still take the scalar verification fallback, which the bucket
assignment does not change.

## Validation

```sh
zig build test-lib -Dtest-filter=nibble -Dtest-filter=PairSet -Dtest-filter='wide alternation' -Dtest-filter=MultiFilter --summary all
zig build test-lib -Doptimize=ReleaseFast -Dtest-filter=nibble -Dtest-filter=PairSet -Dtest-filter='wide alternation' -Dtest-filter=MultiFilter -Dtest-filter=prefilter --summary all
zig test -OReleaseFast -target x86_64-linux -Mroot=src/root.zig --test-filter nibble --test-no-exec
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/nibble_filter.zig src/regex/prefilter.zig
```

All seven Debug and fourteen ReleaseFast scoped tests, 9,252 V8 comparisons
and the 56-case gate passed; the x86_64 build cross-compiled but was not
executed on this ARM64 host. Tests compare every input offset against exact
literal search over fixed, random, dense, malformed and UTF-8 inputs, and
check that every literal prefix still produces a candidate in its lane. The
gate reports `find large alternation (24 literals) no-match` at
7,971.0 -> 2,210.2 ns (0.28x).
