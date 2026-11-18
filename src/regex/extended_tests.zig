const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;
const unset = std.math.maxInt(usize);

fn expectFull(pattern: []const u8, input: []const u8, limits: regex.Limits, expected: bool) !void {
    var value = try regex.Regex.init(gpa, pattern, limits);
    defer value.deinit();
    try std.testing.expectEqual(expected, try value.matches(gpa, input));
}

fn expectFind(pattern: []const u8, input: []const u8, limits: regex.Limits, expected: ?struct { start: usize, end: usize }) !void {
    var value = try regex.Regex.init(gpa, pattern, limits);
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
    defer workspace.deinit();
    const found = try workspace.find(input, 0);
    if (expected) |want| {
        const match = found orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(want.start, match.start);
        try std.testing.expectEqual(want.end, match.end);
    } else try std.testing.expect(found == null);
}

test "general lookahead and lookbehind" {
    try expectFull("a(?=b)b", "ab", .{}, true);
    try expectFull("a(?=c)b", "ab", .{}, false);
    try expectFull("a(?!b)b", "ab", .{}, false);
    try expectFull("a(?!c)b", "ab", .{}, true);
    try expectFull("(?=ab)ab", "ab", .{}, true);
    try expectFull("(?!ab)ac", "ac", .{}, true);
    try expectFind("(?<=a)b", "ab", .{}, .{ .start = 1, .end = 2 });
    try expectFind("(?<!a)b", "ab", .{}, null);
    try expectFind("(?<!c)b", "ab", .{}, .{ .start = 1, .end = 2 });
    try expectFind("(?<=a+)b", "aaab", .{}, .{ .start = 3, .end = 4 });
    try expectFind("(?<=ab|b)c", "abc", .{}, .{ .start = 2, .end = 3 });
    try expectFind("(?<!ab)c", "abc", .{}, null);
    try expectFind("(?<!ab)c", "xbc", .{}, .{ .start = 2, .end = 3 });
}

test "numeric and named backreferences" {
    try expectFull("(a)\\1", "aa", .{}, true);
    try expectFull("(a)\\1", "ab", .{}, false);
    try expectFull("(a|b)\\1", "bb", .{}, true);
    try expectFull("(a)?\\1", "aa", .{}, true);
    try expectFull("(a)?\\1", "a", .{}, false);
    try expectFull("(?P<x>a)\\k<x>", "aa", .{}, true);
    try expectFull("(?P<x>a)(?P=x)", "aa", .{}, true);
    try expectFull("(?<x>a)\\k'x'", "aa", .{}, true);
    try expectFull("(?<x>a)\\k{x}", "aa", .{}, true);
    try expectFull("(?<x>a)\\g{x}", "aa", .{}, true);
}

test "atomic groups and possessive quantifiers" {
    try expectFull("(?>a|ab)b", "abb", .{}, false);
    try expectFull("(a|ab)b", "abb", .{}, true);
    try expectFull("(?>ab|a)b", "abb", .{}, true);
    try expectFull("a++a", "aaa", .{}, false);
    try expectFull("a+a", "aaa", .{}, true);
    try expectFull("a*+a", "aaa", .{}, false);
    try expectFull("a*+b", "aaab", .{}, true);
    try expectFull("a{1,3}+a", "aaaa", .{}, true);
    try expectFull("a{1,3}+a", "aaa", .{}, false);
}

test "conditionals" {
    try expectFull("(a)?(?(1)b|c)", "ab", .{}, true);
    try expectFull("(a)?(?(1)b|c)", "c", .{}, true);
    try expectFull("(a)?(?(1)b|c)", "ac", .{}, false);
    try expectFull("(?P<x>a)?(?(<x>)b|c)", "ab", .{}, true);
    try expectFull("(?P<x>a)?(?(<x>)b|c)", "c", .{}, true);
    try expectFull("(?P<x>a)?(?('x')b|c)", "ab", .{}, true);
}

test "named captures expose indices and slots" {
    var value = try regex.Regex.init(gpa, "(?P<year>\\d{4})-(?P<month>\\d{2})", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(?u16, 1), value.program.groupIndex("year"));
    try std.testing.expectEqual(@as(?u16, 2), value.program.groupIndex("month"));
    try std.testing.expectEqualStrings("year", value.program.groupName(1).?);
    try std.testing.expectEqualStrings("month", value.program.groupName(2).?);
    try std.testing.expectEqual(@as(?u16, null), value.program.groupIndex("missing"));
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find("x2026-11y", 0)).?;
    try std.testing.expectEqual(@as(usize, 1), match.start);
    try std.testing.expectEqual(@as(usize, 8), match.end);
    try std.testing.expectEqual(@as(usize, 1), match.slots[2]);
    try std.testing.expectEqual(@as(usize, 5), match.slots[3]);
    try std.testing.expectEqual(@as(usize, 6), match.slots[4]);
    try std.testing.expectEqual(@as(usize, 8), match.slots[5]);
}

