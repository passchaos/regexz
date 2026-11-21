//! Canonical Unicode sets, ASCII Perl/POSIX classes and bounded complements.
//!
//! Negation and case folding are materialized at compile time. The resulting
//! `Set` is always positive, so matching is one binary search with no
//! per-rune fold walk.
const std = @import("std");
const m = @import("model.zig");

/// Sorting only by `first` is enough: the merge loop takes the maximum
/// `last` of adjacent ranges with the same start, so the tie order is
/// irrelevant. Dropping the `last` comparison removes a branch that
/// mispredicts on the many equal starts produced by property unions.
fn lessThan(_: void, a: m.Range, b: m.Range) bool {
    return a.first < b.first;
}

/// Whether the ranges are already sorted by `first`. Property groups and
/// most parsed classes arrive sorted, so the full sort only runs for unions
/// that concatenate them out of order.
fn sorted(ranges: []const m.Range) bool {
    for (ranges[1..], 1..) |range, index| {
        if (range.first < ranges[index - 1].first) return false;
    }
    return true;
}

/// Add every simple case-fold peer of the runes already in `ranges`.
/// Only runes covered by the fold table can produce peers, so the work is
/// bounded by the size of that table rather than by the input range width.
fn appendFolded(gpa: std.mem.Allocator, ranges: *std.ArrayList(m.Range)) m.Error!void {
    const original_len = ranges.items.len;
    const fold_count = m.unicode.fold_range_count;
    for (0..original_len) |range_index| {
        const range = ranges.items[range_index];
        // Fold entries are sorted, so binary-search the first entry that can
        // intersect this class range and walk only the overlapping entries.
        // Small classes such as case-insensitive literals then touch one or
        // two entries instead of the whole table.
        var low: usize = 0;
        var high: usize = fold_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (m.unicode.foldRange(middle).last < range.first) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        while (low < fold_count) : (low += 1) {
            const folded = m.unicode.foldRange(low);
            if (folded.first > range.last) break;
            // A fold entry is self-contained when every peer stays inside it.
            // That is only true for some EvenOdd/OddEven entries; entries with
            // a non-trivial delta (for example A-Z -> a-z) must still be
            // expanded.
            const first_peer = m.unicode.foldNext(folded.first);
            const last_peer = m.unicode.foldNext(folded.last);
            const self_contained = first_peer >= folded.first and first_peer <= folded.last and
                last_peer >= folded.first and last_peer <= folded.last;
            if (self_contained and range.first <= folded.first and range.last >= folded.last) continue;
            const intersect_first = @max(range.first, folded.first);
            const intersect_last = @min(range.last, folded.last);
            var rune: u32 = intersect_first;
            while (rune <= intersect_last) : (rune += 1) {
                var peer: u32 = m.unicode.foldNext(@intCast(rune));
                while (peer != rune) : (peer = m.unicode.foldNext(@intCast(peer))) {
                    try ranges.append(gpa, .{ .first = @intCast(peer), .last = @intCast(peer) });
                }
            }
        }
    }
}

/// Add Turkish/Azeri peers: `i` pairs with U+0130 and `I` with U+0131,
/// while the ASCII `I`/`i` pair is removed.
fn appendTurkishFolded(gpa: std.mem.Allocator, ranges: *std.ArrayList(m.Range)) m.Error!void {
    const original_len = ranges.items.len;
    try appendFolded(gpa, ranges);
    var write: usize = 0;
    for (ranges.items, 0..) |range, index| {
        if (index >= original_len and range.first == range.last and (range.first == 'I' or range.first == 'i')) continue;
        ranges.items[write] = range;
        write += 1;
    }
    ranges.shrinkRetainingCapacity(write);
    for (ranges.items[0..original_len]) |range| {
        if (range.first <= 'i' and range.last >= 'i') try ranges.append(gpa, .{ .first = 0x130, .last = 0x130 });
        if (range.first <= 'I' and range.last >= 'I') try ranges.append(gpa, .{ .first = 0x131, .last = 0x131 });
        if (range.first <= 0x130 and range.last >= 0x130) try ranges.append(gpa, .{ .first = 'i', .last = 'i' });
        if (range.first <= 0x131 and range.last >= 0x131) try ranges.append(gpa, .{ .first = 'I', .last = 'I' });
    }
}

