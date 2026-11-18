const std = @import("std");
const regex = @import("../root.zig");
const sentence_boundary = @import("sentence_boundary.zig");
const data = @import("unicode/sentence_break_test_data.zig");

test "UAX #29 sentence break official cases" {
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
            try std.testing.expectEqual(expected, sentence_boundary.isBoundary(input[0..length], offsets[index]));
        }
    }
}

test "sentence boundary regex assertions" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { pattern: []const u8, input: []const u8, matches: bool }{
        .{ .pattern = "\\b{sb}", .input = "", .matches = true },
        .{ .pattern = "\\B{sb}", .input = "", .matches = false },
        .{ .pattern = "Hello.\\b{sb} World", .input = "Hello. World", .matches = false },
        .{ .pattern = "Hello. \\b{sb}World", .input = "Hello. World", .matches = true },
        .{ .pattern = "Hello\\b{sb}. World", .input = "Hello. World", .matches = false },
        .{ .pattern = "Hello!\\b{sb} World", .input = "Hello! World", .matches = false },
        .{ .pattern = "Hello! \\b{sb}World", .input = "Hello! World", .matches = true },
        .{ .pattern = "Hi\\b{sb} there", .input = "Hi there", .matches = false },
        .{ .pattern = "H\\B{sb}ello", .input = "Hello", .matches = true },
        .{ .pattern = "Mr.\\b{sb} Smith", .input = "Mr. Smith", .matches = false },
        .{ .pattern = "Hello.\\n\\b{sb}World", .input = "Hello.\nWorld", .matches = true },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(allocator, case.pattern, .{});
        defer value.deinit();
        try std.testing.expectEqual(case.matches, try value.matches(allocator, case.input));
    }
}
