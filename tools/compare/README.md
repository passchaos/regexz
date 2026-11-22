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

## Feature differential

`pcre2_diff.zig` is a semantic audit, not a benchmark. It links regexz and a
locally built PCRE2 10.45 and compares compile success, the first-match span,
every capture slot, the last `(*MARK)` name, and whole `findAll` sequences over
a curated battery covering every section of the PCRE2 pattern documentation.
It is the evidence behind `docs/feature-audit.md`.

```sh
# Build PCRE2 10.45 once (the system library is older).
curl -L -o /tmp/pcre2-10.45.tar.gz \
  https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.45/pcre2-10.45.tar.gz
tar -C /tmp -xzf /tmp/pcre2-10.45.tar.gz
cd /tmp/pcre2-10.45 && ./configure --prefix=/tmp/pcre2-10.45-install \
  --enable-jit --enable-pcre2-8 --disable-shared --disable-pcre2-16 \
  --disable-pcre2-32 && make -j"$(nproc)" && make install

# Build and run the differential from the repository root.
zig build-exe -O ReleaseFast -lc \
  -I/tmp/pcre2-10.45-install/include \
  -L/tmp/pcre2-10.45-install/lib -lpcre2-8 \
  --dep regexz -Mroot=tools/compare/pcre2_diff.zig -Mregexz=src/root.zig \
  -femit-bin=/tmp/regexz-pcre2-diff
/tmp/regexz-pcre2-diff
```

Rows print `MISMATCH` when behavior differs. `EXTENSION` marks a construct
regexz intentionally supports beyond PCRE2, and `LIMIT` marks a configurable
resource cap. The process exits non-zero when any mismatch remains.
