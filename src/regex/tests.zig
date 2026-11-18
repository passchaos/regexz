const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;
test "gRPC xDS safe regex supports full match RE2 operators Unicode and byte escapes" {
    const Case = struct { pattern: []const u8, yes: []const []const u8, no: []const []const u8 };
    for ([_]Case{
        .{ .pattern = "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", .yes = &.{ "/demo.Service/Get", "/test.Backend/List" }, .no = &.{ "prefix/demo.Service/Get", "/demo.Service/Put" } },
        .{ .pattern = "[a-z]{2,4}[0-9]+?", .yes = &.{ "ab1", "abcd1234" }, .no = &.{ "a1", "abcde1" } },
        .{ .pattern = "(?:ab){2,}(c|)", .yes = &.{ "abab", "abababc" }, .no = &.{ "ab", "ababd" } },
        .{ .pattern = "(?i:k|s|σ|ß)", .yes = &.{ "K", "K", "ſ", "ς", "Σ", "ẞ" }, .no = &.{ "SS", "x" } },
        .{ .pattern = "\\p{Greek}+\\p{Nd}", .yes = &.{ "Δσ2", "Σ٣" }, .no = &.{ "abc2", "Σx" } },
        .{ .pattern = "[[:alpha:]_][[:^digit:]]*", .yes = &.{ "abc", "xé_" }, .no = &.{ "1abc", "a2" } },
        .{ .pattern = "(?m:^a$)\\n(?s:.)", .yes = &.{ "a\nb", "a\n\n" }, .no = &.{ "a\n", "b\nx" } },
        .{ .pattern = "\\A\\bword\\b\\z", .yes = &.{"word"}, .no = &.{ "words", " word" } },
        .{ .pattern = "\\Q(a+b)[x]\\E*", .yes = &.{ "(a+b)[x", "(a+b)[x]]]" }, .no = &.{ "aaaabx", "(a+b)(a+b)" } },
        .{ .pattern = "\\C\\C", .yes = &.{ "é", "ab", "\xff\x80" }, .no = &.{ "a", "猫" } },
        .{ .pattern = "\\C猫\\C", .yes = &.{ "x猫y", "\xff猫\xff" }, .no = &.{ "猫", "é猫é" } },
        .{ .pattern = ".", .yes = &.{ "猫", "é" }, .no = &.{ "\n", "\xff", "ab" } },
        .{ .pattern = "^+", .yes = &.{""}, .no = &.{"a"} },
        .{ .pattern = "[^é]+", .yes = &.{"猫abc"}, .no = &.{ "é", "猫é" } },
        .{ .pattern = "\\x{d800}", .yes = &.{}, .no = &.{ "猫", "x", "\xed\xa0\x80" } },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        for (case.yes) |input| try std.testing.expect(try value.matches(gpa, input));
        for (case.no) |input| try std.testing.expect(!try value.matches(gpa, input));
    }
}
test "set lookahead supports positive and negative assertions" {
    const Case = struct { pattern: []const u8, yes: []const []const u8, no: []const []const u8 };
    for ([_]Case{
        .{ .pattern = "(?=a)a", .yes = &.{"a"}, .no = &.{ "b", "aa" } },
        .{ .pattern = "(?!a)b", .yes = &.{"b"}, .no = &.{ "a", "ab" } },
        .{ .pattern = "(?!\\S)\\s", .yes = &.{ " ", "\t", "\n" }, .no = &.{ "a", "0" } },
        .{ .pattern = "(?=\\p{L})\\p{L}", .yes = &.{ "é", "猫" }, .no = &.{ "1", "_" } },
        .{ .pattern = "(?![^a])a", .yes = &.{"a"}, .no = &.{ "b", "aa" } },
        .{ .pattern = "(?=.)a", .yes = &.{"a"}, .no = &.{ "\n", "b" } },
        .{ .pattern = "(?i:(?=a))A", .yes = &.{"A"}, .no = &.{"a"} },
        .{ .pattern = "(?!\\S)", .yes = &.{""}, .no = &.{"a"} },
        .{ .pattern = "(?=\\S)", .yes = &.{}, .no = &.{ "", "a" } },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        for (case.yes) |input| try std.testing.expect(try value.matches(gpa, input));
        for (case.no) |input| try std.testing.expect(!try value.matches(gpa, input));
    }
}
test "set lookahead compiles Qwen pre-tokenizer pattern and returns spans" {
    const pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    try std.testing.expect(try value.matches(gpa, "hello"));
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const Case = struct { input: []const u8, spans: []const [2]usize };
    for ([_]Case{
        .{ .input = "a b", .spans = &.{ .{ 0, 1 }, .{ 1, 3 } } },
        .{ .input = "a  b", .spans = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 4 } } },
        .{ .input = "a   ", .spans = &.{ .{ 0, 1 }, .{ 1, 4 } } },
        .{ .input = "a \n b", .spans = &.{ .{ 0, 1 }, .{ 1, 3 }, .{ 3, 5 } } },
        .{ .input = "a\n b", .spans = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 4 } } },
        .{ .input = "a\r\n \r\nb", .spans = &.{ .{ 0, 1 }, .{ 1, 6 }, .{ 6, 7 } } },
        .{ .input = "hello!  world", .spans = &.{ .{ 0, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 13 } } },
        .{ .input = "'s 'S 'ſ 're 'll", .spans = &.{ .{ 0, 2 }, .{ 2, 4 }, .{ 4, 5 }, .{ 5, 7 }, .{ 7, 9 }, .{ 9, 11 }, .{ 11, 13 }, .{ 13, 15 }, .{ 15, 17 } } },
    }) |case| {
        var offset: usize = 0;
        for (case.spans) |span| {
            const match = (try workspace.find(case.input, offset)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(span[0], match.start);
            try std.testing.expectEqual(span[1], match.end);
            offset = match.end;
        }
        try std.testing.expectEqual(case.input.len, offset);
    }
}
test "set lookahead decodes multi-byte runes in the backtracking workspace" {
    var value = try regex.Regex.init(gpa, "\\p{L}+(?!\\p{L})", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const single = (try workspace.find("é1", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), single.start);
    try std.testing.expectEqual(@as(usize, 2), single.end);
    const whole = (try workspace.find("éé", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), whole.start);
    try std.testing.expectEqual(@as(usize, 4), whole.end);
}
test "UCP Perl space matches Unicode White_Space" {
    const ucp = regex.Limits{ .unicode_perl_space = true };
    var space = try regex.Regex.init(gpa, "\\s+", ucp);
    defer space.deinit();
    for ([_][]const u8{ " ", "\t", "\u{0085}", "\u{00A0}", "\u{1680}", "\u{2000}", "\u{2028}", "\u{202F}", "\u{205F}", "\u{3000}" }) |input|
        try std.testing.expect(try space.matches(gpa, input));
    try std.testing.expect(!try space.matches(gpa, "a"));

    var non_space = try regex.Regex.init(gpa, "\\S+", ucp);
    defer non_space.deinit();
    try std.testing.expect(try non_space.matches(gpa, "a"));
    try std.testing.expect(!try non_space.matches(gpa, "\u{00A0}"));

    // In-class and complemented forms use the same UCP set.
    var class_space = try regex.Regex.init(gpa, "[\\s]+", ucp);
    defer class_space.deinit();
    try std.testing.expect(try class_space.matches(gpa, "\u{00A0}"));
    var negated_non_space = try regex.Regex.init(gpa, "[^\\S]+", ucp);
    defer negated_non_space.deinit();
    try std.testing.expect(try negated_non_space.matches(gpa, "\u{00A0}"));

    // The default remains ASCII-only.
    var ascii_space = try regex.Regex.init(gpa, "\\s+", .{});
    defer ascii_space.deinit();
    try std.testing.expect(try ascii_space.matches(gpa, " "));
    try std.testing.expect(!try ascii_space.matches(gpa, "\u{00A0}"));
}
test "UCP Qwen pre-tokenizer matches PCRE2 on Unicode whitespace" {
    const pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
    const ucp = regex.Limits{ .unicode_perl_space = true };
    var value = try regex.Regex.init(gpa, pattern, ucp);
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, ucp);
    defer workspace.deinit();
    const Case = struct { input: []const u8, spans: []const [2]usize };
    for ([_]Case{
        .{ .input = "a\u{00A0}!", .spans = &.{ .{ 0, 1 }, .{ 1, 3 }, .{ 3, 4 } } },
        .{ .input = "a\u{3000}!", .spans = &.{ .{ 0, 1 }, .{ 1, 4 }, .{ 4, 5 } } },
        .{ .input = "a\u{00A0}  b", .spans = &.{ .{ 0, 1 }, .{ 1, 4 }, .{ 4, 6 } } },
        .{ .input = "a\u{00A0} b", .spans = &.{ .{ 0, 1 }, .{ 1, 3 }, .{ 3, 5 } } },
        .{ .input = "a\u{00A0}\u{00A0} b", .spans = &.{ .{ 0, 1 }, .{ 1, 5 }, .{ 5, 7 } } },
        .{ .input = "a\u{3000} b", .spans = &.{ .{ 0, 1 }, .{ 1, 4 }, .{ 4, 6 } } },
        .{ .input = "a\u{00A0}", .spans = &.{ .{ 0, 1 }, .{ 1, 3 } } },
        .{ .input = "a\u{00A0}b", .spans = &.{ .{ 0, 1 }, .{ 1, 4 } } },
    }) |case| {
        var offset: usize = 0;
        for (case.spans) |span| {
            const match = (try workspace.find(case.input, offset)) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(span[0], match.start);
            try std.testing.expectEqual(span[1], match.end);
            offset = match.end;
        }
        try std.testing.expectEqual(case.input.len, offset);
    }
}
test "gRPC xDS safe regex rejects invalid syntax and bounds nested repetitions" {
    for ([_][]const u8{ "(", "[a-z", "[z-a]", "a**", "(?=", "(?=[a-z)", "(?i-)a", "(?i)*", "{1}", "a{1}{2}", "\\p{Unknown}", "\\x{110000}", "a{2,1}", "a{1001}", "[a-\\d]", "[\\b]", "\\" }) |pattern| try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, pattern, .{}));
    try std.testing.expectError(error.RegexLimitExceeded, regex.Regex.init(gpa, "abcdef", .{ .max_pattern_bytes = 5 }));
    try std.testing.expectError(error.RegexLimitExceeded, regex.Regex.init(gpa, "a{5}", .{ .max_repeat = 4 }));
    try std.testing.expectError(error.RegexLimitExceeded, regex.Regex.init(gpa, "(a{100}){100}", .{ .max_instructions = 64 }));
    try std.testing.expectError(error.RegexLimitExceeded, regex.Regex.init(gpa, "(((a)))", .{ .max_depth = 2 }));
}
test "gRPC xDS safe regex keeps adversarial matching linear and rolls back allocation failures" {
    const pattern = "(?:a|aa)*b";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    const input = try gpa.alloc(u8, 8192);
    defer gpa.free(input);
    @memset(input, 'a');
    try std.testing.expect(!workspace.matches(value.program, input));
    try std.testing.expect(workspace.stats.states_visited <= value.program.instructions.len * (input.len + 1));
    input[input.len - 1] = 'b';
    try std.testing.expect(workspace.matches(value.program, input));
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var compiled = try regex.Regex.init(allocator, "(?i:[a-z]+)|\\p{Greek}{1,3}", .{});
            defer compiled.deinit();
            try std.testing.expect(try compiled.matches(allocator, "K"));
        }
    };
    try std.testing.checkAllAllocationFailures(gpa, Harness.run, .{});
}

