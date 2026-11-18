//! Canonical Unicode sets, ASCII Perl/POSIX classes and bounded complements.
//!
//! Negation and case folding are materialized at compile time. The resulting
//! `Set` is always positive, so matching is one binary search with no
//! per-rune fold walk.
const std = @import("std");
const m = @import("model.zig");

fn lessThan(_: void, a: m.Range, b: m.Range) bool {
    return a.first < b.first or (a.first == b.first and a.last < b.last);
}

/// Add every simple case-fold peer of the runes already in `ranges`.
/// Only runes covered by the fold table can produce peers, so the work is
/// bounded by the size of that table rather than by the input range width.
fn appendFolded(gpa: std.mem.Allocator, ranges: *std.ArrayList(m.Range)) m.Error!void {
    const original_len = ranges.items.len;
    for (0..m.unicode.fold_range_count) |index| {
        const folded = m.unicode.foldRange(index);
        // A fold entry is self-contained when every peer stays inside it.
        // That is only true for some EvenOdd/OddEven entries; entries with a
        // non-trivial delta (for example A-Z -> a-z) must still be expanded.
        const first_peer = m.unicode.foldNext(folded.first);
        const last_peer = m.unicode.foldNext(folded.last);
        const self_contained = first_peer >= folded.first and first_peer <= folded.last and
            last_peer >= folded.first and last_peer <= folded.last;
        for (0..original_len) |range_index| {
            const range = ranges.items[range_index];
            if (self_contained and range.first <= folded.first and range.last >= folded.last) continue;
            const low = @max(range.first, folded.first);
            const high = @min(range.last, folded.last);
            if (low > high) continue;
            var rune: u32 = low;
            while (rune <= high) : (rune += 1) {
                var peer: u32 = m.unicode.foldNext(@intCast(rune));
                while (peer != rune) : (peer = m.unicode.foldNext(@intCast(peer))) {
                    try ranges.append(gpa, .{ .first = @intCast(peer), .last = @intCast(peer) });
                }
            }
        }
    }
}

fn complement(gpa: std.mem.Allocator, ranges: []const m.Range, limit: usize) m.Error![]const m.Range {
    var inverted: std.ArrayList(m.Range) = .empty;
    errdefer inverted.deinit(gpa);
    var next: u32 = 0;
    for (ranges) |range| {
        if (next < range.first) {
            if (inverted.items.len >= limit) return error.RegexLimitExceeded;
            try inverted.append(gpa, .{ .first = @intCast(next), .last = range.first - 1 });
        }
        next = @as(u32, range.last) + 1;
    }
    if (next <= 0x10ffff) {
        if (inverted.items.len >= limit) return error.RegexLimitExceeded;
        try inverted.append(gpa, .{ .first = @intCast(next), .last = 0x10ffff });
    }
    return inverted.toOwnedSlice(gpa);
}

/// Build a materialized set, including its 128-bit ASCII membership bitmap.
pub fn fromRanges(ranges: []const m.Range) m.Set {
    var bitmap = [2]u64{ 0, 0 };
    var ascii_only = true;
    for (ranges) |range| {
        if (range.last >= 128) ascii_only = false;
        const end: u32 = @min(@as(u32, range.last), 127);
        var rune: u32 = range.first;
        while (rune <= end) : (rune += 1) {
            bitmap[@intCast(rune >> 6)] |= @as(u64, 1) << @intCast(rune & 63);
        }
    }
    return .{ .ranges = ranges, .ascii = bitmap, .ascii_only = ascii_only };
}

pub fn normalize(gpa: std.mem.Allocator, raw: []const m.Range, negate: bool, fold: bool, limit: usize) m.Error!m.Set {
    if (raw.len > limit) return error.RegexLimitExceeded;
    var ranges: std.ArrayList(m.Range) = .empty;
    defer ranges.deinit(gpa);
    try ranges.appendSlice(gpa, raw);
    if (fold) try appendFolded(gpa, &ranges);
    std.mem.sort(m.Range, ranges.items, {}, lessThan);
    var count: usize = 0;
    for (ranges.items) |range| {
        if (range.first > range.last) return error.InvalidRegex;
        if (count != 0 and @as(u32, range.first) <= @as(u32, ranges.items[count - 1].last) + 1) {
            ranges.items[count - 1].last = @max(ranges.items[count - 1].last, range.last);
        } else {
            ranges.items[count] = range;
            count += 1;
        }
    }
    if (count > limit) return error.RegexLimitExceeded;
    if (negate) return fromRanges(try complement(gpa, ranges.items[0..count], limit));
    const owned = try ranges.toOwnedSlice(gpa);
    return fromRanges(owned[0..count]);
}

