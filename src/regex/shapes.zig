//! Recognition of compiled shapes that admit deterministic scans.
//!
//! A greedy unbounded loop over a single set compiles to a fixed instruction
//! sequence. The search engine and the streaming scanner both recognize it
//! here so they agree on what counts as the shape and on the captured set.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;

/// `save0 -> member -> star(set) -> save1 -> accept` (`set+`).
///
/// The star backtracks in general, but its continuation always accepts, so a
/// match is the maximal run of members at the leftmost member position.
pub fn setRun(program: Program) ?model.Set {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 7) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .star or
        std.meta.activeTag(ins[6]) != .save) return null;
    if (program.start != 6 or program.body != 5) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const star = ins[4].star;
    if (star.next != 3 or star.backtrack) return null;
    const save0 = ins[6].save;
    if (save0.slot != 0 or save0.next != 5) return null;
    if (star.set.ranges.len == 0) return null;
    switch (ins[5]) {
        // A single-rune set compiles to a literal; the loop set must then be
        // exactly that rune, which also rejects shapes like `ab*`.
        .literal_byte => |literal| {
            if (literal.next != 4 or star.set.ranges.len != 1) return null;
            const range = star.set.ranges[0];
            if (range.first != literal.value or range.last != literal.value) return null;
        },
        .literal_rune => |literal| {
            if (literal.next != 4 or star.set.ranges.len != 1) return null;
            const range = star.set.ranges[0];
            if (range.first != literal.value or range.last != literal.value) return null;
        },
        .consume => |consume| {
            if (consume.next != 4 or star.set.ranges.len != consume.set.ranges.len) return null;
            for (star.set.ranges, consume.set.ranges) |a, b| {
                if (a.first != b.first or a.last != b.last) return null;
            }
        },
        else => return null,
    }
    return star.set;
}

pub fn sameSet(a: model.Set, b: model.Set) bool {
    if (a.ranges.len != b.ranges.len) return false;
    for (a.ranges, b.ranges) |left, right| {
        if (left.first != right.first or left.last != right.last) return false;
    }
    return true;
}

/// A chain `setA+ separator [setB+ tail]` where the separator cannot start a
/// `setA` run and the tail cannot start a `setB` run. The match is then
/// determined by the first separator occurrence that has a non-empty run
/// before it (and a valid run and tail after it, when present).
pub const Chain = struct {
    set_a: model.Set,
    /// The trailing run after the separator; null when the pattern ends at
    /// the separator (e.g. `\w+@`).
    set_b: ?model.Set = null,
    separator: [8]u8 = undefined,
    separator_len: u8 = 0,
    tail: [8]u8 = undefined,
    tail_len: u8 = 0,
    /// Capture slots for the two runs; 0 when the program has no captures.
    slot_a: u16 = 0,
    slot_b: u16 = 0,
};

const max_literal_bytes = 8;

fn isLiteral(instruction: model.Instruction) bool {
    return std.meta.activeTag(instruction) == .literal_byte or std.meta.activeTag(instruction) == .literal_rune;
}

fn appendLiteral(bytes: *[max_literal_bytes]u8, length: *u8, instruction: model.Instruction) bool {
    const used: usize = length.*;
    switch (instruction) {
        .literal_byte => |literal| {
            if (used == max_literal_bytes) return false;
            bytes[used] = literal.value;
            length.* = @intCast(used + 1);
            return true;
        },
        .literal_rune => |literal| {
            var encoded: [4]u8 = undefined;
            const count = std.unicode.utf8Encode(literal.value, &encoded) catch return false;
            if (used + count > max_literal_bytes) return false;
            @memcpy(bytes[used..][0..count], encoded[0..count]);
            length.* = @intCast(used + count);
            return true;
        },
        else => return false,
    }
}

