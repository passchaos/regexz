//! Small direct-mapped rune cache with optional promotion after collisions.
const std = @import("std");

pub const initial_size: usize = 256;
pub const maximum_size: usize = 4096;
const promote_collisions: u8 = 64;
pub const empty_key = std.math.maxInt(u64);
pub const Entry = extern struct {
    key: u64 = empty_key,
    next: u32 = 0,
    pad: u32 = 0,
};

pub inline fn slot(key: u64, capacity: usize) usize {
    // Mix the state id (above bit 20) into small-cache slots as well.
    return @intCast((key ^ (key >> 12) ^ (key >> 21)) & (capacity - 1));
}

pub inline fn put(allocator: std.mem.Allocator, entries: *[]Entry, collisions: *u8, key: u64, next: u32) void {
    const previous = entries.*[slot(key, entries.len)].key;
    if (entries.len < maximum_size and previous != empty_key and previous != key) {
        collisions.* += 1;
        if (collisions.* >= promote_collisions) {
            collisions.* = 0;
            promote(allocator, entries);
        }
    }
    entries.*[slot(key, entries.len)] = .{ .key = key, .next = next };
}

noinline fn promote(allocator: std.mem.Allocator, entries: *[]Entry) void {
    // Growth is optional: allocation failure leaves the existing cache valid.
    const larger = allocator.alloc(Entry, maximum_size) catch return;
    @memset(larger, .{});
    for (entries.*) |entry| {
        if (entry.key != empty_key) larger[slot(entry.key, larger.len)] = entry;
    }
    allocator.free(entries.*);
    entries.* = larger;
}
