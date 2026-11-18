const std = @import("std");
const regex = @import("../root.zig");

test "Unicode character names" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, yes: []const []const u8, no: []const []const u8 }{
        .{ .pattern = "\\N{LATIN SMALL LETTER A}", .yes = &.{"a"}, .no = &.{ "b", "A" } },
        .{ .pattern = "\\N{GREEK SMALL LETTER ALPHA}", .yes = &.{"\u{03b1}"}, .no = &.{"a"} },
        .{ .pattern = "\\N{SNOWMAN}", .yes = &.{"\u{2603}"}, .no = &.{"*"} },
        .{ .pattern = "\\N{latin-small-letter-a}", .yes = &.{"a"}, .no = &.{"b"} },
        .{ .pattern = "\\N{LATIN_SMALL_LETTER_A}", .yes = &.{"a"}, .no = &.{"b"} },
        .{ .pattern = "\\N{U+1F600}", .yes = &.{"\u{1f600}"}, .no = &.{"a"} },
        .{ .pattern = "\\N{2}", .yes = &.{"ab"}, .no = &.{ "a\n", "a" } },
        .{ .pattern = "[\\N{SNOWMAN}]", .yes = &.{"\u{2603}"}, .no = &.{"a"} },
        .{ .pattern = "\\N{LATIN SMALL LETTER A}+", .yes = &.{ "aaa", "aa" }, .no = &.{"bbb"} },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        for (case.yes) |input| try std.testing.expect(try value.matches(allocator, input));
        for (case.no) |input| try std.testing.expect(!try value.matches(allocator, input));
    }
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(allocator, "\\N{NOT A REAL NAME}", .{}));
}
