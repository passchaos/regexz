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
    for ([_][]const u8{ " ", "\t", "\u{0085}", "\u{00A0}", "\u{1680}", "\u{180E}", "\u{2000}", "\u{2028}", "\u{202F}", "\u{205F}", "\u{3000}" }) |input|
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
    for ([_][]const u8{ "(", "[a-z", "[z-a]", "a**", "(?=", "(?=[a-z)", "(?i-)a", "(?i)*", "{1}", "a{1}{2}", "\\p{Unknown}", "\\x{110000}", "a{2,1}", "a{1001}", "[a-\\d]", "\\" }) |pattern| try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, pattern, .{}));
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

test "ASCII property" {
    const Case = struct { pattern: []const u8, yes: []const []const u8, no: []const []const u8 };
    for ([_]Case{
        .{ .pattern = "\\p{ASCII}+", .yes = &.{ "abc", "a b" }, .no = &.{ "\u{00e9}", "\u{732b}" } },
        .{ .pattern = "\\P{ASCII}", .yes = &.{ "\u{00e9}", "\u{732b}" }, .no = &.{ "a", "abc" } },
        .{ .pattern = "[\\p{ASCII}&&[a-z]]+", .yes = &.{"abc"}, .no = &.{ "ABC", "\u{00e9}" } },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        for (case.yes) |input| try std.testing.expect(try value.matches(gpa, input));
        for (case.no) |input| try std.testing.expect(!try value.matches(gpa, input));
    }
}

test "Assigned and unassigned properties" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "\\p{Cn}", .input = "\u{0378}", .matches = true },
        .{ .pattern = "\\p{Cn}", .input = "a", .matches = false },
        .{ .pattern = "\\p{C}", .input = "\u{0378}", .matches = true },
        .{ .pattern = "\\p{Assigned}", .input = "a", .matches = true },
        .{ .pattern = "\\p{Assigned}", .input = "\u{0378}", .matches = false },
        .{ .pattern = "\\P{Assigned}", .input = "\u{0378}", .matches = true },
        .{ .pattern = "\\P{Assigned}", .input = "a", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "Unicode 17 scripts missing from RE2 tables" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "\\p{Script=Sidetic}", .input = "\u{10940}", .matches = true },
        .{ .pattern = "\\p{sc=Sidetic}", .input = "\u{10959}", .matches = true },
        .{ .pattern = "\\p{Sidetic}", .input = "\u{10940}", .matches = true },
        .{ .pattern = "\\p{Script=Sidetic}", .input = "\u{10960}", .matches = false },
        .{ .pattern = "\\p{Script=Tolong_Siki}", .input = "\u{11db0}", .matches = true },
        .{ .pattern = "\\p{scx=Tolong_Siki}", .input = "\u{11de9}", .matches = true },
        .{ .pattern = "\\p{Script=Tolong_Siki}", .input = "\u{11ddc}", .matches = false },
        .{ .pattern = "\\p{Script=Beria_Erfe}", .input = "\u{16ea0}", .matches = true },
        .{ .pattern = "\\p{sc=Beria_Erfe}", .input = "\u{16ed3}", .matches = true },
        .{ .pattern = "\\p{Script=Beria_Erfe}", .input = "\u{16eba}", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "Unicode 17 case folding" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?i)\u{16ea0}", .input = "\u{16ebb}", .matches = true },
        .{ .pattern = "(?i)\u{16ebb}", .input = "\u{16ea0}", .matches = true },
        .{ .pattern = "(?i)\u{16ea0}", .input = "\u{16ea1}", .matches = false },
        .{ .pattern = "(?i)\u{16ea0}", .input = "A", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "Unicode 16 case folding" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?i)\u{10d50}", .input = "\u{10d70}", .matches = true },
        .{ .pattern = "(?i)\u{10d70}", .input = "\u{10d50}", .matches = true },
        .{ .pattern = "(?i)\u{10d50}", .input = "\u{10d51}", .matches = false },
        .{ .pattern = "(?i)\u{10d50}", .input = "A", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "option reset and start-up directives" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?i)a(?^)b", .input = "Ab", .matches = true },
        .{ .pattern = "(?i)a(?^)b", .input = "AB", .matches = false },
        .{ .pattern = "(?i)(?^i)a", .input = "A", .matches = true },
        .{ .pattern = "(?i)(?^)a", .input = "A", .matches = false },
        .{ .pattern = "(*NO_START_OPT)(?i)a", .input = "A", .matches = true },
        .{ .pattern = "(*NO_AUTO_POSSESS)a+", .input = "aaa", .matches = true },
        .{ .pattern = "(*NO_DOTSTAR_ANCHOR)a", .input = "a", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?^-i)a", .{}));
}

