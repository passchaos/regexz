const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

fn expectMatches(allocator: std.mem.Allocator, pattern: []const u8, yes: []const []const u8, no: []const []const u8, limits: regex.Limits) !void {
    var value = try regex.Regex.init(allocator, pattern, limits);
    defer value.deinit();
    for (yes) |input| try std.testing.expect(try value.matches(allocator, input));
    for (no) |input| try std.testing.expect(!try value.matches(allocator, input));
}

test "set-run fullmatch uses the byte table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectMatches(allocator, "[a-z]+", &.{ "abc", "a" }, &.{ "", "ab1", "caf\u{00e9}", "abc\n", "ABC" }, .{});
    try expectMatches(allocator, "\\w+", &.{ "abc_123", "_" }, &.{ "", "ab-c" }, .{});
    try expectMatches(allocator, "[A-Za-z0-9._-]+", &.{"User.Name_42"}, &.{ "", "User Name" }, .{});
    try expectMatches(allocator, "\\d{1,}", &.{ "0", "123456" }, &.{ "", "12a" }, .{});

    var value = try regex.Regex.init(allocator, "[a-z]+", .{});
    defer value.deinit();
    try std.testing.expectEqual(regex.PartialResult.full, try value.partialMatch(allocator, "abc"));
    try std.testing.expectEqual(regex.PartialResult.partial, try value.partialMatch(allocator, ""));
    try std.testing.expectEqual(regex.PartialResult.none, try value.partialMatch(allocator, "ab1"));

    // A case-folded ASCII class gains non-ASCII members, so it stays on the
    // DFA path and must still match them.
    try expectMatches(allocator, "(?i)[a-z]+", &.{ "AbC", "\u{212a}" }, &.{ "", "ab1" }, .{});
}

test "case folding is materialized before class negation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `[a-z]` endpoints stay runes even with (?i), and the final union folds.
    try expectMatches(allocator, "(?i)[a-z]+", &.{ "abc", "ABC", "AbC", "K", "ſ" }, &.{ "1", "Σ", "猫" }, .{});
    try expectMatches(allocator, "(?i)[^a-z]+", &.{ "1", "Σ", "猫" }, &.{ "a", "A", "K", "ſ" }, .{});
    // Negated POSIX classes fold the positive set first, then complement.
    try expectMatches(allocator, "(?i)[[:^alpha:]]+", &.{ "1", "Σ", "猫" }, &.{ "a", "A", "K", "ſ" }, .{});
    // Ranges that cross fold orbits.
    try expectMatches(allocator, "(?i)[k-s]+", &.{ "KLS", "K", "ſ" }, &.{ "a", "z", "1" }, .{});
    // Cased letters are closed under simple folding.
    try expectMatches(allocator, "(?i)\\p{Lu}", &.{ "A", "a", "Σ", "σ", "ς", "ß", "ẞ", "K", "ſ" }, &.{ "1", "猫", " " }, .{});
    try expectMatches(allocator, "(?i)\\P{Lu}", &.{ "1", "猫", " " }, &.{ "a", "A", "k", "K", "K", "ſ", "Σ", "σ", "ς", "ß", "ẞ" }, .{});
}

test "pure literals use the exact-match fast path" {
    var value = try regex.Regex.init(std.testing.allocator, "hello, world!", .{});
    defer value.deinit();
    try std.testing.expect(value.program.literal != null);
    try std.testing.expectEqualStrings("hello, world!", value.program.literal.?);
    try std.testing.expect(try value.matches(std.testing.allocator, "hello, world!"));
    try std.testing.expect(!try value.matches(std.testing.allocator, "hello, world"));

    var non_literal = try regex.Regex.init(std.testing.allocator, "h.llo", .{});
    defer non_literal.deinit();
    try std.testing.expect(non_literal.program.literal == null);

    // Folding digits is an identity, so the literal fast path still applies.
    var digits = try regex.Regex.init(std.testing.allocator, "(?i)123", .{});
    defer digits.deinit();
    try std.testing.expect(digits.program.literal != null);
    try std.testing.expect(try digits.matches(std.testing.allocator, "123"));

    var letters = try regex.Regex.init(std.testing.allocator, "(?i)abc", .{});
    defer letters.deinit();
    try std.testing.expect(letters.program.literal == null);
    try std.testing.expect(try letters.matches(std.testing.allocator, "ABC"));
}

test "escape sequences cover PCRE2 control forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectMatches(allocator, "\\e", &.{"\x1b"}, &.{ "e", "E" }, .{});
    try expectMatches(allocator, "\\cA", &.{"\x01"}, &.{ "A", "c" }, .{});
    try expectMatches(allocator, "\\c?", &.{"\x7f"}, &.{"?"}, .{});
    try expectMatches(allocator, "\\o{101}", &.{"A"}, &.{"o"}, .{});
    try expectMatches(allocator, "\\x{1F600}", &.{"\u{1F600}"}, &.{"x"}, .{});
    try expectMatches(allocator, "\\x41", &.{"A"}, &.{"x41"}, .{});
    // `\E` without `\Q` is ignored; `\Q...\E` quotes metacharacters.
    try expectMatches(allocator, "a\\Eb", &.{"ab"}, &.{"aEb"}, .{});
    try expectMatches(allocator, "\\Qa.b\\E", &.{"a.b"}, &.{ "axb", "a.bc" }, .{});
    try expectMatches(allocator, "\\Qa.b", &.{"a.b"}, &.{"axb"}, .{});
    try expectMatches(allocator, "\\Qa\\Eb", &.{"ab"}, &.{"a\\Eb"}, .{});
}

