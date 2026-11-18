const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

const patterns = [_][]const u8{
    "abc",
    "(?i)abc",
    "a+",
    "[a-z]+",
    "\\p{L}+",
    "\\p{RGI_Emoji}",
    "\\b{gcb}a",
    "(?*(a|ab))(?1)c",
    "(?<*(a+))\\1c",
    "(*sr:\\S+)",
    "(*asr:(?:\\S+|\\S))\\S*",
    "(a)(*scs:(1)a)",
    "(?<w>ab)(*scs:('w')a.c)",
    "(*CRLF)a.b",
    "(*ANY)\\R",
    "(*NOTEMPTY)a*",
    "(*NOTEMPTY_ATSTART)a*",
    "a|ab",
    "(?:ab|cd)+",
    "(a)(b)?",
    "(?<x>a)\\k<x>",
    "a(?=bc)bc",
    "(?<=a)b",
    "(?<!a)b",
    "(?>a+)a",
    "a++",
    "(a)(?(1)b|c)",
    "(?(?=a)a|b)",
    "(?:(a)|(b))+",
    "(?<x>a(?&x)?b)",
    "\\X",
    "a\\Kb",
    "(*MARK:m)ab",
    "(*SKIP:m)",
    "(?C1)a",
    "a{2,3}",
    "[[:alpha:]]+",
    "\\p{scx=Hiragana}+",
    "(?n)(a)(?<x>b)",
    "(?U)a+",
    "a(*THEN)b|ac",
    "a\\Z",
    "\\bword\\b",
    "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+",
};

const inputs = [_][]const u8{
    "",           "a",                 "abc", "abab", "aab",                 "word", "a b", "x\na\ny",
    "\u{732b}a1", "Hello, world! 123", "aaa", "abxy", "it's a test\n\nnext",
};

fn expectSameOptional(a: ?[]const u8, b: ?[]const u8) !void {
    if (a) |left| {
        try std.testing.expect(b != null);
        try std.testing.expectEqualStrings(left, b.?);
    } else {
        try std.testing.expect(b == null);
    }
}

fn expectSameProgram(a: regex.Program, b: regex.Program) !void {
    try std.testing.expectEqual(a.instructions.len, b.instructions.len);
    try std.testing.expectEqual(a.start, b.start);
    try std.testing.expectEqual(a.body, b.body);
    try std.testing.expectEqual(a.accept, b.accept);
    try std.testing.expectEqual(a.capture_count, b.capture_count);
    try std.testing.expectEqual(a.dfa_eligible, b.dfa_eligible);
    try std.testing.expectEqual(a.extended, b.extended);
    try std.testing.expectEqual(a.newline, b.newline);
    try std.testing.expectEqual(a.notempty, b.notempty);
    try std.testing.expectEqual(a.notempty_atstart, b.notempty_atstart);
    try std.testing.expectEqual(a.skip_start, b.skip_start);
    try std.testing.expectEqual(a.first.ascii, b.first.ascii);
    try std.testing.expectEqual(a.first.nonascii, b.first.nonascii);
    try std.testing.expectEqual(a.first.empty, b.first.empty);
    try expectSameOptional(a.literal, b.literal);
    try expectSameOptional(a.literal_prefix, b.literal_prefix);
    try std.testing.expectEqual(a.group_names.len, b.group_names.len);
    for (a.group_names, b.group_names) |left, right| {
        try std.testing.expectEqual(left.index, right.index);
        try std.testing.expectEqualStrings(left.name, right.name);
    }
    try std.testing.expectEqual(a.marks.len, b.marks.len);
    for (a.marks, b.marks) |left, right| try std.testing.expectEqualStrings(left, right);
    try std.testing.expectEqual(a.callouts.len, b.callouts.len);
    for (a.callouts, b.callouts) |left, right| {
        try std.testing.expectEqual(left.number, right.number);
        try expectSameOptional(left.name, right.name);
    }
    try std.testing.expectEqual(a.dispatches.len, b.dispatches.len);
}

fn collectSpans(allocator: std.mem.Allocator, program: regex.Program, limits: regex.Limits, input: []const u8) ![]const [2]usize {
    var workspace = try regex.ReplaceWorkspace.init(allocator, program, limits);
    defer workspace.deinit();
    var spans: std.ArrayList([2]usize) = .empty;
    errdefer spans.deinit(allocator);
    var offset: usize = 0;
    while (offset <= input.len) {
        const found = (try workspace.find(input, offset)) orelse break;
        try spans.append(allocator, .{ found.start, found.end });
        if (found.end <= found.start) {
            if (found.start == input.len) break;
            const len = std.unicode.utf8ByteSequenceLength(input[found.start]) catch 1;
            offset = found.start + len;
        } else offset = found.end;
    }
    return spans.toOwnedSlice(allocator);
}

test "program serialization round-trips and preserves behavior" {
    for (patterns) |pattern| {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const allocator = arena.allocator();
        var value = try regex.Regex.init(allocator, pattern, .{ .unicode_perl_space = true });
        defer value.deinit();

        const blob = try value.program.serialize(gpa);
        defer gpa.free(blob);
        var loaded_arena = std.heap.ArenaAllocator.init(gpa);
        defer loaded_arena.deinit();
        const loaded = try regex.Program.deserialize(loaded_arena.allocator(), blob);
        try expectSameProgram(value.program, loaded);

        const round_trip = try loaded.serialize(gpa);
        defer gpa.free(round_trip);
        try std.testing.expectEqualSlices(u8, blob, round_trip);

        for (inputs) |input| {
            const expected = try collectSpans(allocator, value.program, value.limits, input);
            defer allocator.free(expected);
            const actual = try collectSpans(loaded_arena.allocator(), loaded, value.limits, input);
            defer loaded_arena.allocator().free(actual);
            try std.testing.expectEqual(expected.len, actual.len);
            for (expected, actual) |want, got| {
                try std.testing.expectEqual(want[0], got[0]);
                try std.testing.expectEqual(want[1], got[1]);
            }
        }
    }
}

test "program deserialization rejects corrupt blobs" {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var value = try regex.Regex.init(arena.allocator(), "(a)(b)?[a-z]+", .{});
    defer value.deinit();
    const blob = try value.program.serialize(gpa);
    defer gpa.free(blob);

    try std.testing.expectError(error.InvalidRegex, regex.Program.deserialize(arena.allocator(), ""));
    try std.testing.expectError(error.InvalidRegex, regex.Program.deserialize(arena.allocator(), "NOPE"));
    const truncated = try gpa.dupe(u8, blob[0 .. blob.len - 1]);
    defer gpa.free(truncated);
    try std.testing.expectError(error.InvalidRegex, regex.Program.deserialize(arena.allocator(), truncated));
    const half = try gpa.dupe(u8, blob[0 .. blob.len / 2]);
    defer gpa.free(half);
    try std.testing.expectError(error.InvalidRegex, regex.Program.deserialize(arena.allocator(), half));
}
