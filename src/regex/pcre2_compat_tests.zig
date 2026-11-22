//! PCRE2 10.43-10.45 compatibility details found by the feature audit.
const std = @import("std");
const regex = @import("../root.zig");

const gpa = std.testing.allocator;

fn expectFull(pattern: []const u8, input: []const u8, expected: bool) !void {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    try std.testing.expectEqual(expected, try value.matches(gpa, input));
}

fn expectSpan(pattern: []const u8, input: []const u8, start: usize, end: usize) !void {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const match = (try value.find(gpa, input, &captures)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(start, match.start);
    try std.testing.expectEqual(end, match.end);
}

test "PCRE2 10.43 brace and quantifier forms" {
    try expectFull("a{,3}", "aaa", true);
    try expectFull("a{,3}", "aaaa", false);
    try expectFull("a{,2}?b", "aab", true);
    try expectFull("a{ 2, 3 }", "aaa", true);
    try expectFull("a{2 ,3}", "aaa", true);
    try expectFull("a{2, 3}", "aaa", true);
    try expectFull("a{ 2 }", "aa", true);
    try expectFull("\\x{ 41 }", "A", true);
    try expectFull("\\x{41 }", "A", true);
    try expectFull("\\o{ 101 }", "A", true);
    try expectFull("\\o{101 }", "A", true);
    try expectFull("(a)\\g{ 1 }", "aa", true);
    try expectFull("(?<x>a)\\k{ x }", "aa", true);
    try expectFull("\\N{ U+41 }", "A", true);
    try expectFull("(*UTF8)abc", "abc", true);
}

test "PCRE2 10.45 caseless cased-letter properties" {
    try expectFull("\\p{L&}+", "aB", true);
    try expectFull("\\p{ ^L }+", "123", true);
    try expectFull("(?i)\\p{Lu}+", "abc", true);
    try expectFull("(?i)\\p{Ll}+", "ABC", true);
    try expectFull("(?i)\\p{Lt}+", "abc", true);
    try expectFull("(?i)\\P{Lu}+", "a", false);
    try expectFull("(?i)\\P{Lu}+", "1", true);
}

test "PCRE2 caseless restrict keeps ASCII and non-ASCII separate" {
    try expectFull("(?ir)\u{00e9}", "\u{00c9}", true);
    try expectFull("(?ir)k", "\u{212a}", false);
    try expectFull("(?ir)s", "\u{017f}", false);
    try expectFull("(?ri)(k)\\1", "k\u{212a}", false);
    try expectFull("(?ri)(\u{00e9})\\1", "\u{00e9}\u{00c9}", true);
}

test "PCRE2 10.45 Perl extended character classes" {
    try expectSpan("(?[[a-z]&[^aeiou]])+", "hello", 0, 1);
    try expectSpan("(?[[a-z]-[aeiou]])+", "hello", 0, 1);
    try expectSpan("(?[[a-z]^[aeiou]])+", "hello", 0, 1);
    try expectSpan("(?[![a-z]])+", "12", 0, 2);
    try expectFull("(?[[a-z]|[0-9]])+", "a1", true);
    try expectFull("(?[\\d])", "5", true);
    try expectFull("(?[[:alpha:]])", "a", true);
    // `&` binds tighter than `|`: [a-z] union ([0-9] minus 5).
    try expectSpan("(?[[a-z]|[0-9]&[^5]])+", "a5", 0, 1);
    try expectFull("(?[[a-z]|[0-9]&[^5]])+", "a4", true);
    try expectFull("(?[[a-z]|[0-9]&[^5]])+", "5", false);
    // Caseless folding happens per atom, so this difference is empty.
    var value = try regex.Regex.init(gpa, "(?i)(?[[a-z]-[A-Z]])+", .{});
    defer value.deinit();
    try std.testing.expect(!try value.matches(gpa, "a"));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?[a])", .{}));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?[ ])", .{}));
}

test "class union operator and POSIX word-boundary forms" {
    try expectSpan("[a-z||[0-9]]+", "a|1", 0, 1);
    try expectFull("[a-z||[0-9]]+", "a1", true);
    try expectFull("[[:<:]]abc", "abc", true);
    try expectFull("abc[[:>:]]", "abc", true);
    try expectFull("(*UCP)[[:<:]]\u{00e9}", "\u{00e9}", true);
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "[a[:<:]b]", .{}));
}

test "ACCEPT closes captures, can be quantified, and returns from subroutines" {
    var value = try regex.Regex.init(gpa, "a(*ACCEPT)b", .{});
    defer value.deinit();
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const match = (try value.find(gpa, "ab", &captures)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(@as(usize, 1), match.end);
    try std.testing.expectEqualStrings("a", match.group("ab", 0).?);

    try expectFull("(A(*ACCEPT)??B)C", "ABC", true);
    try expectSpan("(A(*ACCEPT)??B)C", "AC", 0, 1);

    var define = try regex.Regex.init(gpa, "(?(DEFINE)(?<x>a(*ACCEPT)b))(?&x)cd", .{});
    defer define.deinit();
    var define_captures = try regex.Captures.init(gpa, define.program);
    defer define_captures.deinit(gpa);
    const define_match = (try define.find(gpa, "acd", &define_captures)).?;
    try std.testing.expectEqual(@as(usize, 3), define_match.end);
    try std.testing.expect(define_match.group("acd", 1) == null);
}

test "subroutine captures revert on return" {
    var value = try regex.Regex.init(gpa, "(ab)(?1)", .{});
    defer value.deinit();
    var captures = try regex.Captures.init(gpa, value.program);
    defer captures.deinit(gpa);
    const match = (try value.find(gpa, "abab", &captures)).?;
    try std.testing.expectEqualStrings("ab", match.group("abab", 1).?);

    var recursive = try regex.Regex.init(gpa, "(?<x>a(?&x)?b)", .{});
    defer recursive.deinit();
    var recursive_captures = try regex.Captures.init(gpa, recursive.program);
    defer recursive_captures.deinit(gpa);
    const recursive_match = (try recursive.find(gpa, "aabb", &recursive_captures)).?;
    try std.testing.expectEqualStrings("aabb", recursive_match.group("aabb", 1).?);
}

test "NO_START_OPT makes control verbs observe the requested start" {
    // PCRE2's start optimization skips to the literal by default...
    try expectSpan("(*COMMIT)abc", "xyzabc", 3, 6);
    // ...and (*NO_START_OPT) disables that skip, so the commit at position 0
    // rejects the whole search.
    var value = try regex.Regex.init(gpa, "(*NO_START_OPT)(*COMMIT)abc", .{});
    defer value.deinit();
    try std.testing.expect(!try value.isMatch(gpa, "xyzabc"));
}

test "CRLF-mode dot and N exclude both halves of a pair" {
    try expectSpan("(*CRLF).", "\r", 0, 1);
    try expectSpan("(*CRLF).", "\n", 0, 1);
    var value = try regex.Regex.init(gpa, "(*CRLF).", .{});
    defer value.deinit();
    try std.testing.expect(!try value.isMatch(gpa, "\r\n"));
    var not_newline = try regex.Regex.init(gpa, "(*CRLF)\\N", .{});
    defer not_newline.deinit();
    try std.testing.expect(!try not_newline.isMatch(gpa, "\r\n"));
}
