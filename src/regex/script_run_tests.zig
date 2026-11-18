const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "script run accepts shared scripts and Common characters" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "\\s+(*sr:\\S+)", .input = " google.com", .matches = true },
        .{ .pattern = "\\s+(*sr:\\S+)", .input = " g\u{043e}\u{043e}gle.com", .matches = false },
        .{ .pattern = "(*script_run:\\p{Han}\\p{Hiragana})", .input = "\u{6f22}\u{3042}", .matches = true },
        .{ .pattern = "(*sr:\\p{Han}[\\p{Hiragana}\\p{Katakana}])", .input = "\u{6f22}\u{30a2}", .matches = true },
        .{ .pattern = "(*sr:\\p{Han}\\p{Hangul})", .input = "\u{6f22}\u{ac00}", .matches = true },
        .{ .pattern = "(*sr:\\p{Han}\\p{Bopomofo})", .input = "\u{6f22}\u{3105}", .matches = true },
        .{ .pattern = "(*sr:\\p{Hangul}\\p{Bopomofo}\\p{Han})", .input = "\u{ac00}\u{3105}\u{6f22}", .matches = false },
        .{ .pattern = "(*sr:\\p{Hiragana}\\p{Hangul})", .input = "\u{3042}\u{ac00}", .matches = false },
        .{ .pattern = "(*sr:)", .input = "", .matches = true },
        .{ .pattern = "(*sr:x)", .input = "x", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "script run enforces a single decimal digit set" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(*sr:\\p{Nd}\\p{Nd})", .input = "00", .matches = true },
        .{ .pattern = "(*sr:\\p{Nd}\\p{Nd})", .input = "0\u{ff10}", .matches = false },
        .{ .pattern = "(*sr:\\p{Nd}\\p{Nd})", .input = "\u{ff10}\u{ff11}", .matches = true },
        .{ .pattern = "(*sr:\\p{Nd}\\p{Nd})", .input = "\u{0660}\u{0661}", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "script run treats unknown scripts as valid only for short runs" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(*sr:\\x{0378})", .input = "\u{0378}", .matches = true },
        .{ .pattern = "(*sr:\\x{0378}\\x{0378})", .input = "\u{0378}\u{0378}", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "atomic script run does not retry its child" {
    // `\S+` first consumes the whole token, which mixes Latin and Cyrillic.
    // The non-atomic form backtracks to "ab", a valid run, and lets `\S*`
    // consume the rest. The atomic form commits to the invalid first match.
    var value = try regex.Regex.init(gpa, "(*sr:(?:\\S+|\\S))\\S*", .{});
    defer value.deinit();
    try std.testing.expect(try value.matches(gpa, "ab\u{0445}"));
    var atomic = try regex.Regex.init(gpa, "(*asr:(?:\\S+|\\S))\\S*", .{});
    defer atomic.deinit();
    try std.testing.expect(!try atomic.matches(gpa, "ab\u{0445}"));
    var long = try regex.Regex.init(gpa, "(*atomic_script_run:(?:\\S+|\\S))\\S*", .{});
    defer long.deinit();
    try std.testing.expect(!try long.matches(gpa, "ab\u{0445}"));
}

test "script run failures backtrack out of the group" {
    // The first token mixes Latin and Cyrillic. The non-atomic form backtracks
    // to the valid "ab" prefix, while the atomic form skips the whole token
    // and matches the next one.
    var value = try regex.Regex.init(gpa, "\\s+(*sr:\\S+)", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find(" ab\u{0445} ok", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(@as(usize, 3), match.end);
}
