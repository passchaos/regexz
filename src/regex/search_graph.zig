//! One reusable DFS workspace for search-DFA construction analyses.
const std = @import("std");

pub const Walk = struct {
    storage: []u32,
    seen: []u8,
    stack: []u32,
    pending: usize = 0,
    epoch: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, count: usize) std.mem.Allocator.Error!Walk {
        const seen_words = (count + 3) / 4;
        // Each visited node pops once and emits at most two successors, so
        // pending entries never exceed count + 1. Marking on pop retains
        // the original left-first priority walk's order.
        const storage = try allocator.alloc(u32, seen_words + count + 1);
        const seen = std.mem.sliceAsBytes(storage[0..seen_words])[0..count];
        @memset(seen, 0);
        return .{ .storage = storage, .seen = seen, .stack = storage[seen_words..] };
    }

    pub fn deinit(self: *Walk, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }

    pub fn reset(self: *Walk, start: usize) void {
        self.pending = 0;
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.seen, 0);
            self.epoch = 1;
        }
        self.push(start);
    }

    pub fn push(self: *Walk, pc: usize) void {
        std.debug.assert(self.pending < self.stack.len);
        self.stack[self.pending] = @intCast(pc);
        self.pending += 1;
    }

    pub fn pop(self: *Walk) ?u32 {
        while (self.pending != 0) {
            self.pending -= 1;
            const pc = self.stack[self.pending];
            if (self.seen[pc] == self.epoch) continue;
            self.seen[pc] = self.epoch;
            return pc;
        }
        return null;
    }
};
