//! Deterministic set runs with capture saves before and after the run.
//! The shape has one mandatory member followed by a greedy star and accepts
//! immediately, so every capture save has a fixed start or end position.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const prefilter = @import("prefilter.zig");
const shapes = @import("shapes.zig");
const pike = @import("pike.zig");
const unset = std.math.maxInt(usize);
const max_captures = 127;
const mask_words = (2 * (max_captures + 1) + 63) / 64;

pub const Plan = struct {
    set: model.Set,
    start_slots: [mask_words]u64 = .{0} ** mask_words,
    end_slots: [mask_words]u64 = .{0} ** mask_words,
    /// Replay cost excluding the star's additional consumed members.
    instruction_steps: usize,
    slot_words: u8,
    scalar_probes: u8,

    pub fn init(program: Program) ?Plan {
        if (program.capture_count == 0 or program.capture_count > max_captures or !pike.eligible(program)) return null;
        const instructions = program.instructions;
        const slot_count = 2 * (@as(usize, program.capture_count) + 1);
        var start_slots = [_]u64{0} ** mask_words;
        var end_slots = [_]u64{0} ** mask_words;
        var pc = program.body;
        var walked: usize = 0;
        while (pc < instructions.len and walked < instructions.len) {
            walked += 1;
            switch (instructions[pc]) {
                .save => |save| {
                    if (save.slot >= slot_count) return null;
                    start_slots[save.slot >> 6] |= @as(u64, 1) << @intCast(save.slot & 63);
                    pc = save.next;
                },
                .consume, .literal_byte, .literal_rune => break,
                else => return null,
            }
        } else return null;
        const member = instructions[pc];
        pc = switch (member) {
            .consume => |value| value.next,
            .literal_byte => |value| value.next,
            .literal_rune => |value| value.next,
            else => unreachable,
        };
        if (pc >= instructions.len or std.meta.activeTag(instructions[pc]) != .star) return null;
        const star = instructions[pc].star;
        if (star.set.ranges.len == 0) return null;
        switch (member) {
            .consume => |value| {
                if (value.set.ascii_only != star.set.ascii_only or !shapes.sameSet(value.set, star.set) or
                    !std.mem.eql(u64, &value.set.ascii, &star.set.ascii)) return null;
            },
            .literal_byte => |value| if (!singleton(star.set, value.value)) return null,
            .literal_rune => |value| if (!singleton(star.set, value.value)) return null,
            else => unreachable,
        }
        walked += 1;
        pc = star.next;
        while (pc < instructions.len and walked < instructions.len) {
            walked += 1;
            switch (instructions[pc]) {
                .save => |save| {
                    if (save.slot >= slot_count) return null;
                    end_slots[save.slot >> 6] |= @as(u64, 1) << @intCast(save.slot & 63);
                    pc = save.next;
                },
                .accept => return .{
                    .set = star.set,
                    .start_slots = start_slots,
                    .end_slots = end_slots,
                    .instruction_steps = walked,
                    .slot_words = @intCast((slot_count + 63) / 64),
                    .scalar_probes = if (@as(usize, @popCount(star.set.ascii[0])) + @popCount(star.set.ascii[1]) <= 10) 8 else 2,
                },
                else => return null,
            }
        }
        return null;
    }

    pub const Span = struct { start: usize, end: usize };

    pub fn findUnicode(
        self: *const Plan,
        first: *prefilter.FirstFilter,
        input: []const u8,
        from: usize,
        slots: []usize,
        steps: *usize,
        max_steps: usize,
        linear_fallback: bool,
    ) error{RegexLimitExceeded}!?Span {
        steps.* = 0;
        var start = from;
        var rejected: u8 = 0;
        while (start < input.len) {
            start = first.indexOfRuneCandidates(input, start) orelse return null;
            // Decode a candidate once. Its width advances rejected valid
            // runes as well as matches; malformed input advances one byte.
            const byte = input[start];
            const length = if (byte < 0x80) 1 else std.unicode.utf8ByteSequenceLength(byte) catch {
                start += 1;
                continue;
            };
            if (length > input.len - start) {
                start += 1;
                continue;
            }
            const rune: u21 = if (byte < 0x80) byte else std.unicode.utf8Decode(input[start..][0..length]) catch {
                start += 1;
                continue;
            };
            const first_end = start + length;
            if (!self.set.matches(rune)) {
                start = first_end;
                if (rejected < 8) {
                    rejected += 1;
                    if (rejected == 8) first.prepareRunePrefixes(self.set);
                }
                continue;
            }
            if (!linear_fallback and max_steps < self.instruction_steps) {
                steps.* = max_steps +| 1;
                return error.RegexLimitExceeded;
            }
            var end = first_end;
            var extra: usize = 0;
            while (self.set.matchAdvance(input, end)) |next| {
                if (!linear_fallback and extra == max_steps - self.instruction_steps) {
                    steps.* = max_steps +| 1;
                    return error.RegexLimitExceeded;
                }
                end = next;
                extra += 1;
            }
            steps.* = self.instruction_steps +| extra;
            self.fillSlots(slots, start, end);
            return .{ .start = start, .end = end };
        }
        return null;
    }

    pub fn find(
        self: *const Plan,
        table: *const [256]bool,
        first: *const prefilter.FirstFilter,
        input: []const u8,
        from: usize,
        slots: []usize,
        steps: *usize,
        max_steps: usize,
        linear_fallback: bool,
    ) error{RegexLimitExceeded}!?Span {
        steps.* = 0;
        if (from >= input.len) return null;
        var offset = from;
        // Literal/digit sets handle several short separators cheaply. Wider
        // classes use two probes, then switch long gaps to SIMD.
        const scalar_limit = from + @min(input.len - from, @as(usize, self.scalar_probes));
        while (offset < scalar_limit and !table[input[offset]]) offset += 1;
        if (offset >= scalar_limit) {
            if (offset >= input.len) return null;
            offset = first.indexOf(input, offset) orelse return null;
        }
        const start = offset;
        offset += 1;
        if (linear_fallback) {
            while (offset < input.len and table[input[offset]]) offset += 1;
        } else {
            if (max_steps < self.instruction_steps) {
                steps.* = max_steps + 1;
                return error.RegexLimitExceeded;
            }
            const extra = @min(input.len - offset, max_steps - self.instruction_steps);
            const stop = offset + extra;
            while (offset < stop and table[input[offset]]) offset += 1;
            if (offset == stop and offset < input.len and table[input[offset]]) {
                steps.* = max_steps + 1;
                return error.RegexLimitExceeded;
            }
        }
        steps.* = std.math.add(usize, self.instruction_steps, offset - start - 1) catch std.math.maxInt(usize);
        // This scan is itself linear and needs no choices or capture trail.
        // With fallback enabled it supplies the same captures as the Pike VM;
        // strict callers retain the deterministic replay's step limit.
        self.fillSlots(slots, start, offset);
        return .{ .start = start, .end = offset };
    }

    fn fillSlots(self: *const Plan, slots: []usize, start: usize, end: usize) void {
        @memset(slots, unset);
        writeSlots(self.start_slots[0..self.slot_words], slots, start);
        writeSlots(self.end_slots[0..self.slot_words], slots, end);
        slots[0] = start;
        slots[1] = end;
    }
};

fn singleton(set: model.Set, value: u21) bool {
    return set.ranges.len == 1 and set.ranges[0].first == value and
        set.ranges[0].last == value and set.matches(value);
}

fn writeSlots(masks: []const u64, slots: []usize, position: usize) void {
    for (masks, 0..) |mask, word| {
        var remaining = mask;
        while (remaining != 0) {
            const bit = @ctz(remaining);
            slots[word * 64 + bit] = position;
            remaining &= remaining - 1;
        }
    }
}
