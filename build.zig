const std = @import("std");
const builtin = @import("builtin");

const required_zig_version = "0.16.0";

pub fn build(b: *std.Build) void {
    comptime {
        if (!std.mem.eql(u8, builtin.zig_version_string, required_zig_version)) {
            @compileError("regexz requires Zig " ++ required_zig_version ++ "; found " ++ builtin.zig_version_string);
        }
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests whose name contains one of these substrings",
    ) orelse &.{};

    const regexz_mod = b.addModule("regexz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "regexz",
        .root_module = regexz_mod,
    });
    b.installArtifact(lib);

    const lib_tests = b.addTest(.{
        .root_module = regexz_mod,
        .filters = test_filters,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_lib_step = b.step(
        "test-lib",
        "Compile and run the regexz unit tests",
    );
    test_lib_step.dependOn(&run_lib_tests.step);

    const test_step = b.step("test", "Compile and run the regexz unit tests");
    test_step.dependOn(&run_lib_tests.step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_mod.addImport("regexz", regexz_mod);
    const bench_exe = b.addExecutable(.{
        .name = "regexz-bench",
        .root_module = bench_mod,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run regexz microbenchmarks (use -Doptimize=ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    const replace_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench/replace.zig"),
        .target = target,
        .optimize = optimize,
    });
    replace_bench_mod.addImport("regexz", regexz_mod);
    const replace_bench_exe = b.addExecutable(.{
        .name = "regexz-replace-bench",
        .root_module = replace_bench_mod,
    });
    const run_replace_bench = b.addRunArtifact(replace_bench_exe);
    const replace_bench_step = b.step("bench-replace", "Run scoped replacement benchmarks and count output allocations");
    replace_bench_step.dependOn(&run_replace_bench.step);
}
