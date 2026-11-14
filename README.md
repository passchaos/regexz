# regexz

Bounded, owned RE2-style regular-expression engine with boolean/full matching
and replacement support. Extracted from the xDS safe-regex implementation in
`netz` so it can be reused independently of gRPC/xDS.

## Features

- RE2-style syntax subset with explicit limits for program size, states,
  instructions, and replacement expansion.
- Caller-owned compilation: `compile` writes into the allocator you provide;
  `Regex` keeps an internal arena.
- Reusable workspaces (`Workspace`, `ReplaceWorkspace`) for matching and
  substitution without per-call program compilation.
- Bounded Unicode class data generated from a pinned RE2 revision
  (`tools/codegen/generate.py`).
- No dependency on `netz`; only the Zig standard library.

## Usage

```zig
const regexz = @import("regexz");

var value = try regexz.Regex.init(allocator, "a+b", .{});
defer value.deinit();
try std.testing.expect(try value.matches(allocator, "aaab"));

var workspace = try regexz.Workspace.init(allocator, value.program);
defer workspace.deinit();
try std.testing.expect(try workspace.matches(value.program, "ab"));
```

Replacement:

```zig
var replace = try regexz.ReplaceWorkspace.init(allocator, value.program, .{});
defer replace.deinit();
const output = try replace.replaceAll("aaab", "x");
defer allocator.free(output);
```

## Build and test

```sh
zig build test
zig build test-lib -Dtest-filter="..."
```

## Provenance

The engine and Unicode data were moved from `netz` (`src/grpc/xds/routing/regex`
and `src/grpc/xds/routing/regex.zig`). The generated Unicode tables remain
covered by the RE2 BSD license in `src/regex/unicode/LICENSE.re2`.

## License

MIT. See `LICENSE`.
