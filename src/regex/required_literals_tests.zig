const std = @import("std");
const regex = @import("../root.zig");

test "required literals extract pure strings and alternations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cases = [_]struct { pattern: []const u8, expected: []const []const u8 }{
        .{ .pattern = "foo", .expected = &.{"foo"} },
        .{ .pattern = "(?:foo|bar)", .expected = &.{ "foo", "bar" } },
        .{ .pattern = "[a-z]*(?:foo|bar)", .expected = &.{ "foo", "bar" } },
        .{ .pattern = "(?:ab|cd)*e", .expected = &.{"e"} },
        .{ .pattern = "(\\w+)@(\\w+)\\.com", .expected = &.{".com"} },
        .{ .pattern = "a+b?", .expected = &.{"a"} },
        .{ .pattern = "(?i)foo", .expected = &.{} },
        .{ .pattern = "(?:foo|bar)+x", .expected = &.{ "foo", "bar" } },
        .{ .pattern = "(?<=foo)bar", .expected = &.{"ar"} },
    };
    for (cases) |case| {
        const program = try regex.compile(allocator, case.pattern, .{});
        if (case.expected.len == 0) {
            try std.testing.expect(program.required_literals == null);
        } else {
            const actual = program.required_literals.?;
            try std.testing.expectEqual(case.expected.len, actual.len);
            for (case.expected, actual) |expected, value| {
                try std.testing.expectEqualStrings(expected, value);
            }
        }
    }
    {
        const program = try regex.compile(allocator, "foo(?=bar)", .{});
        const actual = program.required_literals.?;
        try std.testing.expectEqual(@as(usize, 1), actual.len);
        try std.testing.expect(std.mem.eql(u8, actual[0], "foo") or std.mem.eql(u8, actual[0], "bar"));
    }
}

test "required literal prefilter preserves search results" {
    const allocator = std.testing.allocator;
    const Case = struct {
        pattern: []const u8,
        input: []const u8,
        spans: []const [2]usize,
    };
    const cases = [_]Case{
        .{ .pattern = "[a-z]*(?:foo|bar)", .input = "xxfoo yybar", .spans = &.{ .{ 0, 5 }, .{ 6, 11 } } },
        .{ .pattern = "[a-z]*(?:foo|bar)", .input = "nothing here", .spans = &.{} },
        .{ .pattern = "(?:ab|cd)*e", .input = "abcdcde", .spans = &.{.{ 0, 7 }} },
        .{ .pattern = "(?:ab|cd)*e", .input = "abcd", .spans = &.{} },
        .{ .pattern = "(\\w+)@(\\w+)\\.com", .input = "mail me@example.com", .spans = &.{.{ 5, 19 }} },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
        defer workspace.deinit();
        var offset: usize = 0;
        var index: usize = 0;
        while (offset <= case.input.len) {
            const found = try workspace.find(case.input, offset);
            if (found) |match| {
                try std.testing.expect(index < case.spans.len);
                try std.testing.expectEqual(case.spans[index][0], match.start);
                try std.testing.expectEqual(case.spans[index][1], match.end);
                index += 1;
                if (match.end <= match.start) {
                    if (match.start == case.input.len) break;
                    offset = match.start + (std.unicode.utf8ByteSequenceLength(case.input[match.start]) catch 1);
                } else {
                    offset = match.end;
                }
            } else {
                break;
            }
        }
        try std.testing.expectEqual(case.spans.len, index);
    }
}
