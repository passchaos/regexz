# Competitor comparison

Optional harnesses that run the same workloads against regexz, Rust's
`regex` crate, and PCRE2 10.42 with JIT. They are development tools, not part
of the library build.

Zig side:

```sh
zig build-exe -O ReleaseFast --dep regexz \
    -Mroot=tools/compare/zig_regex.zig -Mregexz=src/root.zig \
    -femit-bin=/tmp/regexz-compare
/tmp/regexz-compare
```

Rust side:

```sh
cd tools/compare/rust_regex
cargo run --release
```

PCRE2 side:

```sh
zig build-exe -O ReleaseFast -lc -lpcre2-8 \
    tools/compare/pcre2_regex.zig -femit-bin=/tmp/regexz-pcre2
/tmp/regexz-pcre2
```

All three harnesses print one `name ns/iter` line per case in the same order.
Passing a case name as the first argument runs only that case. The documented
evidence is collected with one process per case:

```sh
python3 tools/compare/isolated_sweep.py --rounds 5 --out /tmp/compare.json
python3 tools/compare/isolated.py 5 "find IPv4" "find IPv6"
```

`isolated_sweep.py` starts a fresh process for each case and interleaves the
implementations; this removes the cross-case heap and code-layout
interference that can move unrelated rows by 10-50% in a single-process
sweep. `isolated.py` re-measures selected cases. Both expect the Zig, Rust and
PCRE2 binaries at the paths shown above and pin each process to CPU 0 with
`taskset`.

The `find` rows use each library's per-position API (`find_at` for Rust,
`Workspace.find` for regexz); the `findAll` rows use each library's iterator
(`find_iter`, `findAllWith`). PCRE2 has no iterator API, so its `findAll` rows
use the same per-position match loop.
