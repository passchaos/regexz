//! True streaming leftmost-first scanner for linear programs.
//!
//! The scanner persists a Pike-style thread list across input chunks. A
//! position is processed only when its next rune (or EOF) is known, so
//! assertions, set-lookahead, and UTF-8 boundaries are evaluated exactly.
//! Captures use absolute stream offsets; the caller's emit callback may copy
//! them before returning.
//!
//! A completed match can still be extended by higher-priority threads. While
//! that happens the scanner keeps the bytes from the match end so it can
//! replay them for the next search; bytes before the current match are
//! discarded as soon as no match is pending. Memory is therefore bounded by
//! the longest pending match, not by the stream length.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const prefilter = @import("prefilter.zig");
const unset = std.math.maxInt(usize);

pub const StreamMatch = struct {
    start: usize,
    end: usize,
    /// Whole-match and group slots in absolute stream offsets. Valid only
    /// during the emit callback.
    slots: []const usize,
};

pub const EmitFn = *const fn (context: ?*anyopaque, match: StreamMatch) void;

const Thread = struct { pc: u32, start: usize, slots: []usize };
const ResetEntry = struct { slot: u16, old: usize };
const Rune = struct { value: u21, len: usize };
const RuneStatus = union(enum) { valid: Rune, invalid, incomplete };
const Position = struct {
    start: bool,
    end: bool,
    final_newline: bool,
    previous: ?u21,
    next: ?u21,
};

