const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "ASCII DFA omits Unicode transition storage" {
    var value = try regex.Regex.init(gpa, "(?:foo|bar)+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, "foobar"));
    try std.testing.expect(workspace.dfa != null);
    try std.testing.expect(workspace.dfa.?.ascii_only);
    try std.testing.expectEqual(@as(usize, 0), workspace.dfa.?.unicode_cache.len);
    try std.testing.expect(!workspace.matchesBorrowed(&value.program, "foo你好"));
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "barfoo"));
}

test "Unicode DFA retains its rune transition cache" {
    var value = try regex.Regex.init(gpa, "(?:\\p{Greek}|[0-9])+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, "Δ1σ2"));
    try std.testing.expect(workspace.dfa != null);
    try std.testing.expect(!workspace.dfa.?.ascii_only);
    try std.testing.expect(workspace.dfa.?.unicode_cache.len > 0);
    for ([_][]const u8{ "Δ", "123", "Δ1σ2", "Ω0" }) |input| {
        try std.testing.expect(workspace.matchesBorrowed(&value.program, input));
    }
    try std.testing.expect(!workspace.matchesBorrowed(&value.program, "你好"));
}

test "DFA construction allocation failures release scratch storage" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, program: regex.Program, input: []const u8) !void {
            var workspace = try regex.Workspace.init(allocator, program);
            defer workspace.deinit();
            for (0..4) |_| try std.testing.expect(workspace.matchesBorrowed(&program, input));
        }
    };
    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "(?:foo|bar)+", .input = "foobar" },
        .{ .pattern = "(?:\\p{Greek}|[0-9])+", .input = "Δ1σ2" },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var counted = std.testing.FailingAllocator.init(gpa, .{});
        try Harness.run(counted.allocator(), value.program, case.input);
        for (0..counted.allocations) |fail_index| {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            Harness.run(failing.allocator(), value.program, case.input) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(failing.has_induced_failure);
            };
            // DFA allocation errors are intentionally swallowed by the NFA
            // fallback, but both successful and failed calls must release all
            // allocations. The generic failure checker requires propagation.
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}
