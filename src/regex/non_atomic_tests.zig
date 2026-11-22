const std = @import("std");
const regex = @import("../root.zig");

test "non-atomic lookahead backtracks into alternatives" {
    const allocator = std.testing.allocator;
    var value = try regex.Regex.init(allocator, "(?*(a|ab))(?1)c", .{});
    defer value.deinit();
    try std.testing.expect(try value.matches(allocator, "abc"));
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find("abc", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(@as(usize, 3), match.end);
    // PCRE2 restores captures set by the subroutine call, so group 1
    // keeps the value from the non-atomic lookahead.
    try std.testing.expectEqualStrings("a", match.group("abc", 1).?);
    // Hidden position slots must not leak into user-visible groups.
    try std.testing.expect(match.group("abc", 2) == null);
}

test "non-atomic lookahead is zero-width and can fail" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, matches: bool }{
        .{ .pattern = "(?*(a|ab))(?1)", .input = "ab", .matches = true },
        .{ .pattern = "(?*(a|ab))(?1)b", .input = "abb", .matches = true },
        .{ .pattern = "(?*a)a", .input = "a", .matches = true },
        .{ .pattern = "(?*ab)ab", .input = "ab", .matches = true },
        .{ .pattern = "(?*a)b", .input = "ab", .matches = false },
        .{ .pattern = "(?*(a|ab))x", .input = "ab", .matches = false },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(allocator, case.input));
    }
}

fn findSpan(allocator: std.mem.Allocator, value: *regex.Regex, input: []const u8) !?[2]usize {
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find(input, 0)) orelse return null;
    return .{ match.start, match.end };
}

test "non-atomic lookbehind is zero-width and scans starts" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: ?[2]usize }{
        .{ .pattern = "(?<*)a", .input = "a", .span = .{ 0, 1 } },
        .{ .pattern = "(?<*b)c", .input = "abc", .span = .{ 2, 3 } },
        .{ .pattern = "(?<*bc)d", .input = "abcd", .span = .{ 3, 4 } },
        .{ .pattern = "(?<*b)c", .input = "ac", .span = null },
        .{ .pattern = "(?<*x)a", .input = "a", .span = null },
        .{ .pattern = "(?<*a)a", .input = "a", .span = null },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.span, try findSpan(allocator, &value, case.input));
    }
}

test "non-atomic lookbehind backtracks into the assertion" {
    const allocator = std.testing.allocator;
    // At position 2 the first successful assertion match captures "aa", so
    // `\1c` fails. A non-atomic assertion may retry from position 1, where the
    // capture is "a" and the continuation matches.
    var value = try regex.Regex.init(allocator, "(?<*(a+))\\1c", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(?[2]usize, .{ 2, 4 }), try findSpan(allocator, &value, "aaac"));
    // The atomic lookbehind commits to the first assertion match and finds
    // nothing.
    var atomic = try regex.Regex.init(allocator, "(?<=(a+))\\1c", .{});
    defer atomic.deinit();
    try std.testing.expectEqual(@as(?[2]usize, null), try findSpan(allocator, &atomic, "aaac"));
}

test "alphabetic assertion names" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: ?[2]usize }{
        .{ .pattern = "(*pla:a)a", .input = "aa", .span = .{ 0, 1 } },
        .{ .pattern = "(*positive_lookahead:a)a", .input = "aa", .span = .{ 0, 1 } },
        .{ .pattern = "(*nla:b)a", .input = "a", .span = .{ 0, 1 } },
        .{ .pattern = "(*plb:a)b", .input = "ab", .span = .{ 1, 2 } },
        .{ .pattern = "(*nlb:a)b", .input = "cb", .span = .{ 1, 2 } },
        .{ .pattern = "(*napla:(a|ab))(?1)c", .input = "abc", .span = .{ 0, 3 } },
        .{ .pattern = "(*non_atomic_positive_lookahead:(a|ab))(?1)c", .input = "abc", .span = .{ 0, 3 } },
        .{ .pattern = "(*naplb:(a+))\\1c", .input = "aaac", .span = .{ 2, 4 } },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.span, try findSpan(allocator, &value, case.input));
    }
}

test "non-atomic lookbehind captures are visible" {
    const allocator = std.testing.allocator;
    var value = try regex.Regex.init(allocator, "(?<*(ab))c", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find("abc", 0)).?;
    try std.testing.expectEqual(@as(usize, 2), match.start);
    try std.testing.expectEqual(@as(usize, 3), match.end);
    // Non-atomic lookbehind captures stay visible to the continuation.
    try std.testing.expectEqualStrings("ab", match.group("abc", 1).?);
    // Hidden slots must not leak into user-visible groups.
    try std.testing.expect(match.group("abc", 2) == null);
}