test "extended-more classes and ASCII option letters" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?xx)[ a ]", .input = "a", .matches = true },
        .{ .pattern = "(?xx)[ a ]", .input = " ", .matches = false },
        .{ .pattern = "(?xx)[ a - z ]+", .input = "abc", .matches = true },
        .{ .pattern = "(?xx)[ a - z ]+", .input = "A", .matches = false },
        .{ .pattern = "(?xx)[\\ ]", .input = " ", .matches = true },
        .{ .pattern = "(?xx:[ a ])", .input = "a", .matches = true },
        .{ .pattern = "[ a ]", .input = " ", .matches = true },
        .{ .pattern = "(?aD)\\d", .input = "\u{0663}", .matches = false },
        .{ .pattern = "(?aD)\\d", .input = "3", .matches = true },
        .{ .pattern = "(?aD:\\d)", .input = "3", .matches = true },
        .{ .pattern = "(?aD)(?-aD)\\d", .input = "\u{0663}", .matches = true },
        .{ .pattern = "(?aS)\\s", .input = "\u{3000}", .matches = false },
        .{ .pattern = "(?aS)\\s", .input = " ", .matches = true },
        .{ .pattern = "(?aW)\\w", .input = "\u{00e9}", .matches = false },
        .{ .pattern = "(?aW)\\w", .input = "a", .matches = true },
        .{ .pattern = "(?a)\\w", .input = "\u{00e9}", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{ .unicode_perl_classes = true });
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "caseless restrict folds only ASCII" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?i)k", .input = "\u{212a}", .matches = true },
        .{ .pattern = "(?ir)k", .input = "\u{212a}", .matches = false },
        .{ .pattern = "(?ir)k", .input = "K", .matches = true },
        .{ .pattern = "(?ir:k)", .input = "K", .matches = true },
        .{ .pattern = "(?i)s", .input = "\u{017f}", .matches = true },
        .{ .pattern = "(?ir)s", .input = "\u{017f}", .matches = false },
        .{ .pattern = "(?i)\u{00e9}", .input = "\u{00c9}", .matches = true },
        .{ .pattern = "(?ir)\u{00e9}", .input = "\u{00c9}", .matches = false },
        .{ .pattern = "(?i)[a-z]", .input = "\u{212a}", .matches = true },
        .{ .pattern = "(?ir)[a-z]", .input = "\u{212a}", .matches = false },
        .{ .pattern = "(?ir)[a-z]", .input = "A", .matches = true },
        .{ .pattern = "(?ir)(?^i)k", .input = "\u{212a}", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "VERSION condition compares the feature level" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?(VERSION>=10.4)yes|no)", .input = "yes", .matches = true },
        .{ .pattern = "(?(VERSION>=10.4)yes|no)", .input = "no", .matches = false },
        .{ .pattern = "(?(VERSION>=10.45)yes|no)", .input = "yes", .matches = true },
        .{ .pattern = "(?(VERSION>=10.46)yes|no)", .input = "no", .matches = true },
        .{ .pattern = "(?(VERSION=10.45)yes|no)", .input = "yes", .matches = true },
        .{ .pattern = "(?(VERSION=10.4)yes|no)", .input = "no", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "(?(VERSION<10.45)yes|no)", .{}));
}

