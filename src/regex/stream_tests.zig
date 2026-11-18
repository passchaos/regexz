const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

const Collector = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayList([2]usize) = .empty,
    slots: std.ArrayList(usize) = .empty,

    fn init(allocator: std.mem.Allocator) Collector {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *Collector) void {
        self.spans.deinit(self.allocator);
        self.slots.deinit(self.allocator);
    }
};

fn emitMatch(context: ?*anyopaque, match: regex.StreamMatch) void {
    const collector: *Collector = @ptrCast(@alignCast(context.?));
    collector.spans.append(collector.allocator, .{ match.start, match.end }) catch @panic("out of memory");
    if (collector.slots.items.len == 0) {
        collector.slots.appendSlice(collector.allocator, match.slots) catch @panic("out of memory");
    }
}

/// Byte length of the rune at `start`, or 1 for invalid/truncated sequences;
/// mirrors how the scanner treats undecodable bytes when bumping past an
/// empty match.
fn bumpLength(input: []const u8, start: usize) usize {
    if (start >= input.len) return 1;
    const len = std.unicode.utf8ByteSequenceLength(input[start]) catch return 1;
    if (start + len > input.len) return 1;
    _ = std.unicode.utf8Decode(input[start..][0..len]) catch return 1;
    return len;
}

fn wholeInputSpans(allocator: std.mem.Allocator, program: regex.Program, limits: regex.Limits, input: []const u8) ![]const [2]usize {
    var workspace = try regex.ReplaceWorkspace.init(allocator, program, limits);
    defer workspace.deinit();
    var spans: std.ArrayList([2]usize) = .empty;
    errdefer spans.deinit(allocator);
    var offset: usize = 0;
    var count: usize = 0;
    while (offset <= input.len and count < 1000) {
        const found = (try workspace.find(input, offset)) orelse break;
        try spans.append(allocator, .{ found.start, found.end });
        count += 1;
        if (found.end <= found.start) {
            if (found.start == input.len) break;
            offset = found.start + bumpLength(input, found.start);
        } else offset = found.end;
    }
    return spans.toOwnedSlice(allocator);
}

fn expectScannerMatches(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8, chunk_size: usize, limits: regex.Limits) !void {
    var value = try regex.Regex.init(allocator, pattern, limits);
    defer value.deinit();
    const expected = try wholeInputSpans(allocator, value.program, limits, input);
    defer allocator.free(expected);

    var scanner = try regex.StreamScanner.init(allocator, value.program, limits);
    defer scanner.deinit();
    var collector = Collector.init(allocator);
    defer collector.deinit();

    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(input.len, offset + chunk_size);
        try scanner.feed(input[offset..end], &collector, emitMatch);
        offset = end;
    }
    try scanner.finish(&collector, emitMatch);

    try std.testing.expectEqual(expected.len, collector.spans.items.len);
    for (expected, collector.spans.items) |want, got| {
        try std.testing.expectEqual(want[0], got[0]);
        try std.testing.expectEqual(want[1], got[1]);
    }
}

test "streaming scanner agrees with whole-input search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "[a-z]+", .input = "Hello, world!  abc def ghi" },
        .{ .pattern = "\\p{L}+", .input = "caf\u{00e9} \u{4f60}\u{597d}\u{4e16}\u{754c} abc" },
        .{ .pattern = "\\s+(?!\\S)", .input = "a  b   c\n\td" },
        .{ .pattern = "a|ab", .input = "abab aab" },
        .{ .pattern = "(?:a|b)+", .input = "abba ab" },
        .{ .pattern = "a*b", .input = "aaab b aab" },
        .{ .pattern = "a*", .input = "baaac" },
        .{ .pattern = "^a+$", .input = "aaa" },
        .{ .pattern = "a\\Z", .input = "a\n" },
        .{ .pattern = "(?m)^a$", .input = "x\na\ny" },
        .{ .pattern = "\\Aabc", .input = "abc" },
        .{ .pattern = "\\bword\\b", .input = "a word, wordy word!" },
        .{ .pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+", .input = "Hello, world!  It's a test\n\nNumbers 12345 \u{4f60}\u{597d} caf\u{00e9}.\n" },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 5, 7, 64 }) |chunk| {
            try expectScannerMatches(allocator, case.pattern, case.input, chunk, .{ .unicode_perl_space = true });
        }
    }
}

