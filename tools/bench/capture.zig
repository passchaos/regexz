//! Scoped capture-search benchmarks; use `zig build bench-capture -Doptimize=ReleaseFast`.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;

fn pass(workspace: *regexz.ReplaceWorkspace, input: []const u8) !usize {
    var offset: usize = 0;
    var checksum: usize = 0;
    while (offset <= input.len) {
        const match = (try workspace.find(input, offset)) orelse break;
        for (match.slots) |slot| checksum +%= slot;
        if (match.end <= match.start) {
            if (match.start == input.len) break;
            offset = nextRune(input, match.start);
        } else offset = match.end;
    }
    return checksum;
}

fn nextRune(input: []const u8, offset: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(input[offset]) catch return offset + 1;
    if (length > input.len - offset) return offset + 1;
    _ = std.unicode.utf8Decode(input[offset..][0..length]) catch return offset + 1;
    return offset + length;
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
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(input.ptr);
            std.mem.doNotOptimizeAway(try pass(&workspace, input));
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));

    var counter = std.testing.FailingAllocator.init(gpa, .{});
    var cold = try regexz.ReplaceWorkspace.init(counter.allocator(), value.program, .{});
    defer cold.deinit();
    const init_allocations = counter.allocations;
    const init_bytes = counter.allocated_bytes;
    std.mem.doNotOptimizeAway(try cold.find(input, 0));
    const first_allocations = counter.allocations - init_allocations;
    const ns = @as(f64, @floatFromInt(samples[samples.len / 2])) / iterations;
    try out.print("{s:<24} {d:>12.1} ns/pass input_bytes={d} first_find_allocations={d} first_requested_bytes={d} init_allocations={d} init_bytes={d} trail_capacity={d} choice_capacity={d}\n", .{
        name, ns, input.len, first_allocations, counter.allocated_bytes - init_bytes, init_allocations, init_bytes, cold.trail.capacity, cold.choices.capacity,
    });
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
    var runs: std.ArrayList(u8) = .empty;
    defer runs.deinit(gpa);
    var unicode_runs: std.ArrayList(u8) = .empty;
    defer unicode_runs.deinit(gpa);
    var han_misses: std.ArrayList(u8) = .empty;
    defer han_misses.deinit(gpa);
    var greek_misses: std.ArrayList(u8) = .empty;
    defer greek_misses.deinit(gpa);
    var sparse_han: std.ArrayList(u8) = .empty;
    defer sparse_han.deinit(gpa);
    var long_han: std.ArrayList(u8) = .empty;
    defer long_han.deinit(gpa);
    var nullable: std.ArrayList(u8) = .empty;
    defer nullable.deinit(gpa);
    var overlap_nullable: std.ArrayList(u8) = .empty;
    defer overlap_nullable.deinit(gpa);
    var optional_ascii: std.ArrayList(u8) = .empty;
    defer optional_ascii.deinit(gpa);
    var optional_unicode: std.ArrayList(u8) = .empty;
    defer optional_unicode.deinit(gpa);
    for (0..4000) |_| {
        try words.appendSlice(gpa, "aaa bbb ");
        try digits.appendSlice(gpa, "12345 x ");
    }
    for (0..1000) |_| try unicode.appendSlice(gpa, "猫狗 Ελληνικά abc ");
    for (0..2000) |_| {
        try runs.appendSlice(gpa, "hello123XYZ ");
        try unicode_runs.appendSlice(gpa, "Σσ١٢猫狗 ");
        try han_misses.appendSlice(gpa, "Ελληνικά café ١٢٣ 😀𐐀 ");
        try greek_misses.appendSlice(gpa, "你好世界😀𠀀１２３ ");
        try sparse_han.appendSlice(gpa, "Ελληνικά😀𐐀𠀀猫 ");
        try long_han.appendSlice(gpa, "猫𠀀");
        try nullable.appendSlice(gpa, "aaabbb ");
        try overlap_nullable.appendSlice(gpa, "aaaa ");
        try optional_ascii.appendSlice(gpa, "hello123XYZ helloXYZ ");
        try optional_unicode.appendSlice(gpa, "Σσ١٢猫狗 Σσ猫狗 猫狗 ");
    }
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
    try bench(io, out, "disjoint ASCII captures", "([a-z]+)([0-9]+)([A-Z]+)", runs.items);
    try bench(io, out, "disjoint Unicode captures", "(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)", unicode_runs.items);
    try bench(io, out, "Unicode empty captures", "()(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)()", unicode_runs.items);
    try bench(io, out, "overlapping run control", "([a-z0-9]+)([0-9]+)([A-Z]+)", runs.items);
    try bench(io, out, "no-match control", "([A-Z]+)", words.items);
    try bench(io, out, "Han mixed-script miss", "(\\p{Han}+)", han_misses.items);
    try bench(io, out, "Greek mixed-script miss", "(\\p{Greek}+)", greek_misses.items);
    try bench(io, out, "Han sparse captures", "()(\\p{Han}+)()", sparse_han.items);
    try bench(io, out, "Han long capture", "(\\p{Han}+)", long_han.items);
    try bench(io, out, "Han ASCII miss", "(\\p{Han}+)", words.items);
    try han_misses.appendSlice(gpa, "𠀀猫猫");
    try greek_misses.appendSlice(gpa, "Σσ");
    try bench(io, out, "Han after long prefix", "(\\p{Han}+)", han_misses.items);
    try bench(io, out, "Greek after long prefix", "((\\p{Greek}+))", greek_misses.items);
    try bench(io, out, "nullable greedy captures", "(a*)(b*)", nullable.items);
    try bench(io, out, "trailing nullable capture", "(a+)(b*)", nullable.items);
    try bench(io, out, "sandwiched nullable captures", "(a*)(b+)(c*)", nullable.items);
    try bench(io, out, "overlap nullable captures", "(a*)(a*)", overlap_nullable.items);
    try bench(io, out, "optional ASCII captures", "([a-z]+)([0-9]*)([A-Z]+)", optional_ascii.items);
    try bench(io, out, "optional overlapping run", "([a-z]+)([a-z0-9]*)([A-Z]+)", optional_ascii.items);
    try bench(io, out, "nullable Unicode captures", "(\\p{Greek}*)(\\p{Nd}*)(\\p{Han}+)", optional_unicode.items);
    try bench(io, out, "Unicode optional captures", "()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", optional_unicode.items);
    try bench(io, out, "optional lazy control", "([a-z]+)([0-9]*?)([A-Z]+)", optional_ascii.items);
    try bench(io, out, "overlap mandatory control", "([a-z]+)([a-z]*)([a-z]+)", optional_ascii.items);
    try out.flush();
}
