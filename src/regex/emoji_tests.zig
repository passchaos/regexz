const std = @import("std");
const regex = @import("../root.zig");

test "RGI emoji string property matches sequences" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, matches: bool }{
        .{ .pattern = "\\p{RGI_Emoji}", .input = "\u{1f600}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji}", .input = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji}", .input = "\u{1f1e8}\u{1f1f3}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji}", .input = "1\u{fe0f}\u{20e3}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji}", .input = "\u{1f44d}\u{1f3fd}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji}", .input = "A", .matches = false },
        .{ .pattern = "\\p{RGI_Emoji}", .input = "", .matches = false },
        .{ .pattern = "x\\p{RGI_Emoji}y", .input = "x\u{1f600}y", .matches = true },
        .{ .pattern = "x\\p{RGI_Emoji}y", .input = "xy", .matches = false },
        .{ .pattern = "\\p{RGI_Emoji}+", .input = "\u{1f600}\u{1f600}", .matches = true },
        .{ .pattern = "\\p{Basic_Emoji}", .input = "\u{231a}", .matches = true },
        .{ .pattern = "\\p{Basic_Emoji}", .input = "\u{00a9}\u{fe0f}", .matches = true },
        .{ .pattern = "\\p{Basic_Emoji}", .input = "\u{00a9}", .matches = false },
        .{ .pattern = "\\p{Basic_Emoji}", .input = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", .matches = false },
        .{ .pattern = "\\p{Emoji_Keycap_Sequence}", .input = "1\u{fe0f}\u{20e3}", .matches = true },
        .{ .pattern = "\\p{Emoji_Keycap_Sequence}", .input = "1", .matches = false },
        .{ .pattern = "\\p{RGI_Emoji_Flag_Sequence}", .input = "\u{1f1e8}\u{1f1f3}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji_Flag_Sequence}", .input = "\u{1f600}", .matches = false },
        .{ .pattern = "\\p{RGI_Emoji_Tag_Sequence}", .input = "\u{1f3f4}\u{e0067}\u{e0062}\u{e0065}\u{e006e}\u{e0067}\u{e007f}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji_Tag_Sequence}", .input = "\u{1f600}", .matches = false },
        .{ .pattern = "\\p{RGI_Emoji_Modifier_Sequence}", .input = "\u{1f44d}\u{1f3fd}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji_Modifier_Sequence}", .input = "\u{1f44d}", .matches = false },
        .{ .pattern = "\\p{RGI_Emoji_ZWJ_Sequence}", .input = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}", .matches = true },
        .{ .pattern = "\\p{RGI_Emoji_ZWJ_Sequence}", .input = "\u{1f600}", .matches = false },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(allocator, case.input));
    }
}

test "RGI emoji search spans and captures" {
    const allocator = std.testing.allocator;
    const family = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}\u{200d}\u{1f466}";
    const input = "a" ++ family ++ "b";
    var value = try regex.Regex.init(allocator, "(\\p{RGI_Emoji})", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find(input, 0)).?;
    try std.testing.expectEqual(@as(usize, 1), match.start);
    try std.testing.expectEqual(@as(usize, 1 + family.len), match.end);
    try std.testing.expectEqualStrings(family, match.group(input, 0).?);
    try std.testing.expectEqualStrings(family, match.group(input, 1).?);
}

test "RGI emoji property rejects unsupported forms" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedRegexFeature, regex.Regex.init(allocator, "\\P{RGI_Emoji}", .{}));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(allocator, "[\\p{RGI_Emoji}]", .{}));
}
