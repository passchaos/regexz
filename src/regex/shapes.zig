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
