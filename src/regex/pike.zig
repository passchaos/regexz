//! Linear-time leftmost-first search for linear (non-extended) programs.
//!
//! The backtracking VM in `replace.zig` needs capture slots and a work budget.
//! Linear programs can use this Pike-style thread list instead: work is
//! bounded by input bytes times program size, and thread order preserves
//! leftmost-first priority. Each thread carries its own capture slots, so the
//! search returns exact group boundaries without backtracking.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const unset = std.math.maxInt(usize);

pub const Match = struct {
    start: usize,
    end: usize,
    /// Whole-match and group slots. Points into the workspace and is valid
    /// until the next `find` call.
    slots: []const usize,
};
const Thread = struct { pc: u32, start: usize, slots: []usize };
const ResetEntry = struct { slot: u16, old: usize };

/// Upper bound on slot-arena words (two lists of `instructions × slots`).
/// Programs with very many captures stay on the bounded backtracking VM.
const max_slot_words: usize = 1 << 20;

pub fn eligible(program: Program) bool {
    if (program.extended) return false;
    const slot_count = 2 * (@as(usize, program.capture_count) + 1);
    if (slot_count > 256) return false;
    const instructions = program.instructions.len;
    if (instructions == 0 or instructions > max_slot_words / slot_count) return false;
    for (program.instructions) |instruction| switch (instruction) {
        .byte => return false,
        else => {},
    };
    return true;
}

fn position(input: []const u8, offset: usize) struct { start: bool, end: bool, final_newline: bool, previous: ?u21, next: ?u21 } {
    const final_newline = offset == input.len or
        (offset + 1 == input.len and input[offset] == '\n') or
        (offset + 2 == input.len and input[offset] == '\r' and input[offset + 1] == '\n');
    return .{
        .start = offset == 0,
        .end = offset == input.len,
        .final_newline = final_newline,
        .previous = if (offset == 0) null else input[offset - 1],
        .next = if (offset == input.len) null else input[offset],
    };
}