test "POSIX classes follow PCRE2 UCP replacements" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "[[:alpha:]]", .input = "\u{00e9}", .matches = true },
        .{ .pattern = "[[:alpha:]]", .input = "\u{732b}", .matches = true },
        .{ .pattern = "[[:alpha:]]", .input = "1", .matches = false },
        .{ .pattern = "[[:alnum:]]", .input = "\u{0663}", .matches = true },
        .{ .pattern = "[[:digit:]]", .input = "\u{0663}", .matches = true },
        .{ .pattern = "(?aT)[[:digit:]]", .input = "\u{0663}", .matches = false },
        .{ .pattern = "(?aP)[[:digit:]]", .input = "\u{0663}", .matches = false },
        .{ .pattern = "(?aP)[[:alpha:]]", .input = "\u{00e9}", .matches = false },
        .{ .pattern = "[[:lower:]]", .input = "\u{00e9}", .matches = true },
        .{ .pattern = "[[:upper:]]", .input = "\u{00c9}", .matches = true },
        .{ .pattern = "[[:word:]]", .input = "\u{732b}", .matches = true },
        .{ .pattern = "[[:space:]]", .input = "\u{3000}", .matches = true },
        .{ .pattern = "[[:blank:]]", .input = "\u{00a0}", .matches = true },
        .{ .pattern = "[[:graph:]]", .input = "\u{732b}", .matches = true },
        .{ .pattern = "[[:graph:]]", .input = "\u{061c}", .matches = false },
        .{ .pattern = "[[:print:]]", .input = " ", .matches = true },
        .{ .pattern = "[[:print:]]", .input = "\u{732b}", .matches = true },
        .{ .pattern = "[[:punct:]]", .input = "!", .matches = true },
        .{ .pattern = "[[:punct:]]", .input = "$", .matches = true },
        .{ .pattern = "[[:punct:]]", .input = "\u{00a1}", .matches = true },
        .{ .pattern = "[[:xdigit:]]", .input = "A", .matches = true },
        .{ .pattern = "[[:xdigit:]]", .input = "\u{ff21}", .matches = true },
        .{ .pattern = "[[:xdigit:]]", .input = "G", .matches = false },
        .{ .pattern = "(?aT)[[:xdigit:]]", .input = "\u{ff21}", .matches = false },
        .{ .pattern = "[[:^alpha:]]", .input = "1", .matches = true },
        .{ .pattern = "[[:ascii:]]", .input = "\u{00e9}", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{ .unicode_perl_classes = true });
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
    // Without UCP the POSIX classes stay ASCII.
    var ascii_only = try regex.Regex.init(gpa, "[[:alpha:]]", .{});
    defer ascii_only.deinit();
    try std.testing.expect(!try ascii_only.matches(gpa, "\u{00e9}"));
}

test "ASCII word option affects UCP word boundaries" {
    var ucp = try regex.Regex.init(gpa, "\\b\u{00e9}", .{ .unicode_perl_classes = true });
    defer ucp.deinit();
    try std.testing.expect(try ucp.matches(gpa, "\u{00e9}"));
    var ascii = try regex.Regex.init(gpa, "(?aW)\\b\u{00e9}", .{ .unicode_perl_classes = true });
    defer ascii.deinit();
    try std.testing.expect(!try ascii.matches(gpa, "\u{00e9}"));
    var non_boundary = try regex.Regex.init(gpa, "(?aW)\\B\u{00e9}", .{ .unicode_perl_classes = true });
    defer non_boundary.deinit();
    try std.testing.expect(try non_boundary.matches(gpa, "\u{00e9}"));
}

