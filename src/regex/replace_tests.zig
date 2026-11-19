const std = @import("std");
const regex = @import("../root.zig");

fn expectReplace(
    pattern: []const u8,
    substitution: []const u8,
    input: []const u8,
    expected: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = try regex.compile(allocator, pattern, .{});
    var workspace = try regex.ReplaceWorkspace.init(allocator, program, .{});
    defer workspace.deinit();
    const actual = try workspace.replaceAll(input, substitution);
    try std.testing.expectEqualStrings(expected, actual);
}

test "regex replacement expands numbered capture groups" {
    try expectReplace(
        "^/service/([^/]+)(/.*)$",
        "\\2/instance/\\1",
        "/service/foo/v1/api",
        "/v1/api/instance/foo",
    );
}

test "chain search drives replacement captures" {
    try expectReplace("(\\w+)@(\\w+)", "\\2@\\1", "ab@cd", "cd@ab");
    try expectReplace("(\\w+)@(\\w+)\\.com", "\\2 <\\1>", "user.name@example.com", "user.example <name>");
    try expectReplace("(\\d+)\\.(\\d+)ms", "\\2.\\1s", "12.34ms", "34.12s");
}

test "regex replacement replaces every non-overlapping match" {
    try expectReplace(
        "one",
        "two",
        "/xxx/one/yyy/one/zzz",
        "/xxx/two/yyy/two/zzz",
    );
}

test "regex replacement honors lazy quantifiers" {
    try expectReplace(
        "^(.*?)one(.*)$",
        "\\1two\\2",
        "/xxx/one/yyy/one/zzz",
        "/xxx/two/yyy/one/zzz",
    );
}

test "regex replacement honors inline case folding" {
    try expectReplace(
        "(?i)/xxx/",
        "/yyy/",
        "/aaa/XxX/bbb",
        "/aaa/yyy/bbb",
    );
}

test "regex replacement supports whole match and escaped backslash" {
    try expectReplace("a+", "[\\0]", "baaac", "b[aaa]c");
    try expectReplace("a", "\\\\", "a", "\\");
}

test "regex replacement leaves unmatched groups empty" {
    try expectReplace("(a)|(b)", "<\\1\\2>", "ab", "<a><b>");
}

test "regex replacement leaves unmatched input unchanged" {
    try expectReplace("zzz", "x", "/a/b/c", "/a/b/c");
}

test "regex replacement rejects unknown capture references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = try regex.compile(allocator, "(a)", .{});
    var workspace = try regex.ReplaceWorkspace.init(allocator, program, .{});
    defer workspace.deinit();
    try std.testing.expectError(
        error.InvalidRegex,
        workspace.replaceAll("a", "\\2"),
    );
}

test "regex replacement handles Unicode captures" {
    try expectReplace(
        "(猫+)",
        "<\\1>",
        "a猫猫b",
        "a<猫猫>b",
    );
}

test "regex replacement enforces the backtracking budget" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = try regex.compile(allocator, "(a|aa)*b", .{});
    var workspace = try regex.ReplaceWorkspace.init(
        allocator,
        program,
        .{ .max_execution_steps = 32, .linear_fallback = false },
    );
    defer workspace.deinit();
    try std.testing.expectError(
        error.RegexLimitExceeded,
        workspace.replaceAll("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "x"),
    );
}

fn wrapCapture(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: []const u8,
    match: regex.Match,
) regex.Error![]u8 {
    _ = context;
    const text = match.group(input, 1) orelse return allocator.dupe(u8, "?");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "[");
    try out.appendSlice(allocator, text);
    try out.appendSlice(allocator, "]");
    return out.toOwnedSlice(allocator);
}

fn boundaryMarker(
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: []const u8,
    match: regex.Match,
) regex.Error![]u8 {
    _ = context;
    _ = input;
    _ = match;
    return allocator.dupe(u8, "|");
}

test "regex callback replacement builds dynamic output" {
    const allocator = std.testing.allocator;
    var value = try regex.Regex.init(allocator, "([a-z]+)", .{});
    defer value.deinit();
    const output = try value.replaceAllWithFn(allocator, "one two", null, wrapCapture);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("[one] [two]", output);
}

test "regex callback replacement handles zero-width matches" {
    const allocator = std.testing.allocator;
    var value = try regex.Regex.init(allocator, "\\b", .{});
    defer value.deinit();
    const output = try value.replaceAllWithFn(allocator, "ab cd", null, boundaryMarker);
    defer allocator.free(output);
    try std.testing.expectEqualStrings("|ab| |cd|", output);
}

