//! SIMD first-byte prefilter for selective start sets.
//!
//! ASCII first-byte sets are scanned 16 bytes at a time: small sets compare
//! against up to eight byte splats, and sets that form at most four contiguous
//! ranges (classes like `[A-Z]` or `\w`) compare against the range bounds.
//! Everything else falls back to the byte-at-a-time bitmap loop.
const std = @import("std");
const model = @import("model.zig");

const max_simd_bytes = 8;
const max_simd_ranges = 4;
const Vec = @Vector(16, u8);

/// First offset at or after `start` holding `byte`, scanned 16 bytes at a
/// time. Returns null when the byte is absent.
pub fn indexOfByte(input: []const u8, start: usize, byte: u8) ?usize {
    if (start >= input.len) return null;
    const needle: Vec = @splat(byte);
    var offset = start;
    while (offset + 16 <= input.len) : (offset += 16) {
        const chunk: Vec = input[offset..][0..16].*;
        if (@reduce(.Or, chunk == needle)) {
            while (input[offset] != byte) offset += 1;
            return offset;
        }
    }
    while (offset < input.len) : (offset += 1) {
        if (input[offset] == byte) return offset;
    }
    return null;
}

/// First offset at or after `start` where `a` is immediately followed by
/// `b`, scanned 16 bytes at a time. Returns null when the pair is absent.
pub fn indexOfPair(input: []const u8, start: usize, a: u8, b: u8) ?usize {
    if (start + 1 >= input.len) return null;
    const splat_a: Vec = @splat(a);
    const splat_b: Vec = @splat(b);
    var offset = start;
    while (offset + 16 <= input.len - 1) : (offset += 16) {
        const chunk_a: Vec = input[offset..][0..16].*;
        const chunk_b: Vec = input[offset + 1 ..][0..16].*;
        const mask = (chunk_a == splat_a) & (chunk_b == splat_b);
        if (@reduce(.Or, mask)) {
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                if (input[offset + i] == a and input[offset + i + 1] == b) return offset + i;
            }
        }
    }
    while (offset + 1 < input.len) : (offset += 1) {
        if (input[offset] == a and input[offset + 1] == b) return offset;
    }
    return null;
}

