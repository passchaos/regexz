# Pooled replacement workspaces

Baseline: `0723b71`, macOS ARM64, Zig 0.16.0 ReleaseFast.

`Regex.replaceAll` and `Regex.replacen` built a `ReplaceWorkspace` for every
call and destroyed it afterwards: slot storage, pair filters, shape detection
and every optional cache were recreated even though the program never changes.
`Regex.findAll` already recycles its owning workspace through a process-wide
slot for page/smp allocators; the replacement entry points now use the same
slot.

A workspace is only taken when both the program id and the allocator match.
The page and smp allocators are stateless and their `Allocator.ptr` field is
undefined, so the vtable identifies them. A freshly created workspace is also
returned to the slot, so the pool warms after the first call. A workspace from
another program is dropped and the slot is cleared; that also fixes a
pre-existing dangling entry where an evicted workspace was deinited but left
in the slot, so a later take could hand out freed memory. Custom and testing
allocators stay excluded, so leak checks still see every allocation.

## Measurements

A focused harness replaces `\A|\z` with `X` over the 24 KiB comparison text,
with the two executables run in alternating order for eight rounds:

| Row | Before, ns/call | After, ns/call | Speedup |
| --- | ---: | ---: | ---: |
| `Regex.replaceAll` | 5,308.0 | 3,588.3 | 1.48x |
| warm `Workspace.replaceAll` control | 2,844.1 | 2,872.6 | 0.99x |

`ReplaceWorkspace.init` plus `deinit` alone measures 1.8-2.2 us, which is the
removed share. The warm pass is dominated by the output allocation and copy:
allocating, copying and freeing the 24 KiB result costs about 2.7 us.

The full comparison harness ran seven alternating rounds; raw samples and
executable SHA-256 identities are in
[`replace-workspace-pool.json`](replace-workspace-pool.json):

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| replaceAll `a+` -> `x` | 25,404.0 | 22,796.3 | 1.11x |
| replaceAll `\A|\z` -> `X` | 6,711.0 | 3,615.0 | 1.86x |

Across the 17 non-replacement cases the median is 1.02x. The zero-width
replacement case against Rust's `regex` moves from 1.24x to 2.23x (see the
[comparison](../benchmarks/rust-comparison.md)).

## Validation

```sh
zig build test --summary all
python3 tools/fuzz/replace.py --cases 400 --seed 20261121
python3 tools/bench/check.py --runs 1
zig fmt --check src/root.zig
```

Five fuzzer seeds (400 cases each) pass. New tests cover repeated pooled
calls, switching between page and smp allocators, eviction when another
program replaces the slot, and the `findAll` stale-slot path.

## Pointer pool

The pool used to hold a `ReplaceWorkspace` value. That struct is 7,808 bytes
because it inlines four 256-entry byte tables and the prepared search state,
so every owning `findAll` and every pooled `replaceAll` moved it into and out
of the iterator. The pool now stores a `*ReplaceWorkspace` allocated once per
program: `Matches` drops from 7,856 to 56 bytes and no call copies the struct.

The comparison harness ran seven alternating rounds; raw samples and
executable identities are in
[`pointer-workspace-pool.json`](pointer-workspace-pool.json):

| Case | Before, ns/iter | After, ns/iter | Speedup |
| --- | ---: | ---: | ---: |
| findAll Qwen (owning) | 45,254.2 | 42,690.0 | 1.06x |
| findAll Qwen (borrowed) control | 42,944.2 | 43,105.0 | 1.00x |
| replaceAll `a+` -> `x` | 22,876.5 | 21,208.3 | 1.08x |
| replaceAll `\A|\z` -> `X` | 3,372.3 | 2,613.8 | 1.29x |

The 15 other cases keep a 1.00x median. Owning `findAll` now matches the
borrowed form, and the zero-width replacement reaches 2.66x ahead of Rust
(see the [comparison](rust-comparison.md)).
