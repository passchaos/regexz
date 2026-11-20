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
            if (consume.next != 4 or !sameSet(star.set, consume.set)) return null;
        },
        else => return null,
    }
    return star.set;
}

pub fn sameSet(a: model.Set, b: model.Set) bool {
    if (a.ranges.len != b.ranges.len) return false;
    // Repeated instructions borrow the same immutable materialized ranges.
    if (a.ranges.ptr == b.ranges.ptr) return true;
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
    /// Mandatory members before the separator and whether the run is
    /// unbounded (`set+` / `set{2,}`) or fixed (`set{3}`).
    min_a: u8 = 1,
    star_a: bool = true,
    /// The trailing run after the separator; null when the pattern ends at
    /// the separator (e.g. `\w+@`).
    set_b: ?model.Set = null,
    min_b: u8 = 1,
    star_b: bool = true,
    separator: [8]u8 = undefined,
    separator_len: u8 = 0,
    /// When set, the separator is a run of this set instead of a literal
    /// sequence (e.g. the `\s+` in `\w+\s+\w+`).
    separator_set: ?model.Set = null,
    tail: [8]u8 = undefined,
    tail_len: u8 = 0,
    /// Capture slots for the two runs; 0 when the program has no captures.
    slot_a: u16 = 0,
    slot_b: u16 = 0,
};

const max_literal_bytes = 8;

/// `(setA*)(setB*)...(setZ*)`: captured greedy runs. When the sets are
/// pairwise disjoint the last mandatory run anchors the match end and a chain
/// with no mandatory run matches at the search offset. Overlapping sets are
/// accepted only in `forward` mode: the first run is mandatory and every
/// mandatory run's set is disjoint from all preceding runs, so the greedy
/// maxima are complete and a failed scan cannot be rescued by backtracking.
pub const RunChain = struct {
    pub const max_items = 5;
    /// `anchor` value when every run is nullable.
    pub const no_anchor: u8 = 255;
    sets: [max_items]model.Set = undefined,
    /// Mandatory members before the unbounded tail of the run (`set{2,}` -> 2,
    /// `set+` -> 1, `set*` -> 0).
    minimum: [max_items]u8 = [_]u8{0} ** max_items,
    /// Empty capture group: both slots take the boundary position.
    empty: [max_items]bool = [_]bool{false} ** max_items,
    start_slots: [max_items]u16 = undefined,
    end_slots: [max_items]u16 = undefined,
    count: u8 = 0,
    /// Index of the last mandatory run; runs after it are nullable.
    anchor: u8 = no_anchor,
    /// Scan forward from the first run's members instead of anchoring on the
    /// last mandatory run. Used when the sets overlap but the mandatory runs
    /// are separated from their predecessors.
    forward: bool = false,
    match_start_slot: u16 = 0,
    match_end_slot: u16 = 1,
};