test "extended mode ignores whitespace and comments outside classes" {
    try expectFull("(?x) a b # comment", "ab", .{}, true);
    try expectFull("(?x)[a b]+", "a b", .{}, true);
    try expectFull("(?x)a\\ b", "a b", .{}, true);
    try expectFull("(?x) a {2} ", "aa", .{}, true);
    try expectFull("(?x) a # comment\n b", "ab", .{}, true);
}

test "UCP classes and property aliases" {
    const ucp = regex.Limits{ .unicode_perl_classes = true };
    try expectFull("\\d+", "٣", ucp, true);
    try expectFull("\\d+", "٣", .{}, false);
    try expectFull("\\w+", "é", ucp, true);
    try expectFull("\\w+", "é", .{}, false);
    try expectFull("\\bé\\b", "é", ucp, true);
    try expectFull("\\bΔσ\\b", "Δσ", ucp, true);
    try expectFull("\\p{Script=Greek}+", "Δσ", .{}, true);
    try expectFull("\\p{sc=Greek}+", "Δσ", .{}, true);
    try expectFull("\\p{IsGreek}+", "Δσ", .{}, true);
    try expectFull("\\p{gc=Nd}+", "٣", .{}, true);
    try expectFull("\\p{General_Category=Nd}+", "٣", .{}, true);
}

test "end of text and start of match assertions" {
    try expectFull("abc\\Z", "abc", .{}, true);
    try expectFind("abc\\Z", "abc\n", .{}, .{ .start = 0, .end = 3 });
    // Under the default LF convention, CR is an ordinary character, so \Z
    // does not match before a CRLF pair.
    try expectFind("abc\\Z", "abc\r\n", .{}, null);
    try expectFind("(*CRLF)abc\\Z", "abc\r\n", .{}, .{ .start = 0, .end = 3 });
    try expectFull("\\Gabc", "abc", .{}, true);
    try expectFind("\\Gabc", "xabc", .{}, null);
    var value = try regex.Regex.init(gpa, "\\Gabc", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find("xabc", 1)).?;
    try std.testing.expectEqual(@as(usize, 1), match.start);
    try std.testing.expectEqual(@as(usize, 4), match.end);
}

test "lookaround captures are visible only for positive assertions" {
    var positive = try regex.Regex.init(gpa, "(?=(a))a", .{});
    defer positive.deinit();
    var positive_ws = try regex.ReplaceWorkspace.init(gpa, positive.program, .{});
    defer positive_ws.deinit();
    const positive_match = (try positive_ws.find("a", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), positive_match.slots[2]);
    try std.testing.expectEqual(@as(usize, 1), positive_match.slots[3]);

    var negative = try regex.Regex.init(gpa, "(?!(a))b", .{});
    defer negative.deinit();
    var negative_ws = try regex.ReplaceWorkspace.init(gpa, negative.program, .{});
    defer negative_ws.deinit();
    const negative_match = (try negative_ws.find("b", 0)).?;
    try std.testing.expectEqual(unset, negative_match.slots[2]);
    try std.testing.expectEqual(unset, negative_match.slots[3]);
}

test "extended execution obeys step and depth budgets" {
    // A multi-character lookahead forces the general backtracking VM; a
    // single-set lookahead stays on the linear DFA path.
    var value = try regex.Regex.init(gpa, "a(?=bc)bc", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{ .max_execution_steps = 1 });
    defer workspace.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, workspace.find("abc", 0));

    var nested = try regex.Regex.init(gpa, "(?=(?=(?=(?=a))))a", .{ .max_recursion_depth = 2 });
    defer nested.deinit();
    var nested_ws = try regex.ReplaceWorkspace.init(gpa, nested.program, nested.limits);
    defer nested_ws.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, nested_ws.find("a", 0));
}

test "match start reset and PCRE character escapes" {
    try expectFind("a\\Kb", "ab", .{}, .{ .start = 1, .end = 2 });
    try expectFull("\\R", "\n", .{}, true);
    try expectFull("\\R", "\r\n", .{}, true);
    try expectFull("\\R", "\r", .{}, true);
    try expectFull("\\R", "\u{2028}", .{}, true);
    try expectFull("a\\Rb", "a\r\nb", .{}, true);
    try expectFull("\\N", "a", .{}, true);
    try expectFull("\\N", "\n", .{}, false);
    try expectFull("\\h+", " \t\u{00A0}", .{}, true);
    try expectFull("\\h", "\n", .{}, false);
    try expectFull("\\H", "\n", .{}, true);
    try expectFull("\\H", " ", .{}, false);
}

