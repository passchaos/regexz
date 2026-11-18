const std = @import("std");
const regex = @import("../root.zig");
const word_boundary = @import("word_boundary.zig");
const data = @import("unicode/word_break_test_data.zig");

test "UAX #29 word break official cases" {
    var input: [512]u8 = undefined;
    var offsets: [128]usize = undefined;
    for (data.cases) |case| {
        try std.testing.expect(case.cps.len < offsets.len);
        var length: usize = 0;
        for (case.cps, 0..) |cp, index| {
            offsets[index] = length;
            length += std.unicode.utf8Encode(cp, input[length..]) catch return error.TestUnexpectedResult;
        }
        offsets[case.cps.len] = length;
        try std.testing.expectEqual(case.cps.len + 1, case.boundaries.len);
        for (case.boundaries, 0..) |expected, index| {
            try std.testing.expectEqual(expected, word_boundary.isBoundary(input[0..length], offsets[index]));
        }
    }
}

test "word boundary regex assertions" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, matches: bool }{
        .{ .pattern = "\\b{wb}hello\\b{wb}", .input = "hello", .matches = true },
        .{ .pattern = "hello\\b{wb}world", .input = "hello world", .matches = false },
        .{ .pattern = "hello\\b{wb} world", .input = "hello world", .matches = true },
        .{ .pattern = "h\\B{wb}e", .input = "he", .matches = true },
        .{ .pattern = "don't\\b{wb}", .input = "don't", .matches = true },
        .{ .pattern = "don\\b{wb}'t", .input = "don't", .matches = false },
        .{ .pattern = "\\B{wb}", .input = "", .matches = false },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(allocator, case.input));
    }
}
