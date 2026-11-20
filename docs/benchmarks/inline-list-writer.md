# Inline reserved replacement appends

Baseline: `47f2213`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`replaceAllWith` reserves the output capacity once before the first match, but
every replacement byte still went through `ListWriter` → `ArrayList.append`,
which re-checks capacity and goes through the list's growth policy on each
call. On append-heavy passes (8,000 matches over a 32 KiB subject) those calls
are a meaningful share of the remaining time.

`subst.ListWriter.append` and `appendSlice` are now `inline` fast paths: when
the reserved capacity has room, they bump `items.len` and write directly,
skipping the `ArrayList` method call and its capacity branch; when the list is
full they fall back to `list.append` / `list.appendSlice`, which keeps the
growth policy and all allocation accounting intact. The length writer and
caller-buffer writer are unaffected.

## Measurements

`bench-replace` replaces over a 32 KiB subject. Each executable reports the
median of five batches of 200 replacements. Five executions were interleaved
before/after, after/before, alternating. The table reports medians across
those executions; raw samples and executable SHA-256 identities are in
[`inline-list-writer.json`](inline-list-writer.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| captures (`(\w+)` → `[$1]`), page | 168,596.0 | 147,193.3 | 1.15x |
| captures (`(\w+)` → `[$1]`), SMP | 168,197.3 | 144,669.4 | 1.16x |
| shrink, page | 61,556.0 | 51,124.6 | 1.20x |
| shrink, SMP | 59,711.9 | 51,786.9 | 1.15x |
| grow, page | 67,930.8 | 58,859.8 | 1.15x |
| grow, SMP | 67,936.3 | 57,796.9 | 1.18x |
| word boundary, page | 320,007.5 | 281,621.7 | 1.14x |
| word boundary, SMP | 313,891.7 | 284,234.8 | 1.10x |
| not word boundary, page | 321,252.3 | 278,749.4 | 1.15x |
| not word boundary, SMP | 319,766.0 | 275,461.5 | 1.16x |
| boundary or end, page | 364,416.9 | 329,016.0 | 1.11x |
| boundary or end, SMP | 360,337.9 | 322,570.8 | 1.12x |
| no match control, page | 3,547.7 | 3,645.8 | 0.97x |
| no match control, SMP | 4,780.0 | 4,711.0 | 1.02x |
| zero width control, page | 3,295.8 | 3,308.1 | 1.00x |
| zero width control, SMP | 3,528.3 | 4,023.8 | 0.88x |
| limited control, page | 3,039.4 | 2,996.5 | 1.01x |
| limited control, SMP | 3,404.6 | 3,902.9 | 0.87x |
| callback control, page | 7,090,215.2 | 7,133,377.7 | 0.99x |
| callback control, SMP | 68,082.7 | 68,833.5 | 0.99x |
| delete whole input, page | 10,907.7 | 11,371.9 | 0.96x |
| delete whole input, SMP | 10,978.3 | 11,252.5 | 0.98x |

Append-heavy passes improve in every round, including the capture replacement
that already went through the parsed template. The controls are literal or
single-append cases where the inline path has nothing to save; their 0.87–1.02x
spread is within the host's run-to-run noise (the two 0.87x samples are
~0.5 µs in 3–4 µs cases). Allocation counts and allocated bytes are unchanged.

## Validation

```sh
zig build test --summary all
zig build test-lib -Dtest-filter='replacement' -Dtest-filter='substitution' -Dtest-filter='replacen' -Dtest-filter='zero-width' --summary all
python3 tools/fuzz/replace.py --cases 100 --seed 191
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/substitution.zig
```

The replacement tests cover `$0`..`$9`, `$&`, named and braced groups,
`$``/`$'`/`$+`/`$_`, `$$`, case transforms, missing groups, and the
length/caller-buffer writers; the V8 replacement fuzzer compares 1,900 cases.
