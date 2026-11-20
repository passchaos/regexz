//! Leftmost search for a materialized set run, with optional UTF-8 storage.
const std = @import("std");
const deferred = @import("deferred_utf8_run.zig");
const utf8_run = @import("utf8_run.zig");
const utf8_set = @import("utf8_set.zig");
const prefilter = @import("prefilter.zig");

pub const Span = struct { start: usize, end: usize };
pub const Result = struct { span: ?Span, prepared: bool = false };

pub inline fn findDeferred(
    run: *deferred.CompactRun,
    allocator: std.mem.Allocator,
    ascii: *const [256]bool,
    first: *prefilter.FirstFilter,
    input: []const u8,
    from: usize,
) Result {
    std.debug.assert(run.table == null);
    if (from >= input.len) return .{ .span = null };
    const start = if (ascii[input[from]]) from else first.indexOfRuneCandidates(input, from) orelse return .{ .span = null };
    if (ascii[input[start]]) {
        var end = start + 1;
        while (end < input.len and ascii[input[end]]) end += 1;
        if (end == input.len or input[end] < 0x80) return .{ .span = .{ .start = start, .end = end } };
    }
    const found = findUnprepared(run, allocator, ascii, first, input, start);
    return .{ .span = found, .prepared = run.table != null };
}

noinline fn findUnprepared(
    run: *deferred.CompactRun,
    allocator: std.mem.Allocator,
    ascii: *const [256]bool,
    first: *prefilter.FirstFilter,
    input: []const u8,
    from: usize,
) ?Span {
    var start = from;
    while (start < input.len) {
        start = first.indexOfRuneCandidates(input, start) orelse return null;
        if (input[start] < 0x80) {
            if (!ascii[input[start]]) {
                start += 1;
                continue;
            }
            var end = start + 1;
            while (end < input.len and ascii[input[end]]) end += 1;
            if (end < input.len and input[end] >= 0x80) {
                if (probe(run, allocator, first, input, end)) |found| {
                    if (found.matched) end = run.runEnd(allocator, input, end);
                }
            }
            return .{ .start = start, .end = end };
        }
        if (probe(run, allocator, first, input, start)) |found| {
            if (found.matched) return .{ .start = start, .end = run.runEnd(allocator, input, start) };
            start += found.length;
        } else start += 1;
        if (run.table) |*table| return findPrepared(table, first, input, start);
    }
    return null;
}

fn probe(run: *deferred.CompactRun, allocator: std.mem.Allocator, first: *prefilter.FirstFilter, input: []const u8, offset: usize) ?deferred.CompactRun.SearchProbe {
    const found = run.probeForSearch(allocator, input, offset, first.prefix_state == .disabled) orelse return null;
    if (!found.matched and first.noteRuneMiss(run.set, @max(1, 4 -| run.unicode_probes)) and first.prefix_state == .disabled) {
        run.restoreSearchMisses(allocator, first.prefix_probes);
    }
    return found;
}

/// Byte automaton scan once its storage is prepared.
pub inline fn findPrepared(run: *const utf8_run.Utf8Run, first: *const prefilter.FirstFilter, input: []const u8, from: usize) ?Span {
    const table = run.table;
    var offset = from;
    var rune_start = from;
    search: while (offset < input.len) {
        offset = first.indexOfRuneCandidates(input, offset) orelse return null;
        rune_start = offset;
        var prefix_state = table[input[offset]];
        offset += 1;
        if (prefix_state == utf8_set.accept) break :search;
        if (prefix_state == utf8_set.dead) continue;
        while (offset < input.len) {
            const next = table[@as(usize, prefix_state) * 256 + input[offset]];
            if (next == utf8_set.accept) {
                offset += 1;
                break :search;
            }
            if (next == utf8_set.dead) {
                // A failed prefix may be followed by a fresh rune start.
                // Continuation bytes cannot start a rune and advance once.
                if (input[offset] & 0xc0 == 0x80) offset += 1;
                continue :search;
            }
            prefix_state = next;
            offset += 1;
        }
        return null;
    } else return null;
    const start = rune_start;
    var end = offset;
    var rune_begin = end;
    var state: u16 = 0;
    while (end < input.len) {
        const next = table[@as(usize, state) * 256 + input[end]];
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
    return .{ .start = start, .end = end };
}
