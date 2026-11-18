const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

fn findSpan(value: *regex.Regex, input: []const u8) !?[2]usize {
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find(input, 0)) orelse return null;
    return .{ match.start, match.end };
}

test "scan substring matches a captured substring" {
    const Case = struct { pattern: []const u8, input: []const u8, span: ?[2]usize };
    for ([_]Case{
        .{ .pattern = "\\b(\\w++)(*scs:(1).+rh)", .input = "barh", .span = .{ 0, 4 } },
        .{ .pattern = "\\b(\\w++)(*scs:(1).+rh)", .input = "rh", .span = null },
        .{ .pattern = "(a)?(b)(*scs:(1,2)b)", .input = "b", .span = .{ 0, 1 } },
        .{ .pattern = "(a)?(b)(*scs:(1)b)", .input = "b", .span = null },
        .{ .pattern = "(?<w>abc)(*scs:('w')a.c)", .input = "abc", .span = .{ 0, 3 } },
        .{ .pattern = "(?<w>abc)(*scs:(<w>)a.c)", .input = "abc", .span = .{ 0, 3 } },
        .{ .pattern = "(abc)(*scan_substring:(1)abc)", .input = "abc", .span = .{ 0, 3 } },
        .{ .pattern = "(a)(b)(*scs:(-1)b)", .input = "ab", .span = .{ 0, 2 } },
        .{ .pattern = "(a)(b)(*scs:(-2)a)", .input = "ab", .span = .{ 0, 2 } },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.span, try findSpan(&value, case.input));
    }
}

test "scan substring resets the subject end but not the start" {
    const Case = struct { pattern: []const u8, input: []const u8, span: ?[2]usize };
    for ([_]Case{
        // `$` sees the end of the captured substring, not the main subject.
        .{ .pattern = "(abc)(*scs:(1)abc$)", .input = "abcd", .span = .{ 0, 3 } },
        // `^` still refers to the start of the main subject.
        .{ .pattern = "(a)(*scs:(1)^a)", .input = "a", .span = .{ 0, 1 } },
        .{ .pattern = "(a)(*scs:(1)^a)", .input = "ba", .span = null },
        // Lookbehind may inspect text before the substring.
        .{ .pattern = "(b)(*scs:(1)(?<=a)b)", .input = "ab", .span = .{ 1, 2 } },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.span, try findSpan(&value, case.input));
    }
}

test "scan substring keeps captures from a successful scan" {
    var value = try regex.Regex.init(gpa, "(abc)(*scs:(1)(a)(b))", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find("abc", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(@as(usize, 3), match.end);
    try std.testing.expectEqualStrings("abc", match.group("abc", 1).?);
    try std.testing.expectEqualStrings("a", match.group("abc", 2).?);
    try std.testing.expectEqualStrings("b", match.group("abc", 3).?);
}
