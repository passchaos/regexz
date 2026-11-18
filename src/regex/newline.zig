//! Newline conventions (`(*CR)`, `(*LF)`, `(*CRLF)`, `(*ANYCRLF)`, `(*ANY)`,
//! `(*NUL)`) shared by `^`, `$`, `\Z`, dot, and `\N`.
const std = @import("std");
const model = @import("model.zig");

const lf_only = [_]model.Range{.{ .first = '\n', .last = '\n' }};
const cr_only = [_]model.Range{.{ .first = '\r', .last = '\r' }};
const crlf_pair = [_]model.Range{
    .{ .first = '\r', .last = '\r' },
    .{ .first = '\n', .last = '\n' },
};
const unicode_set = [_]model.Range{
    .{ .first = '\n', .last = '\n' },
    .{ .first = 0x0b, .last = 0x0c },
    .{ .first = '\r', .last = '\r' },
    .{ .first = 0x85, .last = 0x85 },
    .{ .first = 0x2028, .last = 0x2029 },
};
const nul_only = [_]model.Range{.{ .first = 0, .last = 0 }};
const none = [_]model.Range{};

/// Runes that form single-character Unicode line endings under `(*ANY)`.
fn isUnicodeBreak(rune: u21) bool {
    return rune == 0x0b or rune == 0x0c or rune == 0x85 or rune == 0x2028 or rune == 0x2029;
}

fn runeBefore(input: []const u8, offset: usize) ?u21 {
    if (offset == 0 or offset > input.len) return null;
    var start = offset - 1;
    var steps: usize = 0;
    while (start > 0 and (input[start] & 0xc0) == 0x80 and steps < 3) : (steps += 1) start -= 1;
    const len = std.unicode.utf8ByteSequenceLength(input[start]) catch return null;
    if (start + len != offset) return null;
    return std.unicode.utf8Decode(input[start..offset]) catch null;
}

fn runeAt(input: []const u8, offset: usize) ?struct { value: u21, len: usize } {
    if (offset >= input.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn anycrlfBefore(input: []const u8, offset: usize) bool {
    if (offset == 0) return false;
    if (offset >= 2 and input[offset - 2] == '\r' and input[offset - 1] == '\n') return true;
    if (input[offset - 1] == '\r') return offset >= input.len or input[offset] != '\n';
    if (input[offset - 1] == '\n') return offset < 2 or input[offset - 2] != '\r';
    return false;
}

fn anycrlfAfter(input: []const u8, offset: usize) bool {
    if (offset >= input.len) return false;
    if (input[offset] == '\r') return true;
    if (input[offset] == '\n') return offset == 0 or input[offset - 1] != '\r';
    return false;
}

/// True when a line break ends exactly at `offset`.
pub fn before(input: []const u8, offset: usize, mode: model.Newline) bool {
    return switch (mode) {
        .lf => offset > 0 and input[offset - 1] == '\n',
        .cr => offset > 0 and input[offset - 1] == '\r',
        .crlf => offset >= 2 and input[offset - 2] == '\r' and input[offset - 1] == '\n',
        .anycrlf => anycrlfBefore(input, offset),
        .any => anycrlfBefore(input, offset) or (if (runeBefore(input, offset)) |rune| isUnicodeBreak(rune) else false),
        .nul => offset > 0 and input[offset - 1] == 0,
    };
}

/// True when a line break starts exactly at `offset`.
pub fn after(input: []const u8, offset: usize, mode: model.Newline) bool {
    return switch (mode) {
        .lf => offset < input.len and input[offset] == '\n',
        .cr => offset < input.len and input[offset] == '\r',
        .crlf => offset + 1 < input.len and input[offset] == '\r' and input[offset + 1] == '\n',
        .anycrlf => anycrlfAfter(input, offset),
        .any => anycrlfAfter(input, offset) or (if (runeAt(input, offset)) |rune| isUnicodeBreak(rune.value) else false),
        .nul => offset < input.len and input[offset] == 0,
    };
}

/// True when `offset` is at `end` or immediately before a final line break
/// that ends at `end` (`\Z`).
pub fn final(input: []const u8, offset: usize, end: usize, mode: model.Newline) bool {
    if (offset >= end) return offset == end;
    return switch (mode) {
        .lf => offset + 1 == end and input[offset] == '\n',
        .cr => offset + 1 == end and input[offset] == '\r',
        .crlf => offset + 2 == end and input[offset] == '\r' and input[offset + 1] == '\n',
        .anycrlf => blk: {
            if (offset + 1 == end and input[offset] == '\r') break :blk true;
            if (offset + 1 == end and input[offset] == '\n') break :blk offset == 0 or input[offset - 1] != '\r';
            break :blk offset + 2 == end and input[offset] == '\r' and input[offset + 1] == '\n';
        },
        .any => blk: {
            if (offset + 1 == end and input[offset] == '\r') break :blk true;
            if (offset + 1 == end and input[offset] == '\n') break :blk offset == 0 or input[offset - 1] != '\r';
            if (offset + 2 == end and input[offset] == '\r' and input[offset + 1] == '\n') break :blk true;
            const rune = runeAt(input, offset) orelse break :blk false;
            break :blk offset + rune.len == end and isUnicodeBreak(rune.value);
        },
        .nul => offset + 1 == end and input[offset] == 0,
    };
}

/// Static dot/`\N` exclusion set for a convention. `crlf` is context
/// dependent and handled by the parser with a composite node.
pub fn excluded(mode: model.Newline) []const model.Range {
    return switch (mode) {
        .lf => &lf_only,
        .cr => &cr_only,
        .anycrlf => &crlf_pair,
        .any => &unicode_set,
        .nul => &nul_only,
        .crlf => &none,
    };
}
