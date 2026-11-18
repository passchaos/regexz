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
    try std.testing.expectEqualStrings("ab", match.group("abc", 1).?);
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

test "non-atomic lookbehind is rejected" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedRegexFeature, regex.Regex.init(allocator, "(?<*a)b", .{}));
}