/// Recognizes a captured run chain. Conservative: any other instruction,
/// a fixed-count run or an unsupported overlap rejects the shape.
pub fn runChain(program: Program) ?RunChain {
    if (program.extended or program.capture_count == 0 or program.capture_count > 15) return null;
    const ins = program.instructions;
    if (ins.len < 6 or ins.len > 128 or program.accept != 0) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (program.start >= ins.len) return null;
    const whole = ins[program.start];
    if (std.meta.activeTag(whole) != .save or whole.save.slot != 0 or whole.save.next != program.body) return null;
    var plan = RunChain{};
    var pc = program.body;
    var saw_run = false;
    while (true) {
        if (pc >= ins.len) return null;
        const instruction = ins[pc];
        if (std.meta.activeTag(instruction) != .save) return null;
        const save = instruction.save;
        if (save.slot == 1) {
            // Whole-match end: the body must finish at accept.
            if (save.next >= ins.len or std.meta.activeTag(ins[save.next]) != .accept) return null;
            break;
        }
        if (save.slot < 2 or save.slot & 1 != 0) return null;
        if (plan.count == RunChain.max_items) return null;
        const index = plan.count;
        plan.start_slots[index] = save.slot;
        plan.end_slots[index] = save.slot + 1;
        pc = save.next;
        if (pc >= ins.len) return null;
        if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot == save.slot + 1) {
            plan.empty[index] = true;
            plan.sets[index] = .{ .ranges = &.{} };
            pc = ins[pc].save.next;
        } else if (std.meta.activeTag(ins[pc]) == .star) {
            // Nullable run: the star is the whole group body.
            const star = ins[pc].star;
            if (star.set.ranges.len == 0) return null;
            const end_pc = star.next;
            if (end_pc >= ins.len) return null;
            const end = ins[end_pc];
            if (std.meta.activeTag(end) != .save or end.save.slot != save.slot + 1) return null;
            plan.sets[index] = star.set;
            plan.minimum[index] = 0;
            saw_run = true;
            pc = end.save.next;
        } else if (std.meta.activeTag(ins[pc]) == .split and !ins[pc].split.alternation) {
            // Lazy `set*?`: the split tries the exit (the group end save)
            // first and the body loops back. With disjoint sets the lazy
            // capture expands to exactly the maximal run, so it shares the
            // run-chain boundaries.
            const split = ins[pc].split;
            const end_pc = split.left;
            if (end_pc >= ins.len) return null;
            const end = ins[end_pc];
            if (std.meta.activeTag(end) != .save or end.save.slot != save.slot + 1) return null;
            const body_pc = split.right;
            if (body_pc >= ins.len) return null;
            const body = ins[body_pc];
            const body_set = switch (body) {
                .consume => |consume| blk: {
                    if (consume.next != pc) return null;
                    break :blk consume.set;
                },
                else => return null,
            };
            if (body_set.ranges.len == 0) return null;
            plan.sets[index] = body_set;
            plan.minimum[index] = 0;
            saw_run = true;
            pc = end.save.next;
        } else {
            const run = runPrefix(ins, pc) orelse return null;
            if (!run.star or run.set.ranges.len == 0) return null;
            const end_pc = run.after;
            if (end_pc >= ins.len) return null;
            const end = ins[end_pc];
            if (std.meta.activeTag(end) != .save or end.save.slot != save.slot + 1) return null;
            plan.sets[index] = run.set;
            plan.minimum[index] = run.min;
            if (run.min != 0) plan.anchor = index;
            saw_run = true;
            pc = end.save.next;
        }
        plan.count += 1;
    }
    if (!saw_run or plan.count == 0) return null;
    // Every capture group must be one of the walked items, so the plan's
    // slot writes cover the whole slot array.
    if (plan.count != program.capture_count) return null;
    var disjoint = true;
    for (0..plan.count) |i| {
        if (plan.empty[i]) continue;
        for (i + 1..plan.count) |j| {
            if (plan.empty[j]) continue;
            if (setsOverlap(plan.sets[i], plan.sets[j])) {
                disjoint = false;
                break;
            }
        }
        if (!disjoint) break;
    }
    if (disjoint) {
        // A chain with no mandatory run matches empty at every offset; the
        // empty-match restrictions need the general engine's retry loop.
        if (plan.anchor == RunChain.no_anchor and (program.notempty or program.notempty_atstart)) return null;
        return plan;
    }
    // Overlapping sets are only complete with a forward scan: the first run
    // is mandatory and every mandatory run's set is disjoint from all
    // preceding sets, so backtracking an earlier run can never make a
    // mandatory run match that the greedy maxima missed.
    if (plan.empty[0] or plan.minimum[0] != 1) return null;
    for (0..plan.count) |i| {
        if (plan.empty[i] or plan.minimum[i] == 0) continue;
        if (plan.minimum[i] != 1) return null;
        for (0..i) |j| {
            if (plan.empty[j]) continue;
            if (setsOverlap(plan.sets[i], plan.sets[j])) return null;
        }
    }
    plan.forward = true;
    plan.anchor = RunChain.no_anchor;
    return plan;
}

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
    const run_a = runPrefix(ins, pc) orelse return null;
    // Fixed-width runs are checked byte-wise at search time, which is only
    // exact for ASCII-only sets.
    if (!run_a.star and !run_a.set.ascii_only) return null;
    result.set_a = run_a.set;
    result.min_a = run_a.min;
    result.star_a = run_a.star;
    visited += run_a.min;
    if (run_a.star) visited += 1;
    pc = run_a.after;
    if (pc >= ins.len) return null;
    if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot != 1) {
        if (result.slot_a == 0 or ins[pc].save.slot != result.slot_a + 1) return null;
        visited += 1;
        pc = ins[pc].save.next;
        if (pc >= ins.len) return null;
    } else if (result.slot_a != 0) return null;
    // A set run separator (`\s+` between two runs) takes precedence over the
    // literal path.
    if (runPrefix(ins, pc)) |sep_run| {
        // Byte-wise run tracking keeps the scan one pass; non-ASCII runs
        // stay on the general engine.
        if (!sep_run.star or sep_run.min != 1 or !sep_run.set.ascii_only) return null;
        if (!result.set_a.ascii_only) return null;
        result.separator_set = sep_run.set;
        visited += sep_run.min + 1;
        pc = sep_run.after;
        if (pc >= ins.len) return null;
        if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot != 1) {
            result.slot_b = ins[pc].save.slot;
            visited += 1;
            pc = ins[pc].save.next;
            if (pc >= ins.len) return null;
        }
        if (runPrefix(ins, pc)) |run_b| {
            if (!run_b.set.ascii_only) return null;
            result.set_b = run_b.set;
            result.min_b = run_b.min;
            result.star_b = run_b.star;
            visited += run_b.min;
            if (run_b.star) visited += 1;
            pc = run_b.after;
        } else return null;
        if (std.meta.activeTag(ins[pc]) == .save and ins[pc].save.slot != 1) {
            if (result.slot_b == 0 or ins[pc].save.slot != result.slot_b + 1) return null;
            visited += 1;
            pc = ins[pc].save.next;
            if (pc >= ins.len) return null;
        } else if (result.slot_b != 0) return null;
        while (isLiteral(ins[pc])) {
            if (!appendLiteral(&result.tail, &result.tail_len, ins[pc])) return null;
            visited += 1;
            pc = literalNext(ins[pc]);
            if (pc >= ins.len or visited > ins.len) return null;
        }
        const tail_finish = ins[pc];
        if (std.meta.activeTag(tail_finish) != .save) return null;
        if (tail_finish.save.slot != 1 or tail_finish.save.next != program.accept) return null;
        visited += 1;
        if (visited != ins.len) return null;
        if (result.slot_a != 0) {
            if (result.slot_b != result.slot_a + 2 or program.capture_count != 2) return null;
        } else if (result.slot_b != 0 or program.capture_count != 0) return null;
        if (result.set_a.ranges.len == 0 or result.separator_set.?.ranges.len == 0) return null;
        if (result.set_b) |set_b| {
            if (set_b.ranges.len == 0) return null;
        }
        // The separator run must be delimited by both runs.
        if (result.separator_set.?.ranges.len != 0) {
            if (setsOverlap(result.set_a, result.separator_set.?)) return null;
            if (result.set_b) |set_b| {
                if (setsOverlap(set_b, result.separator_set.?)) return null;
            }
        }
        return result;
    }
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
    if (runPrefix(ins, pc)) |run_b| {
        if (!run_b.star and !run_b.set.ascii_only) return null;
        result.set_b = run_b.set;
        result.min_b = run_b.min;
        result.star_b = run_b.star;
        visited += run_b.min;
        if (run_b.star) visited += 1;
        pc = run_b.after;
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

/// A leading set run: `min` mandatory members, optionally followed by an
/// unbounded star over the same set.
const Run = struct { set: model.Set, min: u8, star: bool, after: usize };

fn runPrefix(ins: []const model.Instruction, pc_in: usize) ?Run {
    if (pc_in >= ins.len) return null;
    const first = ins[pc_in];
    // A single-rune set compiles to a literal; it is only a run when the
    // following star loops over that same rune.
    if (std.meta.activeTag(first) == .literal_byte or std.meta.activeTag(first) == .literal_rune) {
        const star_pc = literalNext(first);
        if (star_pc >= ins.len or std.meta.activeTag(ins[star_pc]) != .star) return null;
        const star = ins[star_pc].star;
        const value: u21 = switch (first) {
            .literal_byte => |literal| literal.value,
            .literal_rune => |literal| literal.value,
            else => unreachable,
        };
        if (!singleRuneSet(star.set, value)) return null;
        return .{ .set = star.set, .min = 1, .star = true, .after = star.next };
    }
    const set = switch (first) {
        .consume => |consume| consume.set,
        else => return null,
    };
    var count: usize = 0;
    var pc = pc_in;
    while (pc < ins.len and count < 255) {
        const instruction = ins[pc];
        switch (instruction) {
            .consume => |consume| {
                if (!sameSet(consume.set, set)) return null;
                count += 1;
                pc = consume.next;
            },
            else => break,
        }
    }
    if (count == 0) return null;
    if (pc < ins.len and std.meta.activeTag(ins[pc]) == .star) {
        const star = ins[pc].star;
        if (!sameSet(star.set, set)) return null;
        return .{ .set = set, .min = @intCast(count), .star = true, .after = star.next };
    }
    return .{ .set = set, .min = @intCast(count), .star = false, .after = pc };
}

/// Whether two sets share any rune.
pub fn setsOverlap(a: model.Set, b: model.Set) bool {
    var left: usize = 0;
    var right: usize = 0;
    while (left < a.ranges.len and right < b.ranges.len) {
        const x = a.ranges[left];
        const y = b.ranges[right];
        if (x.last < y.first) {
            left += 1;
        } else if (y.last < x.first) {
            right += 1;
        } else {
            return true;
        }
    }
    return false;
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

/// `(?:setA+ setB)+` over disjoint ASCII-only sets. Every iteration is a
/// non-empty run of A followed by exactly one B, and a full match must cover
/// the whole input. The disjointness condition keeps the greedy A+ run from
/// competing with B, so no backtracking can change the outcome.
pub const SetLoop = struct { a: model.Set, b: model.Set };

pub fn setLoop(program: Program) ?SetLoop {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 9) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .split or
        std.meta.activeTag(ins[5]) != .consume or std.meta.activeTag(ins[6]) != .star or
        std.meta.activeTag(ins[7]) != .consume or std.meta.activeTag(ins[8]) != .save) return null;
    if (program.start != 8 or program.body != 7) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const split = ins[4].split;
    if (split.alternation or split.left != 7 or split.right != 3) return null;
    const b = ins[5].consume;
    if (b.next != 4) return null;
    // The star may keep its backtrack flag: with disjoint sets, backtracking
    // the greedy A run can only move the B check onto A members, so the
    // greedy run already decides the outcome.
    const star = ins[6].star;
    if (star.next != 5) return null;
    const a = ins[7].consume;
    if (a.next != 6) return null;
    const save0 = ins[8].save;
    if (save0.slot != 0 or save0.next != 7) return null;
    if (!sameSet(a.set, star.set)) return null;
    if (a.set.ranges.len == 0 or b.set.ranges.len == 0) return null;
    if (!a.set.ascii_only or !b.set.ascii_only) return null;
    // The ASCII bitmap is authoritative, so two word ANDs replace 256 probes.
    if (a.set.ascii[0] & b.set.ascii[0] != 0 or a.set.ascii[1] & b.set.ascii[1] != 0) return null;
    return .{ .a = a.set, .b = b.set };
}

