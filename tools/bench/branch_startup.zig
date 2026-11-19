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
        checksum +%= found.start +% found.end;
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

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, input: []const u8, mode: Mode) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    const subject = try gpa.dupe(u8, input);
    defer gpa.free(subject);
    var warm = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
    defer warm.deinit();
    for (0..8) |_| std.mem.doNotOptimizeAway(try pass(&warm, subject));
    const iterations: usize = switch (mode) {
        .init, .first => 100,
        .cold_pass => 20,
        .warm_first => 20000,
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
    const cases = [_]struct { name: []const u8, input: []const u8 }{
        .{ .name = "ASCII token", .input = "hello" },
        .{ .name = "Unicode token", .input = "Σ猫" },
        .{ .name = "ASCII text", .input = ascii.items },
        .{ .name = "mixed text", .input = mixed.items },
        .{ .name = "CJK text", .input = cjk.items },
    };
    for (cases) |case| for ([_]Mode{ .init, .first, .cold_pass, .warm_first, .warm_pass }) |mode| {
        try bench(io, &stdout.interface, case.name, case.input, mode);
    };
    try stdout.interface.flush();
}