/// `save0 [saveA memberA starA saveA+1] separator [saveB memberB starB saveB+1] tail* save1 accept`.
pub fn chain(program: Program) ?Chain {
    if (program.extended or program.capture_count > 2) return null;
    const ins = program.instructions;
    if (ins.len < 8 or ins.len > 40) return null;
    if (program.accept != 0) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (program.start >= ins.len) return null;
    const start = ins[program.start];
    if (std.meta.activeTag(start) != .save) return null;
    if (start.save.slot != 0 or start.save.next != program.body) return null;
    var result = Chain{ .set_a = undefined };
    // 0, 1, 2, and the save0 instruction.
    var visited: usize = 4;
    var pc = program.body;
    // Optional capture start for the first run.
    if (std.meta.activeTag(ins[pc]) == .save) {
        result.slot_a = ins[pc].save.slot;
        visited += 1;
        pc = ins[pc].save.next;
        if (pc >= ins.len) return null;
    }
    const run_a = runBody(ins, pc) orelse return null;
    result.set_a = run_a.set;
    visited += 2;
    pc = ins[run_a.star].star.next;
    if (pc >= ins.len) return null;
    if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot != 1) {
        if (result.slot_a == 0 or ins[pc].save.slot != result.slot_a + 1) return null;
        visited += 1;
        pc = ins[pc].save.next;
        if (pc >= ins.len) return null;
    } else if (result.slot_a != 0) return null;
    while (isLiteral(ins[pc])) {
        if (!appendLiteral(&result.separator, &result.separator_len, ins[pc])) return null;
        visited += 1;
        pc = literalNext(ins[pc]);
        if (pc >= ins.len or visited > ins.len) return null;
    }
    if (result.separator_len == 0 or visited > ins.len) return null;
    if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot != 1) {
        result.slot_b = ins[pc].save.slot;
        visited += 1;
        pc = ins[pc].save.next;
        if (pc >= ins.len) return null;
    }
    if (runBody(ins, pc)) |run_b| {
        result.set_b = run_b.set;
        visited += 2;
        pc = ins[run_b.star].star.next;
        if (pc >= ins.len) return null;
        if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot != 1) {
            if (result.slot_b == 0 or ins[pc].save.slot != result.slot_b + 1) return null;
            visited += 1;
            pc = ins[pc].save.next;
            if (pc >= ins.len) return null;
        } else if (result.slot_b != 0) return null;
    }
    while (isLiteral(ins[pc])) {
        if (!appendLiteral(&result.tail, &result.tail_len, ins[pc])) return null;
        visited += 1;
        pc = literalNext(ins[pc]);
        if (pc >= ins.len or visited > ins.len) return null;
    }
    const finish = ins[pc];
    if (std.meta.activeTag(finish) != .save) return null;
    if (finish.save.slot != 1 or finish.save.next != program.accept) return null;
    visited += 1;
    if (visited != ins.len) return null;
    // Capture slots must be a matched pair, and their presence must agree
    // with the program's capture count.
    if (result.slot_a != 0) {
        if (result.slot_b != 0) {
            if (result.slot_b != result.slot_a + 2 or program.capture_count != 2) return null;
        } else if (program.capture_count != 1) return null;
    } else if (result.slot_b != 0 or program.capture_count != 0) return null;
    if (result.set_a.ranges.len == 0) return null;
    if (result.set_b) |set_b| {
        if (set_b.ranges.len == 0) return null;
    }
    // The separator must end the first run, and the tail must end the second.
    const separator_first = firstRune(result.separator[0..result.separator_len]) orelse return null;
    if (result.set_a.matches(separator_first)) return null;
    if (result.tail_len != 0) {
        const tail_first = firstRune(result.tail[0..result.tail_len]) orelse return null;
        if (result.set_b) |set_b| {
            if (set_b.matches(tail_first)) return null;
        }
    }
    return result;
}

fn literalNext(instruction: model.Instruction) usize {
    return switch (instruction) {
        .literal_byte => |literal| literal.next,
        .literal_rune => |literal| literal.next,
        else => unreachable,
    };
}

fn firstRune(bytes: []const u8) ?u21 {
    if (bytes.len == 0) return null;
    if (bytes[0] < 0x80) return bytes[0];
    const length = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (length > bytes.len) return null;
    return std.unicode.utf8Decode(bytes[0..length]) catch null;
}

const RunBody = struct { set: model.Set, star: usize };

fn runBody(ins: []const model.Instruction, pc: usize) ?RunBody {
    if (pc >= ins.len) return null;
    const first = ins[pc];
    const star_pc = switch (first) {
        .consume => |consume| consume.next,
        .literal_byte => |literal| literal.next,
        .literal_rune => |literal| literal.next,
        else => return null,
    };
    if (star_pc >= ins.len or std.meta.activeTag(ins[star_pc]) != .star) return null;
    const star = ins[star_pc].star;
    switch (first) {
        .consume => |consume| if (!sameSet(consume.set, star.set)) return null,
        .literal_byte => |literal| if (!singleRuneSet(star.set, literal.value)) return null,
        .literal_rune => |literal| if (!singleRuneSet(star.set, literal.value)) return null,
        else => unreachable,
    }
    return .{ .set = star.set, .star = star_pc };
}

fn singleRuneSet(set: model.Set, rune: u21) bool {
    return set.ranges.len == 1 and set.ranges[0].first == rune and set.ranges[0].last == rune;
}

/// `save0 -> star(set) -> save1 -> accept` (`set*`).
///
/// The star must be non-backtracking, which holds when its continuation is
/// the accepting save.
pub fn setStar(program: Program) ?model.Set {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 6) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .star or
        std.meta.activeTag(ins[5]) != .save) return null;
    if (program.start != 5 or program.body != 4) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const star = ins[4].star;
    if (star.next != 3 or star.backtrack) return null;
    const save0 = ins[5].save;
    if (save0.slot != 0 or save0.next != 4) return null;
    if (star.set.ranges.len == 0) return null;
    return star.set;
}
