const std = @import("std");
const regex = @import("../root.zig");

test "regex set reports all matching patterns" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "\\d+", "[a-z]+", "^foo", "(?i)hello" };
    var set = try regex.RegexSet.init(allocator, &patterns, .{});
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 4), set.count());
    var matched: [4]bool = undefined;
    try set.matches("xx foo 123 HELLO", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, &matched);
    try std.testing.expect(!try set.isMatch("xx foo 123 HELLO", 2));
    try std.testing.expect(try set.isMatch("xx foo 123 HELLO", 3));
    try std.testing.expect(!try set.isMatch("anything", 99));
}

test "regex set supports extended patterns and match indices" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "(a)\\1", "\\p{Greek}+", "missing" };
    var set = try regex.RegexSet.init(allocator, &patterns, .{});
    defer set.deinit();
    var matched: [3]bool = undefined;
    try set.matches("xx aa \u{0394}\u{03c3}", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, &matched);
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(allocator);
    try set.matchIndices("xx aa \u{0394}\u{03c3}", &indices);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, indices.items);
}

test "regex set handles an empty pattern list" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{};
    var set = try regex.RegexSet.init(allocator, &patterns, .{});
    defer set.deinit();
    try std.testing.expectEqual(@as(usize, 0), set.count());
    var matched: [0]bool = .{};
    try set.matches("anything", &matched);
}

test "regex set reports compile errors without leaking" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "a", "(" };
    const result = regex.RegexSet.init(allocator, &patterns, .{});
    if (result) |value| {
        var set = value;
        set.deinit();
        return error.ExpectedCompileFailure;
    } else |_| {}
}

test "regex set DFA agrees with per-pattern search" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{
        "a",        "ab",         "a|b",         "a*",        "a+",
        "a?",       ".*",         "[a-z]+",      "\\d+",      "\\p{L}+",
        "(a)(b)?",  "(?:ab|cd)+", "a.*b",        "(?i)hello", "\\bword\\b",
        "^foo",     "(a)\\1",     "\\p{Greek}+", "[^a]+",     "a{2,4}",
        "(ab|a)*c", "x?y?z?",     "\\s+",        "\\w+@\\w+", ".*?",
    };
    const inputs = [_][]const u8{
        "",        "a",                        "b",         "ab",          "abc",
        "aaa",     "aab",                      "xyz",       "hello HELLO", "word wordy",
        "123",     "\u{03b1}\u{03b2}\u{03b3}", "caf\u{e9}", "a b c",       "\n\t",
        "foo bar", "xx@yy",                    "cdcdab",    "aaab",        "zzz",
    };
    var set = try regex.RegexSet.init(allocator, &patterns, .{});
    defer set.deinit();
    try std.testing.expect(set.dfa != null);
    try std.testing.expect(set.dfa.?.covers(0));

    var expected: [patterns.len]bool = undefined;
    for (inputs) |input| {
        var matched: [patterns.len]bool = undefined;
        try set.matches(input, &matched);
        for (patterns, 0..) |pattern, index| {
            var value = try regex.Regex.init(allocator, pattern, .{});
            defer value.deinit();
            var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
            defer workspace.deinit();
            expected[index] = (try workspace.find(input, 0)) != null;
        }
        try std.testing.expectEqualSlices(bool, expected[0..], matched[0..]);
    }
}

test "regex set DFA agrees with per-pattern search on random patterns" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed_2026);
    const random = prng.random();
    const atoms = [_][]const u8{
        "a",   "b",   "c",      "1",   " ",       ".",     "[ab]",       "[^a]", "\\d",
        "\\w", "\\s", "\\p{L}", "(a)", "(?:b|c)", "(a|b)", "\\p{Greek}",
    };
    const quantifiers = [_][]const u8{ "", "", "", "*", "+", "?", "*?", "+?", "{0,2}", "{1,3}" };
    const alphabet = [_][]const u8{ "a", "b", "c", "1", " ", "A", "\u{03b1}", "\n" };

    var round: usize = 0;
    while (round < 100) : (round += 1) {
        var pattern_buf: [4][256]u8 = undefined;
        var pattern_lengths: [4]usize = undefined;
        const pattern_count = random.intRangeAtMost(usize, 1, 4);
        var patterns: [4][]const u8 = undefined;
        for (0..pattern_count) |index| {
            var length: usize = 0;
            const pieces = random.intRangeAtMost(usize, 1, 3);
            for (0..pieces) |_| {
                const atom = atoms[random.uintLessThan(usize, atoms.len)];
                const quantifier = quantifiers[random.uintLessThan(usize, quantifiers.len)];
                const written = std.fmt.bufPrint(pattern_buf[index][length..], "{s}{s}", .{ atom, quantifier }) catch unreachable;
                length += written.len;
            }
            pattern_lengths[index] = length;
            patterns[index] = pattern_buf[index][0..length];
        }
        var set = try regex.RegexSet.init(allocator, patterns[0..pattern_count], .{});
        defer set.deinit();
        try std.testing.expect(set.dfa != null);
        var expected_workspaces: [4]regex.ReplaceWorkspace = undefined;
        var expected_count: usize = 0;
        defer for (expected_workspaces[0..expected_count]) |*workspace| workspace.deinit();
        for (set.programs, 0..) |program, index| {
            expected_workspaces[index] = try regex.ReplaceWorkspace.init(allocator, program, .{});
            expected_count += 1;
        }
        var input_buf: [32]u8 = undefined;
        for (0..10) |_| {
            var input_len: usize = 0;
            const input_pieces = random.intRangeAtMost(usize, 0, 10);
            for (0..input_pieces) |_| {
                const piece = alphabet[random.uintLessThan(usize, alphabet.len)];
                @memcpy(input_buf[input_len..][0..piece.len], piece);
                input_len += piece.len;
            }
            const input = input_buf[0..input_len];
            var matched: [4]bool = undefined;
            try set.matches(input, matched[0..pattern_count]);
            for (0..pattern_count) |index| {
                const expected = (try expected_workspaces[index].find(input, 0)) != null;
                try std.testing.expectEqual(expected, matched[index]);
            }
        }
    }
}

test "regex set handles empty patterns and empty input" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "", "a*", "a+" };
    var set = try regex.RegexSet.init(allocator, &patterns, .{});
    defer set.deinit();
    var matched: [3]bool = undefined;
    try set.matches("", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, &matched);
    try set.matches("b", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false }, &matched);
    try set.matches("aaa", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &matched);
}

test "regex set falls back on invalid UTF-8" {
    const allocator = std.testing.allocator;
    const patterns = [_][]const u8{ "a", ".*", "" };
    var set = try regex.RegexSet.init(allocator, &patterns, .{});
    defer set.deinit();
    var matched: [3]bool = undefined;
    try set.matches("\xff", &matched);
    try std.testing.expectEqualSlices(bool, &.{ false, true, true }, &matched);
    try std.testing.expect(!set.dfa_failed);
    // The DFA stays available for the next, valid input.
    try set.matches("abc", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &matched);
}