test "ASCII and non-ASCII literal instructions match mixed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectMatches(allocator, "abc", &.{"abc"}, &.{ "ab", "abcd", "xabc", "a猫b" }, .{});
    try expectMatches(allocator, "a猫b", &.{"a猫b"}, &.{ "a猫", "a猫bc", "a猫B" }, .{});
    try expectMatches(allocator, "(?i)k", &.{ "k", "K", "K" }, &.{ "x", "kk" }, .{});
    try expectMatches(allocator, "猫+", &.{ "猫", "猫猫" }, &.{ "猫a", "x" }, .{});
}

test "lazy DFA agrees with the NFA" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const patterns = [_][]const u8{
        "a*",
        "(?:a|aa)*b",
        "[a-z]+",
        "(?i)[a-z]+",
        "(?:ab|cd)+",
        "\\p{L}+",
        "[0-9]{2,4}",
    };
    const short_inputs = [_][]const u8{ "", "a", "aa", "ab", "abc", "1234", "猫", "a猫b", "abab", "abcde" };
    var long_a: std.ArrayList(u8) = .empty;
    defer long_a.deinit(allocator);
    var long_mixed: std.ArrayList(u8) = .empty;
    defer long_mixed.deinit(allocator);
    for (0..2000) |index| {
        try long_a.append(allocator, 'a');
        try long_mixed.append(allocator, if (index % 7 == 0) 'b' else 'a');
    }
    for (patterns) |pattern| {
        var value = try regex.Regex.init(allocator, pattern, .{});
        defer value.deinit();
        try std.testing.expect(value.program.dfa_eligible);
        var workspace = try regex.Workspace.init(allocator, value.program);
        defer workspace.deinit();
        for (short_inputs) |input| {
            for (0..3) |_| _ = workspace.matches(value.program, input);
            try std.testing.expectEqual(workspace.matchesNfa(value.program, input), workspace.matches(value.program, input));
        }
        for ([_][]const u8{ long_a.items, long_mixed.items }) |input| {
            try std.testing.expectEqual(workspace.matchesNfa(value.program, input), workspace.matches(value.program, input));
        }
    }
}

test "DFA eligibility excludes context-sensitive programs" {
    const patterns = [_][]const u8{ "^a+$", "(?m)^a$", "(?=a)a", "(?!a)b", "\\C", "\\bword\\b" };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(std.testing.allocator, pattern, .{});
        defer value.deinit();
        try std.testing.expect(!value.program.dfa_eligible);
    }
}

test "linear fallback resolves capture-free searches when the budget is exhausted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var value = try regex.Regex.init(allocator, "(?:a|aa)*b", .{});
    defer value.deinit();
    const limits = regex.Limits{ .max_execution_steps = 8, .linear_fallback = true };
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, limits);
    defer workspace.deinit();

    var matching: [31]u8 = undefined;
    @memset(matching[0..30], 'a');
    matching[30] = 'b';
    const match = (try workspace.find(&matching, 0)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(matching.len, match.end);
    const output = try workspace.replaceAll(&matching, "x");
    try std.testing.expectEqualStrings("x", output);

    var no_match: [30]u8 = undefined;
    @memset(&no_match, 'a');
    try std.testing.expect((try workspace.find(&no_match, 0)) == null);

    // Disabling the fallback keeps the budget fail-closed.
    var strict = try regex.ReplaceWorkspace.init(allocator, value.program, .{ .max_execution_steps = 8, .linear_fallback = false });
    defer strict.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, strict.find(&no_match, 0));
}

