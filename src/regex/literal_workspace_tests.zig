const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "literal workspace needs no allocation for matching or partial prefixes" {
    for ([_][]const u8{ "", "hello", "猫", "\\Q(a+b)[x]\\E" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        const literal = value.program.literal.?;
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
        var workspace = try regex.Workspace.init(failing.allocator(), value.program);
        defer workspace.deinit();
        try std.testing.expect(workspace.matchesBorrowed(&value.program, literal));
        try std.testing.expect(workspace.matchesNfa(value.program, literal));
        try std.testing.expectEqual(regex.PartialResult.full, workspace.partialMatch(value.program, literal));
        if (literal.len > 0) {
            try std.testing.expectEqual(regex.PartialResult.partial, workspace.partialMatch(value.program, literal[0 .. literal.len - 1]));
            try std.testing.expect(!workspace.matchesNfa(value.program, literal[0 .. literal.len - 1]));
        }
        try std.testing.expect(!workspace.matchesBorrowed(&value.program, "unmatched"));
        try std.testing.expectEqual(regex.PartialResult.none, workspace.partialMatch(value.program, "unmatched"));
        try std.testing.expectEqual(@as(usize, 0), workspace.storage.len);
        try std.testing.expectEqual(@as(usize, 0), workspace.seen.len);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
    }
}

test "literal workspace retains timeout and cancellation checks" {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const base = threaded.io();
    var value = try regex.Regex.init(gpa, "猫", .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var workspace = try regex.Workspace.init(failing.allocator(), value.program);
    defer workspace.deinit();
    try std.testing.expect(try workspace.matchesWithBudget(value.program, "猫", .{ .io = base }));
    try std.testing.expectError(error.Timeout, workspace.matchesWithBudget(value.program, "猫", .{ .io = base, .deadline = .fromNow(base, .{ .clock = .awake, .raw = .fromNanoseconds(-1) }) }));
    const Cancel = struct {
        fn check(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var table = base.vtable.*;
    table.checkCancel = Cancel.check;
    const io = std.Io{ .userdata = base.userdata, .vtable = &table };
    try std.testing.expectError(error.Canceled, workspace.matchesWithBudget(value.program, "猫", .{ .io = io }));
    try std.testing.expect(workspace.matchesNfa(value.program, "猫"));
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "literal workspace optimization retains nonliteral initialization errors" {
    var value = try regex.Regex.init(gpa, "(?:foo|bar)", .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, regex.Workspace.init(failing.allocator(), value.program));
    try std.testing.expect(failing.has_induced_failure);
}