fn isWord(rune: ?u21) bool {
    const value = rune orelse return false;
    return value == '_' or (value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9');
}

fn allows(context: anytype, assertion: model.Assertion) bool {
    const boundary = isWord(context.previous) != isWord(context.next);
    return switch (assertion) {
        .start_text, .start_match => context.start,
        .end_text => context.end,
        .end_text_or_newline => context.end or context.final_newline,
        .start_line => context.start or context.previous == '\n',
        .end_line => context.end or context.next == '\n',
        .word_boundary, .word_boundary_unicode => boundary,
        .no_word_boundary, .no_word_boundary_unicode => !boundary,
    };
}

fn runeAt(input: []const u8, offset: usize) ?struct { value: u21, len: usize } {
    if (offset >= input.len) return null;
    const byte = input[offset];
    if (byte < 0x80) return .{ .value = byte, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(byte) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn runeLenAt(input: []const u8, offset: usize) usize {
    return if (runeAt(input, offset)) |rune| rune.len else 1;
}

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    current: []Thread,
    next: []Thread,
    slot_a: []usize,
    slot_b: []usize,
    current_used: usize = 0,
    next_used: usize = 0,
    scratch: []usize,
    best_slots: []usize,
    slot_count: usize,
    reset_trail: std.ArrayList(ResetEntry) = .empty,
    seen: []u32,
    epoch: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, program: Program) std.mem.Allocator.Error!Workspace {
        const instructions = program.instructions.len;
        const slot_count = 2 * (@as(usize, program.capture_count) + 1);
        const current = try allocator.alloc(Thread, instructions);
        errdefer allocator.free(current);
        const next = try allocator.alloc(Thread, instructions);
        errdefer allocator.free(next);
        const slot_a = try allocator.alloc(usize, instructions * slot_count);
        errdefer allocator.free(slot_a);
        const slot_b = try allocator.alloc(usize, instructions * slot_count);
        errdefer allocator.free(slot_b);
        const scratch = try allocator.alloc(usize, slot_count);
        errdefer allocator.free(scratch);
        const best_slots = try allocator.alloc(usize, slot_count);
        errdefer allocator.free(best_slots);
        @memset(best_slots, unset);
        const seen = try allocator.alloc(u32, instructions);
        @memset(seen, 0);
        return .{
            .allocator = allocator,
            .current = current,
            .next = next,
            .slot_a = slot_a,
            .slot_b = slot_b,
            .scratch = scratch,
            .best_slots = best_slots,
            .slot_count = slot_count,
            .seen = seen,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.current);
        self.allocator.free(self.next);
        self.allocator.free(self.slot_a);
        self.allocator.free(self.slot_b);
        self.allocator.free(self.scratch);
        self.allocator.free(self.best_slots);
        self.allocator.free(self.seen);
        self.reset_trail.deinit(self.allocator);
        self.* = undefined;
    }

    fn copySlots(self: *Workspace, region: []usize, used: *usize, slots: []const usize) model.Error![]usize {
        if (used.* + self.slot_count > region.len) return error.RegexLimitExceeded;
        const destination = region[used.*..][0..self.slot_count];
        @memcpy(destination, slots);
        used.* += self.slot_count;
        return destination;
    }

    /// Add `index` and its epsilon closure to `list`, preserving leftmost-first
    /// priority. `slots` is a mutable scratch buffer: saves are applied while
    /// walking the path and restored before returning, so sibling branches see
    /// the original captures.
    fn add(
        self: *Workspace,
        program: Program,
        list: []Thread,
        count: *usize,
        region: []usize,
        used: *usize,
        index: usize,
        start: usize,
        input: []const u8,
        offset: usize,
        slots: []usize,
    ) model.Error!void {
        if (self.seen[index] == self.epoch) return;
        self.seen[index] = self.epoch;
        switch (program.instructions[index]) {
            .accept, .consume, .literal_byte, .literal_rune => {
                list[count.*] = .{
                    .pc = @intCast(index),
                    .start = start,
                    .slots = try self.copySlots(region, used, slots),
                };
                count.* += 1;
            },
            .star => |*star| {
                // Greedy: list the loop thread before its exit so it keeps
                // priority at the next position.
                list[count.*] = .{
                    .pc = @intCast(index),
                    .start = start,
                    .slots = try self.copySlots(region, used, slots),
                };
                count.* += 1;
                try self.add(program, list, count, region, used, star.next, start, input, offset, slots);
            },
            .split => |*split| {
                try self.add(program, list, count, region, used, split.left, start, input, offset, slots);
                try self.add(program, list, count, region, used, split.right, start, input, offset, slots);
            },
            .save => |*save| {
                const old = slots[save.slot];
                slots[save.slot] = offset;
                try self.add(program, list, count, region, used, save.next, start, input, offset, slots);
                slots[save.slot] = old;
            },
            .dispatch => |*dispatch| {
                for (program.dispatches[dispatch.table].branches) |branch| {
                    try self.add(program, list, count, region, used, branch, start, input, offset, slots);
                }
            },
            .reset_captures => |*reset| {
                const base = self.reset_trail.items.len;
                var slot = reset.first;
                while (slot < reset.last) : (slot += 1) {
                    try self.reset_trail.append(self.allocator, .{ .slot = slot, .old = slots[slot] });
                    slots[slot] = unset;
                }
                try self.add(program, list, count, region, used, reset.next, start, input, offset, slots);
                while (self.reset_trail.items.len > base) {
                    const entry = self.reset_trail.pop().?;
                    slots[entry.slot] = entry.old;
                }
            },
            .assertion => |*assertion| {
                if (allows(position(input, offset), assertion.kind)) {
                    try self.add(program, list, count, region, used, assertion.next, start, input, offset, slots);
                }
            },
            .lookahead => |*look| {
                const next = runeAt(input, offset);
                const matched = if (next) |rune| look.set.matches(rune.value) else false;
                if (matched != look.negative) {
                    try self.add(program, list, count, region, used, look.next, start, input, offset, slots);
                }
            },
            else => unreachable,
        }
    }

    fn nextEpoch(self: *Workspace) u32 {
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.seen, 0);
            self.epoch = 1;
        }
        return self.epoch;
    }

    pub fn find(self: *Workspace, program: Program, input: []const u8, search_start: usize) model.Error!?Match {
        if (search_start > input.len) return null;
        var current_count: usize = 0;
        var next_count: usize = 0;
        var recorded: ?Match = null;
        var offset = search_start;
        self.current_used = 0;
        self.next_used = 0;
        // Continue the epoch sequence across calls so stale `seen` entries
        // from a previous search cannot suppress threads in this one.
        var current_epoch: u32 = self.nextEpoch();
        while (true) {
            self.epoch = current_epoch;
            if (recorded == null and current_count == 0 and program.skip_start) {
                // No carried threads: fast-forward to the next byte that can
                // begin a match.
                while (offset < input.len and !program.first.allowsByte(input[offset])) {
                    offset += if (input[offset] < 0x80) 1 else runeLenAt(input, offset);
                }
            }
            if (recorded == null) {
                const allowed = if (program.skip_start)
                    offset < input.len and program.first.allowsByte(input[offset])
                else
                    true;
                if (allowed) {
                    // New starts have lower priority than threads carried
                    // from earlier positions, so append them last.
                    @memset(self.scratch, unset);
                    self.scratch[0] = offset;
                    try self.add(
                        program,
                        self.current,
                        &current_count,
                        self.slot_a,
                        &self.current_used,
                        program.body,
                        offset,
                        input,
                        offset,
                        self.scratch,
                    );
                }
            }
            const next_epoch = self.nextEpoch();
            for (self.current[0..current_count]) |thread| {
                switch (program.instructions[thread.pc]) {
                    .accept => {
                        @memcpy(self.best_slots, thread.slots);
                        self.best_slots[1] = offset;
                        recorded = .{ .start = thread.start, .end = offset, .slots = self.best_slots };
                        break;
                    },
                    .consume => |*consume| if (consume.set.matchAdvance(input, offset)) |next| {
                        try self.add(
                            program,
                            self.next,
                            &next_count,
                            self.slot_b,
                            &self.next_used,
                            consume.next,
                            thread.start,
                            input,
                            next,
                            thread.slots,
                        );
                    },
                    .literal_byte => |*literal| {
                        if (offset < input.len and input[offset] == literal.value) {
                            try self.add(
                                program,
                                self.next,
                                &next_count,
                                self.slot_b,
                                &self.next_used,
                                literal.next,
                                thread.start,
                                input,
                                offset + 1,
                                thread.slots,
                            );
                        }
                    },
                    .literal_rune => |*literal| if (runeAt(input, offset)) |rune| {
                        if (rune.value == literal.value) {
                            try self.add(
                                program,
                                self.next,
                                &next_count,
                                self.slot_b,
                                &self.next_used,
                                literal.next,
                                thread.start,
                                input,
                                offset + rune.len,
                                thread.slots,
                            );
                        }
                    },
                    .star => |*star| if (star.set.matchAdvance(input, offset)) |next| {
                        // Re-adding the star also re-adds its exit at the new
                        // offset.
                        try self.add(
                            program,
                            self.next,
                            &next_count,
                            self.slot_b,
                            &self.next_used,
                            thread.pc,
                            thread.start,
                            input,
                            next,
                            thread.slots,
                        );
                    },
                    else => unreachable,
                }
            }
            if (recorded != null and next_count == 0) return recorded;
            if (offset == input.len) return recorded;
            offset += runeLenAt(input, offset);
            const swap_threads = self.current;
            self.current = self.next;
            self.next = swap_threads;
            const swap_slots = self.slot_a;
            self.slot_a = self.slot_b;
            self.slot_b = swap_slots;
            self.current_used = self.next_used;
            self.next_used = 0;
            current_count = next_count;
            next_count = 0;
            current_epoch = next_epoch;
        }
    }
};