test "ASCII digit options are scoped to Perl or POSIX digit" {
    var perl_digit = try regex.Regex.init(gpa, "(?aD)\\d", .{ .unicode_perl_classes = true });
    defer perl_digit.deinit();
    try std.testing.expect(!try perl_digit.matches(gpa, "\u{0663}"));
    var perl_posix = try regex.Regex.init(gpa, "(?aD)[[:digit:]]", .{ .unicode_perl_classes = true });
    defer perl_posix.deinit();
    try std.testing.expect(try perl_posix.matches(gpa, "\u{0663}"));
    var posix_digit = try regex.Regex.init(gpa, "(?aT)[[:digit:]]", .{ .unicode_perl_classes = true });
    defer posix_digit.deinit();
    try std.testing.expect(!try posix_digit.matches(gpa, "\u{0663}"));
    var posix_perl = try regex.Regex.init(gpa, "(?aT)\\d", .{ .unicode_perl_classes = true });
    defer posix_perl.deinit();
    try std.testing.expect(try posix_perl.matches(gpa, "\u{0663}"));
}

test "Bidi_Class properties" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "\\p{Bidi_Class:AL}", .input = "\u{0627}", .matches = true },
        .{ .pattern = "\\p{Bidi_Class:AL}", .input = "A", .matches = false },
        .{ .pattern = "\\p{BC:R}", .input = "\u{05d0}", .matches = true },
        .{ .pattern = "\\p{bc:EN}", .input = "0", .matches = true },
        .{ .pattern = "\\p{bc:EN}", .input = "A", .matches = false },
        .{ .pattern = "\\P{Bidi_Class:L}", .input = "\u{0627}", .matches = true },
        .{ .pattern = "\\P{Bidi_Class:L}", .input = "A", .matches = false },
        .{ .pattern = "\\p{Bidi_Class:WS}", .input = " ", .matches = true },
        .{ .pattern = "\\p{Bi-di class = Al}", .input = "\u{0627}", .matches = true },
        .{ .pattern = "\\p{BC:NSM}", .input = "\u{0300}", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
    try std.testing.expectError(error.InvalidRegex, regex.Regex.init(gpa, "\\p{BC:XX}", .{}));
}

test "unbounded assertion repetition is capped" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(?=a)+a", .input = "a", .matches = true },
        .{ .pattern = "(?=a)*a", .input = "a", .matches = true },
        .{ .pattern = "(?=a){2,}a", .input = "a", .matches = true },
        .{ .pattern = "(?=b)+a", .input = "a", .matches = false },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "pattern resource limit directives" {
    const runaway = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaac";
    var lowered = try regex.Regex.init(gpa, "(*LIMIT_MATCH=50)(a+)+b\\1", .{ .max_execution_steps = 10_000_000 });
    defer lowered.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, lowered.matches(gpa, runaway));

    // A caller limit below the pattern's cap still wins.
    var caller = try regex.Regex.init(gpa, "(*LIMIT_MATCH=1000000)(a+)+b\\1", .{ .max_execution_steps = 40 });
    defer caller.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, caller.matches(gpa, runaway));

    // Repeated settings take the lower value.
    var repeated = try regex.Regex.init(gpa, "(*LIMIT_MATCH=100000)(*LIMIT_MATCH=30)(a+)+b\\1", .{ .max_execution_steps = 10_000_000 });
    defer repeated.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, repeated.matches(gpa, runaway));

    // Depth and heap caps.
    var depth = try regex.Regex.init(gpa, "(*LIMIT_DEPTH=2)(a(?1)?b)", .{ .max_recursion_depth = 100 });
    defer depth.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, depth.matches(gpa, "aaabbb"));
    var heap = try regex.Regex.init(gpa, "(*LIMIT_HEAP=1)(a+)+b\\1", .{ .max_backtrack_choices = 1_000_000 });
    defer heap.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, heap.matches(gpa, runaway));
}

test "backspace escape inside character classes" {
    var value = try regex.Regex.init(gpa, "[\\b]", .{});
    defer value.deinit();
    try std.testing.expect(try value.matches(gpa, "\x08"));
    try std.testing.expect(!try value.matches(gpa, "b"));
    var mixed = try regex.Regex.init(gpa, "[a\\b]", .{});
    defer mixed.deinit();
    try std.testing.expect(try mixed.matches(gpa, "\x08"));
    try std.testing.expect(try mixed.matches(gpa, "a"));
}