test "streaming scanner preserves captures" {
    var value = try regex.Regex.init(gpa, "(a+)(b*)", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(gpa, value.program, .{});
    defer scanner.deinit();
    var collector = Collector.init(gpa);
    defer collector.deinit();
    const input = "aaabb x a";
    var offset: usize = 0;
    while (offset < input.len) {
        const end = @min(input.len, offset + 2);
        try scanner.feed(input[offset..end], &collector, emitMatch);
        offset = end;
    }
    try scanner.finish(&collector, emitMatch);
    try std.testing.expectEqual(@as(usize, 2), collector.spans.items.len);
    try std.testing.expectEqualSlices(usize, &.{ 0, 5, 0, 3, 3, 5 }, collector.slots.items);
}

test "streaming scanner defers end-anchored matches until finish" {
    var value = try regex.Regex.init(gpa, "^a+$", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(gpa, value.program, .{});
    defer scanner.deinit();
    var collector = Collector.init(gpa);
    defer collector.deinit();
    try scanner.feed("aa", &collector, emitMatch);
    try scanner.feed("a", &collector, emitMatch);
    try std.testing.expectEqual(@as(usize, 0), collector.spans.items.len);
    try scanner.finish(&collector, emitMatch);
    try std.testing.expectEqual(@as(usize, 1), collector.spans.items.len);
    try std.testing.expectEqual(@as(usize, 0), collector.spans.items[0][0]);
    try std.testing.expectEqual(@as(usize, 3), collector.spans.items[0][1]);
}

test "streaming scanner keeps memory bounded on non-matching input" {
    var value = try regex.Regex.init(gpa, "needle", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(gpa, value.program, .{});
    defer scanner.deinit();
    var collector = Collector.init(gpa);
    defer collector.deinit();
    const chunk = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    for (0..200) |_| {
        try scanner.feed(chunk, &collector, emitMatch);
        try std.testing.expect(scanner.buffer.items.len <= 8);
    }
    try scanner.feed("needle", &collector, emitMatch);
    try scanner.finish(&collector, emitMatch);
    try std.testing.expectEqual(@as(usize, 1), collector.spans.items.len);
    try std.testing.expectEqual(@as(usize, 6400), collector.spans.items[0][0]);
    try std.testing.expectEqual(@as(usize, 6406), collector.spans.items[0][1]);
}

test "streaming scanner rejects extended programs" {
    var value = try regex.Regex.init(gpa, "a(?=bc)bc", .{});
    defer value.deinit();
    try std.testing.expectError(error.UnsupportedRegexFeature, regex.StreamScanner.init(gpa, value.program, .{}));
}

test "streaming simple-run fast path handles chunk boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The set+ shape takes the direct run scan; chunk boundaries may split
    // ASCII runs, multi-byte runes, and run/non-member transitions.
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "[a-z]+", .input = "ab cd  ef" },
        .{ .pattern = "[a-z]+", .input = "aaaa" },
        .{ .pattern = "[a-z]+", .input = "!!!aaa???" },
        .{ .pattern = "\\d+", .input = "12 345 6" },
        .{ .pattern = "\\p{Han}+", .input = "a\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}b" },
        .{ .pattern = "\\p{Han}+", .input = "\u{4f60}\u{597d}\u{4e16}\u{754c}" },
        .{ .pattern = "(?i)[a-z]+", .input = "AbC dEf" },
        .{ .pattern = "\\w+", .input = "ab_12 cd" },
        .{ .pattern = "\\s+", .input = "a \t b\n" },
        .{ .pattern = "[\\p{L}\\p{N}]+", .input = "caf\u{00e9} 12 \u{4f60}\u{597d}" },
        // Single-rune sets compile to a literal body, not a set instruction.
        .{ .pattern = "a+", .input = "baaac a" },
        .{ .pattern = "x+", .input = "xxabcx" },
        .{ .pattern = "\u{732b}+", .input = "a\u{732b}\u{732b}\u{ff0c}\u{732b}" },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 4, 5, 8 }) |chunk| {
            try expectScannerMatches(allocator, case.pattern, case.input, chunk, .{});
        }
    }

    var value = try regex.Regex.init(allocator, "[a-z]+", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(allocator, value.program, .{});
    defer scanner.deinit();
    try std.testing.expect(scanner.simple_set != null);
}

