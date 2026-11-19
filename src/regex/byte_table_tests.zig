const std = @import("std");
const model = @import("model.zig");
const classes = @import("classes.zig");
const byte_table = @import("byte_table.zig");

fn check(set: model.Set) !void {
    const ascii = byte_table.init(128, set);
    const bytes = byte_table.init(256, set);
    for (0..128) |value| try std.testing.expectEqual(set.matches(@intCast(value)), ascii[value]);
    for (0..256) |value| try std.testing.expectEqual(set.matches(@intCast(value)), bytes[value]);
}

test "byte tables match scalar membership for bitmap boundaries" {
    const patterns = [_][2]u64{
        .{ 0, 0 },                                   .{ ~@as(u64, 0), ~@as(u64, 0) },
        .{ 1, 1 << 63 },                             .{ 1 << 63, 1 },
        .{ 0xaaaaaaaaaaaaaaaa, 0x5555555555555555 }, .{ 0x7fffffffffffffff, 0xfffffffffffffffe },
    };
    for (patterns) |bitmap| {
        // The ASCII bitmap is authoritative even when a set is assembled
        // directly rather than produced by the parser.
        try check(.{ .ranges = &.{}, .ascii = bitmap, .ascii_only = true });
        try check(.{ .ranges = &.{.{ .first = 0, .last = 255 }}, .ascii = bitmap, .ascii_only = false });
    }
    for (0..128) |bit| {
        var bitmap = [_]u64{ 0, 0 };
        bitmap[bit / 64] = @as(u64, 1) << @intCast(bit % 64);
        try check(.{ .ranges = &.{}, .ascii = bitmap, .ascii_only = true });
    }
}

test "byte tables preserve Latin-1 and Unicode range boundaries" {
    for ([_][]const model.Range{
        &.{.{ .first = 0, .last = 0x10ffff }},
        &.{.{ .first = 127, .last = 128 }},
        &.{.{ .first = 255, .last = 256 }},
        &.{ .{ .first = 0, .last = 63 }, .{ .first = 64, .last = 127 }, .{ .first = 128, .last = 255 } },
        &.{ .{ .first = 'A', .last = 'Z' }, .{ .first = 0x85, .last = 0x85 }, .{ .first = 0xa0, .last = 0xa0 }, .{ .first = 0x4e00, .last = 0x9fff } },
    }) |ranges| try check(classes.fromRanges(ranges));
}

test "byte tables match random ASCII bitmaps" {
    var random = std.Random.DefaultPrng.init(191);
    for (0..256) |_| {
        try check(.{ .ranges = &.{}, .ascii = .{ random.random().int(u64), random.random().int(u64) }, .ascii_only = true });
    }
}
