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

    const capture_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench/capture.zig"),
        .target = target,
        .optimize = optimize,
    });
    capture_bench_mod.addImport("regexz", regexz_mod);
    const capture_bench_exe = b.addExecutable(.{
        .name = "regexz-capture-bench",
        .root_module = capture_bench_mod,
    });
    const run_capture_bench = b.addRunArtifact(capture_bench_exe);
    const capture_bench_step = b.step("bench-capture", "Run scoped capture-search benchmarks and count first-find allocations");
    capture_bench_step.dependOn(&run_capture_bench.step);

    const prefilter_mod = b.createModule(.{
        .root_source_file = b.path("src/regex/prefilter.zig"),
        .target = target,
        .optimize = optimize,
    });
    const prefilter_bench_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench/prefilter.zig"),
        .target = target,
        .optimize = optimize,
    });
    prefilter_bench_mod.addImport("prefilter", prefilter_mod);
    const prefilter_bench_exe = b.addExecutable(.{
        .name = "regexz-prefilter-bench",
        .root_module = prefilter_bench_mod,
    });
    const run_prefilter_bench = b.addRunArtifact(prefilter_bench_exe);
    const prefilter_bench_step = b.step("bench-prefilter", "Run scoped shared-prefix and case-folded search benchmarks");
    prefilter_bench_step.dependOn(&run_prefilter_bench.step);

    const prefilter_search_mod = b.createModule(.{
        .root_source_file = b.path("tools/bench/prefilter_search.zig"),
        .target = target,
        .optimize = optimize,
    });
    prefilter_search_mod.addImport("regexz", regexz_mod);
    const prefilter_search_exe = b.addExecutable(.{
        .name = "regexz-prefilter-search-bench",
        .root_module = prefilter_search_mod,
    });
    const run_prefilter_search = b.addRunArtifact(prefilter_search_exe);
    run_prefilter_search.step.dependOn(&run_prefilter_bench.step);
    prefilter_bench_step.dependOn(&run_prefilter_search.step);

    addRegexBench(b, regexz_mod, target, optimize, "comptime", "Compare generated and runtime matchers with runtime input barriers");
    addRegexBench(b, regexz_mod, target, optimize, "startup", "Measure compilation, workspace construction and cold versus warm matching");
    addRegexBench(b, regexz_mod, target, optimize, "search_startup", "Measure search DFA construction, first searches and warmed calls");
    addRegexBench(b, regexz_mod, target, optimize, "branch_startup", "Measure dominant branch initialization and cold or warm token passes");
}

fn addRegexBench(b: *std.Build, regexz_mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, name: []const u8, description: []const u8) void {
    const module = b.createModule(.{
        .root_source_file = b.path(b.fmt("tools/bench/{s}.zig", .{name})),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("regexz", regexz_mod);
    const executable = b.addExecutable(.{ .name = b.fmt("regexz-{s}-bench", .{name}), .root_module = module });
    const run = b.addRunArtifact(executable);
    b.step(b.fmt("bench-{s}", .{name}), description).dependOn(&run.step);
}