test "Turkish casing" {
    const Case = struct { pattern: []const u8, input: []const u8, matches: bool };
    for ([_]Case{
        .{ .pattern = "(*TURKISH_CASING)(?i)i", .input = "\u{0130}", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)i", .input = "I", .matches = false },
        .{ .pattern = "(*TURKISH_CASING)(?i)I", .input = "\u{0131}", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)I", .input = "i", .matches = false },
        .{ .pattern = "(*TURKISH_CASING)(?i)\u{0130}", .input = "i", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)\u{0131}", .input = "I", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)[a-z]", .input = "\u{0130}", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)[a-z]", .input = "I", .matches = false },
        .{ .pattern = "(*TURKISH_CASING)(?i)[A-Z]", .input = "\u{0131}", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)[A-Z]", .input = "i", .matches = false },
        .{ .pattern = "(*TURKISH_CASING)(?i)\u{00e9}", .input = "\u{00c9}", .matches = true },
        .{ .pattern = "(?i)i", .input = "I", .matches = true },
        .{ .pattern = "(?i)i", .input = "\u{0130}", .matches = false },
        .{ .pattern = "(*TURKISH_CASING)(?i)(i)\\1", .input = "i\u{0130}", .matches = true },
        .{ .pattern = "(*TURKISH_CASING)(?i)(i)\\1", .input = "iI", .matches = false },
        .{ .pattern = "(*TURKISH_CASING)(?i)(I)\\1", .input = "I\u{0131}", .matches = true },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }
}

test "literal alternation start prefilter" {
    var value = try regex.Regex.init(gpa, "(?:sunday|saturday|september)", .{});
    defer value.deinit();
    try std.testing.expect(value.program.start_literals != null);
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect((try workspace.find("xx symbols yy", 0)) == null);
    const first = (try workspace.find("xx sunday yy", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), first.start);
    try std.testing.expectEqual(@as(usize, 9), first.end);
    const second = (try workspace.find("september and saturday", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), second.start);
    try std.testing.expectEqual(@as(usize, 9), second.end);
    const third = (try workspace.find("september and saturday", 9)).?;
    try std.testing.expectEqual(@as(usize, 14), third.start);
    try std.testing.expectEqual(@as(usize, 22), third.end);

    // Concatenated prefixes are extracted for a literal prefix plus alternation.
    var prefixed = try regex.Regex.init(gpa, "foo(?:bar|baz)", .{});
    defer prefixed.deinit();
    try std.testing.expect(prefixed.program.start_literals != null);

    // Patterns that can start with a class do not qualify.
    var classy = try regex.Regex.init(gpa, "[a-z]+(?:foo|bar)", .{});
    defer classy.deinit();
    try std.testing.expect(classy.program.start_literals == null);
}

test "wide start alternation absence filter" {
    const pattern = "(?:alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|juliet|kilo|lima|mike|november|oscar|papa|quebec|romeo|sierra|tango|uniform|victor|whiskey|xray)";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    try std.testing.expectEqual(@as(usize, 24), value.program.start_literals.?.len);
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.pair_filter != null);
    try std.testing.expect((try workspace.find("xx yy zz xyzzy", 0)) == null);
    try std.testing.expect((try workspace.find("a brav hote", 0)) == null);
    const found = (try workspace.find("yy charlie zz", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 10), found.end);

    // A repeated alternation contributes only its first-byte prefix: the
    // extracted literals must not be combined with the text after the loop.
    var looped = try regex.Regex.init(gpa, "(?:ab|ac)+de", .{});
    defer looped.deinit();
    var looped_workspace = try regex.ReplaceWorkspace.init(gpa, looped.program, .{});
    defer looped_workspace.deinit();
    const loop_match = (try looped_workspace.find("xx ababde yy", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), loop_match.start);
    try std.testing.expectEqual(@as(usize, 9), loop_match.end);
}