test "recursion and subroutine calls" {
    try expectFull("\\((?:[^()]|(?R))*\\)", "()", .{}, true);
    try expectFull("\\((?:[^()]|(?R))*\\)", "(a)", .{}, true);
    try expectFull("\\((?:[^()]|(?R))*\\)", "((a))", .{}, true);
    try expectFull("\\((?:[^()]|(?R))*\\)", "(()())", .{}, true);
    try expectFull("\\((?:[^()]|(?R))*\\)", "((()))", .{}, true);
    try expectFull("\\((?:[^()]|(?R))*\\)", "(", .{}, false);
    try expectFull("\\((?:[^()]|(?R))*\\)", ")", .{}, false);
    try expectFull("\\((?:[^()]|(?R))*\\)", "(a", .{}, false);
    try expectFull("\\((?:[^()]|(?R))*\\)", "a)", .{}, false);
    try expectFull("\\((?:[^()]|(?R))*\\)", "((a)", .{}, false);

    try expectFull("(ab)(?1)", "abab", .{}, true);
    try expectFull("(ab)(?1)", "ab", .{}, false);
    try expectFull("(a(?1)?b)", "ab", .{}, true);
    try expectFull("(a(?1)?b)", "aabb", .{}, true);
    try expectFull("(a(?1)?b)", "aaabbb", .{}, true);
    try expectFull("(a(?1)?b)", "aab", .{}, false);
    try expectFull("(?<x>a(?&x)?b)", "aaabbb", .{}, true);
    try expectFull("(?<x>a(?&x)?b)", "aab", .{}, false);
    try expectFull("(?P<x>a(?P>x)?b)", "aabb", .{}, true);
    try expectFull("(?<x>a)(?&x)", "aa", .{}, true);
}

test "recursion obeys the depth limit" {
    var value = try regex.Regex.init(gpa, "(a(?1)?b)", .{ .max_recursion_depth = 2 });
    defer value.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, value.matches(gpa, "aaabbb"));
}

test "branch reset shares capture numbers across alternatives" {
    try expectFull("(?|(a)|(b))\\1", "aa", .{}, true);
    try expectFull("(?|(a)|(b))\\1", "bb", .{}, true);
    try expectFull("(?|(a)|(b))\\1", "ab", .{}, false);
    var value = try regex.Regex.init(gpa, "(?|(a)(b)|(c))", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(u16, 2), value.program.capture_count);
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const first = (try value.find(gpa, "ab", &captures)).?;
    try std.testing.expectEqualStrings("a", first.group("ab", 1).?);
    try std.testing.expectEqualStrings("b", first.group("ab", 2).?);
    const second = (try value.find(gpa, "c", &captures)).?;
    try std.testing.expectEqualStrings("c", second.group("c", 1).?);
    try std.testing.expect(second.group("c", 2) == null);
}

test "PCRE special properties and g subroutine syntax" {
    try expectFull("(?<x>ab)\\g<x>", "abab", .{}, true);
    try expectFull("\\p{Xan}+", "a1", .{}, true);
    try expectFull("\\p{Xan}+", "!", .{}, false);
    try expectFull("\\p{Xwd}+", "_é", .{}, true);
    try expectFull("\\p{Xps}+", " \t", .{}, true);
    try expectFull("\\p{Xsp}+", " ", .{}, true);
}

test "conditional assertions and DEFINE blocks" {
    try expectFull("(?(?=a)ab|cd)", "ab", .{}, true);
    try expectFull("(?(?=a)ab|cd)", "cd", .{}, true);
    try expectFull("(?(?=a)ab|cd)", "ad", .{}, false);
    try expectFull("(?(?=a)ab|cd)", "cb", .{}, false);
    try expectFull("(?(?!a)cd|ab)", "cd", .{}, true);
    try expectFull("(?(?!a)cd|ab)", "ab", .{}, true);
    try expectFind("(?(?<=a)b|c)", "ab", .{}, .{ .start = 1, .end = 2 });
    try expectFind("(?(?<=a)b|c)", "xc", .{}, .{ .start = 1, .end = 2 });
    try expectFind("(?(?<!a)b|c)", "ab", .{}, null);
    try expectFind("(?(?<!a)b|c)", "xb", .{}, .{ .start = 1, .end = 2 });
    try expectFull("(?(DEFINE)(?<byte>\\d{1,3}))(?&byte)", "123", .{}, true);
    try expectFull("(?(DEFINE)(?<byte>\\d{1,3}))(?&byte)", "1234", .{}, false);
    try expectFull("(?(DEFINE)(?<pair>\\((?:[^()]|(?&pair))*\\)))(?&pair)", "((a))", .{}, true);
}

