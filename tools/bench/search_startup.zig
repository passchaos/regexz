//! Separate search-DFA setup, first search and warmed API/DFA calls.
const std = @import("std");
const regexz = @import("regexz");
const Dfa = @typeInfo(@FieldType(regexz.ReplaceWorkspace, "search_dfa_workspace")).optional.child;
const gpa = std.heap.smp_allocator;
const Mode = enum { dfa_init, dfa_cold, api_cold, dfa_warm, api_warm };

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, mode: Mode) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    const subject = try gpa.dupe(u8, input);
    defer gpa.free(subject);
    var warm = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
    defer warm.deinit();
    var dfa = try Dfa.init(gpa, value.program);
    defer if (dfa) |*workspace| workspace.deinit();
    for (0..100) |_| {
        std.mem.doNotOptimizeAway(try warm.find(subject, 0));
        if (dfa) |*workspace| std.mem.doNotOptimizeAway(try workspace.find(subject, 0));
    }
    const iterations: usize = if (mode == .dfa_warm or mode == .api_warm) 20000 else 1000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(subject.ptr);
            switch (mode) {
                .dfa_init, .dfa_cold => {
                    var fresh = try Dfa.init(gpa, value.program);
                    defer if (fresh) |*workspace| workspace.deinit();
                    if (fresh) |*workspace| {
                        if (mode == .dfa_cold) std.mem.doNotOptimizeAway(try workspace.find(subject, 0));
                        std.mem.doNotOptimizeAway(workspace);
                    }
                },
                .api_cold => {
                    var fresh = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
                    defer fresh.deinit();
                    std.mem.doNotOptimizeAway(try fresh.find(subject, 0));
                },
                .dfa_warm => if (dfa) |*workspace| {
                    std.mem.doNotOptimizeAway(try workspace.find(subject, 0));
                },
                .api_warm => std.mem.doNotOptimizeAway(try warm.find(subject, 0)),
            }
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));

    var counter = std.testing.FailingAllocator.init(gpa, .{});
    var counted = try Dfa.init(counter.allocator(), value.program);
    defer if (counted) |*workspace| workspace.deinit();
    const init_allocations = counter.allocations;
    const init_bytes = counter.allocated_bytes;
    if (counted) |*workspace| std.mem.doNotOptimizeAway(try workspace.find(subject, 0));
    const cache_bytes = if (counted) |workspace| workspace.unicode_cache.len * @sizeOf(@TypeOf(workspace.unicode_cache[0])) else 0;
    const front_bytes = if (counted) |workspace| (if (workspace.unicode_cache.len == 0) 0 else workspace.state_cache.items.len * @sizeOf(@TypeOf(workspace.state_cache.items[0]))) else 0;
    try out.print("{s:<22} {s:<10} {d:>12.1} ns/iter init_allocations={d} init_bytes={d} first_allocations={d} first_bytes={d} unicode_bytes={d} front_bytes={d}\n", .{
        name,                                 @tagName(mode), @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations)),
        init_allocations,                     init_bytes,     counter.allocations - init_allocations,
        counter.allocated_bytes - init_bytes, cache_bytes,    front_bytes,
    });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const cases = [_]struct { name: []const u8, pattern: []const u8, input: []const u8 }{
        .{ .name = "ASCII alternatives", .pattern = "(?:foo|bar)", .input = "xx foo yy bar" },
        .{ .name = "ASCII captures", .pattern = "(\\w+) (\\w+)", .input = "hello world" },
        .{ .name = "ASCII lookahead", .pattern = "[a-z]+(?=!)", .input = "hello!" },
        .{ .name = "Unicode boundary", .pattern = "[a-z]+(?=\\p{Han})", .input = "hello猫" },
        .{ .name = "Unicode lookahead", .pattern = "\\p{L}+(?!\\p{L})", .input = "Ελληνικά1" },
        .{ .name = "Unicode ASCII subject", .pattern = "\\p{L}+(?!\\p{L})", .input = "hello1" },
        .{ .name = "byte DFA control", .pattern = "\\p{Han}+x", .input = "你好x" },
        .{ .name = "literal API control", .pattern = "hello", .input = "xx hello" },
        .{ .name = "ineligible control", .pattern = "(?:ab|a)*b", .input = "aab" },
    };
    for (cases) |case| {
        for ([_]Mode{ .dfa_init, .dfa_cold, .api_cold, .dfa_warm, .api_warm }) |mode| {
            try bench(io, &stdout.interface, case.name, case.pattern, case.input, mode);
        }
    }
    try stdout.interface.flush();
}