test "case-folded literal absence filter" {
    var value = try regex.Regex.init(gpa, "(?i)strasse", .{});
    defer value.deinit();
    try std.testing.expect(value.program.caseless_literal != null);
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fold_filter != null);
    try std.testing.expect((try workspace.find("she sells sea shells", 0)) == null);
    const upper = (try workspace.find("xx STRASSE yy", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), upper.start);
    try std.testing.expectEqual(@as(usize, 10), upper.end);
    // Simple Unicode folding: U+017F LATIN SMALL LETTER LONG S folds to `s`.
    const long_s = (try workspace.find("xx \u{017F}tra\u{017F}\u{017F}e yy", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), long_s.start);
    // Three 2-byte long-s runes plus four ASCII bytes.
    try std.testing.expectEqual(@as(usize, 13), long_s.end);

    // The rarest pair may sit inside the literal; hits must map back to the
    // candidate match start.
    var hello = try regex.Regex.init(gpa, "(?i)hello", .{});
    defer hello.deinit();
    var hello_workspace = try regex.ReplaceWorkspace.init(gpa, hello.program, .{});
    defer hello_workspace.deinit();
    const found = (try hello_workspace.find("say HELLO!", 0)).?;
    try std.testing.expectEqual(@as(usize, 4), found.start);
    try std.testing.expectEqual(@as(usize, 9), found.end);
}

test "non-ASCII set run scan" {
    var value = try regex.Regex.init(gpa, "\\p{Han}+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.utf8_run != null);
    try std.testing.expect(workspace.simple_set == null);

    // A pure Han run matches from the first rune through the last.
    const han = "abc \u{4f60}\u{597d}\u{4e16}\u{754c} def";
    const first = (try workspace.find(han, 0)).?;
    try std.testing.expectEqual(@as(usize, 4), first.start);
    try std.testing.expectEqual(@as(usize, 16), first.end);
    // A later search resumes past the run.
    try std.testing.expect((try workspace.find(han, 16)) == null);

    // ASCII input skips through the first-byte filter.
    try std.testing.expect((try workspace.find("plain ascii text", 0)) == null);

    // A truncated rune at the end of input is not part of the run.
    const truncated = "xx \u{4f60}\u{597d}"[0..7];
    const partial = (try workspace.find(truncated, 0)).?;
    try std.testing.expectEqual(@as(usize, 3), partial.start);
    try std.testing.expectEqual(@as(usize, 6), partial.end);
}

test "byte escape runs on the DFA and Pike paths" {
    // Capture-free: search DFA byte mode.
    var plain = try regex.Regex.init(gpa, "\\C{4}test", .{});
    defer plain.deinit();
    var plain_workspace = try regex.ReplaceWorkspace.init(gpa, plain.program, .{});
    defer plain_workspace.deinit();
    const plain_match = (try plain_workspace.find("abcxtest", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), plain_match.start);
    try std.testing.expectEqual(@as(usize, 8), plain_match.end);
    try std.testing.expect((try plain_workspace.find("xyztests", 0)) == null);

    // Captures: Pike byte stepping, including mid-rune positions.
    var captured = try regex.Regex.init(gpa, "(\\C\\C)", .{});
    defer captured.deinit();
    var captured_workspace = try regex.ReplaceWorkspace.init(gpa, captured.program, .{});
    defer captured_workspace.deinit();
    const split = (try captured_workspace.find("\u{4f60}", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), split.start);
    try std.testing.expectEqual(@as(usize, 2), split.end);

    var rune_after = try regex.Regex.init(gpa, "a(\\C)b", .{});
    defer rune_after.deinit();
    var rune_workspace = try regex.ReplaceWorkspace.init(gpa, rune_after.program, .{});
    defer rune_workspace.deinit();
    // A two-byte rune between the literals cannot satisfy a single \C.
    try std.testing.expect((try rune_workspace.find("a\u{00e9}b", 0)) == null);
    const ascii = (try rune_workspace.find("axb", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), ascii.end);
}

test "multi-rune loops do not skip candidate starts" {
    const cases = [_]struct { pattern: []const u8, input: []const u8, span: [2]usize }{
        .{ .pattern = "(?:ab)*b+", .input = "ab", .span = .{ 1, 2 } },
        .{ .pattern = "(?:ab)*b+", .input = "aab", .span = .{ 2, 3 } },
        .{ .pattern = "(?:ab)*b+", .input = "xxab", .span = .{ 3, 4 } },
        .{ .pattern = "(?:ab)*c", .input = "ababc", .span = .{ 0, 5 } },
        .{ .pattern = "a*b", .input = "c aab", .span = .{ 2, 5 } },
        .{ .pattern = ".*foo", .input = "x\nfoo", .span = .{ 2, 5 } },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        const found = (try workspace.find(case.input, 0)).?;
        try std.testing.expectEqual(case.span[0], found.start);
        try std.testing.expectEqual(case.span[1], found.end);
    }
}
test "set loop full match fast path" {
    var value = try regex.Regex.init(gpa, "(?:[a-z0-9]+[ \\n])+", .{});
    defer value.deinit();
    const cases = [_]struct { input: []const u8, matches: bool }{
        .{ .input = "", .matches = false },
        .{ .input = "abc ", .matches = true },
        .{ .input = "abc def ", .matches = true },
        .{ .input = "abc def\nghi ", .matches = true },
        .{ .input = "abc", .matches = false },
        .{ .input = " abc ", .matches = false },
        .{ .input = "abc  ", .matches = false },
        .{ .input = "abc \n", .matches = false },
        .{ .input = "abc d", .matches = false },
        .{ .input = "abc \u{4f60}", .matches = false },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case.matches, try value.matches(gpa, case.input));
    }

    // Overlapping sets do not take the fast path; the engine result stands.
    var overlap = try regex.Regex.init(gpa, "(?:[a-z]+[a-z])+", .{});
    defer overlap.deinit();
    try std.testing.expect(try overlap.matches(gpa, "abc"));
    // Greedy A+ takes both bytes, then backtracks one to let B match.
    try std.testing.expect(try overlap.matches(gpa, "ab"));
}