test "leftmost-longest mode" {
    const longest = regex.Limits{ .longest = true };
    try expectFind("(a|ab)c?", "abc", .{}, .{ .start = 0, .end = 1 });
    try expectFind("(a|ab)c?", "abc", longest, .{ .start = 0, .end = 3 });
    try expectFind("\\d{2}|\\d+", "1234", .{}, .{ .start = 0, .end = 2 });
    try expectFind("\\d{2}|\\d+", "1234", longest, .{ .start = 0, .end = 4 });
    try expectFind("(?:(a)|(ab))(?!d)", "ab", .{}, .{ .start = 0, .end = 1 });
    try expectFind("(?:(a)|(ab))(?!d)", "ab", longest, .{ .start = 0, .end = 2 });

    var value = try regex.Regex.init(gpa, "(?:(a)|(ab))(?!d)", longest);
    defer value.deinit();
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const match = (try value.find(gpa, "ab", &captures)).?;
    try std.testing.expect(match.group("ab", 1) == null);
    try std.testing.expectEqualStrings("ab", match.group("ab", 2).?);

    var replace = try regex.Regex.init(gpa, "\\d{2}|\\d+", longest);
    defer replace.deinit();
    const output = try replace.replaceAll(gpa, "1234", "X");
    defer gpa.free(output);
    try std.testing.expectEqualStrings("X", output);
}

test "duplicate group names with (?J)" {
    try expectFull("(?J)(?<x>a)|(?<x>b)", "a", .{}, true);
    try expectFull("(?J)(?<x>a)|(?<x>b)", "b", .{}, true);
    var value = try regex.Regex.init(gpa, "(?J)(?<x>a)(?<x>b)", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(?u16, 1), value.groupIndex("x"));
    try std.testing.expectEqual(@as(u16, 2), value.program.capture_count);
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?<x>a)(?<x>b)", .{}));
}

test "relative subroutine calls" {
    // Relative references count from the most recently started group.
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(ab)(?+1)", .{}));
    try expectFull("(ab)(cd(?-1))", "abcdab", .{}, false);
    try expectFull("(a)(b(?-1))", "aba", .{}, false);
    try expectFull("(a(?+1)b)(c)", "acbc", .{}, true);
    try expectFull("(a(?-1)?b)", "aabb", .{}, true);
    try expectFull("(a(?-1)?b)", "aab", .{}, false);
    try expectFull("(a)(?-1)", "aa", .{}, true);
    try expectFull("(?+1)(a)", "aa", .{}, true);
}

test "recursion condition (?(R))" {
    try expectFull("(a(?1)?(?(R)b|c))", "ac", .{}, true);
    try expectFull("(a(?1)?(?(R)b|c))", "aabc", .{}, true);
    try expectFull("(a(?1)?(?(R)b|c))", "aab", .{}, false);
}

test "extended grapheme clusters" {
    try expectFull("\\X", "a", .{}, true);
    try expectFull("\\X", "é", .{}, true);
    try expectFull("\\X", "e\u{0301}", .{}, true);
    try expectFull("\\X", "e\u{0301}\u{0302}", .{}, true);
    try expectFull("\\X", "👨‍👩‍👧‍👦", .{}, true);
    try expectFull("\\X", "🇨🇳", .{}, true);
    try expectFull("\\X\\X", "🇨🇳🇺🇸", .{}, true);
    try expectFull("\\X", "🇨🇳🇺🇸", .{}, false);
    try expectFull("\\X", "\r\n", .{}, true);
    try expectFull("\\X\\X", "\r\n\r\n", .{}, true);
    try expectFull("\\X", "각", .{}, true);
    try expectFull("\\X", "각", .{}, true);
    try expectFull("\\X", "क्ष", .{}, true);
    try expectFull("\\X\\X", "क्ष", .{}, false);
    try expectFull("\\X", "👩‍👩", .{}, true);
    try expectFull("\\X\\X", "👩x", .{}, true);
    try expectFull("\\X", "\u{0600}1", .{}, true);
    try expectFind("\\X", "e\u{0301}x", .{}, .{ .start = 0, .end = 3 });
}

test "Unicode binary properties and PCRE2 special properties" {
    try expectFull("\\p{Alphabetic}+", "aé猫", .{}, true);
    try expectFull("\\p{Alphabetic}+", "1", .{}, false);
    try expectFull("\\p{White_Space}+", " \t\u{00A0}", .{}, true);
    try expectFull("\\p{Emoji}", "😀", .{}, true);
    try expectFull("\\p{Extended_Pictographic}", "😀", .{}, true);
    try expectFull("\\p{Lowercase}+", "aé", .{}, true);
    try expectFull("\\p{Uppercase}", "A", .{}, true);
    try expectFull("\\p{Hex_Digit}+", "F09", .{}, true);
    try expectFull("\\p{ID_Start}\\p{ID_Continue}*", "a1", .{}, true);
    try expectFull("\\p{Alpha}+", "a", .{}, true);
    try expectFull("\\p{Lower}", "a", .{}, true);
    try expectFull("\\p{WSpace}", " ", .{}, true);
    try expectFull("\\p{Xuc}", "$", .{}, true);
    try expectFull("\\p{Xuc}", "@", .{}, true);
    try expectFull("\\p{Xuc}", "`", .{}, true);
    try expectFull("\\p{Xuc}", "é", .{}, true);
    try expectFull("\\p{Xuc}", "A", .{}, false);
    try expectFull("\\p{Xuc}", "1", .{}, false);
    try expectFull("\\p{Script=Greek}+", "Δσ", .{}, true);
    try expectFull("\\p{gc=Nd}+", "٣", .{}, true);
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "\\p{Script=Alphabetic}", .{}));
}