test "Regex.matchesWithWorkspace reuses caller storage" {
    var value = try regex.Regex.init(std.testing.allocator, "[a-z]+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(std.testing.allocator, value.program);
    defer workspace.deinit();
    try std.testing.expect(value.matchesWithWorkspace(&workspace, "abc"));
    try std.testing.expect(!value.matchesWithWorkspace(&workspace, "ABC"));
}

test "partial matching reports prefixes of possible matches" {
    const P = regex.PartialResult;
    const Case = struct { pattern: []const u8, input: []const u8, expected: P };
    for ([_]Case{
        .{ .pattern = "abc", .input = "", .expected = .partial },
        .{ .pattern = "abc", .input = "a", .expected = .partial },
        .{ .pattern = "abc", .input = "ab", .expected = .partial },
        .{ .pattern = "abc", .input = "abc", .expected = .full },
        .{ .pattern = "abc", .input = "abcd", .expected = .none },
        .{ .pattern = "abc", .input = "x", .expected = .none },
        .{ .pattern = "a+", .input = "", .expected = .partial },
        .{ .pattern = "a+", .input = "a", .expected = .full },
        .{ .pattern = "a+", .input = "aa", .expected = .full },
        .{ .pattern = "a+", .input = "b", .expected = .none },
        .{ .pattern = "a*", .input = "", .expected = .full },
        .{ .pattern = "a*", .input = "a", .expected = .full },
        .{ .pattern = "a*", .input = "b", .expected = .none },
        .{ .pattern = "a|ab", .input = "", .expected = .partial },
        .{ .pattern = "a|ab", .input = "a", .expected = .full },
        .{ .pattern = "a|ab", .input = "ab", .expected = .full },
        .{ .pattern = "a|ab", .input = "ac", .expected = .none },
        .{ .pattern = "\\p{L}+", .input = "", .expected = .partial },
        .{ .pattern = "\\p{L}+", .input = "é", .expected = .full },
        .{ .pattern = "\\p{L}+", .input = "1", .expected = .none },
        .{ .pattern = "(?i)hello", .input = "He", .expected = .partial },
        .{ .pattern = "(?i)hello", .input = "HELLO", .expected = .full },
        .{ .pattern = "hello", .input = "he", .expected = .partial },
        .{ .pattern = "a{2,4}", .input = "a", .expected = .partial },
        .{ .pattern = "a{2,4}", .input = "aaaa", .expected = .full },
        .{ .pattern = "a{2,4}", .input = "aaaaa", .expected = .none },
        .{ .pattern = "a?", .input = "", .expected = .full },
        .{ .pattern = "\\C", .input = "", .expected = .partial },
        .{ .pattern = "\\C", .input = "a", .expected = .full },
        .{ .pattern = "\\C", .input = "ab", .expected = .none },
        // A positive lookahead at EOF makes the subject a partial match.
        .{ .pattern = "a(?=b)", .input = "a", .expected = .partial },
        .{ .pattern = "a(?=b)", .input = "", .expected = .partial },
        .{ .pattern = "a(?=b)", .input = "ab", .expected = .none },
        .{ .pattern = "a(?!b)", .input = "a", .expected = .full },
        .{ .pattern = "a(?=\\p{Han})", .input = "a", .expected = .partial },
        // Negative assertions and lookbehind windows must not leak a child's
        // partial state.
        .{ .pattern = "(?!ab)", .input = "a", .expected = .none },
        .{ .pattern = "(?!ab)", .input = "", .expected = .full },
        .{ .pattern = "(?=ab)", .input = "a", .expected = .partial },
        .{ .pattern = "(?<=ab)", .input = "a", .expected = .none },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.expected, try value.partialMatch(gpa, case.input));
    }

    // Extended programs now report prefix partiality through the bounded VM.
    var extended = try regex.Regex.init(gpa, "(?=ab)ab", .{});
    defer extended.deinit();
    try std.testing.expectEqual(regex.PartialResult.full, try extended.partialMatch(gpa, "ab"));
    try std.testing.expectEqual(regex.PartialResult.partial, try extended.partialMatch(gpa, "a"));
    try std.testing.expectEqual(regex.PartialResult.none, try extended.partialMatch(gpa, "ax"));
    var lookbehind = try regex.Regex.init(gpa, "a(?<=a)b", .{});
    defer lookbehind.deinit();
    try std.testing.expectEqual(regex.PartialResult.partial, try lookbehind.partialMatch(gpa, "a"));
    try std.testing.expectEqual(regex.PartialResult.full, try lookbehind.partialMatch(gpa, "ab"));
    try std.testing.expectEqual(regex.PartialResult.none, try lookbehind.partialMatch(gpa, "ac"));
    var backref = try regex.Regex.init(gpa, "(ab)\\1", .{});
    defer backref.deinit();
    try std.testing.expectEqual(regex.PartialResult.partial, try backref.partialMatch(gpa, "aba"));
    try std.testing.expectEqual(regex.PartialResult.full, try backref.partialMatch(gpa, "abab"));
    try std.testing.expectEqual(regex.PartialResult.none, try backref.partialMatch(gpa, "abx"));
}

test "Regex.matches is safe across threads" {
    var value = try regex.Regex.init(gpa, "[a-z]+", .{});
    defer value.deinit();
    const Context = struct {
        regex: *regex.Regex,
        ok: std.atomic.Value(bool) = .init(true),
        fn run(self: *@This()) void {
            for (0..2000) |_| {
                const matched = self.regex.matches(gpa, "abc") catch {
                    self.ok.store(false, .monotonic);
                    return;
                };
                if (!matched) self.ok.store(false, .monotonic);
            }
        }
    };
    var context = Context{ .regex = &value };
    var threads: [2]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Context.run, .{&context});
    for (threads) |thread| thread.join();
    try std.testing.expect(context.ok.load(.monotonic));
}

test "lazy DFA falls back when its cache cannot be allocated" {
    var value = try regex.Regex.init(std.testing.allocator, "(?:a|aa)*b", .{});
    defer value.deinit();
    // Workspace.init consumes the first two allocations; the DFA cache
    // allocation then fails and matching must fall back to the NFA.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    const allocator = failing.allocator();
    var workspace = try regex.Workspace.init(allocator, value.program);
    defer workspace.deinit();
    var input: [5000]u8 = undefined;
    @memset(&input, 'a');
    input[input.len - 1] = 'b';
    try std.testing.expect(workspace.matches(value.program, &input));
    try std.testing.expect(failing.has_induced_failure);
}

test "linear fallback rolls back allocation failures" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var value = try regex.Regex.init(allocator, "(?:a|aa)*b", .{});
            defer value.deinit();
            var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{ .max_execution_steps = 8, .linear_fallback = true });
            defer workspace.deinit();
            var input: [31]u8 = undefined;
            @memset(input[0..30], 'a');
            input[30] = 'b';
            try std.testing.expect((try workspace.find(&input, 0)) != null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "greedy single-set loops compile to the counting star" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var value = try regex.Regex.init(allocator, "a+", .{});
    defer value.deinit();
    var has_star = false;
    for (value.program.instructions) |instruction| {
        if (instruction == .star) has_star = true;
    }
    try std.testing.expect(has_star);

    var alternation = try regex.Regex.init(allocator, "(?:ab|cd)+", .{});
    defer alternation.deinit();
    var has_skippable_split = false;
    for (alternation.program.instructions) |instruction| switch (instruction) {
        .split => |split| {
            if (split.skip) has_skippable_split = true;
        },
        else => {},
    };
    try std.testing.expect(has_skippable_split);

    // Extended programs keep the split/consume form for the backtracking VM.
    var possessive = try regex.Regex.init(allocator, "a++", .{});
    defer possessive.deinit();
    try std.testing.expect(possessive.program.extended);
    for (possessive.program.instructions) |instruction| try std.testing.expect(instruction != .star);

    try expectMatches(allocator, "a+", &.{ "a", "aaa" }, &.{ "", "b", "aab" }, .{});
    try expectMatches(allocator, "a{2,}", &.{ "aa", "aaa" }, &.{ "a", "" }, .{});
    try expectMatches(allocator, "(?:ab|cd)+", &.{ "ab", "abcd", "abcdab" }, &.{ "a", "abx", "" }, .{});
    try expectMatches(allocator, "(?:a|ab)*b", &.{ "b", "ab", "aab", "abab" }, &.{ "", "a", "aba" }, .{});
    try expectMatches(allocator, "[^a]*", &.{ "", "bbb" }, &.{ "a", "ab" }, .{});
    try expectMatches(allocator, "(?i)k+", &.{ "k", "KK", "KK" }, &.{ "x", "kKx" }, .{});
    try expectMatches(allocator, "猫+", &.{ "猫", "猫猫" }, &.{ "猫a", "" }, .{});
    try expectMatches(allocator, "a*b*c*", &.{ "", "abc", "aaabbbccc" }, &.{ "cba", "abca" }, .{});
}

