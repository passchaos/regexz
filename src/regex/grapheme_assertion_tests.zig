const std = @import("std");
const regex = @import("../root.zig");

test "grapheme cluster boundary assertions" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, matches: bool }{
        .{ .pattern = "\\b{gcb}", .input = "", .matches = true },
        .{ .pattern = "\\B{gcb}", .input = "", .matches = false },
        .{ .pattern = "\\b{gcb}a", .input = "a", .matches = true },
        .{ .pattern = "a\\b{gcb}", .input = "a", .matches = true },
        .{ .pattern = "a\\b{gcb}\u{0301}", .input = "a\u{0301}", .matches = false },
        .{ .pattern = "a\u{0301}\\b{gcb}", .input = "a\u{0301}", .matches = true },
        .{ .pattern = "a\\B{gcb}\u{0301}", .input = "a\u{0301}", .matches = true },
        .{ .pattern = "\u{1f468}\\B{gcb}\u{200d}", .input = "\u{1f468}\u{200d}", .matches = true },
        .{ .pattern = "\u{1f1e8}\\B{gcb}\u{1f1f3}", .input = "\u{1f1e8}\u{1f1f3}", .matches = true },
        .{ .pattern = "\\b{g}a", .input = "a", .matches = true },
        .{ .pattern = "\\b{2}word\\b{2}", .input = "word", .matches = true },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(allocator, case.input));
    }
}

test "grapheme boundary rejects unsupported boundary kinds" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedRegexFeature, regex.Regex.init(allocator, "\\b{wb}", .{}));
    try std.testing.expectError(error.UnsupportedRegexFeature, regex.Regex.init(allocator, "\\b{sb}", .{}));
}
