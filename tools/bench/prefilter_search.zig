//! Regex API checks accompanying the prefilter microbenchmarks.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (0..20) |_| std.mem.doNotOptimizeAway(try workspace.find(input, 0));
    const iterations = 1000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(try workspace.find(input, 0));
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
    var collisions: std.ArrayList(u8) = .empty;
    defer collisions.deinit(gpa);
    for (0..1024) |_| try collisions.appendSlice(gpa, "sell seed suit sail sooner see ");
    var late: std.ArrayList(u8) = .empty;
    defer late.deinit(gpa);
    try late.appendSlice(gpa, collisions.items);
    try late.appendSlice(gpa, " saturday");
    try bench(io, out, "regex prefix collisions", "(?:sunday|saturday|september)", collisions.items);
    try bench(io, out, "regex late literal", "(?:sunday|saturday|september)", late.items);
    try bench(io, out, "wide alternatives control", "(?:alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|juliet|kilo|lima|mike|november|oscar|papa|quebec|romeo|sierra|tango|uniform|victor|whiskey|xray)", collisions.items);
    try bench(io, out, "case-folded control", "(?i)STRASSE", collisions.items);
    try bench(io, out, "capture run control", "(\\w+)", "words 123");
    try out.flush();
}