test "backtracking control verbs" {
    try expectFull("a(*FAIL)|b", "b", .{}, true);
    try expectFull("a(*FAIL)|b", "a", .{}, false);
    try expectFind("a(*ACCEPT)b", "ab", .{}, .{ .start = 0, .end = 1 });
    try expectFull("a(*ACCEPT)b", "a", .{}, true);
    try expectFull("a(*ACCEPT)b", "ab", .{}, false);
    try expectFull("a(*PRUNE)b|ac", "ac", .{}, false);
    try expectFull("(a|ab)(*PRUNE)c", "abc", .{}, false);
    try expectFull("(a|ab)(*PRUNE)c", "ac", .{}, true);
    try expectFind("a(*SKIP)(*FAIL)|b", "ab", .{}, .{ .start = 1, .end = 2 });
    try expectFind("a(*SKIP)b|aab", "aab", .{}, .{ .start = 1, .end = 3 });
    try expectFind("a(*COMMIT)b|ac", "ac", .{}, null);
    try expectFull("a(*COMMIT)b|ab", "ab", .{}, true);
    try expectFull("(*UCP)\\d+", "٣", .{}, true);
    try expectFull("(*UTF)(*MARK:x)a", "a", .{}, true);
}

test "Unicode blocks" {
    try expectFull("\\p{InBasic_Latin}+", "ABC", .{}, true);
    try expectFull("\\p{InBasicLatin}+", "ABC", .{}, true);
    try expectFull("\\p{InBasic_Latin}", "é", .{}, false);
    try expectFull("\\p{InGreek_and_Coptic}", "Δ", .{}, true);
    try expectFull("\\p{InGreek}", "Δ", .{}, true);
    try expectFull("\\p{InEmoticons}", "😀", .{}, true);
    try expectFull("\\p{Block=Basic_Latin}", "A", .{}, true);
    try expectFull("\\P{InBasic_Latin}", "é", .{}, true);
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "\\p{InNoSuchBlock}", .{}));
}

test "PCRE2 vertical whitespace opt-in" {
    try expectFull("\\v", "\x0b", .{}, true);
    try expectFull("\\v", "\n", .{}, false);
    const pcre = regex.Limits{ .pcre_vertical_whitespace = true };
    try expectFull("\\v", "\n", pcre, true);
    try expectFull("\\v", "\x0b", pcre, true);
    try expectFull("\\v", "a", pcre, false);
    try expectFull("\\V", "a", pcre, true);
    try expectFull("\\V", "\n", pcre, false);
    try expectFull("[\\v]+", "\n\r", pcre, true);
}

test "literal and prefix search fast paths" {
    try expectFind("abc", "xxabc", .{}, .{ .start = 2, .end = 5 });
    try expectFind("(abc)", "xxabc", .{}, .{ .start = 2, .end = 5 });
    try expectFind("(ab)c", "xxabc", .{}, .{ .start = 2, .end = 5 });
    try expectFind("^abc", "abc", .{}, .{ .start = 0, .end = 3 });
    try expectFind("^abc", "xabc", .{}, null);
    try expectFind("\\bword", "x word", .{}, .{ .start = 2, .end = 6 });
    try expectFind("ab+c", "xxabbbc", .{}, .{ .start = 2, .end = 7 });
    var value = try regex.Regex.init(gpa, "(ab)c", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find("xxabc", 0)).?;
    try std.testing.expectEqualStrings("ab", match.group("xxabc", 1).?);
}

test "extended allocation failures roll back" {
    const Harness = struct {
        fn full(allocator: std.mem.Allocator) !void {
            var value = try regex.Regex.init(allocator, "a(?=b)b", .{});
            defer value.deinit();
            try std.testing.expect(try value.matches(allocator, "ab"));
        }
        fn find(allocator: std.mem.Allocator) !void {
            var value = try regex.Regex.init(allocator, "(?<=a)b", .{});
            defer value.deinit();
            var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
            defer workspace.deinit();
            try std.testing.expect((try workspace.find("ab", 0)) != null);
        }
    };
    try std.testing.checkAllAllocationFailures(gpa, Harness.full, .{});
    try std.testing.checkAllAllocationFailures(gpa, Harness.find, .{});
}

