const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;
const deferred = @import("deferred_utf8_run.zig");
const pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";

test "deferred run avoids UTF-8 allocation on ASCII dominant branches" {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    var workspace = try regex.ReplaceWorkspace.init(failing.allocator(), value.program, .{});
    defer workspace.deinit();
    const initial = failing.allocations;
    for (0..10) |_| {
        const found = (try workspace.find("hello world", 0)).?;
        try std.testing.expectEqual(@as(usize, 0), found.start);
        try std.testing.expectEqual(@as(usize, 5), found.end);
    }
    try std.testing.expectEqual(initial, failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(workspace.fast_branch.?.run.table == null);
    try std.testing.expect(workspace.fast_branch.?.prefix.?.table == null);
}

test "deferred run matches interpreter across Unicode cache initialization" {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var reference_program = value.program;
    reference_program.fast_branch = null;
    var reference = try regex.ReplaceWorkspace.init(gpa, reference_program, .{});
    defer reference.deinit();
    reference.search_dfa_ineligible = true;
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for ([_][]const u8{ "hello world", "猫Σé café", "。猫 abc!\n", "'s 'ſ foo", "\xff猫1", "Σ" ** 2100 }) |input| {
        for (0..input.len + 1) |from| {
            const expected = try reference.find(input, from);
            const found = try workspace.find(input, from);
            try std.testing.expectEqual(expected != null, found != null);
            if (expected) |match| {
                try std.testing.expectEqual(match.start, found.?.start);
                try std.testing.expectEqual(match.end, found.?.end);
            }
        }
    }
    try std.testing.expect(workspace.fast_branch.?.run.table != null);
}

test "deferred run keeps broad Unicode tables scalar on sparse input" {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const input = "hello 你好世界 café";
    var offset: usize = 0;
    while (offset <= input.len) {
        const found = (try workspace.find(input, offset)) orelse break;
        if (found.end <= found.start) break;
        offset = found.end;
    }
    try std.testing.expect(workspace.fast_branch.?.run.table == null);
}

test "deferred run table allocation failures retain scalar matching and cleanup" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, program: regex.Program) !void {
            var workspace = try regex.ReplaceWorkspace.init(allocator, program, .{});
            defer workspace.deinit();
            for (0..6) |_| {
                for ([_][]const u8{ "Σ猫", "。Σ猫", "hello", "Σ" ** 2100 }) |input| {
                    const found = (try workspace.find(input, 0)).?;
                    try std.testing.expectEqual(@as(usize, 0), found.start);
                    try std.testing.expectEqual(input.len, found.end);
                }
            }
        }
    };
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var counted = std.testing.FailingAllocator.init(gpa, .{});
    try Harness.run(counted.allocator(), value.program);
    for (0..counted.allocations) |fail_index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        Harness.run(failing.allocator(), value.program) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "deferred run warms valid Unicode misses and rejects malformed probes" {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var run = deferred.Run.init(value.program.fast_branch.?.prefix.?);
    defer run.deinit(failing.allocator());
    for ([_][]const u8{ "\xff", "\xe0\x80\x80", "\xe7\x8c", "\x80" }) |input| {
        for (0..4) |_| try std.testing.expect(run.runeAt(failing.allocator(), input, 0) == null);
    }
    try std.testing.expectEqual(@as(u16, 0), run.unicode_probes);
    try std.testing.expect(!failing.has_induced_failure);
    for (0..2048) |_| try std.testing.expect(run.runeAt(failing.allocator(), "猫", 0) == null);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(run.failed);
    try std.testing.expect(run.table == null);
    try std.testing.expectEqual(@as(?usize, 3), run.runeAt(failing.allocator(), "。", 0));
}
