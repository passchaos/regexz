const std = @import("std");
const model = @import("model.zig");
const classes = @import("classes.zig");

fn reference(ranges: []const model.Range) model.Set {
    var bitmap = [_]u64{ 0, 0 };
    var ascii_only = true;
    for (ranges) |range| {
        if (range.last >= 128) ascii_only = false;
        var rune: u32 = range.first;
        const end = @min(@as(u32, range.last), 127);
        while (rune <= end) : (rune += 1) bitmap[rune / 64] |= @as(u64, 1) << @intCast(rune % 64);
    }
    return .{ .ranges = ranges, .ascii = bitmap, .ascii_only = ascii_only };
}

fn check(ranges: []const model.Range) !void {
    const expected = reference(ranges);
    const actual = classes.fromRanges(ranges);
    try std.testing.expectEqualSlices(u64, &expected.ascii, &actual.ascii);
    try std.testing.expectEqual(expected.ascii_only, actual.ascii_only);
    for (0..256) |rune| try std.testing.expectEqual(expected.matches(@intCast(rune)), actual.matches(@intCast(rune)));
}

test "range masks match scalar construction for every ASCII interval" {
    for (0..128) |first| {
        for (first..257) |last| {
            try check(&.{.{ .first = @intCast(first), .last = @intCast(last) }});
        }
    }
}

test "range masks preserve multiple and Unicode intervals" {
    try check(&.{});
    try check(&.{ .{ .first = 62, .last = 65 }, .{ .first = 127, .last = 128 }, .{ .first = 0x4e00, .last = 0x9fff } });
    try check(&.{.{ .first = 0, .last = 0x10ffff }});
    try check(&.{ .{ .first = 97, .last = 122 }, .{ .first = 48, .last = 57 }, .{ .first = 65, .last = 90 }, .{ .first = 95, .last = 95 } });
    try check(&.{ .{ .first = 130, .last = 129 }, .{ .first = 65, .last = 64 } });
}
