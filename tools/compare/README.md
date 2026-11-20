# Competitor comparison

Optional harnesses that run the same workloads against regexz and Rust's
`regex` crate. They are development tools, not part of the library build.

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

Both harnesses print one `name ns/iter` line per case in the same order. Run
them alternately and compare the medians; the shared-host noise is large
enough that a single pair of runs is not conclusive.
