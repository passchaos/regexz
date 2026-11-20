//! Deterministic replay of capture saves and forced greedy rune runs.
const std = @import("std");
const model = @import("model.zig");
const shapes = @import("shapes.zig");
const unset = std.math.maxInt(usize);

/// The instruction graph is immutable for the workspace's lifetime. Prove
/// forced continuations once, when capture replay is first needed.
pub const Plan = enum {
    unprepared,
    forced,
    general,

    pub fn prepare(self: *Plan, instructions: []const model.Instruction, body: usize) bool {
        if (self.* == .unprepared) self.* = if (canReplay(instructions, body)) .forced else .general;
        return self.* == .forced;
    }
};

fn canReplay(instructions: []const model.Instruction, body: usize) bool {
    var pc = body;
    for (0..instructions.len) |_| {
        if (pc >= instructions.len) return false;
        pc = switch (instructions[pc]) {
            .save => |save| save.next,
            .literal_byte => |literal| literal.next,
            .literal_rune => |literal| literal.next,
            .byte => |next| next,
            .consume => |consume| consume.next,
            .star => |star| blk: {
                if (!forcedContinuation(instructions, star.set, star.next)) return false;
                break :blk star.next;
            },
            .accept => return true,
            else => return false,
        };
    }
    return false;
}

fn forcedContinuation(instructions: []const model.Instruction, set: model.Set, next: usize) bool {
    var pc = next;
    for (0..instructions.len) |_| {
        if (pc >= instructions.len) return false;
        switch (instructions[pc]) {
            .save => |save| pc = save.next,
            .accept => return true,
            .literal_byte => |literal| return !set.matches(literal.value),
            .literal_rune => |literal| return !set.matches(literal.value),
            .consume => |consume| return !shapes.setsOverlap(set, consume.set),
            else => return false,
        }
    }
    return false;
}

/// Borrowed views and counters owned by the search workspace.
pub const Context = struct {
    instructions: []const model.Instruction,
    body: usize,
    slots: []usize,
    steps: *usize,
    max_steps: usize,
    forced_runs: bool,
};

/// Deterministic replay for a straight-line program of saves, literals,
/// and greedy set runs whose continuation cannot start with a member.
/// Such a run is forced to its maximal length, so no choice or trail
/// bookkeeping is needed. Returns null when the shape is not covered;
/// otherwise whether the walk ended exactly at `end`.
pub inline fn linear(context: Context, input: []const u8, start: usize, end: usize) ?bool {
    const instructions = context.instructions;
    const max_steps = context.max_steps;
    var steps = context.steps.*;
    defer context.steps.* = steps;
    @memset(context.slots, unset);
    var pc = context.body;
    var pos = start;
    // Belt-and-braces cap for malformed zero-width cycles; the real
    // limit is the interpreter budget, which the fallback path enforces.
    const step_limit = (end - start) + instructions.len + 16;
    var walked: usize = 0;
    while (true) {
        walked += 1;
        if (walked > step_limit) return null;
        steps += 1;
        if (steps > max_steps) return null;
        switch (instructions[pc]) {
            .save => |save| {
                context.slots[save.slot] = pos;
                pc = save.next;
            },
            .literal_byte => |literal| {
                if (pos >= input.len or input[pos] != literal.value) return false;
                pos += 1;
                pc = literal.next;
            },
            .literal_rune => |literal| {
                const rune = runeAt(input, pos) orelse return false;
                if (rune.value != literal.value) return false;
                pos += rune.len;
                pc = literal.next;
            },
            .byte => |next| {
                if (pos >= input.len) return false;
                pos += 1;
                pc = next;
            },
            .consume => |consume| {
                if (consume.set.ascii_only) {
                    if (pos >= input.len or !consume.set.matches(input[pos])) return false;
                    pos += 1;
                } else {
                    pos = consume.set.matchAdvance(input, pos) orelse return false;
                }
                pc = consume.next;
            },
            .star => |star| {
                // The greedy run is forced when its continuation accepts
                // or consumes a literal or set disjoint from this set.
                if (!context.forced_runs) {
                    var next = star.next;
                    while (true) {
                        switch (instructions[next]) {
                            .save => |save| next = save.next,
                            .accept => break,
                            .literal_byte => |literal| {
                                if (star.set.matches(literal.value)) return null;
                                break;
                            },
                            .literal_rune => |literal| {
                                if (star.set.matches(literal.value)) return null;
                                break;
                            },
                            else => return null,
                        }
                    }
                }
                var consumed: usize = 0;
                if (star.set.ascii_only) {
                    while (pos < input.len and star.set.matches(input[pos])) {
                        pos += 1;
                        consumed += 1;
                    }
                } else {
                    while (star.set.matchAdvance(input, pos)) |advanced| {
                        pos = advanced;
                        consumed += 1;
                    }
                }
                steps += consumed;
                if (steps > max_steps) return null;
                pc = star.next;
            },
            .accept => return pos == end,
            else => return null,
        }
    }
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