/// Unicode White_Space, the set PCRE2 uses for UCP `\s`.
pub const unicode_space_ranges = [_]m.Range{
    .{ .first = 0x09, .last = 0x0d },
    .{ .first = 0x20, .last = 0x20 },
    .{ .first = 0x85, .last = 0x85 },
    .{ .first = 0xa0, .last = 0xa0 },
    .{ .first = 0x1680, .last = 0x1680 },
    .{ .first = 0x2000, .last = 0x200a },
    .{ .first = 0x2028, .last = 0x2029 },
    .{ .first = 0x202f, .last = 0x202f },
    .{ .first = 0x205f, .last = 0x205f },
    .{ .first = 0x3000, .last = 0x3000 },
};
/// PCRE2 `\h`: horizontal whitespace.
pub const horizontal_space_ranges = [_]m.Range{
    .{ .first = '\t', .last = '\t' },
    .{ .first = ' ', .last = ' ' },
    .{ .first = 0xa0, .last = 0xa0 },
    .{ .first = 0x1680, .last = 0x1680 },
    .{ .first = 0x180e, .last = 0x180e },
    .{ .first = 0x2000, .last = 0x200a },
    .{ .first = 0x202f, .last = 0x202f },
    .{ .first = 0x205f, .last = 0x205f },
    .{ .first = 0x3000, .last = 0x3000 },
};
/// PCRE2 `\v`: vertical whitespace.
pub const vertical_space_ranges = [_]m.Range{
    .{ .first = '\n', .last = '\n' },
    .{ .first = 0x0b, .last = 0x0c },
    .{ .first = '\r', .last = '\r' },
    .{ .first = 0x85, .last = 0x85 },
    .{ .first = 0x2028, .last = 0x2029 },
};
pub fn unicodePerlSpace(gpa: std.mem.Allocator, negate: bool, fold: bool, limit: usize) m.Error!m.Set {
    return normalize(gpa, &unicode_space_ranges, negate, fold, limit);
}

/// Raw ranges for a Unicode property, allocated in `gpa`.
pub fn unicodePropertyRanges(gpa: std.mem.Allocator, name: []const u8) m.Error![]const m.Range {
    const group = m.unicode.lookup(name) orelse return error.InvalidRegex;
    const ranges = try gpa.alloc(m.Range, group.count);
    for (ranges, 0..) |*range, index| range.* = group.range(index);
    return ranges;
}

/// UCP word characters: letters, marks, numbers, and connector punctuation.
pub fn unicodeWordRanges(gpa: std.mem.Allocator, limit: usize) m.Error![]const m.Range {
    return unicodePropertyUnion(gpa, &.{ "L", "M", "N", "Pc" }, limit);
}

/// Union of several Unicode property groups.
pub fn unicodePropertyUnion(gpa: std.mem.Allocator, names: []const []const u8, limit: usize) m.Error![]const m.Range {
    var ranges: std.ArrayList(m.Range) = .empty;
    errdefer ranges.deinit(gpa);
    for (names) |name| {
        const group = m.unicode.lookup(name) orelse return error.InvalidRegex;
        if (ranges.items.len + group.count > limit) return error.RegexLimitExceeded;
        for (0..group.count) |index| try ranges.append(gpa, group.range(index));
    }
    return ranges.toOwnedSlice(gpa);
}

pub fn append(list: *std.ArrayList(m.Range), gpa: std.mem.Allocator, set: m.Set, limit: usize) m.Error!void {
    if (list.items.len + set.ranges.len > limit) return error.RegexLimitExceeded;
    try list.appendSlice(gpa, set.ranges);
}