test "streaming chain fast path handles chunk boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "[a-z]+ [a-z]+", .input = "ab cd  ef" },
        .{ .pattern = "[a-z]+ [a-z]+", .input = "one two three" },
        .{ .pattern = "\\d+\\.\\d+", .input = "1.23 456.7 8" },
        .{ .pattern = "\\w+:\\w+", .input = "a:b cc:dd ee" },
        .{ .pattern = "[a-z]+ [a-z]+", .input = "  lead and trail  " },
        .{ .pattern = "\\p{Han}+\u{ff0c}\\p{Han}+", .input = "\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}\u{ff0c}abc" },
        .{ .pattern = "\\p{L}+\u{00e9}\\p{L}+", .input = "caf\u{00e9}bar x" },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 4, 5, 8 }) |chunk| {
            try expectScannerMatches(allocator, case.pattern, case.input, chunk, .{});
        }
    }

    var value = try regex.Regex.init(allocator, "[a-z]+ [a-z]+", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(allocator, value.program, .{});
    defer scanner.deinit();
    try std.testing.expect(scanner.simple_chain != null);
}

test "streaming star fast path handles chunk boundaries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `set*` reports the empty matches between runs, so the boundary matrix
    // covers runs, separators, multi-byte runes, and invalid bytes.
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "a*", .input = "baaac" },
        .{ .pattern = "a*", .input = "aaaa" },
        .{ .pattern = "a*", .input = "" },
        .{ .pattern = "a*", .input = "bbbb" },
        .{ .pattern = "[a-z]*", .input = "ab cd  ef" },
        .{ .pattern = "\\s*", .input = "a \t b\n" },
        .{ .pattern = "\\d*", .input = "12 345 6" },
        .{ .pattern = "\\p{Han}*", .input = "a\u{4f60}\u{597d}\u{ff0c}\u{4e16}\u{754c}b" },
        .{ .pattern = "(?i)[a-z]*", .input = "AbC dEf" },
        .{ .pattern = "[a-z]*", .input = "\u{00e9}t\u{00e9}" },
        .{ .pattern = "a*", .input = "baaac\xff" },
        .{ .pattern = "a*", .input = "\xffa\x80" },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 4, 5, 8 }) |chunk| {
            try expectScannerMatches(allocator, case.pattern, case.input, chunk, .{});
        }
    }

    var value = try regex.Regex.init(allocator, "a*", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(allocator, value.program, .{});
    defer scanner.deinit();
    try std.testing.expect(scanner.simple_star != null);

    // A nullable loop with a continuation is a split shape, not a bare star.
    var loop = try regex.Regex.init(allocator, "a*b", .{});
    defer loop.deinit();
    var loop_scanner = try regex.StreamScanner.init(allocator, loop.program, .{});
    defer loop_scanner.deinit();
    try std.testing.expect(loop_scanner.simple_star == null);
}

test "streaming scanner skips invalid bytes after empty matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "a*", .input = "\xff" },
        .{ .pattern = "a*", .input = "b\xffa" },
        .{ .pattern = "(?:a|b)*", .input = "\x80x\xffy" },
        .{ .pattern = "x*", .input = "\xe4\xffx" },
    };
    for (cases) |case| {
        for ([_]usize{ 1, 2, 3, 4, 8 }) |chunk| {
            try expectScannerMatches(allocator, case.pattern, case.input, chunk, .{});
        }
    }
}
