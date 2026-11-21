const std = @import("std");
const regex = @import("../root.zig");
const replace_mod = @import("replace.zig");
const gpa = std.testing.allocator;

/// Unbounded run chains report a distinct kind when the walk fuses following
/// single-byte literals.
fn isUnboundedSequence(kind: replace_mod.FastKind) bool {
    return kind == .unbounded_sequence or kind == .unbounded_sequence_fused;
}
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
test "Qwen tokenizer fast branch scans CJK runs" {
    const pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";
    const limits = regex.Limits{ .unicode_perl_space = true, .max_execution_steps = 16_000_000 };
    const Case = struct { input: []const u8, spans: []const [2]usize };
    for ([_]Case{
        .{ .input = "你", .spans = &.{.{ 0, 3 }} },
        .{ .input = "你好世界", .spans = &.{.{ 0, 12 }} },
        .{ .input = "你好世界这是一个中文分词测试", .spans = &.{.{ 0, 42 }} },
        .{ .input = "你好世界这是一个中文分词测试abcdef", .spans = &.{.{ 0, 48 }} },
        .{ .input = "你好世界Δσabc，def", .spans = &.{ .{ 0, 19 }, .{ 19, 25 } } },
        .{ .input = "你好\xff世界", .spans = &.{ .{ 0, 6 }, .{ 7, 13 } } },
        .{ .input = "\u{3400}\u{3401}abc", .spans = &.{.{ 0, 9 }} },
        .{ .input = "abc你好def", .spans = &.{.{ 0, 12 }} },
        .{ .input = "你好，世界。\n", .spans = &.{ .{ 0, 6 }, .{ 6, 15 }, .{ 15, 19 } } },
        .{ .input = "一二三四五六七八九十一二三四五六七八九十", .spans = &.{.{ 0, 60 }} },
    }) |case| {
        var value = try regex.Regex.init(gpa, pattern, limits);
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
        defer workspace.deinit();
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

test "caseless literal alternation scans folded branches" {
    var value = try regex.Regex.init(gpa, "(?i)alpha|gamma", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .caseless_literal_set);

    try expectFastSpans("(?i)alpha|gamma", "xx ALPHA Gamma yy", &.{ .{ 3, 8 }, .{ 9, 14 } });
    try expectFastSpans("(?i)alpha|gamma", "ALPHABET", &.{.{ 0, 5 }});
    try expectFastSpans("(?i)alpha|gamma", "\u{03B1}\u{03BB}\u{03C6}\u{03B1}", &.{});
    try expectFastSpans("(?i)alpha|gamma", "zzz", &.{});
}

test "caseless alternation with non-ASCII fold peers falls back" {
    // 's' folds with U+017F and 'k' with U+212A; a byte-wise folded scan
    // cannot represent those branches, so the general engine is used.
    var value = try regex.Regex.init(gpa, "(?i)skip|stop", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind != .caseless_literal_set);

    try expectFastSpans("(?i)skip|stop", "SKIP stop", &.{ .{ 0, 4 }, .{ 5, 9 } });
    try expectFastSpans("(?i)ss|aa", "\u{017F}\u{017F} aa", &.{ .{ 0, 4 }, .{ 5, 7 } });
}

test "caseless literal fast path respects case-sensitive scopes" {
    // The whole-pattern caseless-literal scan folds every input byte, so a
    // case-sensitive scope inside the pattern must disable it.
    try expectFastSpans("(?i)a(?-i)b", "aB Ab ab AB", &.{ .{ 3, 5 }, .{ 6, 8 } });
    try expectFastSpans("(?i:ab)c", "ABC ABc", &.{.{ 4, 7 }});
    try expectFastSpans("(?i)a(?^)b", "aB Ab ab AB", &.{ .{ 3, 5 }, .{ 6, 8 } });
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
    try std.testing.expect(workspace.literal_set_pair != null);
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

test "fast branch scans digit and punctuation fallbacks" {
    const qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
    var value = try regex.Regex.init(gpa, qwen, .{});
    defer value.deinit();
    try std.testing.expect(value.program.fast_branch.?.later.len >= 2);
    var reference_program = value.program;
    reference_program.fast_branch = null;
    var reference = try regex.ReplaceWorkspace.init(gpa, reference_program, .{});
    defer reference.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();

    const inputs = [_][]const u8{
        "12345",  "a1b2", "!@#$%^&*()", " !@#", "a !@# b",   "hello, world!",
        "  x",    "\n\n", "a\n\nb",
        "你好 123 !@# x",
        "1",      "!",    " !",         "a!",   "!a",
        // Whitespace tails: newline runs, trailing spaces, lookahead backtracking.
               "  ",
        "a  b",   "a ",   " ",          "\t\t", "a\r\n\r\n", "a \n ",
        " \n\n ", "a\n",  "\n",
        // Non-ASCII punctuation runs take the direct prefix/run-tail scan.
        "你好。\n",
        "。\n",
        "，你好",
        "。",
        "。x",
        "。 \n",
        "a。\n",
    };
    for (inputs) |input| {
        for (0..input.len + 1) |from| {
            const expected = try reference.find(input, from);
            const actual = try workspace.find(input, from);
            try std.testing.expectEqual(expected != null, actual != null);
            if (expected) |match| {
                try std.testing.expectEqual(match.start, actual.?.start);
                try std.testing.expectEqual(match.end, actual.?.end);
            }
        }
    }
}

test "later whitespace plans model lookaround branches" {
    // `A?\s+(?!\S)` is not a pure whitespace branch. The direct plan must
    // leave it to the engine instead of matching the bare run, and a
    // whitespace run that cannot satisfy `\s+(?!\S)` (a single space before
    // text) must fall through instead of matching.
    const patterns = [_][]const u8{
        "\\d+|\\s+(?!\\S)",
        "\\d+|A?\\s+(?!\\S)",
        "\\w+|\\s*[\\r\\n]+",
        "\\w+|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
    };
    const inputs = [_][]const u8{
        " 猫",
        " a ",
        "  ",
        "   x",
        " !",
        " \n",
        "a \n ",
        "a  b",
        "\n\n",
        "x",
        " 猫AA ",
    };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var reference_program = value.program;
        reference_program.fast_branch = null;
        var reference = try regex.ReplaceWorkspace.init(gpa, reference_program, .{});
        defer reference.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        for (inputs) |input| {
            for (0..input.len + 1) |from| {
                const expected = try reference.find(input, from);
                const actual = try workspace.find(input, from);
                try std.testing.expectEqual(expected != null, actual != null);
                if (expected) |match| {
                    try std.testing.expectEqual(match.start, actual.?.start);
                    try std.testing.expectEqual(match.end, actual.?.end);
                }
            }
        }
    }
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

test "literal-run fast path" {
    var value = try regex.Regex.init(gpa, "https?://[^\\s]+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.literal_run != null);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{} },
        .{ .input = "see https://example.com/a and http://x.y", .spans = &.{ .{ 4, 25 }, .{ 30, 40 } } },
        .{ .input = "http://x.y https://z", .spans = &.{ .{ 0, 10 }, .{ 11, 20 } } },
        .{ .input = "httpX://nope https://ok", .spans = &.{.{ 13, 23 }} },
        .{ .input = "https://", .spans = &.{} },
        .{ .input = "https://a", .spans = &.{.{ 0, 9 }} },
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
}

test "literal-run detection rejects an optional literal that overlaps the run" {
    // The optional literal can also belong to the trailing run set, where a
    // greedy scanner would consume the byte the skipped branch needs. The
    // shape falls back to the general search instead of retrying.
    var value = try regex.Regex.init(gpa, "b{1,2}[a-c]+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.literal_run == null);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{} },
        .{ .input = "ab", .spans = &.{} },
        .{ .input = "b2", .spans = &.{} },
        .{ .input = " 1abb2bbc", .spans = &.{ .{ 3, 5 }, .{ 6, 9 } } },
        .{ .input = "xabb2", .spans = &.{.{ 2, 4 }} },
        .{ .input = "abb", .spans = &.{.{ 1, 3 }} },
        .{ .input = "bbc", .spans = &.{.{ 0, 3 }} },
        .{ .input = "bbbc", .spans = &.{.{ 0, 4 }} },
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
}

fn expectFastSpans(pattern: []const u8, input: []const u8, spans: []const [2]usize) !void {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    var offset: usize = 0;
    var index: usize = 0;
    while (offset <= input.len and index < spans.len) : (index += 1) {
        const m = (try workspace.find(input, offset)) orelse break;
        try std.testing.expectEqual(spans[index][0], m.start);
        try std.testing.expectEqual(spans[index][1], m.end);
        offset = m.end;
    }
    try std.testing.expectEqual(spans.len, index);
}

test "word alternation fast path scans boundaries" {
    var value = try regex.Regex.init(gpa, "(?i)\\b(?:get|post|put|delete)\\b", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .word_alternation);

    const pattern = "(?i)\\b(?:get|post|put|delete)\\b";
    try expectFastSpans(pattern, "GET post PUT delete getter", &.{ .{ 0, 3 }, .{ 4, 8 }, .{ 9, 12 }, .{ 13, 19 } });
    try expectFastSpans(pattern, "xget get_ get-get", &.{ .{ 10, 13 }, .{ 14, 17 } });
    try expectFastSpans(pattern, "deleted undelete", &.{});
    // U+017F is a simple-fold peer of `s`, so `poſt` matches `post`.
    try expectFastSpans(pattern, "poſt get", &.{ .{ 0, 5 }, .{ 6, 9 } });
    try expectFastSpans(pattern, "ſet", &.{});
    // A non-ASCII byte is not a word byte under the ASCII assertion.
    try expectFastSpans(pattern, "éget é get", &.{ .{ 2, 5 }, .{ 9, 12 } });

    var strict = try regex.Regex.init(gpa, "\\b(?:get|post)\\b", .{});
    defer strict.deinit();
    var strict_workspace = try regex.ReplaceWorkspace.init(gpa, strict.program, .{});
    defer strict_workspace.deinit();
    try std.testing.expect(strict_workspace.fast_kind == .word_alternation);
    try expectFastSpans("\\b(?:get|post)\\b", "get GET post Post", &.{.{ 0, 3 }});

    // A fold peer in the first two bytes cannot use the pair filter, so the
    // shape is rejected and the general engine matches U+017F.
    var peer = try regex.Regex.init(gpa, "(?i)\\b(?:ask|get)\\b", .{});
    defer peer.deinit();
    var peer_workspace = try regex.ReplaceWorkspace.init(gpa, peer.program, .{});
    defer peer_workspace.deinit();
    try std.testing.expect(peer_workspace.fast_kind != .word_alternation);
    try expectFastSpans("(?i)\\b(?:ask|get)\\b", "aſk get", &.{ .{ 0, 4 }, .{ 5, 8 } });
}

test "email fast path resolves local and domain runs" {
    const pattern = "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .email);

    try expectFastSpans(pattern, "user.name@example.com user@x.org", &.{ .{ 0, 21 }, .{ 22, 32 } });
    try expectFastSpans(pattern, "a@b.co", &.{.{ 0, 6 }});
    try expectFastSpans(pattern, "a@b.c", &.{});
    try expectFastSpans(pattern, "a@b..com", &.{.{ 0, 8 }});
    try expectFastSpans(pattern, "a@b.com.", &.{.{ 0, 7 }});
    try expectFastSpans(pattern, "a@b.com_", &.{});
    try expectFastSpans(pattern, ".a@b.com", &.{.{ 1, 8 }});
    try expectFastSpans(pattern, "a..b@c.com", &.{.{ 0, 10 }});
    try expectFastSpans(pattern, "a@b.c0m", &.{});
    try expectFastSpans(pattern, "a@b.com a@c.org", &.{ .{ 0, 7 }, .{ 8, 15 } });
    try expectFastSpans(pattern, "a@b.com@c.org", &.{.{ 0, 7 }});
    try expectFastSpans(pattern, "a_b@c.d.e.f.gg", &.{.{ 0, 14 }});
    try expectFastSpans(pattern, "éa@b.com", &.{.{ 2, 9 }});
}

test "blank line fast path matches line runs" {
    const pattern = "(?m)^\\s*$";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .blank_lines);

    try expectFastSpans(pattern, "abc\n\n", &.{ .{ 4, 5 }, .{ 5, 5 } });
    try expectFastSpans(pattern, "a\n \n\t\nb", &.{.{ 2, 5 }});
    try expectFastSpans(pattern, " \n \n- x", &.{.{ 0, 3 }});
    try expectFastSpans(pattern, "abc", &.{});
    try expectFastSpans(pattern, "abc\n", &.{.{ 4, 4 }});
    try expectFastSpans(pattern, "", &.{.{ 0, 0 }});
}

test "signed number fast path scans sign and fraction" {
    var value = try regex.Regex.init(gpa, "[+-]?\\d+(?:\\.\\d+)?", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .signed_number);

    try expectFastSpans("[+-]?\\d+(?:\\.\\d+)?", "x=-12.5 y=+3 z=0.25", &.{ .{ 2, 7 }, .{ 10, 12 }, .{ 15, 19 } });
    try expectFastSpans("[+-]?\\d+(?:\\.\\d+)?", "12.", &.{.{ 0, 2 }});
    try expectFastSpans("[+-]?\\d+(?:\\.\\d+)?", ".5", &.{.{ 1, 2 }});
    try expectFastSpans("[+-]?\\d+(?:\\.\\d+)?", "+", &.{});

    var number = try regex.Regex.init(gpa, "-?\\d+(?:\\.\\d+)?", .{});
    defer number.deinit();
    var number_workspace = try regex.ReplaceWorkspace.init(gpa, number.program, .{});
    defer number_workspace.deinit();
    try std.testing.expect(number_workspace.fast_kind == .number);
}

test "float fast path scans exponents" {
    const pattern = "\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .signed_number);

    try expectFastSpans(pattern, "1 1.5 2e10 3.5E-2 4e+7", &.{
        .{ 0, 1 }, .{ 2, 5 }, .{ 6, 10 }, .{ 11, 17 }, .{ 18, 22 },
    });
    // A fraction or exponent without digits is not consumed.
    try expectFastSpans(pattern, "5. 6e 7e+ 8.5.6", &.{
        .{ 0, 1 }, .{ 3, 4 }, .{ 6, 7 }, .{ 10, 13 }, .{ 14, 15 },
    });
    try expectFastSpans(pattern, "1e++5", &.{ .{ 0, 1 }, .{ 4, 5 } });
}

test "line heading fast path matches markdown headings" {
    var value = try regex.Regex.init(gpa, "(?m)^#{1,6} .*$", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .line_heading);

    try expectFastSpans("(?m)^#{1,6} .*$", "# Title\n## Section\ntext\n### Sub\n", &.{ .{ 0, 7 }, .{ 8, 18 }, .{ 24, 31 } });
    try expectFastSpans("(?m)^#{1,6} .*$", "#no space\n# yes\n", &.{.{ 10, 15 }});
    try expectFastSpans("(?m)^#{1,6} .*$", "####### seven\n", &.{});
}

test "unbounded chain accepts a negated-class run" {
    var value = try regex.Regex.init(gpa, "\\w+=\"[^\"]*\"", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(isUnboundedSequence(workspace.fast_kind));

    try expectFastSpans("\\w+=\"[^\"]*\"", "<div id=\"main\" class=\"box\">", &.{ .{ 5, 14 }, .{ 15, 26 } });
    try expectFastSpans("\\w+=\"[^\"]*\"", "a=\"\" b=\"x y\"", &.{ .{ 0, 4 }, .{ 5, 12 } });
}

test "literal alternation expands a common suffix" {
    var value = try regex.Regex.init(gpa, "(?:pre|post)fix", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .literal_multi);

    try expectFastSpans("(?:pre|post)fix", "prefix postfix prefixx", &.{ .{ 0, 6 }, .{ 7, 14 } });
}

test "repeated literal group scans repetitions directly" {
    var value = try regex.Regex.init(gpa, "(?:ab)+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .repeated_literal);

    try expectFastSpans("(?:ab)+", "xx ababab ab yy", &.{ .{ 3, 9 }, .{ 10, 12 } });
    try expectFastSpans("(?:ab)+", "zzz", &.{});
    try expectFastSpans("(?:ab)+", "aba", &.{.{ 0, 2 }});
    try expectFastSpans("(?:aa)+", "aaaaa", &.{.{ 0, 4 }});
}

test "repeated literal group falls back for variable or bounded units" {
    var variable = try regex.Regex.init(gpa, "(?:a+b)+", .{});
    defer variable.deinit();
    var variable_workspace = try regex.ReplaceWorkspace.init(gpa, variable.program, .{});
    defer variable_workspace.deinit();
    try std.testing.expect(variable_workspace.fast_kind != .repeated_literal);

    var bounded = try regex.Regex.init(gpa, "(?:ab){2,}", .{});
    defer bounded.deinit();
    var bounded_workspace = try regex.ReplaceWorkspace.init(gpa, bounded.program, .{});
    defer bounded_workspace.deinit();
    try std.testing.expect(bounded_workspace.fast_kind != .repeated_literal);
}

test "wide distinct-first literal alternation scans pairs" {
    var value = try regex.Regex.init(gpa, "alpha|gamma|epsilon|zeta|theta", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .literal_multi_distinct);

    try expectFastSpans(
        "alpha|gamma|epsilon|zeta|theta",
        "xx theta epsilon gamma zeta alpha yy",
        &.{ .{ 3, 8 }, .{ 9, 16 }, .{ 17, 22 }, .{ 23, 27 }, .{ 28, 33 } },
    );
}

test "single-byte literal alternation scans first bytes only" {
    var value = try regex.Regex.init(gpa, "a|b|c", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .literal_bytes);
    try std.testing.expect(workspace.literal_set_single);

    try expectFastSpans("a|b|c", "xx a b c yy", &.{ .{ 3, 4 }, .{ 5, 6 }, .{ 7, 8 } });
    try expectFastSpans("a|b|c", "zzz", &.{});
    try expectFastSpans("a|b|c", "cab", &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } });
}

test "wide literal alternation reports the matching branch" {
    var value = try regex.Regex.init(gpa, "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|juliet", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .literal_pair);

    try expectFastSpans(
        "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|juliet",
        "xx charlie echo bravo yy",
        &.{ .{ 3, 10 }, .{ 11, 15 }, .{ 16, 21 } },
    );
}

test "bounded sequence handles a trailing optional group" {
    var value = try regex.Regex.init(gpa, "\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .bounded_sequence);

    try expectFastSpans("\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?", "192.168.1.1/24 x 10.0.0.1", &.{ .{ 0, 14 }, .{ 17, 25 } });
    try expectFastSpans("\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?", "1.2.3.4/", &.{.{ 0, 7 }});
    try expectFastSpans("\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?", "1.2.3.4/2", &.{.{ 0, 9 }});
    try expectFastSpans("\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?", "1.2.3.4/123", &.{.{ 0, 10 }});
}

test "bounded loop fast path repeats bounded groups" {
    var value = try regex.Regex.init(gpa, "\\d{1,3}(?:,\\d{3})+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .bounded_loop);

    try expectFastSpans("\\d{1,3}(?:,\\d{3})+", "1,234 12,345,678 999,000", &.{ .{ 0, 5 }, .{ 6, 16 }, .{ 17, 24 } });
    try expectFastSpans("\\d{1,3}(?:,\\d{3})+", "1234", &.{});
    try expectFastSpans("\\d{1,3}(?:,\\d{3})+", "1,23", &.{});
    try expectFastSpans("\\d{1,3}(?:,\\d{3})+", "1,234,56", &.{.{ 0, 5 }});
}

test "escaped delimited fast path honors escapes" {
    const pattern = "\"(?:\\\\.|[^\"\\\\])*\"";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .escaped_delimited);

    try expectFastSpans(pattern, "\"abc\" \"a\\\"b\" \"a\\\\\" x", &.{ .{ 0, 5 }, .{ 6, 12 }, .{ 13, 18 } });
    try expectFastSpans(pattern, "\"abc", &.{});
    try expectFastSpans(pattern, "\"a\\\"", &.{});
    try expectFastSpans(pattern, "\"a\\\nbc", &.{});
    try expectFastSpans(pattern, "\"猫\"", &.{.{ 0, 5 }});
    try expectFastSpans(pattern, "\"a\\\"b\"", &.{.{ 0, 6 }});
    try expectFastSpans(pattern, "x\"a\"y\"b\"", &.{ .{ 1, 4 }, .{ 5, 8 } });
}

test "escaped delimited loop form shares the scanner" {
    const pattern = "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .escaped_delimited);

    try expectFastSpans(pattern, "\"abc\" \"a\\\"b\" \"a\\\\\" x", &.{ .{ 0, 5 }, .{ 6, 12 }, .{ 13, 18 } });
    try expectFastSpans(pattern, "\"abc", &.{});
    try expectFastSpans(pattern, "\"a\\\"", &.{});
    try expectFastSpans(pattern, "\"a\\\nbc", &.{});
    try expectFastSpans(pattern, "\"猫\"", &.{.{ 0, 5 }});
    try expectFastSpans(pattern, "x\"a\"y\"b\"", &.{ .{ 1, 4 }, .{ 5, 8 } });
}

test "line shapes accept whitespace runs" {
    var heading = try regex.Regex.init(gpa, "(?m)^#{1,6}\\s+.*$", .{});
    defer heading.deinit();
    var heading_workspace = try regex.ReplaceWorkspace.init(gpa, heading.program, .{});
    defer heading_workspace.deinit();
    try std.testing.expect(heading_workspace.fast_kind == .line_heading);
    try expectFastSpans("(?m)^#{1,6}\\s+.*$", "# Title\n##  Section\ntext\n###\tSub\n", &.{ .{ 0, 7 }, .{ 8, 19 }, .{ 25, 32 } });
    try expectFastSpans("(?m)^#{1,6}\\s+.*$", "#nospace\n#  ok\n", &.{.{ 9, 14 }});

    var marker = try regex.Regex.init(gpa, "(?m)^\\s*[-*+]\\s+", .{});
    defer marker.deinit();
    var marker_workspace = try regex.ReplaceWorkspace.init(gpa, marker.program, .{});
    defer marker_workspace.deinit();
    try std.testing.expect(marker_workspace.fast_kind == .line_marker);
    try expectFastSpans("(?m)^\\s*[-*+]\\s+", "- a\n  *   b\n\t+ c\nx", &.{ .{ 0, 2 }, .{ 4, 10 }, .{ 12, 15 } });
    try expectFastSpans("(?m)^\\s*[-*+]\\s+", "-\n* x\n", &.{ .{ 0, 2 }, .{ 2, 4 } });
}

test "line marker fast path scans list prefixes" {
    var value = try regex.Regex.init(gpa, "(?m)^\\s*[-*+] ", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .line_marker);

    try expectFastSpans("(?m)^\\s*[-*+] ", "- a\n  * b\n\t+ c\nx", &.{ .{ 0, 2 }, .{ 4, 8 }, .{ 10, 13 } });
    try expectFastSpans("(?m)^\\s*[-*+] ", "text\n# heading\n", &.{});
    try expectFastSpans("(?m)^\\s*[-*+] ", "  - x", &.{.{ 0, 4 }});
    try expectFastSpans("(?m)^\\s*[-*+] ", "a\n\n- x", &.{.{ 2, 5 }});
    try expectFastSpans("(?m)^\\s*[-*+] ", "-", &.{});
    try expectFastSpans("(?m)^\\s*[-*+] ", "-x", &.{});
}

test "bounded-minimum set run scans maximal runs" {
    var value = try regex.Regex.init(gpa, "\\s{2,}", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .set_run_min);

    try expectFastSpans("\\s{2,}", "a  b   c ", &.{ .{ 1, 3 }, .{ 4, 7 } });
    try expectFastSpans("\\s{2,}", "a b", &.{});
    try expectFastSpans("\\s{2,}", "    x", &.{.{ 0, 4 }});
    try expectFastSpans("\\s{3,}", "a  b   c", &.{.{ 4, 7 }});
    try expectFastSpans("\\w{2,}", "a bb ccc", &.{ .{ 2, 4 }, .{ 5, 8 } });
    try expectFastSpans("\\w{2,}", "a b c", &.{});
    // Pair candidates across a 16-byte block boundary.
    try expectFastSpans("\\s{2,}", "aaaaaaaaaaaaaaaa   b", &.{.{ 16, 19 }});
    try expectFastSpans("\\s{2,}", "aaaaaaaaaaaaaaa  b", &.{.{ 15, 17 }});
    // Byte-splat sets (more than four runs) use the same pair scan.
    try expectFastSpans("[acegik]{2,}", "aa cc ee", &.{ .{ 0, 2 }, .{ 3, 5 }, .{ 6, 8 } });
    try expectFastSpans("[acegik]{2,}", "a c e g i k", &.{});
}

test "optional prefix run matches the plain run spans" {
    var value = try regex.Regex.init(gpa, "v?\\w+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .set_run);

    try expectFastSpans("v?\\w+", "v1 2 vv3", &.{ .{ 0, 2 }, .{ 3, 4 }, .{ 5, 8 } });
    try expectFastSpans("v?\\w+", "v v", &.{ .{ 0, 1 }, .{ 2, 3 } });
}

test "unbounded chain handles star runs and single-set elements" {
    var camel = try regex.Regex.init(gpa, "[a-z]+[A-Z][a-z]+", .{});
    defer camel.deinit();
    var camel_workspace = try regex.ReplaceWorkspace.init(gpa, camel.program, .{});
    defer camel_workspace.deinit();
    try std.testing.expect(isUnboundedSequence(camel_workspace.fast_kind));
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "fooBar bazQux x", &.{ .{ 0, 6 }, .{ 7, 13 } });
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "fooB", &.{});
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "aBc", &.{.{ 0, 3 }});
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "fooBARbaz", &.{});
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "xAb", &.{.{ 0, 3 }});
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "aBcDe", &.{.{ 0, 3 }});
    try expectFastSpans("[a-z]+[A-Z][a-z]+", "éFooBar", &.{.{ 3, 8 }});

    var kv = try regex.Regex.init(gpa, "\\w+\\s*=\\s*\\w+", .{});
    defer kv.deinit();
    var kv_workspace = try regex.ReplaceWorkspace.init(gpa, kv.program, .{});
    defer kv_workspace.deinit();
    try std.testing.expect(isUnboundedSequence(kv_workspace.fast_kind));
    try expectFastSpans("\\w+\\s*=\\s*\\w+", "name = value key=value a  =  b", &.{ .{ 0, 12 }, .{ 13, 22 }, .{ 23, 30 } });
    try expectFastSpans("\\w+\\s*=\\s*\\w+", "name value", &.{});
}