/// `(?:set+ sep)+` over a non-ASCII set with a single literal separator
/// byte (`(?:\p{Han}+\n)+`). Each iteration is a non-empty run of `set`
/// followed by one separator; the separator must not be a member.
pub const Utf8Loop = struct { run: model.Set, separator: u8 };

pub fn utf8Loop(program: Program) ?Utf8Loop {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 9) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .split or
        std.meta.activeTag(ins[5]) != .literal_byte or std.meta.activeTag(ins[6]) != .star or
        std.meta.activeTag(ins[7]) != .consume or std.meta.activeTag(ins[8]) != .save) return null;
    if (program.start != 8 or program.body != 7) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const split = ins[4].split;
    if (split.alternation or split.left != 7 or split.right != 3) return null;
    const separator = ins[5].literal_byte;
    if (separator.next != 4) return null;
    const star = ins[6].star;
    if (star.next != 5) return null;
    const a = ins[7].consume;
    if (a.next != 6) return null;
    const save0 = ins[8].save;
    if (save0.slot != 0 or save0.next != 7) return null;
    if (!sameSet(a.set, star.set)) return null;
    if (a.set.ranges.len == 0 or a.set.ascii_only) return null;
    if (a.set.matches(separator.value)) return null;
    return .{ .run = a.set, .separator = separator.value };
}

