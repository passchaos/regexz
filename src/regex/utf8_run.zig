//! Expanded UTF-8 automaton for a non-ASCII `set+` program. Each state owns
//! a 256-entry transition row, so a run scan is one table load per byte.
//! Shared by the search fast path (`replace.zig`) and the full-match fast
//! path (`execute.zig`).
//!
//! Tables are immutable and depend only on the set, so process-lifetime
//! allocators share them through a small bounded cache. Rebuilding a broad
//! class table costs tens of microseconds, and streaming scanners are created
//! per stream.
const std = @import("std");
const model = @import("model.zig");
const utf8_set = @import("utf8_set.zig");

const cache_capacity = 8;
const cache_byte_cap = 4 * 1024 * 1024;
/// Broad classes build multi-megabyte tables that a workspace already keeps
/// alive; the cache targets the modest sets rebuilt by per-stream scanners.
const cache_entry_cap = 256 * 1024;

const CacheEntry = struct {
    hash: u64,
    /// Copy owned by the cache, used to verify hash matches exactly.
    ranges: []const model.Range,
    table: []const u16,
};

var cache_mutex: std.atomic.Mutex = .unlocked;
var cache: [cache_capacity]?CacheEntry = .{null} ** cache_capacity;
var cache_bytes: usize = 0;

/// Only process-lifetime allocators share tables: the cache owns them until
/// the process exits, which would look like a leak to tracking allocators.
fn cacheable(allocator: std.mem.Allocator) bool {
    return allocator.vtable == std.heap.page_allocator.vtable or
        allocator.vtable == std.heap.smp_allocator.vtable;
}

fn rangesHash(ranges: []const model.Range) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(std.mem.asBytes(&ranges.len));
    for (ranges) |range| {
        hasher.update(std.mem.asBytes(&range.first));
        hasher.update(std.mem.asBytes(&range.last));
    }
    return hasher.final();
}

fn sameRanges(a: []const model.Range, b: []const model.Range) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.first != right.first or left.last != right.last) return false;
    }
    return true;
}

fn cacheLock() void {
    while (!cache_mutex.tryLock()) std.Thread.yield() catch {};
}

fn cacheUnlock() void {
    cache_mutex.unlock();
}

fn lookupCached(set: model.Set) ?Utf8Run {
    const hash = rangesHash(set.ranges);
    cacheLock();
    defer cacheUnlock();
    for (&cache) |*slot| {
        const entry = slot.* orelse continue;
        if (entry.hash == hash and sameRanges(entry.ranges, set.ranges)) {
            return .{ .table = entry.table, .owned = false };
        }
    }
    return null;
}

fn insertCached(
    allocator: std.mem.Allocator,
    set: model.Set,
    table: []const u16,
) ?Utf8Run {
    const bytes = table.len * @sizeOf(u16) + set.ranges.len * @sizeOf(model.Range);
    if (bytes > cache_entry_cap) return null;
    const hash = rangesHash(set.ranges);
    const ranges = allocator.dupe(model.Range, set.ranges) catch return null;
    cacheLock();
    if (cache_bytes + bytes <= cache_byte_cap) {
        for (&cache) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .hash = hash, .ranges = ranges, .table = table };
                cache_bytes += bytes;
                cacheUnlock();
                return .{ .table = table, .owned = false };
            }
        }
    }
    cacheUnlock();
    allocator.free(ranges);
    return null;
}

/// Expanded UTF-8 automaton for a non-ASCII `set+` program. Each state owns a
/// 256-entry transition row, so the run scan is one table load per byte.
pub const Utf8Run = struct {
    table: []const u16,
    /// False when the table is shared through the process cache.
    owned: bool = true,

    pub fn init(allocator: std.mem.Allocator, set: model.Set) std.mem.Allocator.Error!Utf8Run {
        if (cacheable(allocator)) {
            if (lookupCached(set)) |run| return run;
        }
        const table = try utf8_set.buildTable(allocator, set.ranges);
        errdefer allocator.free(table);
        if (cacheable(allocator)) {
            if (insertCached(allocator, set, table)) |run| return run;
        }
        return .{ .table = table };
    }

    pub fn deinit(self: *const Utf8Run, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        allocator.free(self.table);
    }

    /// Length of the rune at `offset` when it is a member, else null.
    pub fn runeAt(self: *const Utf8Run, input: []const u8, offset: usize) ?usize {
        var state: u16 = 0;
        var index = offset;
        while (index < input.len) {
            const next = self.table[@as(usize, state) * 256 + input[index]];
            if (next == utf8_set.accept) return index - offset + 1;
            if (next == utf8_set.dead) return null;
            state = next;
            index += 1;
        }
        return null;
    }

    /// End of the maximal member run starting at `offset`, plus whether the
    /// scan stopped inside a rune because the input ended. A streaming caller
    /// keeps that partial rune until the next chunk arrives.
    pub const RunEnd = struct { end: usize, incomplete: bool };

    pub fn runEndStatus(self: *const Utf8Run, input: []const u8, offset: usize) RunEnd {
        var end = offset;
        var rune_begin = offset;
        var state: u16 = 0;
        while (end < input.len) {
            const next = self.table[@as(usize, state) * 256 + input[end]];
            if (next == utf8_set.accept) {
                state = 0;
                end += 1;
                rune_begin = end;
            } else if (next == utf8_set.dead) {
                return .{ .end = rune_begin, .incomplete = false };
            } else {
                state = next;
                end += 1;
            }
        }
        if (state != 0) return .{ .end = rune_begin, .incomplete = true };
        return .{ .end = end, .incomplete = false };
    }

    /// End of the maximal member run starting at `offset`.
    pub fn runEnd(self: *const Utf8Run, input: []const u8, offset: usize) usize {
        return self.runEndStatus(input, offset).end;
    }
};