fn expectFindSpans(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    input: []const u8,
    expected: []const [2]usize,
    limits: regex.Limits,
) !void {
    var value = try regex.Regex.init(allocator, pattern, limits);
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, limits);
    defer workspace.deinit();
    var offset: usize = 0;
    var index: usize = 0;
    while (offset <= input.len and index < expected.len + 1) {
        const found = (try workspace.find(input, offset)) orelse break;
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqual(expected[index][0], found.start);
        try std.testing.expectEqual(expected[index][1], found.end);
        index += 1;
        if (found.end <= found.start) {
            if (found.start == input.len) break;
            const len = std.unicode.utf8ByteSequenceLength(input[found.start]) catch 1;
            offset = found.start + len;
        } else {
            offset = found.end;
        }
    }
    try std.testing.expectEqual(expected.len, index);
}

test "split first-set skipping preserves leftmost-first search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectFindSpans(allocator, "a+", "baaac a", &.{ .{ 1, 4 }, .{ 6, 7 } }, .{});
    try expectFindSpans(allocator, "(?:ab|cd)+", "xabcdab", &.{.{ 1, 7 }}, .{});
    try expectFindSpans(allocator, "(?:a|ab)*b", "abab", &.{ .{ 0, 2 }, .{ 2, 4 } }, .{});
    try expectFindSpans(allocator, "[^a]*", "abbb", &.{ .{ 0, 0 }, .{ 1, 4 }, .{ 4, 4 } }, .{});
    try expectFindSpans(allocator, "\\s*[\\r\\n]+", "a \n\nb", &.{.{ 1, 4 }}, .{});
    try expectFindSpans(
        allocator,
        " ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*",
        "ab !!x",
        &.{.{ 2, 5 }},
        .{ .unicode_perl_space = true },
    );
    try expectFindSpans(
        allocator,
        "\\s+(?!\\S)|\\s+",
        "a  b",
        &.{ .{ 1, 2 }, .{ 2, 3 } },
        .{ .unicode_perl_space = true },
    );
    try expectFindSpans(allocator, "(?i:k|s|σ|ß)+", "KSσςx", &.{.{ 0, 6 }}, .{});
}

test "set-run fast path scans ASCII runs directly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectFindSpans(allocator, "a+", "baaac a", &.{ .{ 1, 4 }, .{ 6, 7 } }, .{});
    try expectFindSpans(allocator, "[a-z]+", "  abc  def", &.{ .{ 2, 5 }, .{ 7, 10 } }, .{});
    try expectFindSpans(allocator, "\\d+", "12 345 6", &.{ .{ 0, 2 }, .{ 3, 6 }, .{ 7, 8 } }, .{});
    try expectFindSpans(allocator, "\\w+", "ab_12 cd", &.{ .{ 0, 5 }, .{ 6, 8 } }, .{});
    try expectFindSpans(allocator, "(?i)[a-z]+", "AbC dEf", &.{ .{ 0, 3 }, .{ 4, 7 } }, .{});
    // Multi-byte runes are non-members of an ASCII-only set and split runs.
    try expectFindSpans(allocator, "[a-z]+", "caf\u{00e9}s", &.{ .{ 0, 3 }, .{ 5, 6 } }, .{});
    try expectFindSpans(allocator, "a+", "\u{1f600}aa\u{1f600}a", &.{ .{ 4, 6 }, .{ 10, 11 } }, .{});
    try expectFindSpans(allocator, "[a-z]+", "", &.{}, .{});

    var value = try regex.Regex.init(allocator, "[a-z]+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.simple_set != null);

    // A mid-run search start still returns the maximal remaining run.
    const found = (try workspace.find("abcdef", 3)).?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 6), found.end);
    try std.testing.expectEqualSlices(usize, &.{ 3, 6 }, found.slots);
    try std.testing.expect((try workspace.find("abcdef", 6)) == null);
    try std.testing.expect((try workspace.find("abcdef", 7)) == null);

    // Shapes that are not a bare ASCII `set+` keep the general engine.
    var han = try regex.Regex.init(allocator, "\\p{Han}+", .{});
    defer han.deinit();
    var han_workspace = try regex.ReplaceWorkspace.init(allocator, han.program, .{});
    defer han_workspace.deinit();
    try std.testing.expect(han_workspace.simple_set == null);
    var captured = try regex.Regex.init(allocator, "(a)+", .{});
    defer captured.deinit();
    var captured_workspace = try regex.ReplaceWorkspace.init(allocator, captured.program, .{});
    defer captured_workspace.deinit();
    try std.testing.expect(captured_workspace.simple_set == null);
    var bounded = try regex.Regex.init(allocator, "a{2,}", .{});
    defer bounded.deinit();
    var bounded_workspace = try regex.ReplaceWorkspace.init(allocator, bounded.program, .{});
    defer bounded_workspace.deinit();
    try std.testing.expect(bounded_workspace.simple_set == null);
}

