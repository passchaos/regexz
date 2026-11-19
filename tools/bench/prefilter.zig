//! Shared-prefix search benchmarks: `zig build bench-prefilter -Doptimize=ReleaseFast`.
const std = @import("std");
const prefilter = @import("prefilter");
const gpa = std.heap.smp_allocator;

fn bench(comptime Filter: type, io: std.Io, out: *std.Io.Writer, name: []const u8, literals: []const []const u8, input: []const u8) !void {
    var filter = Filter.init(literals).?;
    std.mem.doNotOptimizeAway(&filter);
    const iterations = 2000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            if (Filter == prefilter.MultiFilter) {
                std.mem.doNotOptimizeAway(filter.indexOf(input, 0));
            } else {
                std.mem.doNotOptimizeAway(filter.indexOfAny(input, 0));
            }
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    try out.print("{s:<28} {d:>12.1} ns/search\n", .{ name, @as(f64, @floatFromInt(samples[2])) / iterations });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    const words = [_][]const u8{ "sunday", "saturday", "september" };
    const many = [_][]const u8{ "sa0", "sb0", "sc0", "sd0", "se0", "sf0", "sg0", "sh0", "si0", "sj0", "sk0", "sl0", "sm0", "sn0", "so0", "sp0" };
    const dense = [_][]const u8{ "ss0", "ss1", "ss2", "ss3", "ss4", "ss5", "ss6", "ss7" };
    const absent = try gpa.alloc(u8, 32768);
    defer gpa.free(absent);
    @memset(absent, 'x');
    var collisions: std.ArrayList(u8) = .empty;
    defer collisions.deinit(gpa);
    for (0..1024) |_| try collisions.appendSlice(gpa, "sell seed suit sail sooner see ");
    var late: std.ArrayList(u8) = .empty;
    defer late.deinit(gpa);
    try late.appendSlice(gpa, collisions.items);
    try late.appendSlice(gpa, " saturday");
    const all_candidates = try gpa.alloc(u8, 16384);
    defer gpa.free(all_candidates);
    @memset(all_candidates, 's');
    try bench(prefilter.MultiFilter, io, out, "three pairs absent", &words, absent);
    try bench(prefilter.MultiFilter, io, out, "three pairs collisions", &words, collisions.items);
    try bench(prefilter.MultiFilter, io, out, "late complete literal", &words, late.items);
    try bench(prefilter.MultiFilter, io, out, "sixteen pairs absent", &many, absent);
    try bench(prefilter.MultiFilter, io, out, "dense candidates control", &dense, all_candidates);
    try bench(prefilter.MultiFilter, io, out, "short literal hit", &words, "xx saturday yy");
    const wide = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray" };
    const wide_dense = [_][]const u8{ "aa0", "ba0", "ca0", "da0", "ea0", "fa0", "ga0", "ha0", "ia0" };
    const dense_input = try gpa.alloc(u8, 16384);
    defer gpa.free(dense_input);
    @memset(dense_input, 'a');
    var wide_late: std.ArrayList(u8) = .empty;
    defer wide_late.deinit(gpa);
    try wide_late.appendSlice(gpa, collisions.items);
    try wide_late.appendSlice(gpa, " whiskey");
    try bench(prefilter.PairSet, io, out, "wide pairs absent", &wide, absent);
    try bench(prefilter.PairSet, io, out, "wide pairs collisions", &wide, collisions.items);
    try bench(prefilter.PairSet, io, out, "wide pairs late literal", &wide, wide_late.items);
    try bench(prefilter.PairSet, io, out, "wide dense control", &wide_dense, dense_input);
    try bench(prefilter.PairSet, io, out, "wide short control", &wide, "yy whiskey xx");
    try out.flush();
}
