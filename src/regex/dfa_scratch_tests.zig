const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "DFA borrowed scratch uses disjoint existing workspace views" {
    var value = try regex.Regex.init(gpa, "(?:foo|bar|baz)+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, "foo"));
    const n = value.program.instructions.len;
    const dfa = &workspace.dfa.?;
    try std.testing.expectEqual(n, dfa.scratch.len);
    try std.testing.expectEqual(n, dfa.seen.len);
    try std.testing.expect(dfa.scratch.ptr == workspace.storage[n..].ptr);
    try std.testing.expect(dfa.seen.ptr == workspace.seen.ptr);
    try std.testing.expect(dfa.scratch.ptr != workspace.storage.ptr);
}

test "DFA borrowed visits discard NFA markers and retain epoch wrap matching" {
    var value = try regex.Regex.init(gpa, "(?:foo|bar|baz)+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, "foo"));
    try std.testing.expect(workspace.matchesNfa(value.program, "foo"));
    // Reused NFA storage may contain the same generation as a new closure.
    @memset(workspace.seen[0..value.program.instructions.len], 1);
    workspace.dfa.?.epoch = 0;
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "bar"));
    try std.testing.expect(!workspace.dfa.?.seen_invalid);
    @memset(workspace.dfa.?.seen, std.math.maxInt(u32));
    workspace.dfa.?.epoch = std.math.maxInt(u32);
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "baz"));
    try std.testing.expect(workspace.dfa.?.epoch != 0);
    try std.testing.expect(!workspace.dfa_failed);
}

test "DFA borrowed visits survive cancellation after NFA overwrites storage" {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const base = threaded.io();
    const Probe = struct {
        calls: usize = 0,
        var active: ?*@This() = null;
        fn check(_: ?*anyopaque) std.Io.Cancelable!void {
            active.?.calls += 1;
            if (active.?.calls == 3) return error.Canceled;
        }
    };
    var probe: Probe = .{};
    Probe.active = &probe;
    defer Probe.active = null;
    var vtable = base.vtable.*;
    vtable.checkCancel = Probe.check;
    const canceled_io = std.Io{ .userdata = base.userdata, .vtable = &vtable };
    var value = try regex.Regex.init(gpa, "(?:foo|bar)+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, "foo"));
    try std.testing.expectError(error.Canceled, workspace.matchesWithBudget(value.program, "foo" ** 4000, .{ .io = canceled_io }));
    try std.testing.expectEqual(@as(usize, 3), probe.calls);
    try std.testing.expect(workspace.stats.states_visited > 0);
    try std.testing.expect(workspace.dfa.?.seen_invalid);
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "bar"));
    try std.testing.expect(!workspace.dfa.?.seen_invalid);
    try std.testing.expect(!workspace.dfa_failed);
}

test "DFA borrowed buffers preserve mixed NFA partial budget and cached calls" {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cases = [_]struct { pattern: []const u8, warm: []const u8, partial: []const u8, inputs: []const []const u8 }{
        .{ .pattern = "(?:foo|bar|baz)+", .warm = "foo", .partial = "fo", .inputs = &.{ "bar", "baz", "foobar", "", "fo", "x", "barfoo" } },
        .{ .pattern = "(?:\\p{Han}|\\p{Greek}|[0-9])+X?", .warm = "猫Δ1", .partial = "", .inputs = &.{ "Σ猫2", "猫X", "一伀0", "𠀀Δ", "A", "猫\xff", "" } },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.Workspace.init(gpa, value.program);
        defer workspace.deinit();
        var reference = try regex.Workspace.init(gpa, value.program);
        defer reference.deinit();
        for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, case.warm));
        try std.testing.expect(workspace.dfa != null);
        for (0..4) |_| {
            for (case.inputs) |input| {
                const expected = reference.matchesNfa(value.program, input);
                try std.testing.expectEqual(expected, workspace.matchesNfa(value.program, input));
                try std.testing.expectEqual(expected, workspace.matchesBorrowed(&value.program, input));
                try std.testing.expectEqual(reference.partialMatch(value.program, case.partial), workspace.partialMatch(value.program, case.partial));
                try std.testing.expectEqual(expected, workspace.matchesBorrowed(&value.program, input));
                try std.testing.expectEqual(expected, try workspace.matchesWithBudget(value.program, input, .{ .io = io }));
                try std.testing.expectEqual(expected, workspace.matchesBorrowed(&value.program, input));
            }
        }
        try std.testing.expectError(error.Timeout, workspace.matchesWithBudget(value.program, case.warm, .{ .io = io, .deadline = .fromNow(io, .{ .clock = .awake, .raw = .fromNanoseconds(-1) }) }));
        try std.testing.expect(workspace.matchesBorrowed(&value.program, case.warm));
        try std.testing.expect(!workspace.dfa_failed);
    }
}