test "byte-level DFA searches non-ASCII sets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Greedy single-set scans stop at the first rune outside the set.
    try expectFindSpans(allocator, "\\p{Han}+", "a你好世界，x", &.{.{ 1, 13 }}, .{});
    try expectFindSpans(allocator, "\\p{Han}+", "你好，世界", &.{ .{ 0, 6 }, .{ 9, 15 } }, .{});
    try expectFindSpans(allocator, "[\\p{Greek}\\p{Cyrillic}]+", "xαβγддеz", &.{.{ 1, 13 }}, .{});
    // Alternation, anchors, and repetition over non-ASCII classes.
    try expectFindSpans(allocator, "(?:\\p{Han}|\\p{Greek})+", "a猫αb", &.{.{ 1, 6 }}, .{});
    try expectFindSpans(allocator, "^\\p{Han}+$", "你好", &.{.{ 0, 6 }}, .{});
    try expectFindSpans(allocator, "\\p{Han}{2,3}", "你好世界啊", &.{ .{ 0, 9 }, .{ 9, 15 } }, .{});
    // Capture bounds come from the byte DFA and are replayed for slots.
    try expectFindSpans(allocator, "(\\p{Han}+)-(\\p{Han}+)", "a你好-世界b", &.{.{ 1, 14 }}, .{});
    // Lazy quantifiers and non-matching starts.
    try expectFindSpans(allocator, "\\p{Han}+?", "你好", &.{ .{ 0, 3 }, .{ 3, 6 } }, .{});
    // Competing accept priorities must not use the uniform-accept fast path.
    try expectFindSpans(allocator, "\\p{Han}+?|\\p{Han}+", "你好", &.{ .{ 0, 3 }, .{ 3, 6 } }, .{});
    try expectFindSpans(allocator, "\\p{Han}+|\\p{Greek}+", "αβ", &.{.{ 0, 4 }}, .{});
    try expectFindSpans(allocator, "\\p{Han}+", "abc", &.{}, .{});
    // Invalid UTF-8 cannot extend a rune-based match.
    try expectFindSpans(allocator, "\\p{Han}+", "a\xE4\xB8", &.{}, .{});
    // Literal runes, mixed ASCII/Unicode classes, bounded repeats, and
    // case-folded non-ASCII literals all take the byte construction.
    try expectFindSpans(allocator, "\u{4F60}\u{597D}", "x你好y", &.{.{ 1, 7 }}, .{});
    try expectFindSpans(allocator, "[a\u{4E00}-\u{4E10}]+", "z a\u{4E00}a\u{4E01}z", &.{.{ 2, 10 }}, .{});
    try expectFindSpans(allocator, "\u{4E00}{2,4}", "\u{4E00}\u{4E00}\u{4E00}", &.{.{ 0, 9 }}, .{});
    try expectFindSpans(allocator, "(?i)\u{03A3}", "\u{03C3}\u{03C2}\u{03A3}", &.{ .{ 0, 2 }, .{ 2, 4 }, .{ 4, 6 } }, .{});
    try expectFindSpans(allocator, "(?i)\u{03A3}+", "\u{03C3}\u{03C2}\u{03A3}", &.{.{ 0, 6 }}, .{});
}

test "byte loops scan without per-byte choices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectFindSpans(allocator, "\\C+", "abc", &.{.{ 0, 3 }}, .{});
    try expectFindSpans(allocator, "\\C+", "\xFF\xFE\x80", &.{.{ 0, 3 }}, .{});
    try expectFindSpans(allocator, "a\\C+", "abc", &.{.{ 0, 3 }}, .{});
    // Greedy scan backtracks one byte at a time to the last possible exit.
    try expectFindSpans(allocator, "\\C+b", "aab", &.{.{ 0, 3 }}, .{});
    try expectFindSpans(allocator, "\\C+b", "aab b", &.{.{ 0, 5 }}, .{});
    // Capture programs take the trail VM path.
    try expectFindSpans(allocator, "(\\C+)b", "aab", &.{.{ 0, 3 }}, .{});
    // Lazy loops keep the generic per-byte backtracking.
    try expectFindSpans(allocator, "\\C+?b", "aab", &.{.{ 0, 3 }}, .{});
    try expectFindSpans(allocator, "\\C*", "", &.{.{ 0, 0 }}, .{});
}