/// Cached first-byte filter. Building the ASCII byte list costs 128 set
/// probes, so workspaces construct this once instead of on every search.
pub const FirstFilter = struct {
    first: model.FirstSet,
    bytes: [max_simd_bytes]u8 = undefined,
    byte_splats: [max_simd_bytes]Vec = undefined,
    count: u8 = 0,
    /// The set has more ASCII bytes than the byte-splat path can compare.
    too_many: bool = false,
    /// Contiguous ASCII runs of the set (at most `max_simd_ranges`); zero
    /// when the set needs more runs than the range path supports.
    ranges: [max_simd_ranges][2]u8 = undefined,
    range_lo: [max_simd_ranges]Vec = undefined,
    range_hi: [max_simd_ranges]Vec = undefined,
    range_count: u8 = 0,

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
        // Contiguous runs: classes like `[A-Z]` or `\w` are far cheaper to
        // match as ranges than as byte splats.
        var run_start: usize = 0;
        var in_run = false;
        byte = 0;
        while (byte <= 128) : (byte += 1) {
            const member = byte < 128 and first.allowsByte(@intCast(byte));
            if (member and !in_run) {
                run_start = byte;
                in_run = true;
            } else if (!member and in_run) {
                if (result.range_count == max_simd_ranges) {
                    result.range_count = 0;
                    break;
                }
                result.ranges[result.range_count] = .{ @intCast(run_start), @intCast(byte - 1) };
                result.range_count += 1;
                in_run = false;
            }
        }
        var index: usize = 0;
        while (index < result.count) : (index += 1) result.byte_splats[index] = @splat(result.bytes[index]);
        index = 0;
        while (index < result.range_count) : (index += 1) {
            result.range_lo[index] = @splat(result.ranges[index][0]);
            result.range_hi[index] = @splat(result.ranges[index][1]);
        }
        return result;
    }

    /// Return the first offset at or after `start` whose byte can begin a
    /// match, or null when no such byte exists.
    pub fn indexOf(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        if (start >= input.len) return null;
        if (self.first.empty) return start;
        if (self.range_count != 0) return self.indexOfRanges(input, start);
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
        const nonascii: Vec = @splat(@as(u8, 0x80));
        var offset = start;
        while (offset + 16 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var mask = chunk == self.byte_splats[0];
            var index: usize = 1;
            while (index < count) : (index += 1) mask = mask | (chunk == self.byte_splats[index]);
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

    fn indexOfRanges(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        const nonascii: Vec = @splat(@as(u8, 0x80));
        var offset = start;
        while (offset + 16 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var mask = (chunk >= self.range_lo[0]) & (chunk <= self.range_hi[0]);
            var index: usize = 1;
            while (index < self.range_count) : (index += 1) {
                mask = mask | ((chunk >= self.range_lo[index]) & (chunk <= self.range_hi[index]));
            }
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

/// Multi-literal start filter: scans 16 bytes at a time for the two-byte
/// prefixes of a small literal set, then verifies the full literal.
pub const MultiFilter = struct {
    literals: []const []const u8,
    pairs: [max_pairs]u16 = undefined,
    pair_count: u8 = 0,

    const max_pairs = 16;

    pub fn init(literals: []const []const u8) ?MultiFilter {
        if (literals.len == 0 or literals.len > max_pairs) return null;
        var filter = MultiFilter{ .literals = literals };
        const shared_first = literals[0][0];
        for (literals) |literal| {
            // The pair filter pays off when the first byte is shared (and thus
            // useless as a prefilter); otherwise the cheaper first-byte SIMD
            // filter is already selective.
            if (literal.len < 2 or literal[0] != shared_first) return null;
            const pair = (@as(u16, literal[0]) << 8) | literal[1];
            var exists = false;
            for (filter.pairs[0..filter.pair_count]) |existing| {
                if (existing == pair) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                if (filter.pair_count == max_pairs) return null;
                filter.pairs[filter.pair_count] = pair;
                filter.pair_count += 1;
            }
        }
        if (filter.pair_count == 0) return null;
        return filter;
    }

    fn matchesAt(self: *const MultiFilter, input: []const u8, offset: usize) bool {
        for (self.literals) |literal| {
            if (offset + literal.len > input.len) continue;
            if (std.mem.eql(u8, input[offset..][0..literal.len], literal)) return true;
        }
        return false;
    }

    pub fn indexOf(self: *const MultiFilter, input: []const u8, start: usize) ?usize {
        if (start >= input.len) return null;
        var first_splats: [max_pairs]Vec = undefined;
        var second_splats: [max_pairs]Vec = undefined;
        var pair_index: usize = 0;
        while (pair_index < self.pair_count) : (pair_index += 1) {
            const pair = self.pairs[pair_index];
            first_splats[pair_index] = @splat(@intCast(pair >> 8));
            second_splats[pair_index] = @splat(@intCast(pair & 0xFF));
        }
        const count: usize = self.pair_count;
        var offset = start;
        while (offset + 17 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const next_raw: [16]u8 = input[offset + 1 ..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            const next: Vec = @bitCast(next_raw);
            var mask = @as(@Vector(16, bool), @splat(false));
            pair_index = 0;
            while (pair_index < count) : (pair_index += 1) {
                mask = mask | ((chunk == first_splats[pair_index]) & (next == second_splats[pair_index]));
            }
            if (@reduce(.Or, mask)) {
                var index: usize = 0;
                while (index < 16) : (index += 1) {
                    if (self.matchesAt(input, offset + index)) return offset + index;
                }
            }
        }
        while (offset < input.len) : (offset += 1) {
            if (self.matchesAt(input, offset)) return offset;
        }
        return null;
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

test "MultiFilter finds literal prefixes and agrees with a naive scan" {
    const literals = [_][]const u8{ "sunday", "saturday", "september" };
    const filter = MultiFilter.init(&literals).?;
    const input = "xx symbol sunday saturday september";
    const naive = struct {
        fn index(haystack: []const u8, start: usize, needles: []const []const u8) ?usize {
            var offset = start;
            while (offset < haystack.len) : (offset += 1) {
                for (needles) |needle| {
                    if (offset + needle.len <= haystack.len and std.mem.eql(u8, haystack[offset..][0..needle.len], needle)) return offset;
                }
            }
            return null;
        }
    };
    var start: usize = 0;
    while (start <= input.len) : (start += 1) {
        try std.testing.expectEqual(naive.index(input, start, &literals), filter.indexOf(input, start));
    }
    try std.testing.expectEqual(@as(?usize, 10), filter.indexOf(input, 0));
    try std.testing.expectEqual(@as(?usize, 17), filter.indexOf(input, 11));
    try std.testing.expectEqual(@as(?usize, 26), filter.indexOf(input, 18));
    try std.testing.expectEqual(@as(?usize, null), filter.indexOf(input, 27));
    const short = [_][]const u8{"a"};
    try std.testing.expect(MultiFilter.init(&short) == null);
}
