//! SIMD first-byte prefilter for selective start sets.
//!
//! Small ASCII first-byte sets (the common multi-literal alternation case) are
//! scanned 16 bytes at a time with vector compares. Larger or non-ASCII sets
//! fall back to the byte-at-a-time bitmap loop.
const std = @import("std");
const model = @import("model.zig");

const max_simd_bytes = 8;
const Vec = @Vector(16, u8);

/// Cached first-byte filter. Building the ASCII byte list costs 128 set
/// probes, so workspaces construct this once instead of on every search.
pub const FirstFilter = struct {
    first: model.FirstSet,
    bytes: [max_simd_bytes]u8 = undefined,
    count: u8 = 0,
    /// The set has more ASCII bytes than the vector path can compare.
    too_many: bool = false,

    pub fn init(first: model.FirstSet) FirstFilter {
        var result = FirstFilter{ .first = first };
        var byte: usize = 0;
        while (byte < 128) : (byte += 1) {
            if (!first.allowsByte(@intCast(byte))) continue;
            if (result.count == max_simd_bytes) {
                result.too_many = true;
                break;
            }
            result.bytes[result.count] = @intCast(byte);
            result.count += 1;
        }
        return result;
    }

    /// Return the first offset at or after `start` whose byte can begin a
    /// match, or null when no such byte exists.
    pub fn indexOf(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        if (start >= input.len) return null;
        if (self.first.empty) return start;
        if (self.too_many) return byteLoop(input, start, self.first);
        const count: usize = self.count;
        if (count == 0) {
            if (!self.first.nonascii) return null;
            var offset = start;
            while (offset < input.len) : (offset += 1) {
                if (input[offset] >= 0x80) return offset;
            }
            return null;
        }
        var splats: [max_simd_bytes]Vec = undefined;
        var index: usize = 0;
        while (index < count) : (index += 1) splats[index] = @splat(self.bytes[index]);
        const nonascii: Vec = @splat(@as(u8, 0x80));
        var offset = start;
        while (offset + 16 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var mask = chunk == splats[0];
            index = 1;
            while (index < count) : (index += 1) mask = mask | (chunk == splats[index]);
            if (self.first.nonascii) mask = mask | (chunk >= nonascii);
            if (@reduce(.Or, mask)) {
                var i: usize = 0;
                while (i < 16) : (i += 1) {
                    if (self.first.allowsByte(raw[i])) return offset + i;
                }
            }
        }
        return byteLoop(input, offset, self.first);
    }
};

/// One-shot variant for callers that do not keep a workspace. Hot paths
/// should cache `FirstFilter` instead.
pub fn indexOfFirstSet(input: []const u8, start: usize, first: model.FirstSet) ?usize {
    const filter = FirstFilter.init(first);
    return filter.indexOf(input, start);
}

fn byteLoop(input: []const u8, start: usize, first: model.FirstSet) ?usize {
    var offset = start;
    while (offset < input.len) : (offset += 1) {
        if (first.allowsByte(input[offset])) return offset;
    }
    return null;
}

fn testSet(bytes: []const u8, nonascii: bool) model.FirstSet {
    var set = model.FirstSet{ .nonascii = nonascii };
    for (bytes) |byte| set.ascii[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
    return set;
}

fn naiveIndex(input: []const u8, start: usize, first: model.FirstSet) ?usize {
    var offset = start;
    while (offset < input.len) : (offset += 1) {
        if (first.allowsByte(input[offset])) return offset;
    }
    return null;
}

test "FirstFilter matches the naive scan for small and large sets" {
    const small = testSet("abc", false);
    const large = testSet("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", false);
    const nonascii = testSet("ab", true);
    const inputs = [_][]const u8{
        "",
        "zzz",
        "a",
        "xxabcxx",
        "0123456789abcdefghij0123456789abcdefghij",
        "héllo abc",
        "\xff\x80ab",
    };
    for ([_]model.FirstSet{ small, large, nonascii }) |first| {
        for (inputs) |input| {
            var start: usize = 0;
            while (start <= input.len) : (start += 1) {
                const filter = FirstFilter.init(first);
                try std.testing.expectEqual(naiveIndex(input, start, first), filter.indexOf(input, start));
                try std.testing.expectEqual(naiveIndex(input, start, first), indexOfFirstSet(input, start, first));
            }
        }
    }
}

test "FirstFilter flags sets too large for the vector path" {
    const small = FirstFilter.init(testSet("abc", false));
    try std.testing.expect(!small.too_many);
    try std.testing.expectEqual(@as(u8, 3), small.count);
    const large = FirstFilter.init(testSet("abcdefghijklmnopqrstuvwxyz", false));
    try std.testing.expect(large.too_many);
    const empty = FirstFilter.init(.{});
    try std.testing.expectEqual(@as(u8, 0), empty.count);
    try std.testing.expect(empty.indexOf("abc", 0) == null);
}