fn isWord(rune: ?u21) bool {
    const value = rune orelse return false;
    return value == '_' or (value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9');
}

fn allows(context: Position, assertion: model.Assertion) bool {
    const boundary = isWord(context.previous) != isWord(context.next);
    return switch (assertion) {
        .start_text, .start_match => context.start,
        .end_text => context.end,
        .end_text_or_newline => context.end or context.final_newline,
        .start_line => context.start or context.previous == '\n',
        .end_line => context.end or context.next == '\n',
        .word_boundary, .word_boundary_unicode => boundary,
        .no_word_boundary, .no_word_boundary_unicode => !boundary,
        // Grapheme boundary assertions are extended-only and evaluated by the
        // backtracking VM.
        .grapheme_boundary, .no_grapheme_boundary, .word_boundary_uax29, .no_word_boundary_uax29, .sentence_boundary, .no_sentence_boundary => false,
    };
}

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    program: Program,
    limits: model.Limits,
    slot_count: usize,
    needs_final_newline: bool,
    first_filter: prefilter.FirstFilter,
    // Thread state.
    raw: []Thread,
    raw_count: usize = 0,
    terminal: []Thread,
    terminal_count: usize = 0,
    raw_slots: []usize,
    raw_used: usize = 0,
    terminal_slots: []usize,
    terminal_used: usize = 0,
    scratch: []usize,
    best_slots: []usize,
    seen: []u32,
    epoch: u32 = 0,
    reset_trail: std.ArrayList(ResetEntry) = .empty,
    // Stream state.
    buffer: std.ArrayList(u8) = .empty,
    buffer_base: usize = 0,
    scan: usize = 0,
    offset: usize = 0,
    total_len: usize = 0,
    search_start: usize = 0,
    recorded: ?struct { start: usize, end: usize } = null,
    empty_skip: bool = false,
    eof: bool = false,
    eof_processed: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, program: Program, limits: model.Limits) model.Error!Scanner {
        if (!eligible(program)) return error.UnsupportedRegexFeature;
        const count = program.instructions.len;
        const slot_count = 2 * (@as(usize, program.capture_count) + 1);
        if (slot_count > 256 or count > 2048) return error.UnsupportedRegexFeature;
        const raw = try allocator.alloc(Thread, count);
        errdefer allocator.free(raw);
        const terminal = try allocator.alloc(Thread, count);
        errdefer allocator.free(terminal);
        const raw_slots = try allocator.alloc(usize, count * slot_count);
        errdefer allocator.free(raw_slots);
        const terminal_slots = try allocator.alloc(usize, count * slot_count);
        errdefer allocator.free(terminal_slots);
        const scratch = try allocator.alloc(usize, slot_count);
        errdefer allocator.free(scratch);
        const best_slots = try allocator.alloc(usize, slot_count);
        errdefer allocator.free(best_slots);
        @memset(best_slots, unset);
        const seen = try allocator.alloc(u32, count);
        @memset(seen, 0);
        var needs_final_newline = false;
        for (program.instructions) |instruction| switch (instruction) {
            .assertion => |assertion| if (assertion.kind == .end_text_or_newline) {
                needs_final_newline = true;
            },
            else => {},
        };
        return .{
            .allocator = allocator,
            .program = program,
            .limits = limits,
            .slot_count = slot_count,
            .needs_final_newline = needs_final_newline,
            .first_filter = prefilter.FirstFilter.init(program.first),
            .raw = raw,
            .terminal = terminal,
            .raw_slots = raw_slots,
            .terminal_slots = terminal_slots,
            .scratch = scratch,
            .best_slots = best_slots,
            .seen = seen,
        };
    }

    pub fn deinit(self: *Scanner) void {
        self.allocator.free(self.raw);
        self.allocator.free(self.terminal);
        self.allocator.free(self.raw_slots);
        self.allocator.free(self.terminal_slots);
        self.allocator.free(self.scratch);
        self.allocator.free(self.best_slots);
        self.allocator.free(self.seen);
        self.reset_trail.deinit(self.allocator);
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    fn eligible(program: Program) bool {
        if (program.extended) return false;
        for (program.instructions) |instruction| switch (instruction) {
            .accept, .consume, .literal_byte, .literal_rune, .star, .split, .save, .reset_captures, .assertion, .lookahead, .sub_accept, .ret => {},
            else => return false,
        };
        return true;
    }

    /// Feed one chunk. Matches whose end is already determined are delivered
    /// through `emit`; a match that may still extend is retained until the
    /// next chunk or `finish`.
    pub fn feed(self: *Scanner, chunk: []const u8, context: ?*anyopaque, emit: EmitFn) model.Error!void {
        if (self.finished) return error.InvalidRegex;
        try self.buffer.appendSlice(self.allocator, chunk);
        self.total_len += chunk.len;
        try self.process(context, emit);
    }

    /// Signal end of stream and flush the final match, if any.
    pub fn finish(self: *Scanner, context: ?*anyopaque, emit: EmitFn) model.Error!void {
        if (self.finished) return;
        self.eof = true;
        try self.process(context, emit);
        self.finished = true;
    }

    fn nextEpoch(self: *Scanner) void {
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.seen, 0);
            self.epoch = 1;
        }
    }

    fn push(self: *Scanner, index: usize) void {
        if (self.seen[index] == self.epoch) return;
        self.seen[index] = self.epoch;
    }

    fn copySlots(self: *Scanner, region: []usize, used: *usize, slots: []const usize) model.Error![]usize {
        if (used.* + self.slot_count > region.len) return error.RegexLimitExceeded;
        const destination = region[used.*..][0..self.slot_count];
        @memcpy(destination, slots);
        used.* += self.slot_count;
        return destination;
    }

    /// Epsilon closure for one raw thread or a fresh start. `slots` is the
    /// mutable capture scratch for this path; saves are restored before
    /// returning so sibling branches see the original values.
    fn add(
        self: *Scanner,
        index: usize,
        start: usize,
        offset: usize,
        rune: ?u21,
        slots: []usize,
    ) model.Error!void {
        if (self.seen[index] == self.epoch) return;
        self.seen[index] = self.epoch;
        switch (self.program.instructions[index]) {
            .accept, .consume, .literal_byte, .literal_rune => {
                self.terminal[self.terminal_count] = .{
                    .pc = @intCast(index),
                    .start = start,
                    .slots = try self.copySlots(self.terminal_slots, &self.terminal_used, slots),
                };
                self.terminal_count += 1;
            },
            .star => |star| {
                self.terminal[self.terminal_count] = .{
                    .pc = @intCast(index),
                    .start = start,
                    .slots = try self.copySlots(self.terminal_slots, &self.terminal_used, slots),
                };
                self.terminal_count += 1;
                try self.add(@intCast(star.next), start, offset, rune, slots);
            },
            .split => |split| {
                try self.add(@intCast(split.left), start, offset, rune, slots);
                try self.add(@intCast(split.right), start, offset, rune, slots);
            },
            .save => |save| {
                const old = slots[save.slot];
                slots[save.slot] = offset;
                try self.add(@intCast(save.next), start, offset, rune, slots);
                slots[save.slot] = old;
            },
            .reset_captures => |reset| {
                const base = self.reset_trail.items.len;
                var slot = reset.first;
                while (slot < reset.last) : (slot += 1) {
                    try self.reset_trail.append(self.allocator, .{ .slot = slot, .old = slots[slot] });
                    slots[slot] = unset;
                }
                try self.add(@intCast(reset.next), start, offset, rune, slots);
                while (self.reset_trail.items.len > base) {
                    const entry = self.reset_trail.pop().?;
                    slots[entry.slot] = entry.old;
                }
            },
            .assertion => |assertion| {
                if (allows(self.positionAt(offset), assertion.kind)) {
                    try self.add(@intCast(assertion.next), start, offset, rune, slots);
                }
            },
            .lookahead => |look| {
                const matched = if (rune) |value| look.set.matches(value) else false;
                if (matched != look.negative) {
                    try self.add(@intCast(look.next), start, offset, rune, slots);
                }
            },
            .sub_accept, .ret => {},
            else => unreachable,
        }
    }

    fn runeStatus(self: *Scanner, offset: usize) RuneStatus {
        const rel = offset - self.buffer_base;
        if (rel >= self.buffer.items.len) return .incomplete;
        const byte = self.buffer.items[rel];
        if (byte < 0x80) return .{ .valid = .{ .value = byte, .len = 1 } };
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return .invalid;
        if (len > self.buffer.items.len - rel) return .incomplete;
        const value = std.unicode.utf8Decode(self.buffer.items[rel..][0..len]) catch return .invalid;
        return .{ .valid = .{ .value = value, .len = len } };
    }

    fn runeAtAbsolute(self: *Scanner, offset: usize) ?Rune {
        return switch (self.runeStatus(offset)) {
            .valid => |rune| rune,
            else => null,
        };
    }

    fn positionAt(self: *Scanner, offset: usize) Position {
        const rel = offset - self.buffer_base;
        const total = self.total_len;
        const at_end = self.eof and offset == total;
        var final_newline = false;
        if (self.eof) {
            final_newline = offset == total or
                (offset + 1 == total and rel < self.buffer.items.len and self.buffer.items[rel] == '\n') or
                (offset + 2 == total and rel + 1 < self.buffer.items.len and
                    self.buffer.items[rel] == '\r' and self.buffer.items[rel + 1] == '\n');
        }
        return .{
            .start = offset == 0,
            .end = at_end,
            .final_newline = final_newline,
            .previous = if (offset == 0) null else if (rel > 0) self.buffer.items[rel - 1] else null,
            .next = if (rel < self.buffer.items.len) self.buffer.items[rel] else null,
        };
    }

    fn appendRaw(self: *Scanner, pc: usize, start: usize, slots: []const usize) model.Error!void {
        if (self.raw_count >= self.raw.len) return error.RegexLimitExceeded;
        self.raw[self.raw_count] = .{
            .pc = @intCast(pc),
            .start = start,
            .slots = try self.copySlots(self.raw_slots, &self.raw_used, slots),
        };
        self.raw_count += 1;
    }

    fn processPosition(self: *Scanner, rune: ?u21, at_eof: bool) model.Error!void {
        _ = at_eof;
        self.nextEpoch();
        self.terminal_count = 0;
        self.terminal_used = 0;
        for (self.raw[0..self.raw_count]) |thread| {
            try self.add(thread.pc, thread.start, self.offset, rune, thread.slots);
        }
        if (self.recorded == null and self.offset >= self.search_start) {
            @memset(self.scratch, unset);
            self.scratch[0] = self.offset;
            try self.add(self.program.body, self.offset, self.offset, rune, self.scratch);
        }
        self.raw_count = 0;
        self.raw_used = 0;
        for (self.terminal[0..self.terminal_count]) |thread| {
            switch (self.program.instructions[thread.pc]) {
                .accept => {
                    @memcpy(self.best_slots, thread.slots);
                    self.best_slots[1] = self.offset;
                    self.recorded = .{ .start = thread.start, .end = self.offset };
                    break;
                },
                .consume => |consume| if (rune) |value| {
                    if (consume.set.matches(value)) try self.appendRaw(consume.next, thread.start, thread.slots);
                },
                .literal_byte => |literal| if (rune) |value| {
                    if (value == literal.value) try self.appendRaw(literal.next, thread.start, thread.slots);
                },
                .literal_rune => |literal| if (rune) |value| {
                    if (value == literal.value) try self.appendRaw(literal.next, thread.start, thread.slots);
                },
                .star => |star| if (rune) |value| {
                    if (star.set.matches(value)) try self.appendRaw(thread.pc, thread.start, thread.slots);
                },
                else => unreachable,
            }
        }
    }

    fn discardBefore(self: *Scanner, absolute: usize) void {
        const keep = if (absolute == 0) 0 else absolute - 1;
        if (keep <= self.buffer_base) return;
        const buffer_end = self.buffer_base + self.buffer.items.len;
        if (keep >= buffer_end) {
            self.buffer.clearRetainingCapacity();
            self.buffer_base = absolute;
            self.scan = 0;
            return;
        }
        const drop = keep - self.buffer_base;
        std.mem.copyForwards(u8, self.buffer.items[0..], self.buffer.items[drop..]);
        self.buffer.shrinkRetainingCapacity(self.buffer.items.len - drop);
        self.buffer_base = keep;
        self.scan = absolute - keep;
    }

    fn trimBuffer(self: *Scanner) void {
        self.discardBefore(self.offset);
    }

    fn process(self: *Scanner, context: ?*anyopaque, emit: EmitFn) model.Error!void {
        while (true) {
            if (self.recorded) |record| {
                if (self.raw_count == 0) {
                    emit(context, .{ .start = record.start, .end = record.end, .slots = self.best_slots });
                    var next_start = record.end;
                    if (record.end == record.start) {
                        if (self.runeAtAbsolute(record.end)) |rune| {
                            next_start = record.end + rune.len;
                        } else if (self.eof) {
                            next_start = record.end + 1;
                        } else {
                            self.empty_skip = true;
                            next_start = record.end;
                        }
                    }
                    self.search_start = next_start;
                    self.recorded = null;
                    self.raw_count = 0;
                    self.terminal_count = 0;
                    self.eof_processed = false;
                    self.discardBefore(next_start);
                    self.offset = next_start;
                    self.scan = self.offset - self.buffer_base;
                    continue;
                }
            }
            if (self.empty_skip) {
                if (self.runeAtAbsolute(self.offset)) |rune| {
                    self.search_start = self.offset + rune.len;
                    self.offset += rune.len;
                    self.scan = self.offset - self.buffer_base;
                    self.empty_skip = false;
                } else if (self.eof) {
                    self.empty_skip = false;
                    break;
                } else break;
            }
            if (self.eof_processed) {
                if (self.recorded == null) break;
                continue;
            }
            if (self.eof and self.offset > self.total_len) break;
            const buffer_end = self.buffer_base + self.buffer.items.len;
            if (self.offset >= self.total_len) {
                if (!self.eof) break;
                try self.processPosition(null, true);
                self.eof_processed = true;
                continue;
            }
            if (self.offset >= buffer_end) break;
            if (self.needs_final_newline and !self.eof) {
                // `\Z` at the start of a trailing newline sequence depends on
                // whether more input follows. Defer that position.
                const remaining = self.total_len - self.offset;
                const rel = self.offset - self.buffer_base;
                if (remaining == 1 and rel < self.buffer.items.len and self.buffer.items[rel] == '\n') break;
                if (remaining == 2 and rel + 1 < self.buffer.items.len and
                    self.buffer.items[rel] == '\r' and self.buffer.items[rel + 1] == '\n') break;
            }
            if (self.recorded == null and self.raw_count == 0 and self.program.skip_start and
                self.offset < buffer_end and !self.program.first.allowsByte(self.buffer.items[self.offset - self.buffer_base]))
            {
                const rel = self.offset - self.buffer_base;
                if (self.first_filter.indexOf(self.buffer.items[rel..], 0)) |found| {
                    if (found != 0) {
                        self.offset += found;
                        self.scan = self.offset - self.buffer_base;
                        self.trimBuffer();
                        continue;
                    }
                } else {
                    self.offset = buffer_end;
                    self.scan = self.buffer.items.len;
                    self.trimBuffer();
                    continue;
                }
            }
            const status = self.runeStatus(self.offset);
            if (status == .incomplete and !self.eof) break;
            const rune: ?u21 = switch (status) {
                .valid => |value| value.value,
                else => null,
            };
            const len: usize = switch (status) {
                .valid => |value| value.len,
                else => 1,
            };
            try self.processPosition(rune, false);
            self.offset += len;
            self.scan = self.offset - self.buffer_base;
            if (self.recorded == null) self.trimBuffer();
        }
    }
};