test "ungreedy flag swaps quantifier defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Full-match still has to consume the input, so greediness does not
    // change membership.
    try expectMatches(allocator, "(?U)a+", &.{ "a", "aaa" }, &.{ "", "b" }, .{});
    try expectFindSpans(allocator, "(?U)a+", "aaa", &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } }, .{});
    try expectFindSpans(allocator, "(?U)a+?", "aaa", &.{.{ 0, 3 }}, .{});
    try expectFindSpans(allocator, "(?U)a{2,3}", "aaaa", &.{ .{ 0, 2 }, .{ 2, 4 } }, .{});
    try expectFindSpans(allocator, "(?U)a*", "aaa", &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } }, .{});

    var value = try regex.Regex.init(allocator, "(?U)(a+)(a*)", .{});
    defer value.deinit();
    var captures = try regex.Captures.init(allocator, value.program);
    defer captures.deinit(allocator);
    const match = (try value.find(allocator, "aaa", &captures)).?;
    try std.testing.expectEqualStrings("a", match.group("aaa", 1).?);
    try std.testing.expectEqualStrings("", match.group("aaa", 2).?);

    // Scoped `(?U:...)` is restored when the group closes.
    var scoped = try regex.Regex.init(allocator, "(?U:(a+))(a+)", .{});
    defer scoped.deinit();
    var scoped_captures = try regex.Captures.init(allocator, scoped.program);
    defer scoped_captures.deinit(allocator);
    const scoped_match = (try scoped.find(allocator, "aaa", &scoped_captures)).?;
    try std.testing.expectEqualStrings("a", scoped_match.group("aaa", 1).?);
    try std.testing.expectEqualStrings("aa", scoped_match.group("aaa", 2).?);

    // `(?-U)` turns the default back on for the remainder of the group.
    try expectFindSpans(allocator, "(?U)(?-U:a+)", "aaa", &.{.{ 0, 3 }}, .{});
}

test "no-auto-capture flag keeps named groups capturing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var value = try regex.Regex.init(allocator, "(?n)(a)(?<x>b)", .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(u16, 1), value.program.capture_count);
    try std.testing.expectEqual(@as(u16, 1), value.program.groupIndex("x").?);
    var captures = try regex.Captures.init(allocator, value.program);
    defer captures.deinit(allocator);
    const match = (try value.find(allocator, "ab", &captures)).?;
    try std.testing.expectEqualStrings("b", match.group("ab", 1).?);

    var scoped = try regex.Regex.init(allocator, "(?n:(a))(?<x>b)", .{});
    defer scoped.deinit();
    try std.testing.expectEqual(@as(u16, 1), scoped.program.capture_count);

    // `(?-n)` restores automatic capture for the rest of the enclosing group.
    var enabled = try regex.Regex.init(allocator, "(?n)(?-n:(a))", .{});
    defer enabled.deinit();
    try std.testing.expectEqual(@as(u16, 1), enabled.program.capture_count);

    try expectMatches(allocator, "(?n)(a)(b)", &.{"ab"}, &.{ "a", "abc" }, .{});
}

test "character class set operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectMatches(allocator, "[a-z&&[^aeiou]]+", &.{ "bcdf", "xyz" }, &.{ "a", "e", "1", "" }, .{});
    try expectMatches(allocator, "[a-z--[aeiou]]+", &.{ "bcdf", "xyz" }, &.{ "a", "e", "1", "" }, .{});
    try expectMatches(allocator, "[a-g~~b-h]+", &.{ "a", "h", "ah" }, &.{ "b", "g", "" }, .{});
    try expectMatches(allocator, "[\\p{L}--\\p{Lu}]+", &.{ "abc", "σς" }, &.{ "ABC", "Σ", "1" }, .{});
    try expectMatches(allocator, "[a-z&&[^aeiou]--[b]]+", &.{ "cdf", "xyz" }, &.{ "a", "b", "" }, .{});
    try expectMatches(allocator, "(?i)[a-z&&[^aeiou]]+", &.{ "B", "bcdf" }, &.{ "A", "E", "1" }, .{});
    try expectMatches(allocator, "[[:alpha:]&&[^[:digit:]]]+", &.{"abc"}, &.{ "1", "a1", "" }, .{});

    // `&&`, `--`, and `~~` without an operand on one side, and lone
    // punctuation, keep their literal meaning.
    try expectMatches(allocator, "[&&]", &.{"&"}, &.{ "a", "" }, .{});
    try expectMatches(allocator, "[a-z-]+", &.{ "a-z", "---" }, &.{ "1", "" }, .{});
}

test "counting star scan respects the step budget" {
    // A capture keeps this on the interpreter path so the star scan itself is
    // subject to the step budget.
    var value = try regex.Regex.init(std.testing.allocator, "(a+)", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(std.testing.allocator, value.program, .{ .max_execution_steps = 8, .linear_fallback = false });
    defer workspace.deinit();
    var input: [64]u8 = undefined;
    @memset(&input, 'a');
    try std.testing.expectError(error.RegexLimitExceeded, workspace.find(&input, 0));
}

test "linear capture replay fills the same slots as the interpreter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The first cases take the deterministic replay (forced greedy runs);
    // the later ones are shapes it must reject and hand to the VM.
    const cases = [_]struct { pattern: []const u8, input: []const u8, groups: []const []const u8 }{
        .{ .pattern = "(\\w+)@(\\w+)\\.com", .input = "user.name@example.com", .groups = &.{ "name@example.com", "name", "example" } },
        .{ .pattern = "(\\d+)-(\\d+)", .input = "12-345", .groups = &.{ "12-345", "12", "345" } },
        .{ .pattern = "(a+)b", .input = "aaab", .groups = &.{ "aaab", "aaa" } },
        .{ .pattern = "(\\p{Han}+)-(\\p{Han}+)", .input = "a\u{4f60}\u{597d}-\u{4e16}\u{754c}b", .groups = &.{ "\u{4f60}\u{597d}-\u{4e16}\u{754c}", "\u{4f60}\u{597d}", "\u{4e16}\u{754c}" } },
        .{ .pattern = "(?i)([a-z]+)(\\d+)", .input = "AbC12", .groups = &.{ "AbC12", "AbC", "12" } },
        .{ .pattern = "(a+)ab", .input = "aaab", .groups = &.{ "aaab", "aa" } },
        .{ .pattern = "(\\w+)(\\w+)", .input = "abcd", .groups = &.{ "abcd", "abc", "d" } },
        .{ .pattern = "(a*)(a*)", .input = "aaa", .groups = &.{ "aaa", "aaa", "" } },
        .{ .pattern = "(a|aa)*b", .input = "aaab", .groups = &.{ "aaab", "a" } },
        .{ .pattern = "(a+)(a+)(a*)", .input = "aaaa", .groups = &.{ "aaaa", "aaa", "a", "" } },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
        defer workspace.deinit();
        const found = (try workspace.find(case.input, 0)).?;
        for (case.groups, 0..) |want, index| {
            const got = found.group(case.input, index) orelse "";
            try std.testing.expectEqualStrings(want, got);
        }
    }
}

