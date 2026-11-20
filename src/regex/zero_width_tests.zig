//! Zero-width edge-assertion fast path: `^`, `$`, `(?m)^$`, ...
const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

const Span = struct {
    start: usize,
    end: usize,
    slots: []const usize,
};

fn collect(allocator: std.mem.Allocator, workspace: *regex.ReplaceWorkspace, input: []const u8) ![]Span {
    var spans: std.ArrayList(Span) = .empty;
    errdefer {
        for (spans.items) |span| allocator.free(span.slots);
        spans.deinit(allocator);
    }
    var offset: usize = 0;
    while (offset <= input.len) {
        const match = (try workspace.find(input, offset)) orelse break;
        const slots = try allocator.dupe(usize, match.slots);
        try spans.append(allocator, .{ .start = match.start, .end = match.end, .slots = slots });
        if (match.end <= match.start) {
            if (match.start == input.len) break;
            const length = std.unicode.utf8ByteSequenceLength(input[match.start]) catch 1;
            const step = if (length > input.len - match.start) 1 else length;
            offset = match.start + step;
        } else {
            offset = match.end;
        }
    }
    return spans.toOwnedSlice(allocator);
}

fn freeSpans(allocator: std.mem.Allocator, spans: []Span) void {
    for (spans) |span| allocator.free(span.slots);
    allocator.free(spans);
}

fn compare(allocator: std.mem.Allocator, pattern: []const u8, input: []const u8, from: usize) !void {
    var value = try regex.Regex.init(allocator, pattern, .{});
    defer value.deinit();
    var direct = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer direct.deinit();
    var reference = try regex.ReplaceWorkspace.init(allocator, value.program, .{});
    defer reference.deinit();
    reference.fast_kind = .none;
    reference.search_dfa_ineligible = true;
    const actual = direct.find(input, from) catch |err| {
        try std.testing.expectError(err, reference.find(input, from));
        return;
    };
    const expected = try reference.find(input, from);
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |match| {
        try std.testing.expectEqual(match.start, actual.?.start);
        try std.testing.expectEqual(match.end, actual.?.end);
        try std.testing.expectEqualSlices(usize, match.slots, actual.?.slots);
    }
}

test "zero-width fast path agrees with the interpreter at every offset" {
    const patterns = [_][]const u8{
        "^|$",
        "^",
        "$",
        "(?m)^",
        "(?m)$",
        "(?m)^$",
        "\\A\\z",
        "^|(?m)$",
        "(^)",
        "($)",
        "(^)|($)",
        "(?m)(^|$)",
        "(?:^)(?:$)",
    };
    const inputs = [_][]const u8{
        "",
        "a",
        "abc",
        "abc\n",
        "abc\r\n",
        "abc\ndef",
        "abc\r\ndef",
        "\n",
        "\n\n",
        "a\n\nb\n",
        "a\r\n\r\nb",
        "猫\n狗",
        "猫\r\n狗",
    };
    for (patterns) |pattern| {
        for (inputs) |input| {
            var from: usize = 0;
            while (from <= input.len + 1) : (from += 1) {
                try compare(gpa, pattern, input, from);
            }
        }
    }
}

test "zero-width fast path drives replacement iteration" {
    const cases = [_]struct { pattern: []const u8, substitution: []const u8, input: []const u8 }{
        .{ .pattern = "^|$", .substitution = "!", .input = "abc\ndef\n" },
        .{ .pattern = "(?m)^", .substitution = ">", .input = "a\n\nb\n" },
        .{ .pattern = "(?m)$", .substitution = "<", .input = "a\n\nb\n" },
        .{ .pattern = "(?m)^$", .substitution = "E", .input = "a\n\nb\n\n" },
        .{ .pattern = "^", .substitution = "[", .input = "abc" },
        .{ .pattern = "$", .substitution = "]", .input = "abc\n" },
        .{ .pattern = "\\A\\z", .substitution = "0", .input = "" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var direct = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer direct.deinit();
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.fast_kind = .none;
        reference.search_dfa_ineligible = true;
        const actual = try direct.replaceAll(case.input, case.substitution);
        defer gpa.free(actual);
        const expected = try reference.replaceAll(case.input, case.substitution);
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "zero-width empty-match restrictions keep the general engine" {
    const patterns = [_][]const u8{
        "(*NOTEMPTY)^|$",
        "(*NOTEMPTY_ATSTART)^|$",
    };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        try std.testing.expect(workspace.fast_kind != .zero_width);
        const input = "abc\ndef";
        var direct = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer direct.deinit();
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.fast_kind = .none;
        reference.search_dfa_ineligible = true;
        const actual = try collect(gpa, &direct, input);
        defer freeSpans(gpa, actual);
        const expected = try collect(gpa, &reference, input);
        defer freeSpans(gpa, expected);
        try std.testing.expectEqual(expected.len, actual.len);
        for (actual, expected) |left, right| {
            try std.testing.expectEqual(right.start, left.start);
            try std.testing.expectEqual(right.end, left.end);
            try std.testing.expectEqualSlices(usize, right.slots, left.slots);
        }
    }
}
