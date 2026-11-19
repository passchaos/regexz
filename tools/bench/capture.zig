//! Scoped capture-search benchmarks; use `zig build bench-capture -Doptimize=ReleaseFast`.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;

fn pass(workspace: *regexz.ReplaceWorkspace, input: []const u8) !usize {
    var offset: usize = 0;
    var checksum: usize = 0;
    while (offset < input.len) {
        const match = (try workspace.find(input, offset)) orelse break;
        for (match.slots) |slot| checksum +%= slot;
        if (match.end <= match.start) break;
        offset = match.end;
    }
    return checksum;
}

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (0..20) |_| std.mem.doNotOptimizeAway(try pass(&workspace, input));
    const iterations = 100;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(try pass(&workspace, input));
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));

    var counter = std.testing.FailingAllocator.init(gpa, .{});
    var cold = try regexz.ReplaceWorkspace.init(counter.allocator(), value.program, .{});
    defer cold.deinit();
    const init_allocations = counter.allocations;
    std.mem.doNotOptimizeAway(try cold.find(input, 0));
    const first_allocations = counter.allocations - init_allocations;
    const ns = @as(f64, @floatFromInt(samples[samples.len / 2])) / iterations;
    try out.print("{s:<24} {d:>12.1} ns/pass  first_find_allocations={d}\n", .{ name, ns, first_allocations });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;
    var words: std.ArrayList(u8) = .empty;
    defer words.deinit(gpa);
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(gpa);
    var unicode: std.ArrayList(u8) = .empty;
    defer unicode.deinit(gpa);
    for (0..4000) |_| {
        try words.appendSlice(gpa, "aaa bbb ");
        try digits.appendSlice(gpa, "12345 x ");
    }
    for (0..1000) |_| try unicode.appendSlice(gpa, "猫狗 Ελληνικά abc ");
    try bench(io, out, "word capture", "(\\w+)", words.items);
    try bench(io, out, "literal capture", "(a+)", words.items);
    try bench(io, out, "digit capture", "(\\d+)", digits.items);
    try bench(io, out, "nested capture", "((\\w+))", words.items);
    try bench(io, out, "empty adjacent captures", "()(\\w+)()", words.items);
    try bench(io, out, "adjacent run control", "(\\w+) (\\w+)", words.items);
    try bench(io, out, "repeated capture control", "(a)+", words.items);
    try bench(io, out, "Unicode letters capture", "(\\p{L}+)", unicode.items);
    try bench(io, out, "Unicode nested capture", "((\\p{L}+))", unicode.items);
    try bench(io, out, "Han capture", "(\\p{Han}+)", unicode.items);
    try bench(io, out, "Unicode literal capture", "(猫+)", unicode.items);
    try bench(io, out, "capture-free control", "\\w+", words.items);
    try bench(io, out, "no-match control", "([A-Z]+)", words.items);
    try out.flush();
}
