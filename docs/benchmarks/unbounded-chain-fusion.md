# Unbounded chain literal fusion

Baseline: `81750ad`, macOS ARM64, Zig 0.16.0 ReleaseFast.

Unbounded run chains (`v?\d+\.\d+\.\d+`, `\d+\.\d+\.\d+\.\d+:\d+`,
`\w+@\w+\.(?:com|org|net)`) walked one element per loop iteration, including
the single-byte separators between runs. Two changes remove that overhead.

## First-run end reuse

After a failed start, the walk skipped the whole first run because every
start inside it shares the same run end and remaining input. The skip
rescanned the run with the membership table even though the walk had just
scanned it. The walk now records the first run's end while scanning and
jumps there directly. The skip condition is unchanged (the first element
must be a run with a positive minimum), so the fast path matches exactly the
same spans; it just stops doing the second scan.

## Gated literal fusion

When a run is followed by a single-byte literal, the literal's first byte is
outside the run set (the builder already rejects overlapping shapes). The
walk therefore knows the literal must follow the maximal run, and it can
consume both in one iteration instead of advancing to the next element.

The marker is the high bit of the run element's `value` byte: the low seven
bits keep the set index, and bit 7 marks a fused pair. `UnboundedSequenceState`
counts the pairs at build time and enables fusion only when at least two
exist. A single pair does not repay the per-run marker test: the key-value
chain (`\w+\s*=\s*\w+`) has one and measured about 5% slower when fused. The
enabled state selects a distinct `fast_kind` (`unbounded_sequence_fused`),
so chains without fusion call the unfused walk directly without a per-search
branch.

The fused walk still checks the run minimum, then the literal byte; a failed
literal check stops the walk exactly where the separate literal element
would have stopped. The first-run end is recorded before the fused literal
is consumed, so the skip target stays the run end.

## Measurements

The comparison harness runs every case with the same inputs as
[the Rust comparison](rust-comparison.md). Eight executions were interleaved
in alternating order (four rounds `before, after`, four rounds `after,
before`); the table reports medians across those executions. Raw samples and
executable SHA-256 identities are in
[`unbounded-chain-fusion.json`](unbounded-chain-fusion.json).

| Case | Before, ns/iter | After, ns/iter | Change |
| --- | ---: | ---: | ---: |
| find semver | 80,741.6 | 69,642.6 | 1.16x faster |
| find email TLD | 12,408.5 | 10,871.5 | 1.14x faster |
| find IP port | 88,229.5 | 78,387.2 | 1.13x faster |
| find html attribute | 52,240.6 | 48,731.8 | 1.07x faster |
| find version | 59,640.7 | 58,192.4 | 1.02x faster |
| find camelCase | 83,756.9 | 81,613.9 | 1.03x faster |
| find key-value | 92,394.8 | 91,904.3 | 1.01x faster |

The host was busy (load average about 8) and per-case noise is large: an
A/A run of the same executable over five rounds varied from 0.90x to 1.05x
across cases. The four large wins repeat in every batch; the smaller rows
and the unrelated comparison cases move within the A/A band and are not
attributable.

## Validation

```sh
zig build test-lib -Dtest-filter=unbounded -Dtest-filter=replace
```

The span tests cover fused and unfused chains (`v?\d+\.\d+\.\d+`,
`\w+="[^"]*"`, `\w+@\w+\.(?:com|org|net)`, `[a-z]+[A-Z][a-z]+`,
`\w+\s*=\s*\w+`), including failed starts, literal mismatches and the
ambiguous optional case that must stay off the fast path.