test "numeric and relative backreferences via \\g" {
    // Absolute numbers.
    try expectFull("(a)(b)\\g{2}", "abb", .{}, true);
    try expectFull("(a)(b)\\g{2}", "aba", .{}, false);
    try expectFull("(a)(b)\\g{1}", "aba", .{}, true);
    // Relative numbers are anchored at the most recently opened group.
    try expectFull("(a)(b)\\g{-1}", "abb", .{}, true);
    try expectFull("(a)(b)\\g{-2}", "aba", .{}, true);
    try expectFull("(a)(b)\\g{-2}", "abb", .{}, false);
    try expectFull("(a)\\g{1}", "aa", .{}, true);
    try expectFull("((a)b)\\g{-1}", "aba", .{}, true);
    try expectFull("((a)b)\\g{-2}", "abab", .{}, true);
    // Names keep working through the same brace form.
    try expectFull("(?<x>a)\\g{x}", "aa", .{}, true);
    // Invalid forms fail closed.
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "\\g{-1}", .{}));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(a)\\g{+1}", .{}));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(a)\\g{0}", .{}));
}

test "relative subroutine calls via \\g<...>" {
    // Relative calls are anchored at the enclosing group.
    try expectFull("(a)(b\\g<-1>)", "aba", .{}, true);
    try expectFull("(a)\\g<+1>", "aa", .{}, true);
    try expectFull("\\g<+1>(a)", "aa", .{}, true);
    try expectFull("(a)\\g<1>", "aa", .{}, true);
    // Outside a group a negative relative call has no anchor.
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "\\g<-1>", .{}));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(a)\\g<-1>", .{}));
}

test "backtracking THEN verb" {
    try expectFull("a(*THEN)b", "ab", .{}, true);
    try expectFull("a(*THEN)b", "ac", .{}, false);
    try expectFull("a+(*THEN)b", "aaab", .{}, true);
    try expectFull("a+(*THEN)b", "aaac", .{}, false);

    // Without THEN, `a+` may give back characters so the first alternative
    // succeeds. THEN discards those choices and moves to the next branch.
    try expectFull("(?:a+ab|aab)", "aaab", .{}, true);
    try expectFull("(?:a+(*THEN)ab|aab)", "aaab", .{}, false);
    try expectFull("(?:a+(*THEN)ab|aab)", "aab", .{}, true);
    try expectFind("(?:a+(*THEN)ab|aab)", "aaab", .{}, .{ .start = 1, .end = 4 });
}

test "MARK records the last mark on the successful path" {
    var value = try regex.Regex.init(gpa, "a(*MARK:one)b|a(*MARK:two)c", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 2), value.program.marks.len);
    try std.testing.expectEqualStrings("one", value.program.markName(0).?);
    try std.testing.expectEqualStrings("two", value.program.markName(1).?);

    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expectEqualStrings("one", (try workspace.find("ab", 0)).?.mark.?);
    try std.testing.expectEqualStrings("two", (try workspace.find("ac", 0)).?.mark.?);

    // The failed first alternative must not leak its mark.
    var backtrack = try regex.Regex.init(gpa, "(?:a(*MARK:x)b|a(*MARK:y)c)", .{});
    defer backtrack.deinit();
    var backtrack_ws = try regex.ReplaceWorkspace.init(gpa, backtrack.program, .{});
    defer backtrack_ws.deinit();
    try std.testing.expectEqualStrings("y", (try backtrack_ws.find("ac", 0)).?.mark.?);

    // Marks inside a repeated group report the last iteration.
    var repeated = try regex.Regex.init(gpa, "(?:a(*MARK:x))*b", .{});
    defer repeated.deinit();
    var repeated_ws = try regex.ReplaceWorkspace.init(gpa, repeated.program, .{});
    defer repeated_ws.deinit();
    try std.testing.expectEqualStrings("x", (try repeated_ws.find("aaab", 0)).?.mark.?);

    // Argument verbs other than MARK are accepted but not exposed.
    var skip = try regex.Regex.init(gpa, "a(*SKIP:target)b", .{});
    defer skip.deinit();
    var skip_ws = try regex.ReplaceWorkspace.init(gpa, skip.program, .{});
    defer skip_ws.deinit();
    try std.testing.expect((try skip_ws.find("ab", 0)).?.mark == null);
}

const CalloutState = struct {
    count: usize = 0,
    last_position: usize = 0,
    last_index: u32 = 0,
    last_name: ?[]const u8 = null,
    name_buffer: [64]u8 = undefined,
};