pub fn ascii(name: []const u8) ?[]const m.Range {
    const digit = &[_]m.Range{.{ .first = '0', .last = '9' }};
    const upper = &[_]m.Range{.{ .first = 'A', .last = 'Z' }};
    const lower = &[_]m.Range{.{ .first = 'a', .last = 'z' }};
    if (std.mem.eql(u8, name, "digit")) return digit;
    if (std.mem.eql(u8, name, "upper")) return upper;
    if (std.mem.eql(u8, name, "lower")) return lower;
    if (std.mem.eql(u8, name, "alpha")) return &.{ upper[0], lower[0] };
    if (std.mem.eql(u8, name, "alnum")) return &.{ digit[0], upper[0], lower[0] };
    if (std.mem.eql(u8, name, "word")) return &.{ digit[0], upper[0], .{ .first = '_', .last = '_' }, lower[0] };
    if (std.mem.eql(u8, name, "xdigit")) return &.{ digit[0], .{ .first = 'A', .last = 'F' }, .{ .first = 'a', .last = 'f' } };
    if (std.mem.eql(u8, name, "blank")) return &.{ .{ .first = '\t', .last = '\t' }, .{ .first = ' ', .last = ' ' } };
    if (std.mem.eql(u8, name, "space")) return &.{ .{ .first = '\t', .last = '\r' }, .{ .first = ' ', .last = ' ' } };
    if (std.mem.eql(u8, name, "perl_space")) return &.{ .{ .first = '\t', .last = '\n' }, .{ .first = '\x0c', .last = '\r' }, .{ .first = ' ', .last = ' ' } };
    if (std.mem.eql(u8, name, "cntrl")) return &.{ .{ .first = 0, .last = 31 }, .{ .first = 127, .last = 127 } };
    if (std.mem.eql(u8, name, "ascii")) return &.{.{ .first = 0, .last = 127 }};
    if (std.mem.eql(u8, name, "graph")) return &.{.{ .first = 33, .last = 126 }};
    if (std.mem.eql(u8, name, "print")) return &.{.{ .first = 32, .last = 126 }};
    if (std.mem.eql(u8, name, "punct")) return &.{ .{ .first = 33, .last = 47 }, .{ .first = 58, .last = 64 }, .{ .first = 91, .last = 96 }, .{ .first = 123, .last = 126 } };
    return null;
}

/// Character-class set operations. Inputs and outputs are normalized
/// (sorted, disjoint) range lists.
pub const SetOp = enum { intersection, difference, symmetric_difference };

fn pushRange(list: *std.ArrayList(m.Range), gpa: std.mem.Allocator, first: u32, last: u32, limit: usize) m.Error!void {
    if (first > last) return;
    if (list.items.len >= limit) return error.RegexLimitExceeded;
    try list.append(gpa, .{ .first = @intCast(first), .last = @intCast(last) });
}

fn intersectRanges(gpa: std.mem.Allocator, a: []const m.Range, b: []const m.Range, limit: usize) m.Error![]const m.Range {
    var out: std.ArrayList(m.Range) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        const first = @max(@as(u32, a[i].first), @as(u32, b[j].first));
        const last = @min(@as(u32, a[i].last), @as(u32, b[j].last));
        try pushRange(&out, gpa, first, last, limit);
        if (a[i].last < b[j].last) i += 1 else j += 1;
    }
    return out.toOwnedSlice(gpa);
}

fn differenceRanges(gpa: std.mem.Allocator, a: []const m.Range, b: []const m.Range, limit: usize) m.Error![]const m.Range {
    var out: std.ArrayList(m.Range) = .empty;
    errdefer out.deinit(gpa);
    var j: usize = 0;
    for (a) |range| {
        var start: u32 = range.first;
        const end: u32 = range.last;
        while (j < b.len and @as(u32, b[j].last) < start) j += 1;
        var k = j;
        while (k < b.len and @as(u32, b[k].first) <= end) : (k += 1) {
            if (@as(u32, b[k].first) > start) try pushRange(&out, gpa, start, @as(u32, b[k].first) - 1, limit);
            if (@as(u32, b[k].last) >= end) {
                start = end + 1;
                break;
            }
            start = @as(u32, b[k].last) + 1;
        }
        if (start <= end) try pushRange(&out, gpa, start, end, limit);
    }
    return out.toOwnedSlice(gpa);
}

fn unionRanges(gpa: std.mem.Allocator, a: []const m.Range, b: []const m.Range, limit: usize) m.Error![]const m.Range {
    var out: std.ArrayList(m.Range) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        const take_a = j >= b.len or (i < a.len and a[i].first <= b[j].first);
        const next = if (take_a) a[i] else b[j];
        if (take_a) i += 1 else j += 1;
        if (out.items.len != 0 and @as(u32, next.first) <= @as(u32, out.items[out.items.len - 1].last) + 1) {
            out.items[out.items.len - 1].last = @max(out.items[out.items.len - 1].last, next.last);
        } else {
            try pushRange(&out, gpa, next.first, next.last, limit);
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Apply a set operation to two materialized sets.
pub fn combine(gpa: std.mem.Allocator, left: m.Set, op: SetOp, right: m.Set, limit: usize) m.Error!m.Set {
    const ranges = switch (op) {
        .intersection => try intersectRanges(gpa, left.ranges, right.ranges, limit),
        .difference => try differenceRanges(gpa, left.ranges, right.ranges, limit),
        .symmetric_difference => blk: {
            const only_left = try differenceRanges(gpa, left.ranges, right.ranges, limit);
            defer gpa.free(only_left);
            const only_right = try differenceRanges(gpa, right.ranges, left.ranges, limit);
            defer gpa.free(only_right);
            break :blk try unionRanges(gpa, only_left, only_right, limit);
        },
    };
    return fromRanges(ranges);
}