test "control and octal escapes" {
    const Case = struct { pattern: []const u8, yes: []const []const u8, no: []const []const u8 };
    for ([_]Case{
        .{ .pattern = "\\cA", .yes = &.{"\x01"}, .no = &.{ "A", "\x02" } },
        .{ .pattern = "\\c?", .yes = &.{"\x7f"}, .no = &.{ "?", "\x1f" } },
        .{ .pattern = "[\\cA-\\cC]+", .yes = &.{"\x01\x02\x03"}, .no = &.{ "\x04", "ABC" } },
        .{ .pattern = "\\o{101}", .yes = &.{"A"}, .no = &.{ "a", "B" } },
        .{ .pattern = "\\o{777}", .yes = &.{"\u{1ff}"}, .no = &.{"A"} },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        for (case.yes) |input| try std.testing.expect(try value.matches(gpa, input));
        for (case.no) |input| try std.testing.expect(!try value.matches(gpa, input));
    }
    for ([_][]const u8{ "\\o{8}", "\\o{}", "\\o{7777777}", "\\c", "\\c\u{00e9}" }) |pattern| {
        try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, pattern, .{}));
    }
}

test "Unicode 16 scripts missing from RE2 tables" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "\\p{Script=Garay}", .input = "\u{10d40}", .matches = true },
        .{ .pattern = "\\p{sc=Garay}", .input = "\u{10d40}", .matches = true },
        .{ .pattern = "\\p{sc=Gara}", .input = "\u{10d40}", .matches = true },
        .{ .pattern = "\\p{Garay}", .input = "\u{10d40}", .matches = true },
        .{ .pattern = "\\p{IsGaray}", .input = "\u{10d40}", .matches = true },
        .{ .pattern = "\\p{scx=Garay}", .input = "\u{10d40}", .matches = true },
        .{ .pattern = "\\p{Script=Garay}", .input = "a", .matches = false },
        .{ .pattern = "\\p{Script=Gurung_Khema}", .input = "\u{16100}", .matches = true },
        .{ .pattern = "\\p{Script=Kirat_Rai}", .input = "\u{16d40}", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}