fn resumeCallout(context: ?*anyopaque, callout: regex.CalloutSpec, position: usize) regex.CalloutAction {
    const state: *CalloutState = @ptrCast(@alignCast(context.?));
    state.count += 1;
    state.last_position = position;
    state.last_index = callout.number;
    if (callout.name) |name| {
        // `name` is valid only during the callback; keep a copy for the test.
        const length = @min(name.len, state.name_buffer.len);
        @memcpy(state.name_buffer[0..length], name[0..length]);
        state.last_name = state.name_buffer[0..length];
    } else {
        state.last_name = null;
    }
    return .proceed;
}

fn failCallout(_: ?*anyopaque, _: regex.CalloutSpec, _: usize) regex.CalloutAction {
    return .fail;
}

test "numeric callouts invoke the callback" {
    var state = CalloutState{};
    const limits = regex.Limits{ .callout = .{ .context = &state, .function = resumeCallout } };
    var value = try regex.Regex.init(gpa, "(?C1)a(?C2)b", limits);
    defer value.deinit();
    try std.testing.expect(try value.matches(gpa, "ab"));
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqual(@as(usize, 1), state.last_position);
    try std.testing.expectEqual(@as(u32, 2), state.last_index);

    // Callouts are ignored when no callback is configured.
    try expectFull("(?C1)a(?C2)b", "ab", .{}, true);
    try expectFull("(?C)a", "a", .{}, true);

    // A failing callout abandons the current path.
    const failing = regex.Limits{ .callout = .{ .function = failCallout } };
    try expectFull("(?C1)a|b", "a", failing, false);
    try expectFull("(?C1)a|b", "b", failing, true);

    // String callouts pass their name to the callback.
    var named_state = CalloutState{};
    const named_limits = regex.Limits{ .callout = .{ .context = &named_state, .function = resumeCallout } };
    try expectFull("(?C\"name\")a", "a", named_limits, true);
    try std.testing.expectEqualStrings("name", named_state.last_name.?);
    var braced_state = CalloutState{};
    const braced_limits = regex.Limits{ .callout = .{ .context = &braced_state, .function = resumeCallout } };
    try expectFull("(?C{tag})a", "a", braced_limits, true);
    try std.testing.expectEqualStrings("tag", braced_state.last_name.?);
    var quoted_state = CalloutState{};
    const quoted_limits = regex.Limits{ .callout = .{ .context = &quoted_state, .function = resumeCallout } };
    try expectFull("(?C'tag')a", "a", quoted_limits, true);
    try std.testing.expectEqualStrings("tag", quoted_state.last_name.?);
}

test "recursion conditions with group numbers and names" {
    // `(?(R1))` is true only inside a call to group 1.
    try expectFull("(x(?(R1)z|w)(?1)?y)", "xwy", .{}, true);
    try expectFull("(x(?(R1)z|w)(?1)?y)", "xwxzyy", .{}, true);
    try expectFull("(x(?(R1)z|w)(?1)?y)", "xwxwyy", .{}, false);

    // `(?(R))` is true for any active recursion.
    try expectFull("(x(?(R)z|w)(?1)?y)", "xwxzyy", .{}, true);
    try expectFull("(x(?(R)z|w)(?1)?y)", "xwxwyy", .{}, false);

    // `(?(R0))` tracks a whole-pattern recursion.
    try expectFull("(x(?(R0)z|w)(?0)?y)", "xwxzyy", .{}, true);

    // Named recursion conditions.
    try expectFull("(?<g>x(?(R&g)z|w)(?&g)?y)", "xwxzyy", .{}, true);
    try expectFull("(?<g>x(?(R&g)z|w)(?&g)?y)", "xwxwyy", .{}, false);

    // A specific numeric group other than the current one stays false.
    try expectFull("(a(b(?(R2)z|w)(?2)?y))", "abwbzyy", .{}, true);
    try expectFull("(a(b(?(R2)z|w)(?2)?y))", "abwbwyy", .{}, false);

    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?(R&missing)a|b)", .{}));
}