test "dominant alternation branch scan" {
    const qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
    var value = try regex.Regex.init(gpa, qwen, .{});
    defer value.deinit();
    try std.testing.expect(value.program.fast_branch != null);
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_branch != null);

    const han = "\u{4f60}\u{597d}\u{4e16}\u{754c}";
    const first = (try workspace.find(han, 0)).?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 12), first.end);

    // A leading quote belongs to the earlier literal branch, so the run
    // branch must not swallow it.
    const quote = (try workspace.find("'s hello", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), quote.start);
    try std.testing.expectEqual(@as(usize, 2), quote.end);
    const after_quote = (try workspace.find("'x abc", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), after_quote.start);
    try std.testing.expectEqual(@as(usize, 2), after_quote.end);

    // The optional prefix is greedy: the prefix rune joins the following run.
    var greedy = try regex.Regex.init(gpa, "[0-9]?[a-z]+|\\s+", .{});
    defer greedy.deinit();
    var greedy_workspace = try regex.ReplaceWorkspace.init(gpa, greedy.program, .{});
    defer greedy_workspace.deinit();
    const joined = (try greedy_workspace.find("1ab", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), joined.start);
    try std.testing.expectEqual(@as(usize, 3), joined.end);
    // A prefix without a following run falls back to the general engine.
    try std.testing.expect((try greedy_workspace.find("1", 0)) == null);

    // Overlapping prefix and run sets keep the greedy prefix order.
    var overlap = try regex.Regex.init(gpa, "x?[a-z]+|\\s+", .{});
    defer overlap.deinit();
    var overlap_workspace = try regex.ReplaceWorkspace.init(gpa, overlap.program, .{});
    defer overlap_workspace.deinit();
    const xy = (try overlap_workspace.find("xy", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), xy.start);
    try std.testing.expectEqual(@as(usize, 2), xy.end);
}

