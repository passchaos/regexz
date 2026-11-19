//! Runtime-input comparisons for generated and interpreted matchers.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;

fn generated(comptime pattern: []const u8, io: std.Io, out: *std.Io.Writer, name: []const u8, input: []const u8) !void {
    const matcher = regexz.comptime_regex.Regex(pattern);
    var subject = input;
    const iterations = 200000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            // Keep both the pointer and length unknown to the optimizer.
            std.mem.doNotOptimizeAway(&subject);
            std.mem.doNotOptimizeAway(matcher.match(subject) != null);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    try out.print("{s:<42} {d:>10.1} ns/iter\n", .{ name, @as(f64, @floatFromInt(samples[2])) / iterations });
}

fn interpreted(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regexz.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    var subject = input;
    for (0..1000) |_| std.mem.doNotOptimizeAway(workspace.matchesBorrowed(&value.program, subject));
    const iterations = 200000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(&subject);
            std.mem.doNotOptimizeAway(workspace.matchesBorrowed(&value.program, subject));
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    try out.print("{s:<42} {d:>10.1} ns/iter\n", .{ name, @as(f64, @floatFromInt(samples[2])) / iterations });
}

pub fn run(io: std.Io, out: *std.Io.Writer) !void {
    const literal = try gpa.dupe(u8, "hello, world!");
    defer gpa.free(literal);
    const class = try gpa.dupe(u8, "foo42");
    defer gpa.free(class);
    try generated("hello, world!", io, out, "comptime fullmatch literal", literal);
    try generated("(?:foo|bar)[0-9]+", io, out, "comptime fullmatch class", class);
    try interpreted(io, out, "runtime input literal control", "hello, world!", literal);
    try interpreted(io, out, "runtime input class control", "(?:foo|bar)[0-9]+", class);
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    try run(io, &stdout.interface);
    try stdout.interface.flush();
}
