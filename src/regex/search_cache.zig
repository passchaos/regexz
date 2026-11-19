//! Unicode caches are allocated only when a rune search reaches UTF-8 input.
const std = @import("std");
pub const global_slots: usize = 4096;
pub const front_slots: usize = 32;
pub const max_states: usize = 64;
pub const Entry = extern struct {
    key: u64 = std.math.maxInt(u64),
    accept: u64 = std.math.maxInt(u64),
    next: u32 = 0,
    pad: u32 = 0,
};

// Valid non-ASCII byte keys are nonzero. These shared zero rows are only
// read; init replaces them with owned rows before any cache write.
var empty_front: [max_states * front_slots]Entry = @splat(.{ .key = 0, .accept = 0 });

pub inline fn emptyFront() std.ArrayList(Entry) {
    return .{ .items = &empty_front, .capacity = empty_front.len };
}

pub inline fn slot(key: u64) usize {
    return @intCast((key ^ (key >> 12) ^ (key >> 24)) & (global_slots - 1));
}

pub noinline fn init(allocator: std.mem.Allocator, global: *[]Entry, front: *std.ArrayList(Entry), states: usize) std.mem.Allocator.Error!void {
    var owned_front: std.ArrayList(Entry) = .empty;
    errdefer owned_front.deinit(allocator);
    const entries = try allocator.alloc(Entry, global_slots);
    errdefer allocator.free(entries);
    @memset(entries, .{});
    try owned_front.appendNTimes(allocator, .{}, states * front_slots);
    front.* = owned_front;
    global.* = entries;
}

pub fn deinit(allocator: std.mem.Allocator, global: []Entry, front: *std.ArrayList(Entry)) void {
    if (global.len == 0) return;
    allocator.free(global);
    front.deinit(allocator);
}
