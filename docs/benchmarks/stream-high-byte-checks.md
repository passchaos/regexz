# Drop redundant high-byte checks in stream ASCII loops

Baseline: `a525bf5`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The streaming scanner's tight loops all carried `items[scan] < 0x80` guards
before the byte-table lookup. Those tables are only built when the set is
`ascii_only` (`simple_ascii` for set-run and star shapes, `chain_ascii` for
chains), and `byte_table.init(256, set)` leaves every byte >= 0x80 false for
such a set. The guard therefore never changes a result: a high byte stops a
member scan because the table entry is false, not because of the guard, and
it is always a non-member.

The guards are removed from `skipMembers`, `skipNonMembers`, and the three
`processChain` phase loops. High bytes inside an idle/non-member stretch are
now consumed byte-wise in the table loop instead of being handed back to the
rune decoder one rune at a time. That is exact for these shapes: an ASCII-only
set has no non-ASCII member, so no match can start, extend, or end there, and
a rune split across a chunk boundary cannot hide one. Invalid and incomplete
bytes keep their existing handling on the member-run path, where the rune
decoder is still used.

A first screen changed only `skipNonMembers`; the focused harness below shows
it is neutral (plus 0.98x), so the win comes from the member-run loop that
`skipMembers` drives. Two full-bench interleaves of that split variant also
reported the `[a-z]*` row at 0.88x even though `processStar`'s source was
untouched, which marks that row in those binaries as layout/ordering noise;
the fresh interleave of the final variant below reads 1.015x there.

## Measurements

A focused harness streams the 216 KiB ASCII text in 4 KiB chunks, 100 passes
per execution, with the two executables run in alternating order for ten
rounds:

| Case | Before, median ns/pass | After, median ns/pass | Speedup |
| --- | ---: | ---: | ---: |
| `[a-z]+` | 141,080.7 | 130,344.6 | 1.08x |
| `[a-z]*` | 165,668.1 | 159,459.0 | 1.04x |
| `[a-z]+ [a-z]+` | 194,510.2 | 190,153.4 | 1.02x |

The means agree (1.07x, 1.03x, 1.03x), and the after executable is faster in
eight, nine, and six of the ten rounds respectively.

The full 67-case interleave is in
[`stream-high-byte-checks.json`](stream-high-byte-checks.json):

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| stream `[a-z]+` | 138,593.8 | 129,312.5 | 1.07x |
| stream `[a-z]*` | 151,920.9 | 149,743.8 | 1.02x |
| stream `[a-z]+ [a-z]+` | 187,237.5 | 181,362.5 | 1.03x |
| stream Han chain control | 139,110.4 | 134,041.7 | 1.04x |

Across the 63 non-stream cases the median is 1.01x. Raw samples and
executable SHA-256 identities are in the JSON.

## Validation

```sh
zig build test --summary all
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/stream.zig
```

The streaming tests already compare the scanner against whole-input search
over one-byte chunks, multi-byte runes split across chunks, and inputs such as
`"\xffa\x80"` for the `set*`, `set+`, and chain fast paths, which covers the
byte-wise high-byte skipping directly.
