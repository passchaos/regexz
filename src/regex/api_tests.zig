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

test "compile diagnostics report where parsing stopped" {
    try std.testing.expect(regex.diagnose(gpa, "abc", .{}) == null);
    try std.testing.expect(regex.diagnose(gpa, "(?<=a*)b", .{}) == null);

    const cases = [_]struct { pattern: []const u8, offset: usize }{
        .{ .pattern = "(", .offset = 1 },
        .{ .pattern = "a[", .offset = 2 },
        .{ .pattern = "\\", .offset = 1 },
        .{ .pattern = "a**", .offset = 2 },
        .{ .pattern = "(?P<n>a)(?P<n>b)", .offset = 14 },
    };
    for (cases) |case| {
        const diagnostic = regex.diagnose(gpa, case.pattern, .{}).?;
        try std.testing.expectEqual(regex.DiagnosticKind.syntax, diagnostic.kind);
        try std.testing.expectEqual(case.offset, diagnostic.offset);
    }

    // Negated Unicode string properties are rejected as unsupported.
    const unsupported = regex.diagnose(gpa, "\\P{RGI_Emoji}", .{}).?;
    try std.testing.expectEqual(regex.DiagnosticKind.unsupported, unsupported.kind);

    // The pattern-size limit reports the end of the pattern.
    const limited = regex.diagnose(gpa, "abc", .{ .max_pattern_bytes = 2 }).?;
    try std.testing.expectEqual(regex.DiagnosticKind.limit, limited.kind);
    try std.testing.expectEqual(@as(usize, 3), limited.offset);
}

test "escape produces a literal pattern" {
    const escaped = try regex.escape(gpa, "a.b*c (d) [e] {f} | ^$ \\ # & - ~");
    defer gpa.free(escaped);
    try std.testing.expectEqualStrings("a\\.b\\*c \\(d\\) \\[e\\] \\{f\\} \\| \\^\\$ \\\\ \\# \\& \\- \\~", escaped);

    var value = try regex.Regex.init(gpa, escaped, .{});
    defer value.deinit();
    try std.testing.expect(try value.matches(gpa, "a.b*c (d) [e] {f} | ^$ \\ # & - ~"));
    try std.testing.expect(!try value.matches(gpa, "axb*c (d) [e] {f} | ^$ \\ # & - ~"));

    // Non-ASCII bytes pass through unchanged.
    const unicode = try regex.escape(gpa, "你好.世界");
    defer gpa.free(unicode);
    var han = try regex.Regex.init(gpa, unicode, .{});
    defer han.deinit();
    try std.testing.expect(try han.matches(gpa, "你好.世界"));
}

test "splitn and replacen honor their limits" {
    var value = try regex.Regex.init(gpa, ",", .{});
    defer value.deinit();

    const all = try value.split(gpa, "a,b,c");
    defer gpa.free(all);
    try std.testing.expectEqual(@as(usize, 3), all.len);

    const two = try value.splitn(gpa, "a,b,c", 2);
    defer gpa.free(two);
    try std.testing.expectEqual(@as(usize, 2), two.len);
    try std.testing.expectEqualStrings("a", two[0]);
    try std.testing.expectEqualStrings("b,c", two[1]);

    const one = try value.splitn(gpa, "a,b,c", 1);
    defer gpa.free(one);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("a,b,c", one[0]);

    const none = try value.splitn(gpa, "a,b,c", 0);
    defer gpa.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);

    const replaced = try value.replacen(gpa, "a,b,c", 1, "-");
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("a-b,c", replaced);

    const replaced_none = try value.replacen(gpa, "a,b,c", 0, "-");
    defer gpa.free(replaced_none);
    try std.testing.expectEqualStrings("a,b,c", replaced_none);

    const replaced_all = try value.replacen(gpa, "a,b,c", 5, "-");
    defer gpa.free(replaced_all);
    try std.testing.expectEqualStrings("a-b-c", replaced_all);
}

test "expand a replacement template for one match" {
    var value = try regex.Regex.init(gpa, "(?<word>\\w+)@(\\w+)\\.com", .{});
    defer value.deinit();
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const input = "mail me at user@example.com!";
    const match = (try value.find(gpa, input, &captures)).?;
    const expanded = try value.expandMatch(gpa, input, match, "[$1|$<2>|$&|$`|$']");
    defer gpa.free(expanded);
    try std.testing.expectEqualStrings("[user|example|user@example.com|mail me at |!]", expanded);
    try std.testing.expectError(error.InvalidRegex, value.expandMatch(gpa, input, match, "$9"));
}
