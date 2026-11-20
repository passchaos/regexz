//! Workspace initialization, first token and complete cold/warm token passes.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;
const pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
const Mode = enum { init, first, cold_pass, warm_first, warm_pass };

fn pass(workspace: *regexz.ReplaceWorkspace, input: []const u8) !usize {
    var offset: usize = 0;
    var checksum: usize = 0;
    while (offset < input.len) {
        const found = (try workspace.find(input, offset)) orelse break;
        for (found.slots) |slot| checksum +%= slot;
        if (found.end <= offset) break;
        offset = found.end;
    }
    return checksum;
}

fn workload(workspace: *regexz.ReplaceWorkspace, input: []const u8, mode: Mode) !void {
    switch (mode) {
        .init => std.mem.doNotOptimizeAway(workspace),
        .first, .warm_first => std.mem.doNotOptimizeAway(try workspace.find(input, 0)),
        .cold_pass, .warm_pass => std.mem.doNotOptimizeAway(try pass(workspace, input)),
    }
}

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, expression: []const u8, input: []const u8, mode: Mode) !void {
    var value = try regexz.Regex.init(gpa, expression, .{});
    defer value.deinit();
    const subject = try gpa.dupe(u8, input);
    defer gpa.free(subject);
    var warm = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
    defer warm.deinit();
    for (0..8) |_| std.mem.doNotOptimizeAway(try pass(&warm, subject));
    const full_scan = subject.len > 64 and (try warm.find(subject, 0)) == null;
    const iterations: usize = switch (mode) {
        .init, .first => 100,
        .cold_pass => 20,
        .warm_first => if (full_scan) 80 else 20000,
        .warm_pass => if (subject.len > 64) 80 else 20000,
    };
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(subject.ptr);
            if (mode == .warm_first or mode == .warm_pass) {
                try workload(&warm, subject, mode);
            } else {
                var fresh = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
                defer fresh.deinit();
                try workload(&fresh, subject, mode);
            }
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    var counter = std.testing.FailingAllocator.init(gpa, .{});
    var counted = try regexz.ReplaceWorkspace.init(counter.allocator(), value.program, .{});
    defer counted.deinit();
    const init_allocations = counter.allocations;
    const init_bytes = counter.allocated_bytes;
    try workload(&counted, subject, mode);
    try out.print("{s:<16} {s:<10} {d:>12.1} ns/iter init_allocations={d} init_bytes={d} first_allocations={d} first_bytes={d} workspace_bytes={d}\n", .{
        name,                                 @tagName(mode),                   @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations)),
        init_allocations,                     init_bytes,                       counter.allocations - init_allocations,
        counter.allocated_bytes - init_bytes, @sizeOf(regexz.ReplaceWorkspace),
    });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    var ascii: std.ArrayList(u8) = .empty;
    defer ascii.deinit(gpa);
    var mixed: std.ArrayList(u8) = .empty;
    defer mixed.deinit(gpa);
    var cjk: std.ArrayList(u8) = .empty;
    defer cjk.deinit(gpa);
    for (0..200) |_| {
        try ascii.appendSlice(gpa, "Hello, world! This is an ASCII tokenizer sample. Numbers 12345 and symbols !@#$%^&*().\n");
        try mixed.appendSlice(gpa, "Hello, world! This is a mixed tokenizer sample. Unicode 你好世界 café Ελληνικά 12345.\n");
    }
    for (0..4000) |_| try cjk.appendSlice(gpa, "你好世界，这是一个中文分词测试。\n");
    const cases = [_]struct { name: []const u8, expression: []const u8 = pattern, input: []const u8 }{
        .{ .name = "ASCII token", .input = "hello" },
        .{ .name = "Unicode token", .input = "Σ猫" },
        .{ .name = "ASCII text", .input = ascii.items },
        .{ .name = "mixed text", .input = mixed.items },
        .{ .name = "CJK text", .input = cjk.items },
        .{ .name = "letters ASCII", .expression = "\\p{L}+", .input = "hello" },
        .{ .name = "letters Unicode", .expression = "\\p{L}+", .input = "Σ猫" },
        .{ .name = "letters capture", .expression = "(\\p{L}+)", .input = "Σ猫" },
        .{ .name = "nested capture", .expression = "((\\p{L}+))", .input = "Σ猫" },
        .{ .name = "word capture", .expression = "(\\w+)", .input = "hello" },
        .{ .name = "Greek tiny hit", .expression = "(\\p{Greek}+)", .input = "Σσ" },
        .{ .name = "Han tiny hit", .expression = "(\\p{Han}+)", .input = "猫" },
        .{ .name = "Greek capture gap", .expression = "(\\p{Greek}+)", .input = "你好世界😀𠀀１２３ " ** 32 ++ "Σσ" },
        .{ .name = "Han capture gap", .expression = "()(\\p{Han}+)()", .input = "Ελληνικά café ١٢٣ 😀𐐀 " ** 32 ++ "𠀀猫" },
        .{ .name = "disjoint ASCII", .expression = "([a-z]+)([0-9]+)([A-Z]+)", .input = "hello123XYZ" },
        .{ .name = "disjoint Unicode", .expression = "(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)", .input = "Σσ١٢猫狗" },
        .{ .name = "empty captures", .expression = "()(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)()", .input = "Σσ١٢猫狗" },
        .{ .name = "nullable greedy", .expression = "(a*)(b*)", .input = "aaabbb" },
        .{ .name = "overlap nullable", .expression = "(a*)(a*)", .input = "aaaa" },
        .{ .name = "optional ASCII", .expression = "([a-z]+)([0-9]*)([A-Z]+)", .input = "helloXYZ" },
        .{ .name = "optional Unicode", .expression = "()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", .input = "Σσ猫狗" },
        .{ .name = "letters text", .expression = "\\p{L}+", .input = ascii.items },
        .{ .name = "letters mixed", .expression = "\\p{L}+", .input = mixed.items },
        .{ .name = "Han text", .expression = "\\p{Han}+", .input = cjk.items },
        .{ .name = "Han ASCII miss", .expression = "\\p{Han}+", .input = ascii.items },
        .{ .name = "Han short miss", .expression = "\\p{Han}+", .input = "plain ascii" },
        .{ .name = "Greek CJK miss", .expression = "\\p{Greek}+", .input = cjk.items },
    };
    for (cases) |case| for ([_]Mode{ .init, .first, .cold_pass, .warm_first, .warm_pass }) |mode| {
        try bench(io, &stdout.interface, case.name, case.expression, case.input, mode);
    };
    try stdout.interface.flush();
}
