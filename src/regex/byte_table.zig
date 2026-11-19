//! Expand materialized set membership into byte tables without per-byte probes.
const std = @import("std");
const model = @import("model.zig");

pub fn init(comptime length: usize, set: model.Set) [length]bool {
    comptime std.debug.assert(length == 128 or length == 256);
    var table = [_]bool{false} ** length;
    for (set.ascii, 0..) |word, index| {
        var remaining = word;
        while (remaining != 0) {
            const start = @ctz(remaining);
            const shifted = remaining >> @as(u6, @intCast(start));
            const count = @ctz(~shifted);
            const end = @as(usize, start) + count;
            @memset(table[index * 64 + start .. index * 64 + end], true);
            remaining = if (end == 64) 0 else remaining & (@as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(end)));
        }
    }
    if (length == 256 and !set.ascii_only) {
        for (set.ranges) |range| {
            if (range.first >= 256) break;
            const start = @max(@as(usize, range.first), 128);
            const end = @min(@as(usize, range.last) + 1, 256);
            if (start < end) @memset(table[start..end], true);
        }
    }
    return table;
}
