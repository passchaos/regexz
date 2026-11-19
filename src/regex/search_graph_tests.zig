const std = @import("std");
const graph = @import("search_graph.zig");
const search = @import("search_dfa.zig");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "search graph resets visits across epoch rollover" {
    var walk = try graph.Walk.init(gpa, 5);
    defer walk.deinit(gpa);
    for (0..600) |_| {
        walk.reset(0);
        try std.testing.expectEqual(@as(?u32, 0), walk.pop());
        walk.push(2);
        walk.push(1);
        walk.push(1);
        try std.testing.expectEqual(@as(?u32, 1), walk.pop());
        try std.testing.expectEqual(@as(?u32, 2), walk.pop());
        walk.push(0);
        try std.testing.expect(walk.pop() == null);
        walk.reset(2);
        try std.testing.expectEqual(@as(?u32, 2), walk.pop());
        try std.testing.expect(walk.pop() == null);
    }
}

test "search graph bounds cyclic two-successor walks without allocation" {
    const count = 257;
    var counter = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    var walk = try graph.Walk.init(counter.allocator(), count);
    defer walk.deinit(counter.allocator());
    walk.reset(0);
    var visits: usize = 0;
    while (walk.pop()) |pc| {
        visits += 1;
        walk.push((pc + 1) % count);
        walk.push((pc + 2) % count);
    }
    try std.testing.expectEqual(@as(usize, count), visits);
    try std.testing.expectEqual(@as(usize, 1), counter.allocations);
    try std.testing.expect(!counter.has_induced_failure);
}

test "search graph analyses retain eligible priorities and rejected loops" {
    for ([_]struct { pattern: []const u8, eligible: bool }{
        .{ .pattern = "(?:ab)?(?:cd)?(?:ef)?(?:gh)?(?:ij)?Z", .eligible = true },
        .{ .pattern = "([a-z]+[0-9]+[A-Z]+)", .eligible = true },
        .{ .pattern = "(?:a|ab)?b", .eligible = true },
        .{ .pattern = "a+?", .eligible = true },
        .{ .pattern = "(?:ab|a)*b", .eligible = false },
        .{ .pattern = "a*?b*", .eligible = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var dfa = try search.Workspace.init(gpa, value.program);
        defer if (dfa) |*workspace| workspace.deinit();
        try std.testing.expectEqual(case.eligible, dfa != null);
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.search_dfa_ineligible = true;
        var actual = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer actual.deinit();
        for ([_][]const u8{ "", "ab", "aab", "abab", "abc", "abcdefghijZ", "hello123XYZ", "aab x b", "aaa", "\xffab" }) |input| {
            for (0..input.len + 1) |from| {
                const expected = try reference.find(input, from);
                const found = try actual.find(input, from);
                try std.testing.expectEqual(expected != null, found != null);
                if (expected) |match| {
                    try std.testing.expectEqual(match.start, found.?.start);
                    try std.testing.expectEqual(match.end, found.?.end);
                    try std.testing.expectEqualSlices(usize, match.slots, found.?.slots);
                }
            }
        }
    }
}

test "search graph construction failures release retained and temporary buffers" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, program: regex.Program, input: []const u8) !void {
            var workspace = try search.Workspace.init(allocator, program);
            defer if (workspace) |*dfa| dfa.deinit();
            if (workspace) |*dfa| {
                const found = (try dfa.find(input, 0)).?;
                try std.testing.expectEqual(@as(usize, 0), found.start);
                try std.testing.expectEqual(input.len, found.end);
            }
        }
    };
    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "(?:ab)?(?:cd)?(?:ef)?(?:gh)?(?:ij)?Z", .input = "abcdefghijZ" },
        .{ .pattern = "([a-z]+[0-9]+[A-Z]+)", .input = "hello123XYZ" },
        .{ .pattern = "(?:ab|a)*b", .input = "aab" },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var counter = std.testing.FailingAllocator.init(gpa, .{});
        try Harness.run(counter.allocator(), value.program, case.input);
        for (0..counter.allocations) |fail_index| {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            Harness.run(failing.allocator(), value.program, case.input) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
            };
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