/// `(?m)^.*$`: a multiline line match. The star must be the dot set (every
/// rune except `\n`), so the match is exactly one line without its newline.
pub fn lineRun(program: Program) bool {
    if (program.capture_count != 0 or program.extended) return false;
    const ins = program.instructions;
    if (ins.len != 8) return false;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return false;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .assertion or
        std.meta.activeTag(ins[5]) != .star or std.meta.activeTag(ins[6]) != .assertion or
        std.meta.activeTag(ins[7]) != .save) return false;
    if (program.start != 7 or program.body != 6) return false;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return false;
    const end_line = ins[4].assertion;
    if (end_line.kind != .end_line or end_line.next != 3) return false;
    const star = ins[5].star;
    if (star.next != 4) return false;
    const start_line = ins[6].assertion;
    if (start_line.kind != .start_line or start_line.next != 5) return false;
    const save0 = ins[7].save;
    if (save0.slot != 0 or save0.next != 6) return false;
    return isDotExceptNewline(star.set);
}

/// ASCII bitmap of every byte except `except` (all values below 0x80).
fn asciiExcept(except: []const u8) [2]u64 {
    var words = [2]u64{ std.math.maxInt(u64), std.math.maxInt(u64) };
    for (except) |byte| {
        std.debug.assert(byte < 0x80);
        words[byte >> 6] &= ~(@as(u64, 1) << @intCast(byte & 63));
    }
    return words;
}

