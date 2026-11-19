//! Expanded UTF-8 automaton for a non-ASCII `set+` program. Each state owns
//! a 256-entry transition row, so a run scan is one table load per byte.
//! Shared by the search fast path (`replace.zig`) and the full-match fast
//! path (`execute.zig`).
const std = @import("std");
const model = @import("model.zig");
const utf8_set = @import("utf8_set.zig");

/// Expanded UTF-8 automaton for a non-ASCII `set+` program. Each state owns a
/// 256-entry transition row, so the run scan is one table load per byte.
pub const Utf8Run = struct {
    table: []u16,

    pub fn init(allocator: std.mem.Allocator, set: model.Set) std.mem.Allocator.Error!Utf8Run {
        var automaton = try utf8_set.build(allocator, set.ranges);
        defer automaton.deinit(allocator);
        const states = automaton.stateCount();
        const table = try allocator.alloc(u16, states * 256);
        errdefer allocator.free(table);
        for (0..states) |state| {
            for (0..256) |byte| {
                table[state * 256 + byte] = automaton.advance(@intCast(state), @intCast(byte));
            }
        }
        return .{ .table = table };
    }

    pub fn deinit(self: *const Utf8Run, allocator: std.mem.Allocator) void {
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

    /// End of the maximal member run starting at `offset`.
    pub fn runEnd(self: *const Utf8Run, input: []const u8, offset: usize) usize {
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
                end = rune_begin;
                break;
            } else {
                state = next;
                end += 1;
            }
        }
        if (state != 0) end = rune_begin;
        return end;
    }
};
