//! Materialized rune sets use UTF-8 tables after Unicode input needs them.
const std = @import("std");
const model = @import("model.zig");
const utf8 = @import("utf8_run.zig");
const byte_table = @import("byte_table.zig");

/// Materialize the UTF-8 table only after this many Unicode runes. Broad
/// classes build multi-megabyte tables, and sparse Unicode input is cheaper to
/// probe than to materialize.
const prepare_probes: u16 = 2048;

pub const Run = struct {
    set: model.Set,
    ascii: [256]bool,
    table: ?utf8.Utf8Run = null,
    unicode_probes: u16 = 0,
    /// The fast branch's run set can be a broad class whose UTF-8 table is
    /// multi-megabyte; require a dense Unicode run before materializing it.
    prepare_after: u16 = prepare_probes,
    failed: bool = false,

    pub fn init(set: model.Set) Run {
        var ascii = [_]bool{false} ** 256;
        ascii[0..128].* = byte_table.init(128, set);
        return .{ .set = set, .ascii = ascii };
    }

    pub fn deinit(self: *Run, allocator: std.mem.Allocator) void {
        if (self.table) |*table| table.deinit(allocator);
        self.* = undefined;
    }

    pub fn runeAt(self: *Run, allocator: std.mem.Allocator, input: []const u8, offset: usize) ?usize {
        if (offset >= input.len) return null;
        const byte = input[offset];
        if (byte < 0x80) return if (self.ascii[byte]) 1 else null;
        if (self.table) |*table| return table.runeAt(input, offset);
        return self.unicodeRuneAt(allocator, input, offset);
    }

    noinline fn unicodeRuneAt(self: *Run, allocator: std.mem.Allocator, input: []const u8, offset: usize) ?usize {
        return unicodeProbe(self, allocator, input, offset);
    }

    pub fn runEnd(self: *Run, allocator: std.mem.Allocator, input: []const u8, offset: usize) usize {
        if (self.table) |*table| return table.runEnd(input, offset);
        var end = offset;
        while (end < input.len and self.ascii[input[end]]) end += 1;
        if (end >= input.len or input[end] < 0x80) return end;
        return self.unicodeRunEnd(allocator, input, end);
    }

    noinline fn unicodeRunEnd(self: *Run, allocator: std.mem.Allocator, input: []const u8, offset: usize) usize {
        var end = offset;
        while (end < input.len) {
            while (end < input.len and self.ascii[input[end]]) end += 1;
            if (end >= input.len or input[end] < 0x80) break;
            const next = self.set.matchAdvance(input, end) orelse break;
            if (!self.failed) {
                self.unicode_probes +|= 1;
                if (self.unicode_probes >= self.prepare_after) {
                    self.prepare(allocator);
                    if (self.table) |*table| return table.runEnd(input, end);
                }
            }
            end = next;
        }
        return end;
    }

    noinline fn prepare(self: *Run, allocator: std.mem.Allocator) void {
        prepareTable(self, allocator);
    }
};

/// Full-match workspaces already own an ASCII table, so their deferred run
/// keeps only the materialized set and optional UTF-8 storage.
pub const CompactRun = struct {
    set: model.Set,
    table: ?utf8.Utf8Run = null,
    unicode_probes: u8 = 0,
    prepare_after: u8 = 4,
    failed: bool = false,

    pub fn init(set: model.Set) CompactRun {
        return .{ .set = set };
    }

    pub fn deinit(self: *CompactRun, allocator: std.mem.Allocator) void {
        if (self.table) |*table| table.deinit(allocator);
        self.* = undefined;
    }

    pub fn runeAt(self: *CompactRun, allocator: std.mem.Allocator, input: []const u8, offset: usize) ?usize {
        if (offset >= input.len) return null;
        const byte = input[offset];
        if (byte < 0x80) return if (self.set.matches(byte)) 1 else null;
        if (self.table) |*table| return table.runeAt(input, offset);
        return self.unicodeRuneAt(allocator, input, offset);
    }

    pub const SearchProbe = struct { length: u3, matched: bool };

    /// Search can route selective misses to a lightweight first filter.
    /// Other callers retain unicodeProbe's original preparation policy.
    pub fn probeForSearch(self: *CompactRun, allocator: std.mem.Allocator, input: []const u8, offset: usize, prepare_misses: bool) ?SearchProbe {
        std.debug.assert(self.table == null);
        const length = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
        if (length > input.len - offset) return null;
        const rune = std.unicode.utf8Decode(input[offset..][0..length]) catch return null;
        const matched = self.set.matches(rune);
        if (!self.failed and (matched or prepare_misses)) {
            self.unicode_probes +|= 1;
            if (self.unicode_probes >= self.prepare_after) self.prepare(allocator);
        }
        return .{ .length = length, .matched = matched };
    }

    /// A wide set declined the lightweight filter: restore the preceding
    /// valid-miss count once and prepare the original byte table.
    pub noinline fn restoreSearchMisses(self: *CompactRun, allocator: std.mem.Allocator, count: u8) void {
        if (self.failed) return;
        self.unicode_probes +|= count;
        if (self.unicode_probes >= self.prepare_after) self.prepare(allocator);
    }

    noinline fn unicodeRuneAt(self: *CompactRun, allocator: std.mem.Allocator, input: []const u8, offset: usize) ?usize {
        return unicodeProbe(self, allocator, input, offset);
    }

    pub fn runEnd(self: *CompactRun, allocator: std.mem.Allocator, input: []const u8, offset: usize) usize {
        if (self.table) |*table| return table.runEnd(input, offset);
        var end = offset;
        while (self.set.matchAdvance(input, end)) |next| {
            if (!self.failed and input[end] >= 0x80 and input.len - end >= 64) {
                self.prepare(allocator);
                if (self.table) |*table| return table.runEnd(input, end);
            }
            end = next;
        }
        return end;
    }

    noinline fn prepare(self: *CompactRun, allocator: std.mem.Allocator) void {
        prepareTable(self, allocator);
    }
};

fn unicodeProbe(self: anytype, allocator: std.mem.Allocator, input: []const u8, offset: usize) ?usize {
    if (self.set.ascii_only) return null;
    const length = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
    if (length > input.len - offset) return null;
    const rune = std.unicode.utf8Decode(input[offset..][0..length]) catch return null;
    const matches = self.set.matches(rune);
    if (!self.failed) {
        self.unicode_probes +|= 1;
        if (self.unicode_probes >= self.prepare_after) self.prepare(allocator);
    }
    return if (matches) length else null;
}

fn prepareTable(self: anytype, allocator: std.mem.Allocator) void {
    if (self.table != null or self.failed) return;
    self.table = utf8.Utf8Run.init(allocator, self.set) catch {
        self.failed = true;
        return;
    };
}