/// Whether `set` is the dot set: every rune except `\n`.
fn isDotExceptNewline(set: model.Set) bool {
    const expected = asciiExcept("\n");
    if (set.ascii[0] != expected[0] or set.ascii[1] != expected[1]) return false;
    // All non-ASCII runes must be members.
    for (set.ranges) |range| {
        if (range.first <= 0x80 and range.last >= 0x10FFFF) return true;
    }
    return false;
}

/// `o [^c]* c` or `o [^c]+ c` (`"[^"]*"`, `<[^>]+>`). The match is the next
/// delimiter pair; `non_empty` requires at least one inner rune.
pub const Delimited = struct { open: u8, close: u8, non_empty: bool };

pub fn delimitedRun(program: Program) ?Delimited {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    // `*` form: save0 -> d -> star(set) -> d -> save1 -> accept (8).
    // `+` form: save0 -> d -> consume(set) -> star(set) -> d -> save1 -> accept (9).
    if (ins.len != 8 and ins.len != 9) return null;
    const plus = ins.len == 9;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save) return null;
    const close_index: usize = 4;
    if (std.meta.activeTag(ins[close_index]) != .literal_byte) return null;
    const star_index: usize = 5;
    if (std.meta.activeTag(ins[star_index]) != .star) return null;
    const open_index: usize = if (plus) 7 else 6;
    if (std.meta.activeTag(ins[open_index]) != .literal_byte) return null;
    if (std.meta.activeTag(ins[open_index + 1]) != .save) return null;
    if (program.start != open_index + 1 or program.body != open_index) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const close = ins[close_index].literal_byte;
    if (close.next != 3) return null;
    const star = ins[star_index].star;
    if (star.next != close_index) return null;
    if (plus) {
        if (std.meta.activeTag(ins[6]) != .consume) return null;
        const member = ins[6].consume;
        if (member.next != star_index) return null;
        if (!sameSet(member.set, star.set)) return null;
    }
    const open = ins[open_index].literal_byte;
    const open_next: usize = if (plus) 6 else star_index;
    if (open.next != open_next) return null;
    const save0 = ins[open_index + 1].save;
    if (save0.slot != 0 or save0.next != open_index) return null;
    if (!isAllExcept(star.set, close.value)) return null;
    return .{ .open = open.value, .close = close.value, .non_empty = plus };
}

/// Whether `set` matches every rune except `excluded` (which is ASCII).
fn isAllExcept(set: model.Set, excluded: u8) bool {
    const expected = asciiExcept(&.{excluded});
    if (set.ascii[0] != expected[0] or set.ascii[1] != expected[1]) return false;
    for (set.ranges) |range| {
        if (range.first <= 0x80 and range.last >= 0x10FFFF) return true;
    }
    return false;
}

/// `literal [optional-literal] literal set+` (`https?://[^\s]+`). The match is
/// the next occurrence of the fixed prefix, optionally followed by one byte,
/// then the fixed middle, then a non-empty maximal run of `set`.
pub const LiteralRun = struct {
    prefix: []const u8,
    optional: ?u8,
    middle: [16]u8 = undefined,
    middle_len: u8,
    set: model.Set,
};

