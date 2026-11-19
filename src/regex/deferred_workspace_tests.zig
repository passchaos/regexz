const std = @import("std");
const regex = @import("../root.zig");
const deferred = @import("deferred_utf8_run.zig");
const gpa = std.testing.allocator;

fn run(workspace: *regex.Workspace) *deferred.CompactRun {
    if (workspace.utf8_run) |*value| return value;
    return &workspace.utf8_loop.?.run;
}

test "deferred workspace keeps ASCII matching free of UTF-8 allocations" {
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "\\p{L}+", .input = "abcdefghijklmnop" },
        .{ .pattern = "(?:\\p{L}+\\n)+", .input = "hello\nworld\n" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
        var workspace = try regex.Workspace.init(failing.allocator(), value.program);
        defer workspace.deinit();
        for (0..10) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, case.input));
        try std.testing.expectEqual(@as(usize, 1), failing.allocations);
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expect(run(&workspace).table == null);
        try std.testing.expectEqual(@as(u8, 0), run(&workspace).unicode_probes);
    }
}

test "deferred workspace agrees with NFA before and after UTF-8 preparation" {
    for ([_][]const u8{ "\\p{L}+", "\\p{Han}+", "[ΣσςaA]+", "(?:\\p{L}+\\n)+", "(?:\\p{Han}+\\n)+" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var workspace = try regex.Workspace.init(gpa, value.program);
        defer workspace.deinit();
        try std.testing.expect(workspace.utf8_run != null or workspace.utf8_loop != null);
        const inputs = [_][]const u8{
            "",               "abc",
            "猫Σé",
            "𐐀𝔄",
            "𠀀",
            "你好世界",
            "Σσςa",
            "hello\nworld\n",
            "猫\n世界\n",
            "𠀀\n猫\n",
            "猫",
            "猫\n",
            "猫\n猫",
            "猫\n\n",
            "\n",
            "猫1",
            "猫\n1\n",
            "\xff",           "\xe7\x8c",
            "猫\xe0\x80\x80",
            "\xed\xa0\x80",   "\xf4\x90\x80\x80",
            "\xf0\x9f\x92",
            "\x80猫",
            "猫\n\xff\n",
        };
        for (0..2) |_| {
            for (inputs) |input| {
                try std.testing.expectEqual(workspace.matchesNfa(value.program, input), workspace.matchesBorrowed(&value.program, input));
            }
            try std.testing.expect(run(&workspace).table != null);
        }
    }
}

test "deferred workspace prepares long runs and continues separator loops" {
    for ([_][]const u8{ "\\p{Han}+", "(?:\\p{Han}+\\n)+" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        for ([_][]const u8{ "猫" ** 24, "猫" ** 24 ++ "\n世界\n", "猫" ** 24 ++ "\n世界", "猫" ** 24 ++ "\n\n", "猫" ** 24 ++ "\xff" }) |input| {
            var workspace = try regex.Workspace.init(gpa, value.program);
            defer workspace.deinit();
            try std.testing.expectEqual(workspace.matchesNfa(value.program, input), workspace.matchesBorrowed(&value.program, input));
            try std.testing.expect(run(&workspace).table != null);
        }
    }
}

test "deferred workspace optional allocation failures preserve scalar results and cleanup" {
    const Harness = struct {
        fn check(allocator: std.mem.Allocator, program: regex.Program, input: []const u8) !void {
            var workspace = try regex.Workspace.init(allocator, program);
            defer workspace.deinit();
            for (0..6) |_| {
                try std.testing.expect(workspace.matchesBorrowed(&program, input));
                try std.testing.expect(!workspace.matchesBorrowed(&program, "猫1"));
            }
        }
    };
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "\\p{L}+", .input = "猫Σé" },
        .{ .pattern = "(?:\\p{L}+\\n)+", .input = "猫\nΣé\n" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var counted = std.testing.FailingAllocator.init(gpa, .{});
        try Harness.check(counted.allocator(), value.program, case.input);
        try std.testing.expect(counted.allocations > 1);
        for (0..counted.allocations) |fail_index| {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            Harness.check(failing.allocator(), value.program, case.input) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expectEqual(@as(usize, 0), fail_index);
            };
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "deferred workspace malformed input does not warm optional UTF-8 tables" {
    var value = try regex.Regex.init(gpa, "\\p{L}+", .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    var workspace = try regex.Workspace.init(failing.allocator(), value.program);
    defer workspace.deinit();
    for ([_][]const u8{ "\xff", "\xe0\x80\x80", "\xe7\x8c", "\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xf0\x9f\x92" }) |input| {
        for (0..4) |_| try std.testing.expect(!workspace.matchesBorrowed(&value.program, input));
    }
    try std.testing.expectEqual(@as(u8, 0), run(&workspace).unicode_probes);
    try std.testing.expect(!failing.has_induced_failure);
    for (0..4) |_| try std.testing.expect(!workspace.matchesBorrowed(&value.program, "。"));
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(run(&workspace).failed);
    try std.testing.expect(run(&workspace).table == null);
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "猫Σé"));
}

test "deferred workspace preserves partial matching and strict budgets without preparation" {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const base = threaded.io();
    const Cancel = struct {
        fn check(_: ?*anyopaque) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var vtable = base.vtable.*;
    vtable.checkCancel = Cancel.check;
    const canceled_io = std.Io{ .userdata = base.userdata, .vtable = &vtable };
    const cases = [_]struct { pattern: []const u8, full: []const u8, partial: []const u8 }{
        .{ .pattern = "\\p{L}+", .full = "猫Σé", .partial = "" },
        .{ .pattern = "(?:\\p{L}+\\n)+", .full = "猫\nΣé\n", .partial = "猫\nΣé" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
        var workspace = try regex.Workspace.init(failing.allocator(), value.program);
        defer workspace.deinit();
        for (0..6) |_| {
            try std.testing.expectEqual(regex.PartialResult.full, workspace.partialMatch(value.program, case.full));
            try std.testing.expectEqual(regex.PartialResult.partial, workspace.partialMatch(value.program, case.partial));
            try std.testing.expectEqual(regex.PartialResult.none, workspace.partialMatch(value.program, "猫1"));
            try std.testing.expect(try workspace.matchesWithBudget(value.program, case.full, .{ .io = base }));
        }
        try std.testing.expectError(error.Timeout, workspace.matchesWithBudget(value.program, case.full, .{ .io = base, .deadline = .fromNow(base, .{ .clock = .awake, .raw = .fromNanoseconds(-1) }) }));
        try std.testing.expectError(error.Canceled, workspace.matchesWithBudget(value.program, case.full, .{ .io = canceled_io }));
        try std.testing.expect(run(&workspace).table == null);
        try std.testing.expectEqual(@as(u8, 0), run(&workspace).unicode_probes);
        try std.testing.expect(!failing.has_induced_failure);
    }
}