test "capture-aware linear fallback matches the backtracking VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const patterns = [_][]const u8{
        "(a|aa)*b",
        "(a|ab)(b?)",
        "(ab|a)(b*)",
        "(?:(a)|(b))+",
        "(a*)(a*)",
        "(\\p{L}+)(\\p{N}+)",
        "(?<x>a|ab)(?<y>b?)",
        "((a)|b)+",
        "(a)(b)?",
        "(?:a|b)+(c?)",
        "(?i)([a-z]+)(\\d+)",
        "(a+)(a+)(a*)",
    };
    const inputs = [_][]const u8{ "", "a", "b", "ab", "aab", "aaab", "abc", "abc123", "aaa", "abab", "café12", "a1b2" };

    for (patterns) |pattern| {
        var value = try regex.Regex.init(allocator, pattern, .{});
        defer value.deinit();
        var normal = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
        defer normal.deinit();
        // One backtracking step forces every search onto the Pike fallback.
        var forced = try regex.ReplaceWorkspace.init(allocator, value.program, .{ .max_execution_steps = 1, .linear_fallback = true });
        defer forced.deinit();
        for (inputs) |input| {
            var offset: usize = 0;
            var spans: usize = 0;
            while (offset <= input.len and spans < 16) {
                const expected = try normal.find(input, offset);
                const actual = try forced.find(input, offset);
                if (expected == null) {
                    try std.testing.expect(actual == null);
                    break;
                }
                const left = expected.?;
                const right = actual.?;
                try std.testing.expectEqual(left.start, right.start);
                try std.testing.expectEqual(left.end, right.end);
                for (0..value.program.capture_count + 1) |group| {
                    const left_text = left.group(input, group);
                    const right_text = right.group(input, group);
                    if (left_text == null) {
                        try std.testing.expect(right_text == null);
                    } else {
                        try std.testing.expectEqualStrings(left_text.?, right_text.?);
                    }
                }
                spans += 1;
                if (left.end <= left.start) {
                    if (left.start == input.len) break;
                    const len = std.unicode.utf8ByteSequenceLength(input[left.start]) catch 1;
                    offset = left.start + len;
                } else {
                    offset = left.end;
                }
            }
        }
    }
}

test "capture search takes DFA bounds and replays exact slots" {
    const allocator = std.testing.allocator;
    const Case = struct {
        pattern: []const u8,
        input: []const u8,
        span: ?[2]usize,
        groups: []const ?[]const u8,
    };
    const cases = [_]Case{
        .{
            .pattern = "(\\w+)@(\\w+)\\.com",
            .input = "xx user.name@example.com yy",
            .span = .{ 8, 24 },
            .groups = &.{ "name@example.com", "name", "example" },
        },
        .{
            .pattern = "(\\p{L}+)@(\\p{L}+)",
            .input = "hello world",
            .span = null,
            .groups = &.{},
        },
        .{
            .pattern = "(\\p{L}+)(\\p{N}+)",
            .input = "abc123",
            .span = .{ 0, 6 },
            .groups = &.{ "abc123", "abc", "123" },
        },
        .{
            .pattern = "(?P<user>\\w+)@(?P<host>\\w+)",
            .input = "mail root@example here",
            .span = .{ 5, 17 },
            .groups = &.{ "root@example", "root", "example" },
        },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
        defer workspace.deinit();
        const found = try workspace.find(case.input, 0);
        if (case.span) |span| {
            const match = found.?;
            try std.testing.expectEqual(span[0], match.start);
            try std.testing.expectEqual(span[1], match.end);
            for (case.groups, 0..) |expected, group| {
                try std.testing.expectEqualStrings(expected.?, match.group(case.input, group).?);
            }
        } else {
            try std.testing.expect(found == null);
        }
    }
}

test "capture-aware fallback is on by default and can be disabled" {
    var value = try regex.Regex.init(std.testing.allocator, "(a|aa)*b", .{});
    defer value.deinit();
    var input: [31]u8 = undefined;
    @memset(input[0..30], 'a');
    input[30] = 'b';

    var relaxed = try regex.ReplaceWorkspace.init(std.testing.allocator, value.program, .{ .max_execution_steps = 8 });
    defer relaxed.deinit();
    const match = (try relaxed.find(&input, 0)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(input.len, match.end);
    try std.testing.expectEqualStrings("a", match.group(&input, 1).?);

    var strict = try regex.ReplaceWorkspace.init(std.testing.allocator, value.program, .{ .max_execution_steps = 8, .linear_fallback = false });
    defer strict.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, strict.find(&input, 0));
}

test "very large capture counts stay on the bounded backtracking VM" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(allocator);
    for (0..129) |_| try pattern.appendSlice(allocator, "(a)");
    var value = try regex.Regex.init(allocator, pattern.items, .{});
    defer value.deinit();
    try std.testing.expect(value.program.capture_count > 128);
    var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{ .max_execution_steps = 8, .linear_fallback = true });
    defer workspace.deinit();
    var input: [160]u8 = undefined;
    @memset(&input, 'a');
    try std.testing.expectError(error.RegexLimitExceeded, workspace.find(&input, 0));
}