test "prefix loop requires a full-coverage loop set" {
    // `(b)*` cannot skip `a`, so a fresh start at offset 1 can match even
    // though the scan from offset 0 died later.
    var value = try regex.Regex.init(gpa, "(b)*(a)(?:ab)", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const found = (try workspace.find("aaab", 0)).?;
    try std.testing.expectEqual(@as(usize, 1), found.start);
    try std.testing.expectEqual(@as(usize, 4), found.end);

    // `.*` (dot excludes the newline) still finds the match after it.
    var dot = try regex.Regex.init(gpa, ".*foo", .{});
    defer dot.deinit();
    var dot_workspace = try regex.ReplaceWorkspace.init(gpa, dot.program, .{});
    defer dot_workspace.deinit();
    const dot_found = (try dot_workspace.find("x\nfoo", 0)).?;
    try std.testing.expectEqual(@as(usize, 2), dot_found.start);
    try std.testing.expectEqual(@as(usize, 5), dot_found.end);
}

test "line run fast path matches line by line" {
    var value = try regex.Regex.init(gpa, "(?m)^.*$", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.line_run);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{.{ 0, 0 }} },
        .{ .input = "abc", .spans = &.{.{ 0, 3 }} },
        .{ .input = "abc\ndef", .spans = &.{ .{ 0, 3 }, .{ 4, 7 } } },
        .{ .input = "abc\n", .spans = &.{ .{ 0, 3 }, .{ 4, 4 } } },
        .{ .input = "a\r\nb", .spans = &.{ .{ 0, 2 }, .{ 3, 4 } } },
        .{ .input = "\u{4f60}\u{597d}\n\u{4e16}\u{754c}", .spans = &.{ .{ 0, 6 }, .{ 7, 13 } } },
        .{ .input = "\n\n", .spans = &.{ .{ 0, 0 }, .{ 1, 1 }, .{ 2, 2 } } },
    };
    for (cases) |case| {
        var offset: usize = 0;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            if (m.end <= m.start) {
                if (m.start == case.input.len) {
                    offset = case.input.len + 1;
                    continue;
                }
                offset = m.start + 1;
            } else offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }

    // Mid-line search starts jump to the next line start.
    const mid = (try workspace.find("abc\ndef", 1)).?;
    try std.testing.expectEqual(@as(usize, 4), mid.start);
    try std.testing.expectEqual(@as(usize, 7), mid.end);
}

test "delimited run fast path" {
    var value = try regex.Regex.init(gpa, "\"[^\"]*\"", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.delimited_run != null);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{} },
        .{ .input = "\"a\"", .spans = &.{.{ 0, 3 }} },
        .{ .input = "x \"a\" y \"bc\"", .spans = &.{ .{ 2, 5 }, .{ 8, 12 } } },
        .{ .input = "\"\"", .spans = &.{.{ 0, 2 }} },
        .{ .input = "\"unclosed", .spans = &.{} },
        .{ .input = "\u{4f60}\"x\"", .spans = &.{.{ 3, 6 }} },
    };
    for (cases) |case| {
        var offset: usize = 0;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
        // No further match past the last recorded span.
        if (index == case.spans.len and offset <= case.input.len) {
            try std.testing.expect((try workspace.find(case.input, offset)) == null);
        }
    }
}

test "word run fast path matches whole words" {
    var value = try regex.Regex.init(gpa, "\\b\\w+\\b", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.word_run);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{} },
        .{ .input = "hello", .spans = &.{.{ 0, 5 }} },
        .{ .input = "hello world", .spans = &.{ .{ 0, 5 }, .{ 6, 11 } } },
        .{ .input = "a-b", .spans = &.{ .{ 0, 1 }, .{ 2, 3 } } },
        .{ .input = "_x_ 123", .spans = &.{ .{ 0, 3 }, .{ 4, 7 } } },
        .{ .input = "  spaced  ", .spans = &.{.{ 2, 8 }} },
        .{ .input = "caf\u{00e9}", .spans = &.{.{ 0, 3 }} },
        .{ .input = "x", .spans = &.{.{ 0, 1 }} },
    };
    for (cases) |case| {
        var offset: usize = 0;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }

    // A search starting inside a word skips that word.
    const mid = (try workspace.find("hello world", 2)).?;
    try std.testing.expectEqual(@as(usize, 6), mid.start);
    try std.testing.expectEqual(@as(usize, 11), mid.end);
}
