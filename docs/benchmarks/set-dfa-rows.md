# Set DFA row-offset transition entries

Baseline: `64d1c35`, macOS ARM64, Zig 0.16.0 ReleaseFast.

The `RegexSet` combined DFA packs each ASCII transition into one `u64`: the
low 32 bits hold `next state id + 1` and the high 32 bits hold the target's
accept mask. The scan therefore computed `state * 128 + byte` on the dependent
address chain for every byte.

Transition entries now store the target's pre-multiplied row offset
(`state * 128`) instead of the state id, and the scan keeps that row in the
hot register: the next address is `row + byte` with one add and no shift. The
cold transition path shifts the row back to a state id (`row >> 7`) when it
interns a state, and the unicode transition map continues to store state ids.
The sentinel (0 = unprepared) and the packed accept mask are unchanged, so the
table size and state numbering stay the same.

## Measurements

The main benchmark's `RegexSet` case scans nine no-match patterns over a
23 KiB subject. Five executions were interleaved before/after, after/before,
alternating; each executable reports the median of its own batches. Raw
samples are in [`set-dfa-rows.json`](set-dfa-rows.json).

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| RegexSet 9 no-match patterns | 46,776.0 | 43,371.9 | 1.08x |
| find Qwen tokenizer | 55,535.8 | 51,715.0 | 1.07x |
| find shared-prefix no-match | 1,570.0 | 1,588.2 | 0.99x |
| find large alternation (24 literals) no-match | 1,437.3 | 1,582.1 | 0.91x |
| replaceAll a+ -> x | 44,775.2 | 45,542.3 | 0.98x |

The host was noisy: the 24-literal control does not touch the set DFA but
moved 0.91x, and the RegexSet samples overlap between the two executables.
The 8% median gain is therefore consistent with, but not proof of, the
expected effect; the change is kept because it strictly shortens the
dependent-load address chain and all `RegexSet` and not-empty tests pass.

## Validation

```sh
zig build test-lib -Dtest-filter='RegexSet' -Dtest-filter='set DFA' -Dtest-filter=notempty --summary all
python3 tools/fuzz/run.py --cases 100 --seed 191
python3 tools/bench/check.py --runs 1
zig fmt --check src/regex/set_dfa.zig
```

The `RegexSet` tests cover mixed eligible and ineligible patterns, duplicate
patterns, empty and malformed subjects, and the not-empty interactions.