test "unbounded chain handles a literal alternation element" {
    var value = try regex.Regex.init(gpa, "\\w+@\\w+\\.(?:com|org|net)", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(isUnboundedSequence(workspace.fast_kind));

    try expectFastSpans("\\w+@\\w+\\.(?:com|org|net)", "user.name@example.com x a@b.org", &.{ .{ 5, 21 }, .{ 24, 31 } });
    try expectFastSpans("\\w+@\\w+\\.(?:com|org|net)", "a@b.net", &.{.{ 0, 7 }});
    try expectFastSpans("\\w+@\\w+\\.(?:com|org|net)", "a@b.io", &.{});
}

test "anchored run fast path matches line ends" {
    var value = try regex.Regex.init(gpa, "(?m)\\w+$", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .anchored);

    try expectFastSpans("(?m)\\w+$", "one two\nthree four\n", &.{ .{ 4, 7 }, .{ 14, 18 } });
    try expectFastSpans("(?m)\\w+$", "trailing space \nnext", &.{.{ 16, 20 }});
    try expectFastSpans("(?m)\\w+$", "abc", &.{.{ 0, 3 }});
}

test "star-literal fast path matches the last occurrence in the run" {
    var value = try regex.Regex.init(gpa, ".*test", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .star_literal);

    try expectFastSpans(".*test", "test", &.{.{ 0, 4 }});
    try expectFastSpans(".*test", "x test", &.{.{ 0, 6 }});
    try expectFastSpans(".*test", "abc test def test", &.{.{ 0, 17 }});
    try expectFastSpans(".*test", "no match", &.{});
    try expectFastSpans(".*test", "\xfftest", &.{.{ 1, 5 }});
    try expectFastSpans(".*test", "a\xfftest", &.{.{ 2, 6 }});
    try expectFastSpans("(?s).*test", "a\nb test", &.{.{ 0, 8 }});
    try expectFastSpans("[a-z]*test", "x test", &.{.{ 2, 6 }});
}

test "prefix-run fast path starts at the first set byte" {
    var value = try regex.Regex.init(gpa, "[A-Za-z_]\\w*", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .prefix_run);

    try expectFastSpans("[A-Za-z_]\\w*", "int foo_1 = bar2;", &.{ .{ 0, 3 }, .{ 4, 9 }, .{ 12, 16 } });
    try expectFastSpans("[A-Za-z_]\\w*", "2foo", &.{.{ 1, 4 }});
    try expectFastSpans("[A-Za-z_]\\w*", "___", &.{.{ 0, 3 }});
    try expectFastSpans("[A-Za-z_]\\w*", "123", &.{});
    try expectFastSpans("[A-Za-z_]\\w+", "a", &.{});
    try expectFastSpans("[A-Za-z_]\\w+", "ab", &.{.{ 0, 2 }});
}

test "chain-loop fast path repeats separator and run" {
    var value = try regex.Regex.init(gpa, "[a-z0-9-]+(?:\\.[a-z0-9-]+)+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .chain_loop);

    try expectFastSpans("[a-z0-9-]+(?:\\.[a-z0-9-]+)+", "www.example.com x api.test.org", &.{ .{ 0, 15 }, .{ 18, 30 } });
    try expectFastSpans("[a-z0-9-]+(?:\\.[a-z0-9-]+)+", "abc", &.{});
    try expectFastSpans("[a-z0-9-]+(?:\\.[a-z0-9-]+)+", "abc.", &.{});
    try expectFastSpans("[a-z0-9-]+(?:\\.[a-z0-9-]+)+", "abc.def", &.{.{ 0, 7 }});
    try expectFastSpans("[a-z0-9-]+(?:\\.[a-z0-9-]+)+", "a.b.c", &.{.{ 0, 5 }});
    try expectFastSpans("[a-z0-9-]+(?:\\.[a-z0-9-]+)+", ".abc", &.{});
}

test "optional-tail fast path backtracks the optional group" {
    var value = try regex.Regex.init(gpa, "\\d+(?:\\.\\d+)?%", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .optional_tail);

    try expectFastSpans("\\d+(?:\\.\\d+)?%", "12.5% 100% 0.25%", &.{ .{ 0, 5 }, .{ 6, 10 }, .{ 11, 16 } });
    try expectFastSpans("\\d+(?:\\.\\d+)?%", "12.5x", &.{});
    try expectFastSpans("\\d+(?:\\.\\d+)?%", "12%3", &.{.{ 0, 3 }});
    try expectFastSpans("\\d+(?:\\.\\d+)?%", "12.5.6%", &.{.{ 3, 7 }});
}

test "unbounded sequence fast path walks runs and separators" {
    var value = try regex.Regex.init(gpa, "v?\\d+\\.\\d+\\.\\d+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(isUnboundedSequence(workspace.fast_kind));

    const cases = [_]struct { input: []const u8, from: usize, spans: []const [2]usize }{
        .{ .input = "v1.2.3 10.0.0 v2.11.5", .from = 0, .spans = &.{ .{ 0, 6 }, .{ 7, 13 }, .{ 14, 21 } } },
        .{ .input = "v1.2.3 10.0.0 v2.11.5", .from = 8, .spans = &.{ .{ 8, 13 }, .{ 14, 21 } } },
        .{ .input = "1.2.3", .from = 0, .spans = &.{.{ 0, 5 }} },
        .{ .input = "12.34.56", .from = 0, .spans = &.{.{ 0, 8 }} },
        .{ .input = "1.2", .from = 0, .spans = &.{} },
        .{ .input = "v", .from = 0, .spans = &.{} },
        .{ .input = "vv1.2.3", .from = 0, .spans = &.{.{ 1, 7 }} },
    };
    for (cases) |case| {
        var offset = case.from;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }

    // An optional byte inside the following run set would need backtracking.
    var ambiguous = try regex.Regex.init(gpa, "1?\\d+\\.\\d+", .{});
    defer ambiguous.deinit();
    var ambiguous_workspace = try regex.ReplaceWorkspace.init(gpa, ambiguous.program, .{});
    defer ambiguous_workspace.deinit();
    try std.testing.expect(!isUnboundedSequence(ambiguous_workspace.fast_kind));
    const still_correct = (try ambiguous_workspace.find("1.2", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), still_correct.start);
    try std.testing.expectEqual(@as(usize, 3), still_correct.end);

    // A single-separator chain keeps its existing path.
    var chain = try regex.Regex.init(gpa, "\\w+=\\w+", .{});
    defer chain.deinit();
    var chain_workspace = try regex.ReplaceWorkspace.init(gpa, chain.program, .{});
    defer chain_workspace.deinit();
    try std.testing.expect(chain_workspace.fast_kind == .chain);
}

test "unbounded chain fuses literal pairs only when two exist" {
    // Two fused pairs select the fused walk.
    var fused = try regex.Regex.init(gpa, "\\d+\\.\\d*\\.\\d+", .{});
    defer fused.deinit();
    var fused_workspace = try regex.ReplaceWorkspace.init(gpa, fused.program, .{});
    defer fused_workspace.deinit();
    try std.testing.expect(fused_workspace.fast_kind == .unbounded_sequence_fused);
    try expectFastSpans("\\d+\\.\\d*\\.\\d+", "1..2 3.4.5 x", &.{ .{ 0, 4 }, .{ 5, 10 } });
    try expectFastSpans("\\d+\\.\\d*\\.\\d+", "1..2.3", &.{.{ 0, 4 }});
    try expectFastSpans("\\d+\\.\\d*\\.\\d+", "1.2.", &.{});

    // One fused pair stays on the unfused walk.
    var single = try regex.Regex.init(gpa, "\\w+\\s*=\\s*\\w+", .{});
    defer single.deinit();
    var single_workspace = try regex.ReplaceWorkspace.init(gpa, single.program, .{});
    defer single_workspace.deinit();
    try std.testing.expect(single_workspace.fast_kind == .unbounded_sequence);
}

test "bounded sequence fast path backtracks greedy runs" {
    var value = try regex.Regex.init(gpa, "\\d{1,3}(?:\\.\\d{1,3}){3}", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .bounded_sequence);

    const cases = [_]struct { input: []const u8, from: usize, spans: []const [2]usize }{
        .{ .input = "192.168.1.1 x 10.0.0.255", .from = 0, .spans = &.{ .{ 0, 11 }, .{ 14, 24 } } },
        .{ .input = "192.168.1.1 x 10.0.0.255", .from = 12, .spans = &.{.{ 14, 24 }} },
        .{ .input = "1.2.3.4", .from = 0, .spans = &.{.{ 0, 7 }} },
        .{ .input = "1234.5.6.7", .from = 0, .spans = &.{.{ 1, 10 }} },
        .{ .input = "999.999.999.999", .from = 0, .spans = &.{.{ 0, 15 }} },
        .{ .input = "1.2.3", .from = 0, .spans = &.{} },
        .{ .input = "1.2.3.4.5", .from = 0, .spans = &.{.{ 0, 7 }} },
    };
    for (cases) |case| {
        var offset = case.from;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }

    // Greedy max fails, the backtracking matcher must shorten the first run.
    var backtrack = try regex.Regex.init(gpa, "\\d{1,3}\\d{2}", .{});
    defer backtrack.deinit();
    var backtrack_workspace = try regex.ReplaceWorkspace.init(gpa, backtrack.program, .{});
    defer backtrack_workspace.deinit();
    try std.testing.expect(backtrack_workspace.fast_kind == .bounded_sequence);
    const found = (try backtrack_workspace.find("1234", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), found.start);
    try std.testing.expectEqual(@as(usize, 4), found.end);

    // Fixed widths and unbounded runs keep their existing paths.
    var fixed = try regex.Regex.init(gpa, "\\d{4}-\\d{2}-\\d{2}", .{});
    defer fixed.deinit();
    var fixed_workspace = try regex.ReplaceWorkspace.init(gpa, fixed.program, .{});
    defer fixed_workspace.deinit();
    try std.testing.expect(fixed_workspace.fast_kind == .fixed_sequence);
    var unbounded = try regex.Regex.init(gpa, "\\d+", .{});
    defer unbounded.deinit();
    var unbounded_workspace = try regex.ReplaceWorkspace.init(gpa, unbounded.program, .{});
    defer unbounded_workspace.deinit();
    try std.testing.expect(unbounded_workspace.fast_kind != .bounded_sequence);
}

test "line-start run fast path matches only at line starts" {
    var value = try regex.Regex.init(gpa, "(?m)^\\w+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .line_start_run);

    const cases = [_]struct { input: []const u8, from: usize, spans: []const [2]usize }{
        .{ .input = "hello world\n  second line\nthird", .from = 0, .spans = &.{ .{ 0, 5 }, .{ 26, 31 } } },
        .{ .input = "hello world\n  second line\nthird", .from = 2, .spans = &.{.{ 26, 31 }} },
        .{ .input = "hello world\n  second line\nthird", .from = 26, .spans = &.{.{ 26, 31 }} },
        .{ .input = "a\r\nb", .from = 0, .spans = &.{ .{ 0, 1 }, .{ 3, 4 } } },
        .{ .input = "\n\na", .from = 0, .spans = &.{.{ 2, 3 }} },
        .{ .input = "abc\n", .from = 3, .spans = &.{} },
        .{ .input = "", .from = 0, .spans = &.{} },
    };
    for (cases) |case| {
        var offset = case.from;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }

    // A trailing end-line assertion is a different shape.
    var anchored = try regex.Regex.init(gpa, "(?m)^\\w+$", .{});
    defer anchored.deinit();
    var anchored_workspace = try regex.ReplaceWorkspace.init(gpa, anchored.program, .{});
    defer anchored_workspace.deinit();
    try std.testing.expect(anchored_workspace.fast_kind != .line_start_run);

    // Non-ASCII run sets stay on the general engine.
    var unicode = try regex.Regex.init(gpa, "(?m)^\\p{Han}+", .{});
    defer unicode.deinit();
    var unicode_workspace = try regex.ReplaceWorkspace.init(gpa, unicode.program, .{});
    defer unicode_workspace.deinit();
    try std.testing.expect(unicode_workspace.fast_kind != .line_start_run);
}

test "fixed sequence fast path matches set and literal concatenations" {
    var value = try regex.Regex.init(gpa, "\\d{4}-\\d{2}-\\d{2}", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .fixed_sequence);

    const cases = [_]struct { input: []const u8, from: usize, spans: []const [2]usize }{
        .{ .input = "2026-11-21 x 1999-12-31", .from = 0, .spans = &.{ .{ 0, 10 }, .{ 13, 23 } } },
        .{ .input = "2026-11-21 x 1999-12-31", .from = 3, .spans = &.{.{ 13, 23 }} },
        .{ .input = "2026-11-2", .from = 0, .spans = &.{} },
        .{ .input = "2026/11/21", .from = 0, .spans = &.{} },
        .{ .input = "x2026-11-21y", .from = 0, .spans = &.{.{ 1, 11 }} },
        .{ .input = "", .from = 0, .spans = &.{} },
    };
    for (cases) |case| {
        var offset = case.from;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try workspace.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }

    // A variable-width run is not a fixed sequence.
    var run = try regex.Regex.init(gpa, "\\d+", .{});
    defer run.deinit();
    var run_workspace = try regex.ReplaceWorkspace.init(gpa, run.program, .{});
    defer run_workspace.deinit();
    try std.testing.expect(run_workspace.fast_kind != .fixed_sequence);
}

test "run-then-literal fast path anchors on the required literal" {
    var value = try regex.Regex.init(gpa, "\\w+@example\\.com", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .run_then_literal);

    const cases = [_]struct { input: []const u8, from: usize, span: ?[2]usize }{
        .{ .input = "user.name@example.com", .from = 0, .span = .{ 5, 21 } },
        .{ .input = "user.name@example.com", .from = 2, .span = .{ 5, 21 } },
        .{ .input = "abc@example.com", .from = 1, .span = .{ 1, 15 } },
        .{ .input = "x@example.com", .from = 0, .span = .{ 0, 13 } },
        .{ .input = "@example.com", .from = 0, .span = null },
        .{ .input = "\u{00e9}@example.com", .from = 0, .span = null },
        .{ .input = "a@example.com b@example.com", .from = 0, .span = .{ 0, 13 } },
        .{ .input = "a@example.com b@example.com", .from = 14, .span = .{ 14, 27 } },
    };
    for (cases) |case| {
        const found = try workspace.find(case.input, case.from);
        if (case.span) |span| {
            const match = found.?;
            try std.testing.expectEqual(span[0], match.start);
            try std.testing.expectEqual(span[1], match.end);
        } else {
            try std.testing.expect(found == null);
        }
    }

    // A literal whose first byte is a run member stays on the chain path.
    var chain = try regex.Regex.init(gpa, "\\w+abc", .{});
    defer chain.deinit();
    var chain_workspace = try regex.ReplaceWorkspace.init(gpa, chain.program, .{});
    defer chain_workspace.deinit();
    try std.testing.expect(chain_workspace.fast_kind != .run_then_literal);
}

test "literal alternation fast path matches leftmost-first" {
    var value = try regex.Regex.init(gpa, "alpha|gamma|epsilon", .{});
    defer value.deinit();
    try std.testing.expect(value.program.literal_set != null);
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.literal_set_multi != null);

    const cases = [_]struct { pattern: []const u8, input: []const u8, spans: []const [2]usize }{
        .{ .pattern = "alpha|gamma|epsilon", .input = "", .spans = &.{} },
        .{ .pattern = "alpha|gamma|epsilon", .input = "xx gamma alpha epsilon yy", .spans = &.{ .{ 3, 8 }, .{ 9, 14 }, .{ 15, 22 } } },
        .{ .pattern = "alpha|gamma|epsilon", .input = "alphabet", .spans = &.{.{ 0, 5 }} },
        .{ .pattern = "alpha|gamma|epsilon", .input = "alga", .spans = &.{} },
        // Leftmost-first: the first alternative wins at the same start.
        .{ .pattern = "ab|abc", .input = "xx abc ab", .spans = &.{ .{ 3, 5 }, .{ 7, 9 } } },
        // Single-byte alternatives skip the pair filter.
        .{ .pattern = "a|b", .input = "xxaab", .spans = &.{ .{ 2, 3 }, .{ 3, 4 }, .{ 4, 5 } } },
        // Non-ASCII literals compare as bytes.
        .{ .pattern = "\u{732b}|\u{72ac}", .input = "x\u{732b}y\u{72ac}", .spans = &.{ .{ 1, 4 }, .{ 5, 8 } } },
    };
    for (cases) |case| {
        var compiled = try regex.Regex.init(gpa, case.pattern, .{});
        defer compiled.deinit();
        var ws = try regex.ReplaceWorkspace.init(gpa, compiled.program, .{});
        defer ws.deinit();
        var offset: usize = 0;
        var index: usize = 0;
        while (offset <= case.input.len and index < case.spans.len) : (index += 1) {
            const m = (try ws.find(case.input, offset)) orelse break;
            try std.testing.expectEqual(case.spans[index][0], m.start);
            try std.testing.expectEqual(case.spans[index][1], m.end);
            offset = m.end;
        }
        try std.testing.expectEqual(case.spans.len, index);
    }
}

test "literal alternation detection distributes a literal suffix" {
    var trailing = try regex.Regex.init(gpa, "(?:ab|ac)d", .{});
    defer trailing.deinit();
    try std.testing.expect(trailing.program.literal_set != null);
    try expectFastSpans("(?:ab|ac)d", "xx abd acd ab yy", &.{ .{ 3, 6 }, .{ 7, 10 } });
    var captures = try regex.Regex.init(gpa, "(ab|ac)", .{});
    defer captures.deinit();
    try std.testing.expect(captures.program.literal_set == null);
    var caseless = try regex.Regex.init(gpa, "(?i)ab|cd", .{});
    defer caseless.deinit();
    try std.testing.expect(caseless.program.literal_set == null);
}

test "literal-run detection rejects an optional literal that overlaps the middle" {
    // The optional literal repeats the first middle byte, so the greedy
    // scanner consumes the byte the skipped branch needs.
    var value = try regex.Regex.init(gpa, "aX?Xb+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.literal_run == null);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{} },
        .{ .input = "ab", .spans = &.{} },
        .{ .input = "aX", .spans = &.{} },
        .{ .input = "aXb", .spans = &.{.{ 0, 3 }} },
        .{ .input = "aXXb", .spans = &.{.{ 0, 4 }} },
        .{ .input = "aXb aXb", .spans = &.{ .{ 0, 3 }, .{ 4, 7 } } },
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

test "line-delimited and trailing-space fast paths" {
    var value = try regex.Regex.init(gpa, "(?m)^[^:\n]+:", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.line_delimited != null);

    const input = "server.port: 8080\nlog.level: debug\nnokey line\nx: y";
    const first = (try workspace.find(input, 0)).?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 12), first.end);
    const second = (try workspace.find(input, first.end)).?;
    try std.testing.expectEqual(@as(usize, 18), second.start);
    try std.testing.expectEqual(@as(usize, 28), second.end);
    // The line without a delimiter is skipped.
    const third = (try workspace.find(input, second.end)).?;
    try std.testing.expectEqual(@as(usize, 46), third.start);
    try std.testing.expectEqual(@as(usize, 48), third.end);
    try std.testing.expect((try workspace.find(input, third.end)) == null);
    // A mid-line search resumes at the next line start.
    const mid = (try workspace.find(input, 3)).?;
    try std.testing.expectEqual(@as(usize, 18), mid.start);

    var trailing = try regex.Regex.init(gpa, "\\s*$", .{});
    defer trailing.deinit();
    var trailing_workspace = try regex.ReplaceWorkspace.init(gpa, trailing.program, .{});
    defer trailing_workspace.deinit();
    try std.testing.expect(trailing_workspace.trailing_space);
    const space = (try trailing_workspace.find("value   \nkey  \n", 0)).?;
    try std.testing.expectEqual(@as(usize, 12), space.start);
    try std.testing.expectEqual(@as(usize, 15), space.end);
    const empty = (try trailing_workspace.find("abc", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), empty.start);
    try std.testing.expectEqual(@as(usize, 3), empty.end);
    const mid_space = (try trailing_workspace.find("value   \nkey  \n", 13)).?;
    try std.testing.expectEqual(@as(usize, 13), mid_space.start);
    try std.testing.expectEqual(@as(usize, 15), mid_space.end);
}

test "front cache survives lazy DFA state growth" {
    // Regression: `compute` can create states and grow the per-state front
    // cache; the fill must re-index instead of reusing the earlier pointer.
    // page_allocator returns the memory to the OS on growth, so a stale
    // pointer write faults instead of silently corrupting.
    const pga = std.heap.page_allocator;
    var value = try regex.Regex.init(pga, "(?i) {1,2}|\\p{Script=Greek}{0,2}\u{0394}{0,2}b{0,2}|[ab]{0,2}\\p{L}+[\\r\\n]*\\s", .{ .unicode_perl_classes = true, .dollar_endonly = true });
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(pga, value.program, .{ .unicode_perl_classes = true });
    defer workspace.deinit();
    const inputs = [_][]const u8{ "\u{0394}\u{03c3}", "2020", "abc", "\u{4f60}", "a1 b2", "" };
    for (inputs) |input| {
        var offset: usize = 0;
        var spans: usize = 0;
        while (offset <= input.len and spans < 32) : (spans += 1) {
            const m = (try workspace.find(input, offset)) orelse break;
            if (m.end > m.start) {
                offset = m.end;
            } else {
                if (m.start == input.len) break;
                offset = m.start + 1;
            }
        }
    }
}

test "number run fast path" {
    var value = try regex.Regex.init(gpa, "-?\\d+(?:\\.\\d+)?", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.number_run);

    const cases = [_]struct { input: []const u8, spans: []const [2]usize }{
        .{ .input = "", .spans = &.{} },
        .{ .input = "42", .spans = &.{.{ 0, 2 }} },
        .{ .input = "-12.5", .spans = &.{.{ 0, 5 }} },
        .{ .input = "x=-3 y=0.25", .spans = &.{ .{ 2, 4 }, .{ 7, 11 } } },
        .{ .input = "3.", .spans = &.{.{ 0, 1 }} },
        .{ .input = "-", .spans = &.{} },
        .{ .input = "-x 7", .spans = &.{.{ 3, 4 }} },
        .{ .input = "1.2.3", .spans = &.{ .{ 0, 3 }, .{ 4, 5 } } },
        .{ .input = "12.x", .spans = &.{.{ 0, 2 }} },
        .{ .input = "--12", .spans = &.{.{ 1, 4 }} },
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
}
