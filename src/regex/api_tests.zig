const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "partial match and capture-aware find" {
    var value = try regex.Regex.init(gpa, "b", .{});
    defer value.deinit();
    try std.testing.expect(try value.isMatch(gpa, "abc"));
    try std.testing.expect(!try value.isMatch(gpa, "ac"));

    var groups = try regex.Regex.init(gpa, "(a)(b)?", .{});
    defer groups.deinit();
    var captures = try regex.Captures.init(gpa, groups.program);
    defer captures.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), captures.count());
    const match = (try groups.find(gpa, "xa", &captures)).?;
    try std.testing.expectEqual(@as(usize, 1), match.start);
    try std.testing.expectEqual(@as(usize, 2), match.end);
    try std.testing.expectEqualStrings("a", match.group("xa", 1).?);
    try std.testing.expectEqualStrings("a", captures.group("xa", 1).?);
    try std.testing.expect(match.group("xa", 2) == null);
    try std.testing.expect(match.group("xa", 0) != null);
}

test "named groups are queryable and usable in find" {
    var value = try regex.Regex.init(gpa, "(?P<year>\\d{4})-(?P<month>\\d{2})", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(?u16, 1), value.groupIndex("year"));
    try std.testing.expectEqual(@as(?u16, 2), value.groupIndex("month"));
    try std.testing.expectEqualStrings("year", value.groupName(1).?);
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const match = (try value.find(gpa, "x2026-11y", &captures)).?;
    try std.testing.expectEqualStrings("2026", match.group("x2026-11y", 1).?);
    try std.testing.expectEqualStrings("11", match.group("x2026-11y", 2).?);
    try std.testing.expectEqualStrings("2026-11", match.group("x2026-11y", 0).?);
}

test "extended patterns use the same find and capture API" {
    var value = try regex.Regex.init(gpa, "(?P<x>a)(?=b)", .{});
    defer value.deinit();
    try std.testing.expect(try value.isMatch(gpa, "ab"));
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const match = (try value.find(gpa, "zab", &captures)).?;
    try std.testing.expectEqual(@as(usize, 1), match.start);
    try std.testing.expectEqual(@as(usize, 2), match.end);
    try std.testing.expectEqualStrings("a", match.group("zab", 1).?);
}

test "findAll iterates non-overlapping matches" {
    var value = try regex.Regex.init(gpa, "\\d+", .{});
    defer value.deinit();
    var iterator = try value.findAll(gpa, "a1b22c333");
    defer iterator.deinit();
    const expected = [_][2]usize{ .{ 1, 2 }, .{ 3, 5 }, .{ 6, 9 } };
    var index: usize = 0;
    while (try iterator.next()) |match| : (index += 1) {
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqual(expected[index][0], match.start);
        try std.testing.expectEqual(expected[index][1], match.end);
    }
    try std.testing.expectEqual(expected.len, index);
}

test "split returns slices of the input" {
    var value = try regex.Regex.init(gpa, ",", .{});
    defer value.deinit();
    const parts = try value.split(gpa, "a,b,,c");
    defer gpa.free(parts);
    try std.testing.expectEqual(@as(usize, 4), parts.len);
    try std.testing.expectEqualStrings("a", parts[0]);
    try std.testing.expectEqualStrings("b", parts[1]);
    try std.testing.expectEqualStrings("", parts[2]);
    try std.testing.expectEqualStrings("c", parts[3]);

    var spaces = try regex.Regex.init(gpa, "\\s+", .{});
    defer spaces.deinit();
    const words = try spaces.split(gpa, "a  b\tc");
    defer gpa.free(words);
    try std.testing.expectEqual(@as(usize, 3), words.len);
    try std.testing.expectEqualStrings("b", words[1]);
}

test "replacement supports dollar syntax and named groups" {
    var numbered = try regex.Regex.init(gpa, "(\\w+)\\s+(\\w+)", .{});
    defer numbered.deinit();
    const swapped = try numbered.replaceAll(gpa, "hello world", "$2 $1");
    defer gpa.free(swapped);
    try std.testing.expectEqualStrings("world hello", swapped);

    var named = try regex.Regex.init(gpa, "(?P<first>\\w+)\\s+(?P<last>\\w+)", .{});
    defer named.deinit();
    const named_out = try named.replaceAll(gpa, "hello world", "${last}, ${first}");
    defer gpa.free(named_out);
    try std.testing.expectEqualStrings("world, hello", named_out);

    var whole = try regex.Regex.init(gpa, "a+", .{});
    defer whole.deinit();
    const bracketed = try whole.replaceAll(gpa, "baaac", "[$&] $$");
    defer gpa.free(bracketed);
    try std.testing.expectEqualStrings("b[aaa] $c", bracketed);

    var extended = try regex.Regex.init(gpa, "(?<=a)b", .{});
    defer extended.deinit();
    const replaced = try extended.replaceAll(gpa, "ab", "X");
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("aX", replaced);
}

test "replacement validation rejects unknown groups" {
    var value = try regex.Regex.init(gpa, "(a)(b)", .{});
    defer value.deinit();
    try std.testing.expectError(error.InvalidRegex, regex.validateSubstitutionFor(value.program, "$3"));
    try std.testing.expectError(error.InvalidRegex, regex.validateSubstitutionFor(value.program, "${missing}"));
    try std.testing.expectError(error.InvalidRegex, regex.validateSubstitutionFor(value.program, "\\3"));
    try regex.validateSubstitutionFor(value.program, "$2 ${1} $& $$ $");
}