pub fn literalRun(program: Program) ?LiteralRun {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    const prefix = program.literal_prefix orelse return null;
    if (prefix.len == 0 or prefix.len > 32) return null;
    var pc: usize = program.start;
    if (pc >= ins.len or std.meta.activeTag(ins[pc]) != .save) return null;
    const save0 = ins[pc].save;
    if (save0.slot != 0 or save0.next != program.body) return null;
    pc = save0.next;
    // The fixed prefix must be plain ASCII bytes that match the compiler's
    // extracted literal prefix exactly.
    var prefix_index: usize = 0;
    while (pc < ins.len) {
        switch (ins[pc]) {
            .literal_byte => |literal| {
                if (prefix_index >= prefix.len or literal.value != prefix[prefix_index]) return null;
                prefix_index += 1;
                pc = literal.next;
            },
            else => break,
        }
    }
    if (prefix_index != prefix.len) return null;
    // One optional literal, compiled as a split whose one branch skips it.
    var optional: ?u8 = null;
    if (pc < ins.len and std.meta.activeTag(ins[pc]) == .split) {
        const split = ins[pc].split;
        if (split.left >= ins.len or split.right >= ins.len) return null;
        if (std.meta.activeTag(ins[split.left]) == .literal_byte and ins[split.left].literal_byte.next == split.right) {
            optional = ins[split.left].literal_byte.value;
            pc = split.right;
        } else if (std.meta.activeTag(ins[split.right]) == .literal_byte and ins[split.right].literal_byte.next == split.left) {
            optional = ins[split.right].literal_byte.value;
            pc = split.left;
        } else return null;
    }
    // Fixed middle bytes.
    var middle: [16]u8 = undefined;
    var middle_len: usize = 0;
    while (pc < ins.len) {
        switch (ins[pc]) {
            .literal_byte => |literal| {
                if (middle_len == middle.len) return null;
                middle[middle_len] = literal.value;
                middle_len += 1;
                pc = literal.next;
            },
            else => break,
        }
    }
    // Non-empty maximal run, then the whole-match accept.
    if (pc >= ins.len or std.meta.activeTag(ins[pc]) != .consume) return null;
    const consume = ins[pc].consume;
    const star_index = consume.next;
    if (star_index >= ins.len or std.meta.activeTag(ins[star_index]) != .star) return null;
    const star = ins[star_index].star;
    if (star.backtrack or !sameSet(consume.set, star.set)) return null;
    const save_index = star.next;
    if (save_index >= ins.len or std.meta.activeTag(ins[save_index]) != .save) return null;
    const save1 = ins[save_index].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    // The scanner consumes the optional literal greedily and never retries
    // without it. Skipping can only succeed when the middle starts with that
    // same byte, or when the middle is empty and the byte is a run member
    // (`b{1,2}[a-c]+`); those shapes must use the general search.
    if (optional) |byte| {
        const retry = if (middle_len == 0)
            consume.set.matches(byte)
        else
            middle[0] == byte;
        if (retry) return null;
    }
    return .{
        .prefix = prefix,
        .optional = optional,
        .middle = middle,
        .middle_len = @intCast(middle_len),
        .set = consume.set,
    };
}

/// `\b\w+\b`: a whole-word match. Both boundaries are ASCII word
/// boundaries, and the run set is ASCII-only.
pub fn wordRun(program: Program) ?model.Set {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 9) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .assertion or
        std.meta.activeTag(ins[5]) != .star or std.meta.activeTag(ins[6]) != .consume or
        std.meta.activeTag(ins[7]) != .assertion or std.meta.activeTag(ins[8]) != .save) return null;
    if (program.start != 8 or program.body != 7) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const end_boundary = ins[4].assertion;
    if (end_boundary.kind != .word_boundary or end_boundary.next != 3) return null;
    const star = ins[5].star;
    if (star.next != 4) return null;
    const member = ins[6].consume;
    if (member.next != 5) return null;
    const start_boundary = ins[7].assertion;
    if (start_boundary.kind != .word_boundary or start_boundary.next != 6) return null;
    const save0 = ins[8].save;
    if (save0.slot != 0 or save0.next != 7) return null;
    if (!sameSet(member.set, star.set)) return null;
    if (!member.set.ascii_only or member.set.ranges.len == 0) return null;
    return member.set;
}