/// Add ASCII case peers for `(?r)`; Unicode pairs stay unfolded.
fn appendAsciiFolded(gpa: std.mem.Allocator, ranges: *std.ArrayList(m.Range)) m.Error!void {
    const original_len = ranges.items.len;
    for (0..original_len) |index| {
        const range = ranges.items[index];
        const upper_low = @max(range.first, 'A');
        const upper_high = @min(range.last, 'Z');
        if (upper_low <= upper_high) {
            var rune: u32 = upper_low;
            while (rune <= upper_high) : (rune += 1) try ranges.append(gpa, .{ .first = @intCast(rune + 32), .last = @intCast(rune + 32) });
        }
        const lower_low = @max(range.first, 'a');
        const lower_high = @min(range.last, 'z');
        if (lower_low <= lower_high) {
            var rune: u32 = lower_low;
            while (rune <= lower_high) : (rune += 1) try ranges.append(gpa, .{ .first = @intCast(rune - 32), .last = @intCast(rune - 32) });
        }
    }
}

fn complement(gpa: std.mem.Allocator, ranges: []const m.Range, limit: usize) m.Error![]const m.Range {
    var inverted: std.ArrayList(m.Range) = .empty;
    errdefer inverted.deinit(gpa);
    // The complement has at most one more range than the input; size it once
    // instead of growing through several reallocations.
    try inverted.ensureTotalCapacity(gpa, ranges.len + 1);
    var next: u32 = 0;
    for (ranges) |range| {
        if (next < range.first) {
            if (inverted.items.len >= limit) return error.RegexLimitExceeded;
            inverted.appendAssumeCapacity(.{ .first = @intCast(next), .last = range.first - 1 });
        }
        next = @as(u32, range.last) + 1;
    }
    if (next <= 0x10ffff) {
        if (inverted.items.len >= limit) return error.RegexLimitExceeded;
        inverted.appendAssumeCapacity(.{ .first = @intCast(next), .last = 0x10ffff });
    }
    return inverted.toOwnedSlice(gpa);
}

/// Complement an already-normalized set without copying and re-merging it.
pub fn complementSet(gpa: std.mem.Allocator, set: m.Set, limit: usize) m.Error!m.Set {
    return fromRanges(try complement(gpa, set.ranges, limit));
}

/// Build a materialized set, including its 128-bit ASCII membership bitmap.
pub fn fromRanges(ranges: []const m.Range) m.Set {
    var bitmap = [2]u64{ 0, 0 };
    var ascii_only = true;
    for (ranges) |range| {
        if (range.last >= 128) ascii_only = false;
        const end: u32 = @min(@as(u32, range.last), 127);
        if (range.first > end) continue;
        const first_word: usize = @intCast(range.first >> 6);
        if (range.first == end) {
            bitmap[first_word] |= @as(u64, 1) << @intCast(range.first & 63);
            continue;
        }
        const last_word: usize = @intCast(end >> 6);
        const first_mask = @as(u64, std.math.maxInt(u64)) << @as(u6, @intCast(range.first & 63));
        const last_mask = @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(63 - (end & 63)));
        if (first_word == last_word) {
            bitmap[first_word] |= first_mask & last_mask;
        } else {
            bitmap[first_word] |= first_mask;
            bitmap[last_word] |= last_mask;
        }
    }
    return .{ .ranges = ranges, .ascii = bitmap, .ascii_only = ascii_only };
}

/// Normalize an owned range list in place. The parser's class operand is
/// already allocated from the compile arena; taking ownership avoids the
/// copy that `normalize` makes before sorting.
pub fn normalizeOwned(gpa: std.mem.Allocator, list: std.ArrayList(m.Range), negate: bool, fold: m.Fold, limit: usize) m.Error!m.Set {
    var ranges = list;
    errdefer ranges.deinit(gpa);
    if (ranges.items.len > limit) return error.RegexLimitExceeded;
    if (fold != .none) {
        switch (fold) {
            .ascii => try appendAsciiFolded(gpa, &ranges),
            .turkish => try appendTurkishFolded(gpa, &ranges),
            else => try appendFolded(gpa, &ranges),
        }
    }
    if (!sorted(ranges.items)) std.mem.sort(m.Range, ranges.items, {}, lessThan);
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
    if (negate) {
        const result = try complement(gpa, ranges.items[0..count], limit);
        ranges.deinit(gpa);
        return fromRanges(result);
    }
    return fromRanges(ranges.items[0..count]);
}

