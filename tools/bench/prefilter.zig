//! Shared-prefix search benchmarks: `zig build bench-prefilter -Doptimize=ReleaseFast`.
const std = @import("std");
const prefilter = @import("prefilter");
const gpa = std.heap.smp_allocator;

fn benchMulti(io: std.Io, out: *std.Io.Writer, name: []const u8, literals: []const []const u8, input: []const u8) !void {
    var filter = prefilter.MultiFilter.init(literals).?;
    std.mem.doNotOptimizeAway(&filter);
    const iterations = 2000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(filter.indexOf(input, 0));
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
    try benchMulti(io, out, "three pairs absent", &words, absent);
    try benchMulti(io, out, "three pairs collisions", &words, collisions.items);
    try benchMulti(io, out, "late complete literal", &words, late.items);
    try benchMulti(io, out, "sixteen pairs absent", &many, absent);
    try benchMulti(io, out, "dense candidates control", &dense, all_candidates);
    try benchMulti(io, out, "short literal hit", &words, "xx saturday yy");
    try out.flush();
}