test "explicit code points and quoted class literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try expectMatches(allocator, "\\N{U+41}", &.{"A"}, &.{ "a", "AA", "" }, .{});
    try expectMatches(allocator, "\\N{U+4E2D}", &.{"中"}, &.{ "A", "" }, .{});
    try expectMatches(allocator, "[\\N{U+41}\\N{U+42}]+", &.{ "AB", "BA" }, &.{ "C", "" }, .{});
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(allocator, "\\N{U+110000}", .{}));
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(allocator, "\\N{U+}", .{}));

    // `\Q...\E` quotes the range operator inside classes.
    try expectMatches(allocator, "[\\Qa-z\\E]+", &.{ "a-z", "-", "za" }, &.{ "b", "" }, .{});
    try expectMatches(allocator, "[\\Q-\\E]", &.{"-"}, &.{ "a", "" }, .{});
    try expectMatches(allocator, "\\Qa-z\\E", &.{"a-z"}, &.{ "b", "az" }, .{});
}

test "Script_Extensions properties" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // U+30FC is Script=Common but Script_Extensions={Hiragana, Katakana}.
    try expectMatches(allocator, "\\p{scx=Hiragana}+", &.{ "あ", "ー", "あー" }, &.{ "ア", "a", "" }, .{});
    try expectMatches(allocator, "\\p{Hiragana}+", &.{"あ"}, &.{ "ー", "ア" }, .{});
    // U+0964 is Script=Common but Script_Extensions includes Devanagari.
    try expectMatches(allocator, "\\p{scx=Devanagari}+", &.{ "क", "।", "क।" }, &.{ "a", "" }, .{});
    try expectMatches(allocator, "\\p{Devanagari}+", &.{"क"}, &.{ "।", "a" }, .{});
    // ISO 15924 codes and long names resolve to the same set.
    try expectMatches(allocator, "\\p{scx=Hira}+", &.{"あ"}, &.{"a"}, .{});
    try expectMatches(allocator, "\\p{scx=Latn}+", &.{"a"}, &.{ "あ", "" }, .{});
    try expectMatches(allocator, "\\P{scx=Hiragana}+", &.{ "ア", "a" }, &.{ "あ", "ー", "" }, .{});
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(allocator, "\\p{scx=NotAScript}", .{}));
}

test "lazy loops with consuming exits stay on the interpreter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The lazy `[^a]+?` can exit successfully at several offsets; the search
    // DFA cannot represent that iteration order, so it must fall back to the
    // interpreter and pick the first exit.
    try expectFindSpans(
        allocator,
        "aA|[^a]+?\\s+|\\p{L}+[\\r\\n]*",
        "BA\n\u{3c3} 2aA",
        &.{ .{ 0, 3 }, .{ 3, 6 }, .{ 7, 9 } },
        .{ .unicode_perl_classes = true },
    );
}

test "Unicode property aliases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Long General_Category names and extra aliases.
    try expectMatches(allocator, "\\p{Letter}+", &.{ "abc", "\u{732b}" }, &.{ "1", "" }, .{});
    try expectMatches(allocator, "\\p{Uppercase_Letter}+", &.{ "AB", "\u{03a3}" }, &.{ "a", "1", "" }, .{});
    try expectMatches(allocator, "\\p{Decimal_Number}+", &.{"123"}, &.{ "a", "" }, .{});
    try expectMatches(allocator, "\\p{Currency_Symbol}", &.{"$"}, &.{ "a", "1" }, .{});
    try expectMatches(allocator, "\\p{Cased_Letter}+", &.{"Aba"}, &.{ "1", "\u{732b}", "" }, .{});
    try expectMatches(allocator, "\\p{LC}+", &.{"A"}, &.{ "1", "" }, .{});
    try expectMatches(allocator, "\\p{IsLetter}+", &.{"abc"}, &.{ "1", "" }, .{});

    // Script names, ISO codes, separators, and case variants.
    try expectMatches(allocator, "\\p{Script=Grek}+", &.{"\u{0394}\u{03c3}"}, &.{ "a", "" }, .{});
    try expectMatches(allocator, "\\p{sc=Latn}+", &.{"abc"}, &.{ "\u{0394}", "" }, .{});
    try expectMatches(allocator, "\\p{Old Italic}+", &.{"\u{10300}"}, &.{ "a", "" }, .{});
    try expectMatches(allocator, "\\p{Script=greek}+", &.{"\u{0394}\u{03c3}"}, &.{ "a", "" }, .{});
    try expectMatches(allocator, "\\p{General Category=Letter}+", &.{"abc"}, &.{ "1", "" }, .{});
    try expectMatches(allocator, "\\p{gc=Uppercase_Letter}+", &.{"AB"}, &.{ "a", "" }, .{});

    // Case-insensitive binary-property names.
    try expectMatches(allocator, "\\p{letter}+", &.{"abc"}, &.{ "1", "" }, .{});
    try expectMatches(allocator, "\\p{alphabetic}+", &.{ "abc", "\u{732b}" }, &.{ "1", "" }, .{});
}

test "rune-mode DFA stops at invalid UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try expectFindSpans(allocator, "a+", "a\xE4\xB8", &.{.{ 0, 1 }}, .{});
    try expectFindSpans(allocator, "[a-z]+", "abc\xFF", &.{.{ 0, 3 }}, .{});
    try expectFindSpans(allocator, "(?=a)a+", "a\xE4", &.{.{ 0, 1 }}, .{});
    try expectFindSpans(allocator, "a+", "\xE4a", &.{.{ 1, 2 }}, .{});
}
