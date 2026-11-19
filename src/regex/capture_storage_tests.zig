const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;
const unset = std.math.maxInt(usize);

test "capture storage retains independent active and best slots in one allocation" {
    for ([_][]const u8{ "hello", "\\p{L}+", "(\\p{L}+)", "()(\\w+)()", "(a|aa)(a?)" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        for ([_]bool{ false, true }) |longest| {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
            {
                var workspace = try regex.ReplaceWorkspace.init(failing.allocator(), value.program, .{ .longest = longest });
                defer workspace.deinit();
                const count = 2 * (@as(usize, value.program.trackedCaptures()) + 1);
                try std.testing.expectEqual(@as(usize, 1), failing.allocations);
                try std.testing.expectEqual(count, workspace.slots.len);
                try std.testing.expectEqual(count, workspace.best_slots.len);
                try std.testing.expect(workspace.slots.ptr != workspace.best_slots.ptr);
                workspace.slots[0] = 7;
                try std.testing.expectEqual(unset, workspace.best_slots[0]);
                workspace.best_slots[count - 1] = 9;
                try std.testing.expectEqual(unset, workspace.slots[count - 1]);
                try std.testing.expect(!failing.has_induced_failure);
            }
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "capture storage preserves longest winners through repeated backtracking" {
    var value = try regex.Regex.init(gpa, "(a|aa)(a?)", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{ .longest = true });
    defer workspace.deinit();
    for (0..4) |_| {
        const full = (try workspace.find("aaa", 0)).?;
        try std.testing.expectEqual(@as(usize, 0), full.start);
        try std.testing.expectEqual(@as(usize, 3), full.end);
        try std.testing.expectEqualStrings("aa", full.group("aaa", 1).?);
        try std.testing.expectEqualStrings("a", full.group("aaa", 2).?);
        const shorter = (try workspace.find("aa", 0)).?;
        try std.testing.expectEqual(@as(usize, 2), shorter.end);
        try std.testing.expectEqualStrings("a", shorter.group("aa", 1).?);
        try std.testing.expectEqualStrings("a", shorter.group("aa", 2).?);
        try std.testing.expect((try workspace.find("x", 0)) == null);
    }
}

test "capture storage propagates required allocation failure" {
    var value = try regex.Regex.init(gpa, "(a|aa)(a?)", .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, regex.ReplaceWorkspace.init(failing.allocator(), value.program, .{}));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}
