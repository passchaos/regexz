//! Scoped replacement benchmarks, including output allocation counts.
//! Run with `zig build bench-replace -Doptimize=ReleaseFast`.
const std = @import("std");
const regexz = @import("regexz");

const Mode = enum { all, limited, callback };
const Case = struct {
    name: []const u8,
    pattern: []const u8,
    substitution: []const u8,
    mode: Mode = .all,
};

fn callback(context: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, _: regexz.Match) regexz.Error![]u8 {
    const replacement: *[]const u8 = @ptrCast(@alignCast(context.?));
    return allocator.dupe(u8, replacement.*);
}

fn replace(workspace: *regexz.ReplaceWorkspace, case: Case, input: []const u8) ![]u8 {
    return switch (case.mode) {
        .all => workspace.replaceAll(input, case.substitution),
        .limited => workspace.replacen(input, 1, case.substitution),
        .callback => blk: {
            var replacement = case.substitution;
            break :blk workspace.replaceAllWithFn(input, @ptrCast(&replacement), callback);
        },
    };
}

fn bench(io: std.Io, out: *std.Io.Writer, allocator: std.mem.Allocator, allocator_name: []const u8, case: Case, input: []const u8) !void {
    var value = try regexz.Regex.init(allocator, case.pattern, .{});
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    for (0..20) |_| {
        const output = try replace(&workspace, case, input);
        allocator.free(output);
    }
    const iterations = 200;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            const output = try replace(&workspace, case, input);
            std.mem.doNotOptimizeAway(output);
            allocator.free(output);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));

    // Warm the engine before counting so these numbers measure output work.
    var counter = std.testing.FailingAllocator.init(allocator, .{});
    const counted = counter.allocator();
    workspace.allocator = counted;
    defer workspace.allocator = allocator;
    const output = try replace(&workspace, case, input);
    const output_len = output.len;
    counted.free(output);
    workspace.allocator = allocator;
    const ns = @as(f64, @floatFromInt(samples[samples.len / 2])) / iterations;
    try out.print("{s:<8} {s:<20} {d:>10.1} ns/iter  allocations={d} allocated_bytes={d} output_bytes={d}\n", .{
        allocator_name, case.name, ns, counter.allocations, counter.allocated_bytes, output_len,
    });
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    const input = try gpa.alloc(u8, 32_000);
    defer gpa.free(input);
    for (0..2000) |index| @memcpy(input[index * 16 ..][0..16], "aaa bbb aaa bbb ");
    const cases = [_]Case{
        .{ .name = "shrink", .pattern = "a+", .substitution = "x" },
        .{ .name = "grow", .pattern = "a+", .substitution = "abcdefghij" },
        .{ .name = "captures", .pattern = "(\\w+)", .substitution = "[$1]" },
        .{ .name = "no match", .pattern = "zzz", .substitution = "x" },
        .{ .name = "zero width", .pattern = "^|$", .substitution = "!" },
        .{ .name = "limited", .pattern = "a+", .substitution = "x", .mode = .limited },
        .{ .name = "callback", .pattern = "a+", .substitution = "x", .mode = .callback },
        .{ .name = "delete whole input", .pattern = ".+", .substitution = "" },
        .{ .name = "word boundary", .pattern = "\\b", .substitution = "|" },
        .{ .name = "not word boundary", .pattern = "\\B", .substitution = "|" },
        .{ .name = "boundary or end", .pattern = "\\b|$", .substitution = "|" },
    };
    for (cases) |case| {
        try bench(io, out, gpa, "page", case, input);
        try bench(io, out, std.heap.smp_allocator, "smp", case, input);
    }
    try out.flush();
}
