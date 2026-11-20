//! Compact candidate-byte ranges for a materialized rune set.
//! Prefix hits still require UTF-8 validation and exact rune membership.
const model = @import("model.zig");

pub const max_ranges = 4;
const max_codepoint: u21 = 0x10ffff;
const max_leads = 24;

pub const Ranges = struct {
    values: [max_ranges][2]u8 = undefined,
    count: u8 = 0,

    pub fn contains(self: Ranges, byte: u8) bool {
        for (self.values[0..self.count]) |range| {
            if (byte >= range[0] and byte <= range[1]) return true;
        }
        return false;
    }
};

/// Sparse UTF-8 leads plus the set's exact ASCII membership. Wide or
/// fragmented sets retain the caller's original first-rune filter.
pub fn fromSet(set: model.Set) ?Ranges {
    if (set.ascii_only) return null;
    var leads: u64 = 0;
    for (set.ranges) |range| {
        if (range.last < 128 or range.first > max_codepoint) continue;
        const lo = lead(@max(range.first, 128));
        const hi = lead(@min(range.last, max_codepoint));
        const width: u6 = @intCast(hi - lo + 1);
        const offset: u6 = @intCast(lo - 0xc0);
        leads |= ((@as(u64, 1) << width) - 1) << offset;
    }
    if (leads == 0 or @popCount(leads) > max_leads) return null;
    var result = Ranges{};
    var run_start: ?u8 = null;
    for (0..257) |value| {
        const member = if (value < 128)
            (set.ascii[value >> 6] >> @as(u6, @intCast(value & 63))) & 1 != 0
        else if (value >= 0xc2 and value <= 0xf4)
            (leads >> @as(u6, @intCast(value - 0xc0))) & 1 != 0
        else
            false;
        if (member) {
            if (run_start == null) run_start = @intCast(value);
        } else if (run_start) |start| {
            if (result.count == max_ranges) return null;
            result.values[result.count] = .{ start, @intCast(value - 1) };
            result.count += 1;
            run_start = null;
        }
    }
    return if (result.count == 0) null else result;
}

// This monotonic lead mapping also admits surrogate endpoints conservatively;
// the consuming decoder remains responsible for rejecting invalid scalars.
fn lead(rune: u21) u8 {
    if (rune < 0x800) return @intCast(0xc0 | (rune >> 6));
    if (rune < 0x10000) return @intCast(0xe0 | (rune >> 12));
    return @intCast(0xf0 | (rune >> 18));
}
