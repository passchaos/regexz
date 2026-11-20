# Skip the first filter for plain non-ASCII set searches

Baseline: `40f9bf3`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`findPrepared` probes every candidate with the first-byte filter. For a set
with no ASCII members and no ranges (such as `\p{Han}+`), the filter's
non-ASCII path returns the current offset unchanged, so the call only adds
overhead on CJK input where every byte is non-ASCII.

When the filter is a plain non-ASCII set (`plainNonAscii`: no ASCII bytes,
no ranges, no prepared rune prefixes), a non-ASCII byte at the current
offset is accepted directly and the filter call is skipped. Other filters,
including prepared rune prefixes, keep the call.

## Measurements

A focused harness finds `\p{Han}+` over the 191 KiB CJK text (8,032 matches
per pass), 50,000 passes per execution:

| Run | Before, ns/pass | After, ns/pass |
| --- | ---: | ---: |
| 1 | 122,904.4 | 118,025.0 |
| 2 | 125,563.7 | 118,170.7 |
| 3 | 125,094.4 | 118,906.3 |

The full 67-case interleave is in [`han-filter-skip.json`](han-filter-skip.json):
`find Han class scan` measures 118,380.0 -> 116,257.5 ns (1.02x) with the
after side faster in three of five rounds, while the 66 control cases keep a
1.01x median. Raw samples and executable SHA-256 identities are in the JSON.

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/run.py --cases 300 --seed 41
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/prefilter.zig src/regex/utf8_run_search.zig
```

The engine fuzzer covers Unicode property sets and CJK alphabets through the
prepared and unprepared set-run paths.