/// `\s*$`: a trailing whitespace run at the end of the text (or before the
/// final newline). The star set must be ASCII whitespace.
pub fn trailingSpaceRun(program: Program) ?model.Set {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 7) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .assertion or
        std.meta.activeTag(ins[5]) != .star or std.meta.activeTag(ins[6]) != .save) return null;
    if (program.start != 6 or program.body != 5) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const end_assertion = ins[4].assertion;
    if (end_assertion.kind != .end_text_or_newline and end_assertion.kind != .end_text) return null;
    if (end_assertion.next != 3) return null;
    const star = ins[5].star;
    if (star.next != 4) return null;
    const save0 = ins[6].save;
    if (save0.slot != 0 or save0.next != 5) return null;
    if (star.set.ranges.len == 0 or !star.set.ascii_only) return null;
    return star.set;
}

/// `(?m)^[^d\n]+d` (`(?m)^[^:\n]+:`): a key from the line start to the
/// first delimiter. The run set must be every rune except `d` and `\n`.
pub const LineDelimited = struct { delimiter: u8 };

pub fn lineDelimitedRun(program: Program) ?LineDelimited {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 9) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .literal_byte or
        std.meta.activeTag(ins[5]) != .star or std.meta.activeTag(ins[6]) != .consume or
        std.meta.activeTag(ins[7]) != .assertion or std.meta.activeTag(ins[8]) != .save) return null;
    if (program.start != 8 or program.body != 7) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const delimiter = ins[4].literal_byte;
    if (delimiter.next != 3) return null;
    const star = ins[5].star;
    if (star.next != 4) return null;
    const member = ins[6].consume;
    if (member.next != 5) return null;
    const start_line = ins[7].assertion;
    if (start_line.kind != .start_line or start_line.next != 6) return null;
    const save0 = ins[8].save;
    if (save0.slot != 0 or save0.next != 7) return null;
    if (!sameSet(member.set, star.set)) return null;
    if (!isAllExceptTwo(star.set, delimiter.value, '\n')) return null;
    return .{ .delimiter = delimiter.value };
}

/// Whether `set` matches every rune except `a` and `b` (both ASCII).
fn isAllExceptTwo(set: model.Set, a: u8, b: u8) bool {
    const expected = asciiExcept(&.{ a, b });
    if (set.ascii[0] != expected[0] or set.ascii[1] != expected[1]) return false;
    for (set.ranges) |range| {
        if (range.first <= 0x80 and range.last >= 0x10FFFF) return true;
    }
    return false;
}

/// `-?\d+(?:\.\d+)?`: a JSON-style number. The optional sign, the digit run,
/// and the optional fraction must all share one ASCII digit set.
pub fn numberRun(program: Program) ?model.Set {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 13) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (std.meta.activeTag(ins[3]) != .save or std.meta.activeTag(ins[4]) != .star or
        std.meta.activeTag(ins[5]) != .consume or std.meta.activeTag(ins[6]) != .literal_byte or
        std.meta.activeTag(ins[7]) != .split or std.meta.activeTag(ins[8]) != .star or
        std.meta.activeTag(ins[9]) != .consume or std.meta.activeTag(ins[10]) != .literal_byte or
        std.meta.activeTag(ins[11]) != .split or std.meta.activeTag(ins[12]) != .save) return null;
    if (program.start != 12 or program.body != 11) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const star_b = ins[4].star;
    if (star_b.next != 3) return null;
    const member_b = ins[5].consume;
    if (member_b.next != 4) return null;
    const dot = ins[6].literal_byte;
    if (dot.value != '.' or dot.next != 5) return null;
    const fraction = ins[7].split;
    if (fraction.alternation or fraction.left != 6 or fraction.right != 3) return null;
    const star_a = ins[8].star;
    if (star_a.next != 7) return null;
    const member_a = ins[9].consume;
    if (member_a.next != 8) return null;
    const sign = ins[10].literal_byte;
    if (sign.value != '-' or sign.next != 9) return null;
    const optional_sign = ins[11].split;
    if (optional_sign.alternation or optional_sign.left != 10 or optional_sign.right != 9) return null;
    const save0 = ins[12].save;
    if (save0.slot != 0 or save0.next != 11) return null;
    if (!sameSet(member_a.set, star_a.set)) return null;
    if (!sameSet(member_a.set, member_b.set)) return null;
    if (!sameSet(member_a.set, star_b.set)) return null;
    if (!member_a.set.ascii_only or member_a.set.ranges.len == 0) return null;
    return member_a.set;
}