test "capture reset semantics" {
    // Default PCRE2/Perl behavior keeps the last participating group value.
    var value = try regex.Regex.init(gpa, "(a|(b))+", .{});
    defer value.deinit();
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const kept = (try value.find(gpa, "ba", &captures)).?;
    try std.testing.expectEqualStrings("a", kept.group("ba", 1).?);
    try std.testing.expectEqualStrings("b", kept.group("ba", 2).?);

    // JavaScript-style reset clears groups that did not participate in the
    // current iteration.
    var reset = try regex.Regex.init(gpa, "(a|(b))+", .{ .capture_reset = true });
    defer reset.deinit();
    var reset_captures = try regex.Captures.init(gpa, reset.program);
    defer reset_captures.deinit(gpa);
    const cleared = (try reset.find(gpa, "ba", &reset_captures)).?;
    try std.testing.expectEqualStrings("a", cleared.group("ba", 1).?);
    try std.testing.expect(cleared.group("ba", 2) == null);
    const first_iteration = (try reset.find(gpa, "b", &reset_captures)).?;
    try std.testing.expectEqualStrings("b", first_iteration.group("b", 2).?);

    // Nested groups are cleared per iteration.
    var nested = try regex.Regex.init(gpa, "((a)|(b))+", .{ .capture_reset = true });
    defer nested.deinit();
    var nested_captures = try regex.Captures.init(gpa, nested.program);
    defer nested_captures.deinit(gpa);
    const nested_match = (try nested.find(gpa, "ab", &nested_captures)).?;
    try std.testing.expect(nested_match.group("ab", 2) == null);
    try std.testing.expectEqualStrings("b", nested_match.group("ab", 3).?);

    // Replacement observes the reset value.
    var workspace = try regex.ReplaceWorkspace.init(gpa, reset.program, .{ .capture_reset = true });
    defer workspace.deinit();
    const output = try workspace.replaceAll("ba", "[$2]");
    defer gpa.free(output);
    try std.testing.expectEqualStrings("[]", output);

    // The Pike fallback honors resets too.
    var forced = try regex.ReplaceWorkspace.init(gpa, reset.program, .{ .capture_reset = true, .max_execution_steps = 1, .linear_fallback = true });
    defer forced.deinit();
    const forced_match = (try forced.find("ba", 0)).?;
    try std.testing.expect(forced_match.group("ba", 2) == null);

    // Extended programs share the same compile-time reset instructions.
    var extended = try regex.Regex.init(gpa, "(a|(b)(?=x)|c|x)+", .{ .capture_reset = true });
    defer extended.deinit();
    var extended_captures = try regex.Captures.init(gpa, extended.program);
    defer extended_captures.deinit(gpa);
    const extended_match = (try extended.find(gpa, "bxc", &extended_captures)).?;
    try std.testing.expectEqualStrings("bxc", extended_match.group("bxc", 0).?);
    try std.testing.expect(extended_match.group("bxc", 2) == null);
}

test "unset backreferences can match empty" {
    // PCRE2/Perl default: a backreference to an unset group fails.
    try expectFull("(a)*(a)\\1", "a", .{}, false);
    try expectFull("(?<x>a)?b\\k<x>", "b", .{}, false);
    try expectFull("(?<x>a)?b\\k<x>", "aba", .{}, true);

    // PCRE2_MATCH_UNSET_BACKREF / JavaScript: it matches the empty string.
    try expectFull("(a)*(a)\\1", "a", .{ .unset_backref_empty = true }, true);
    try expectFull("(?<x>a)?b\\k<x>", "b", .{ .unset_backref_empty = true }, true);
    try expectFull("(?<x>a)?b\\k<x>", "aba", .{ .unset_backref_empty = true }, true);
}

test "auto callouts insert callout 255 before consuming atoms" {
    var state = CalloutState{};
    const limits = regex.Limits{ .auto_callout = true, .callout = .{ .context = &state, .function = resumeCallout } };
    var value = try regex.Regex.init(gpa, "abc", limits);
    defer value.deinit();
    try std.testing.expect(value.program.extended);
    try std.testing.expect(try value.matches(gpa, "abc"));
    try std.testing.expectEqual(@as(usize, 3), state.count);
    try std.testing.expectEqual(@as(u32, 255), state.last_index);
    try std.testing.expectEqual(@as(usize, 2), state.last_position);

    var failing = try regex.Regex.init(gpa, "abc", .{ .auto_callout = true, .callout = .{ .function = failCallout } });
    defer failing.deinit();
    try std.testing.expect(!try failing.matches(gpa, "abc"));

    // Without a callback auto-callouts are transparent.
    try expectFull("abc", "abc", .{ .auto_callout = true }, true);
}

test "named SKIP resumes at the mark position" {
    // The mark is at offset 1; the named skip jumps there, so the `b`
    // alternative can still match at 1.
    try expectFind("a(*MARK:m)b(*SKIP:m)xq|b", "abxp", .{}, .{ .start = 1, .end = 2 });
    // Without a name the skip target is the position where (*SKIP) executed.
    try expectFind("a(*MARK:m)b(*SKIP)xq|b", "abxp", .{}, null);
    // A successful named skip keeps the original match.
    try expectFind("ab(*MARK:m)(*SKIP:m)xy|b", "abxy", .{}, .{ .start = 0, .end = 4 });
    // A missing mark behaves like an unnamed skip.
    try expectFind("a(*SKIP:missing)b", "ab", .{}, .{ .start = 0, .end = 2 });
}

test "relative conditional group references" {
    try expectFull("(a)(?(-1)b|c)", "ab", .{}, true);
    try expectFull("(a)(?(-1)b|c)", "ac", .{}, false);
    try expectFull("(a)(?(+1)b|c)(b)", "acb", .{}, true);
    try expectFull("(?(+1)a|b)(a)", "ba", .{}, true);
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?(-1)a|b)", .{}));
}
