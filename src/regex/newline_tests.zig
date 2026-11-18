const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

fn findSpan(value: *regex.Regex, input: []const u8) !?[2]usize {
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find(input, 0)) orelse return null;
    return .{ match.start, match.end };
}

test "newline conventions control dot and bare \\N" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "a.b", .input = "a\nb", .matches = false },
        .{ .pattern = "a.b", .input = "a\rb", .matches = true },
        .{ .pattern = "(*CR)a.b", .input = "a\rb", .matches = false },
        .{ .pattern = "(*CR)a.b", .input = "a\nb", .matches = true },
        .{ .pattern = "(*CRLF)a.b", .input = "a\r\nb", .matches = false },
        // CRLF mode never lets dot match the CR of a CRLF pair.
        .{ .pattern = "(*CRLF)a..b", .input = "a\r\nb", .matches = false },
        .{ .pattern = "(*CRLF)(?s)a..b", .input = "a\r\nb", .matches = true },
        .{ .pattern = "(*CRLF)a.b", .input = "a\rb", .matches = true },
        .{ .pattern = "(*CRLF)a.b", .input = "a\nb", .matches = true },
        .{ .pattern = "(*ANYCRLF)a.b", .input = "a\rb", .matches = false },
        .{ .pattern = "(*ANYCRLF)a.b", .input = "a\nb", .matches = false },
        .{ .pattern = "(*ANYCRLF)a..b", .input = "a\r\nb", .matches = false },
        .{ .pattern = "(*ANY)a.b", .input = "a\u{2028}b", .matches = false },
        .{ .pattern = "(*ANY)a.b", .input = "a b", .matches = true },
        .{ .pattern = "(*NUL)a.b", .input = "a\x00b", .matches = false },
        .{ .pattern = "(*NUL)a.b", .input = "a\nb", .matches = true },
        .{ .pattern = "(*CRLF)(?s)a.b", .input = "a\rb", .matches = true },
        .{ .pattern = "a\\Nb", .input = "a\nb", .matches = false },
        .{ .pattern = "(*CRLF)a\\Nb", .input = "a\r\nb", .matches = false },
        .{ .pattern = "(*CRLF)a\\Nb", .input = "a\rb", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "newline conventions control multiline anchors" {
    const Case = struct { pattern: []const u8, input: []const u8, span: ?[2]usize };
    for ([_]Case{
        .{ .pattern = "(?m)^b$", .input = "a\nb", .span = .{ 2, 3 } },
        .{ .pattern = "(*CRLF)(?m)^b$", .input = "a\r\nb", .span = .{ 3, 4 } },
        .{ .pattern = "(*CRLF)(?m)^b$", .input = "a\r\nb\r\n", .span = .{ 3, 4 } },
        // `$` matches before the CRLF pair, never between CR and LF.
        .{ .pattern = "(*CRLF)(?m)$", .input = "a\r\nb", .span = .{ 1, 1 } },
        .{ .pattern = "(*ANYCRLF)(?m)^b", .input = "a\rb", .span = .{ 2, 3 } },
        .{ .pattern = "(*ANYCRLF)(?m)^b", .input = "a\nb", .span = .{ 2, 3 } },
        .{ .pattern = "(*ANY)(?m)^b", .input = "a\u{2028}b", .span = .{ 4, 5 } },
        .{ .pattern = "(*ANY)(?m)^b", .input = "a\u{2029}b", .span = .{ 4, 5 } },
        // Default LF convention: CR is ordinary.
        .{ .pattern = "(?m)^b", .input = "a\rb", .span = null },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.span, try findSpan(&value, case.input));
    }
}

test "newline conventions control \\Z" {
    const Case = struct { pattern: []const u8, input: []const u8, span: ?[2]usize };
    for ([_]Case{
        .{ .pattern = "abc\\Z", .input = "abc\n", .span = .{ 0, 3 } },
        .{ .pattern = "abc\\Z", .input = "abc\r\n", .span = null },
        .{ .pattern = "(*CRLF)abc\\Z", .input = "abc\r\n", .span = .{ 0, 3 } },
        .{ .pattern = "(*ANYCRLF)abc\\Z", .input = "abc\r", .span = .{ 0, 3 } },
        .{ .pattern = "(*ANYCRLF)abc\\Z", .input = "abc\n", .span = .{ 0, 3 } },
        .{ .pattern = "(*ANY)abc\\Z", .input = "abc\u{2028}", .span = .{ 0, 3 } },
        .{ .pattern = "(*CR)abc\\Z", .input = "abc\r", .span = .{ 0, 3 } },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.span, try findSpan(&value, case.input));
    }
}

test "BSR settings restrict \\R" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "\\R", .input = "\u{2028}", .matches = true },
        .{ .pattern = "\\R", .input = "\r\n", .matches = true },
        .{ .pattern = "(*BSR_ANYCRLF)\\R", .input = "\u{2028}", .matches = false },
        .{ .pattern = "(*BSR_ANYCRLF)\\R", .input = "\r\n", .matches = true },
        .{ .pattern = "(*BSR_ANYCRLF)(*BSR_UNICODE)\\R", .input = "\u{2028}", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}