test "replacement output allocation failures roll back" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var value = try regex.Regex.init(allocator, "a+", .{});
            defer value.deinit();
            var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
            defer workspace.deinit();
            const input = "aaa bbb " ** 512;
            const cases = [_]struct { replacement: []const u8, expected: []const u8 }{
                .{ .replacement = "x", .expected = "x bbb " ** 512 },
                .{ .replacement = "abcdefghij", .expected = "abcdefghij bbb " ** 512 },
            };
            for (cases) |case| {
                const output = try workspace.replaceAll(input, case.replacement);
                defer allocator.free(output);
                try std.testing.expectEqualStrings(case.expected, output);
            }
            const limited = try workspace.replacen(input, 1, "x");
            defer allocator.free(limited);
            try std.testing.expectEqualStrings("x bbb " ++ "aaa bbb " ** 511, limited);
            const dynamic = try workspace.replaceAllWithFn(input, null, boundaryMarker);
            defer allocator.free(dynamic);
            try std.testing.expectEqualStrings("| bbb " ** 512, dynamic);
            const deleted = try workspace.replaceAll("a" ** 4096, "");
            defer allocator.free(deleted);
            try std.testing.expectEqualStrings("", deleted);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "replacement length and caller buffers avoid output allocation" {
    const allocator = std.testing.allocator;
    var value = try regex.Regex.init(allocator, "a+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    workspace.allocator = failing.allocator();
    defer workspace.allocator = allocator;
    const input = "aaa bbb " ** 512;
    const expected = "x bbb " ** 512;
    try std.testing.expectEqual(expected.len, try workspace.replaceAllLen(input, "x"));
    var output: [expected.len]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try workspace.replaceAllInto(input, "x", &output));
    try std.testing.expectError(error.RegexLimitExceeded, workspace.replaceAllInto(input, "x", output[0..2]));
}

test "regex replacement applies case transforms" {
    try expectReplace("([A-Za-z]+)", "\\U$1", "abc", "ABC");
    try expectReplace("([A-Za-z]+)", "\\L$1", "ABC", "abc");
    try expectReplace("([A-Za-z]+)", "\\u$1", "abc", "Abc");
    try expectReplace("([A-Za-z]+)", "\\l$1", "ABC", "aBC");
    try expectReplace("([A-Za-z]+)", "\\U$1\\E-$1", "abc", "ABC-abc");
    try expectReplace("([A-Za-z]+)", "\\U<\\u$1>", "abc", "<ABC>");
    try expectReplace("([A-Za-z]+)", "\\Uabc", "xyz", "ABC");
    try expectReplace("([A-Za-z]+)", "\\U\u{00e9}$1", "abc", "\u{00c9}ABC");
    try expectReplace("(.)", "\\U$1", "\u{00e9}", "\u{00c9}");
    try expectReplace("(.)", "\\L$1", "\u{00c9}", "\u{00e9}");
    try expectReplace("(.)", "\\U$1", "\u{03c3}", "\u{03a3}");
    try expectReplace("(.)", "\\L$1", "\u{03a3}", "\u{03c3}");
    try expectReplace("(.)", "\\u$1", "\u{00e9}", "\u{00c9}");
    try expectReplace("(.)", "\\l$1", "\u{00c9}", "\u{00e9}");
    try expectReplace("(.)", "\\U$1", "\u{00df}", "\u{00df}");
}

fn expectReplaceLimits(
    pattern: []const u8,
    substitution: []const u8,
    input: []const u8,
    expected: []const u8,
    limits: regex.Limits,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = try regex.compile(allocator, pattern, limits);
    var workspace = try regex.ReplaceWorkspace.init(allocator, program, limits);
    defer workspace.deinit();
    const actual = try workspace.replaceAll(input, substitution);
    try std.testing.expectEqualStrings(expected, actual);
}

test "full Unicode case mapping is opt-in" {
    // Default PCRE2-compatible simple mapping leaves sharp s unchanged.
    try expectReplace("(.)", "\\U$1", "\u{00df}", "\u{00df}");
    const full = regex.Limits{ .full_case_mapping = true };
    try expectReplaceLimits("(.)", "\\U$1", "\u{00df}", "SS", full);
    try expectReplaceLimits("(.)", "\\L$1", "\u{0130}", "i\u{0307}", full);
    try expectReplaceLimits("(.)", "\\U$1", "\u{fb01}", "FI", full);
    try expectReplaceLimits("(.)", "\\U$1", "abc", "ABC", full);
    try expectReplaceLimits("(.)", "\\L$1", "ABC", "abc", full);
    try expectReplaceLimits("(.)", "\\u$1", "\u{00df}", "SS", full);
}

test "substitution supports PCRE2 whole-input and angle-bracket forms" {
    try expectReplace("(a)(b)", "<$<2>|$<1>>", "ab", "<b|a>");
    try expectReplace("b", "[$`][$'][$&][$_]", "abc", "a[a][c][b][abc]c");
    try expectReplace("(?<first>a)(?<second>b)?", "<$+>", "ab", "<b>");
    try expectReplace("(?<first>a)(?<second>b)?", "<$+>", "ac", "<a>c");

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const program = try regex.compile(allocator, "(?<n>a)", .{});
    try regex.validateSubstitutionFor(program, "$<n>");
    try std.testing.expectError(error.InvalidRegex, regex.validateSubstitutionFor(program, "$<missing>"));
    try std.testing.expectError(error.InvalidRegex, regex.validateSubstitutionFor(program, "$<2>"));
}
