//! Materialized rune sets use UTF-8 tables after Unicode input needs them.
const std = @import("std");
const model = @import("model.zig");
const utf8 = @import("utf8_run.zig");
const byte_table = @import("byte_table.zig");

pub const Run = struct {
    set: model.Set,
    ascii: [256]bool,
    table: ?utf8.Utf8Run = null,
    unicode_probes: u8 = 0,
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
        if (self.table) |*table| return table.runeAt(input, offset);
        if (self.set.ascii_only) return null;
        const length = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
        if (length > input.len - offset) return null;
        const rune = std.unicode.utf8Decode(input[offset..][0..length]) catch return null;
        const matches = self.set.matches(rune);
        if (!self.failed) {
            self.unicode_probes +|= 1;
            if (self.unicode_probes >= 4) self.prepare(allocator);
        }
        return if (matches) length else null;
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
            if (!self.failed and input.len - end >= 64) {
                self.prepare(allocator);
                if (self.table) |*table| return table.runEnd(input, end);
            }
            end = next;
        }
        return end;
    }

    noinline fn prepare(self: *Run, allocator: std.mem.Allocator) void {
        if (self.table != null or self.failed) return;
        self.table = utf8.Utf8Run.init(allocator, self.set) catch {
            self.failed = true;
            return;
        };
    }
};