pub fn normalize(gpa: std.mem.Allocator, raw: []const m.Range, negate: bool, fold: m.Fold, limit: usize) m.Error!m.Set {
    if (raw.len > limit) return error.RegexLimitExceeded;
    var ranges: std.ArrayList(m.Range) = .empty;
    defer ranges.deinit(gpa);
    try ranges.appendSlice(gpa, raw);
    if (fold != .none) {
        switch (fold) {
            .ascii => try appendAsciiFolded(gpa, &ranges),
            .turkish => try appendTurkishFolded(gpa, &ranges),
            else => try appendFolded(gpa, &ranges),
        }
    }
    if (!sorted(ranges.items)) std.mem.sort(m.Range, ranges.items, {}, lessThan);
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

/// PCRE2's UCP `\s` set: Unicode White_Space plus U+180E from `\h`.
pub const unicode_space_ranges = [_]m.Range{
    .{ .first = 0x09, .last = 0x0d },
    .{ .first = 0x20, .last = 0x20 },
    .{ .first = 0x85, .last = 0x85 },
    .{ .first = 0xa0, .last = 0xa0 },
    .{ .first = 0x1680, .last = 0x1680 },
    .{ .first = 0x180e, .last = 0x180e },
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
    return unicodePropertyUnion(gpa, &.{ "L", "N", "Mn", "Pc" }, limit);
}

/// Union of several Unicode property groups.
pub fn unicodePropertyUnion(gpa: std.mem.Allocator, names: []const []const u8, limit: usize) m.Error![]const m.Range {
    if (m.unicode.lookupUnion(names)) |table| {
        if (table.count > limit) return error.RegexLimitExceeded;
        const ranges = try gpa.alloc(m.Range, table.count);
        for (ranges, 0..) |*range, index| range.* = table.range(index);
        return ranges;
    }
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

/// Append a sorted set to a sorted list, merging in place from the back.
pub fn appendSorted(list: *std.ArrayList(m.Range), gpa: std.mem.Allocator, set: m.Set, limit: usize) m.Error!void {
    if (list.items.len + set.ranges.len > limit) return error.RegexLimitExceeded;
    if (set.ranges.len == 0) return;
    if (list.items.len == 0) {
        try list.appendSlice(gpa, set.ranges);
        return;
    }
    const old_len = list.items.len;
    const total = old_len + set.ranges.len;
    try list.ensureTotalCapacity(gpa, total);
    list.items.len = total;
    var i = old_len;
    var j = set.ranges.len;
    var k = total;
    while (i > 0 and j > 0) {
        if (list.items[i - 1].first > set.ranges[j - 1].first) {
            k -= 1;
            list.items[k] = list.items[i - 1];
            i -= 1;
        } else {
            k -= 1;
            list.items[k] = set.ranges[j - 1];
            j -= 1;
        }
    }
    while (i > 0) {
        k -= 1;
        list.items[k] = list.items[i - 1];
        i -= 1;
    }
    while (j > 0) {
        k -= 1;
        list.items[k] = set.ranges[j - 1];
        j -= 1;
    }
}

/// Append a precomputed union to a sorted list, merging in place. The
/// ranges are read from the generated table directly, avoiding an
/// intermediate set allocation.
pub fn appendUnionSorted(list: *std.ArrayList(m.Range), gpa: std.mem.Allocator, table: m.unicode.Union, limit: usize) m.Error!void {
    if (list.items.len + table.count > limit) return error.RegexLimitExceeded;
    if (table.count == 0) return;
    if (list.items.len == 0) {
        try list.ensureTotalCapacity(gpa, table.count);
        var index: usize = 0;
        while (index < table.count) : (index += 1) list.appendAssumeCapacity(table.range(index));
        return;
    }
    const old_len = list.items.len;
    const total = old_len + table.count;
    try list.ensureTotalCapacity(gpa, total);
    list.items.len = total;
    var i = old_len;
    var j = table.count;
    var k = total;
    while (i > 0 and j > 0) {
        const range = table.range(j - 1);
        if (list.items[i - 1].first > range.first) {
            k -= 1;
            list.items[k] = list.items[i - 1];
            i -= 1;
        } else {
            k -= 1;
            list.items[k] = range;
            j -= 1;
        }
    }
    while (i > 0) {
        k -= 1;
        list.items[k] = list.items[i - 1];
        i -= 1;
    }
    while (j > 0) {
        k -= 1;
        list.items[k] = table.range(j - 1);
        j -= 1;
    }
}

/// Append a precomputed union to an unsorted operand.
pub fn appendUnion(list: *std.ArrayList(m.Range), gpa: std.mem.Allocator, table: m.unicode.Union, limit: usize) m.Error!void {
    if (list.items.len + table.count > limit) return error.RegexLimitExceeded;
    try list.ensureUnusedCapacity(gpa, table.count);
    var index: usize = 0;
    while (index < table.count) : (index += 1) list.appendAssumeCapacity(table.range(index));
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

/// PCRE2 10.43+ `[:xdigit:]` under UCP: ASCII hex digits plus their fullwidth
/// forms.
const fullwidth_xdigit_ranges = [_]m.Range{
    .{ .first = '0', .last = '9' },
    .{ .first = 'A', .last = 'F' },
    .{ .first = 'a', .last = 'f' },
    .{ .first = 0xff10, .last = 0xff19 },
    .{ .first = 0xff21, .last = 0xff26 },
    .{ .first = 0xff41, .last = 0xff46 },
};

/// POSIX class ranges under UCP, following PCRE2's replacement rules.
/// `ascii_posix` (`(?aP)`) forces the ASCII tables; `ascii_digit` (`(?aT)`)
/// only affects digit/xdigit.
pub fn posixRanges(
    gpa: std.mem.Allocator,
    name: []const u8,
    ucp: bool,
    ascii_posix: bool,
    ascii_digit: bool,
    limit: usize,
) m.Error![]const m.Range {
    const ascii_ranges = ascii(name) orelse return error.InvalidRegex;
    if (!ucp or ascii_posix) return ascii_ranges;
    if (std.mem.eql(u8, name, "ascii")) return ascii_ranges;
    if (std.mem.eql(u8, name, "alnum")) return unicodePropertyUnion(gpa, &.{ "L", "N" }, limit);
    if (std.mem.eql(u8, name, "alpha")) return unicodePropertyRanges(gpa, "L");
    if (std.mem.eql(u8, name, "blank")) return &horizontal_space_ranges;
    if (std.mem.eql(u8, name, "cntrl")) return unicodePropertyRanges(gpa, "Cc");
    if (std.mem.eql(u8, name, "digit")) return if (ascii_digit) ascii_ranges else unicodePropertyRanges(gpa, "Nd");
    if (std.mem.eql(u8, name, "lower")) return unicodePropertyRanges(gpa, "Ll");
    if (std.mem.eql(u8, name, "space")) return &unicode_space_ranges;
    if (std.mem.eql(u8, name, "upper")) return unicodePropertyRanges(gpa, "Lu");
    if (std.mem.eql(u8, name, "word")) return unicodeWordRanges(gpa, limit);
    if (std.mem.eql(u8, name, "xdigit")) return if (ascii_digit) ascii_ranges else &fullwidth_xdigit_ranges;
    if (std.mem.eql(u8, name, "graph")) {
        const base = try unicodePropertyUnion(gpa, &.{ "L", "M", "N", "P", "S", "Cf" }, limit);
        const exceptions = [_]m.Range{
            .{ .first = 0x061c, .last = 0x061c },
            .{ .first = 0x180e, .last = 0x180e },
            .{ .first = 0x2066, .last = 0x2069 },
        };
        const base_set = try normalize(gpa, base, false, .none, limit);
        const excluded = try normalize(gpa, &exceptions, false, .none, limit);
        return (try combine(gpa, base_set, .difference, excluded, limit)).ranges;
    }
    if (std.mem.eql(u8, name, "print")) {
        const graph = try posixRanges(gpa, "graph", true, false, ascii_digit, limit);
        const graph_set = try normalize(gpa, graph, false, .none, limit);
        const zs = try normalize(gpa, try unicodePropertyRanges(gpa, "Zs"), false, .none, limit);
        return (try combine(gpa, graph_set, .symmetric_difference, zs, limit)).ranges;
    }
    if (std.mem.eql(u8, name, "punct")) {
        const p = try normalize(gpa, try unicodePropertyRanges(gpa, "P"), false, .none, limit);
        const s = try normalize(gpa, try unicodePropertyRanges(gpa, "S"), false, .none, limit);
        const below_256 = try normalize(gpa, &.{.{ .first = 0, .last = 255 }}, false, .none, limit);
        const s_ascii = try combine(gpa, s, .intersection, below_256, limit);
        return (try combine(gpa, p, .symmetric_difference, s_ascii, limit)).ranges;
    }
    return error.InvalidRegex;
}

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
