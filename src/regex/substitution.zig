//! PCRE2/Perl substitution expansion: `$1`, `$<name>`, `${name}`, `$&`,
//! `$$`, `` $` ``, `$'`, `$+`, `$_`, `\1`..`\9`, and the `\U \L \E \u \l`
//! case transforms. Kept separate from the search workspace so the syntax,
//! validation, and expansion are usable without an engine.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const unicode = @import("unicode.zig");
const unset = std.math.maxInt(usize);
pub const Error = model.Error;

fn parseSubstitutionGroup(
    substitution: []const u8,
    index: *usize,
    program: ?Program,
    capture_count: u16,
) Error!?u16 {
    const start = index.* + 1;
    if (start >= substitution.len) return null;
    const next = substitution[start];
    if (next == '$') {
        index.* = start;
        return null;
    }
    if (next == '&') {
        index.* = start;
        return 0;
    }
    // PCRE2 also accepts Perl's angle-bracket group syntax `$<name>`.
    if (next == '<') {
        const name_start = start + 1;
        const close = std.mem.indexOfScalarPos(u8, substitution, name_start, '>') orelse return error.InvalidRegex;
        const name = substitution[name_start..close];
        if (name.len == 0) return error.InvalidRegex;
        if (std.fmt.parseInt(u16, name, 10)) |number| {
            if (number > capture_count) return error.InvalidRegex;
            index.* = close;
            return number;
        } else |_| {}
        const group = if (program) |value| value.groupIndex(name) else null;
        const resolved = group orelse return error.InvalidRegex;
        index.* = close;
        return resolved;
    }
    if (next == '{') {
        const name_start = start + 1;
        const close = std.mem.indexOfScalarPos(u8, substitution, name_start, '}') orelse return error.InvalidRegex;
        const name = substitution[name_start..close];
        if (name.len == 0) return error.InvalidRegex;
        if (std.fmt.parseInt(u16, name, 10)) |number| {
            if (number > capture_count) return error.InvalidRegex;
            index.* = close;
            return number;
        } else |_| {}
        const group = if (program) |value| value.groupIndex(name) else null;
        const resolved = group orelse return error.InvalidRegex;
        index.* = close;
        return resolved;
    }
    if (next >= '0' and next <= '9') {
        var value: u32 = next - '0';
        var consumed: usize = 1;
        while (consumed < 2 and start + consumed < substitution.len) {
            const digit = substitution[start + consumed];
            if (digit < '0' or digit > '9') break;
            const candidate = value * 10 + (digit - '0');
            if (candidate > capture_count) break;
            value = candidate;
            consumed += 1;
        }
        if (value > capture_count) return error.InvalidRegex;
        index.* = start + consumed - 1;
        return @intCast(value);
    }
    return null;
}

fn validateSubstitutionInternal(program: ?Program, substitution: []const u8, capture_count: u16) Error!void {
    var index: usize = 0;
    while (index < substitution.len) : (index += 1) {
        const byte = substitution[index];
        if (byte == '\\') {
            index += 1;
            if (index == substitution.len) return error.InvalidRegex;
            const escaped = substitution[index];
            if (escaped >= '0' and escaped <= '9') {
                if (escaped - '0' > capture_count) return error.InvalidRegex;
            }
            continue;
        }
        if (byte == '$') {
            if (index + 1 < substitution.len) {
                switch (substitution[index + 1]) {
                    '`', '\'', '+', '_' => {
                        index += 1;
                        continue;
                    },
                    else => {},
                }
            }
            _ = try parseSubstitutionGroup(substitution, &index, program, capture_count);
        }
    }
}

pub fn validateSubstitution(substitution: []const u8, capture_count: u16) Error!void {
    return validateSubstitutionInternal(null, substitution, capture_count);
}

pub fn validateSubstitutionFor(program: Program, substitution: []const u8) Error!void {
    return validateSubstitutionInternal(program, substitution, program.capture_count);
}

fn groupText(input: []const u8, slots: []const usize, group: u16) ?[]const u8 {
    const begin = slots[@as(usize, group) * 2];
    const end = slots[@as(usize, group) * 2 + 1];
    if (begin != unset and end != unset and end >= begin) return input[begin..end];
    return null;
}

const CaseMode = enum { none, upper, lower };
const CaseState = struct {
    base: CaseMode = .none,
    one_shot: CaseMode = .none,

    fn effective(self: CaseState) CaseMode {
        return if (self.one_shot != .none) self.one_shot else self.base;
    }
};

/// Apply PCRE2 replacement case transforms using simple Unicode case
/// mappings. Invalid UTF-8 bytes are copied unchanged.
fn appendTransformed(writer: anytype, bytes: []const u8, state: *CaseState, full_case: bool) Error!void {
    if (state.base == .none and state.one_shot == .none) {
        try writer.appendSlice(bytes);
        return;
    }
    var index: usize = 0;
    while (index < bytes.len) {
        const length = std.unicode.utf8ByteSequenceLength(bytes[index]) catch {
            state.one_shot = .none;
            try writer.append(bytes[index]);
            index += 1;
            continue;
        };
        if (length > bytes.len - index) {
            try writer.appendSlice(bytes[index..]);
            return;
        }
        const rune = std.unicode.utf8Decode(bytes[index..][0..length]) catch {
            state.one_shot = .none;
            try writer.append(bytes[index]);
            index += 1;
            continue;
        };
        const mode = state.effective();
        state.one_shot = .none;
        if (mode == .none) {
            try writer.appendSlice(bytes[index..][0..length]);
            index += length;
            continue;
        }
        var mapped: [4]u21 = undefined;
        const sequence = if (full_case)
            (if (mode == .upper) unicode.fullToUpper(rune, &mapped) else unicode.fullToLower(rune, &mapped))
        else blk: {
            mapped[0] = if (mode == .upper) unicode.toUpper(rune) else unicode.toLower(rune);
            break :blk mapped[0..1];
        };
        for (sequence) |cp| {
            var buffer: [4]u8 = undefined;
            const encoded = std.unicode.utf8Encode(cp, &buffer) catch continue;
            try writer.appendSlice(buffer[0..encoded]);
        }
        index += length;
    }
}

fn highestGroup(input: []const u8, slots: []const usize, capture_count: u16) ?[]const u8 {
    var group: u16 = capture_count;
    while (group > 0) : (group -= 1) {
        if (groupText(input, slots, group)) |text| return text;
    }
    return null;
}

pub fn appendSubstitution(
    writer: anytype,
    input: []const u8,
    substitution: []const u8,
    slots: []const usize,
    program: Program,
    full_case: bool,
) Error!void {
    var state = CaseState{};
    var index: usize = 0;
    while (index < substitution.len) : (index += 1) {
        const byte = substitution[index];
        if (byte == '\\') {
            index += 1;
            if (index == substitution.len) return error.InvalidRegex;
            const escaped = substitution[index];
            switch (escaped) {
                'U' => {
                    state.base = .upper;
                    state.one_shot = .none;
                    continue;
                },
                'L' => {
                    state.base = .lower;
                    state.one_shot = .none;
                    continue;
                },
                'E' => {
                    state.base = .none;
                    state.one_shot = .none;
                    continue;
                },
                'u' => {
                    state.one_shot = .upper;
                    continue;
                },
                'l' => {
                    state.one_shot = .lower;
                    continue;
                },
                '0'...'9' => {
                    if (groupText(input, slots, escaped - '0')) |text| {
                        try appendTransformed(writer, text, &state, full_case);
                    }
                    continue;
                },
                '\\' => {
                    try writer.append('\\');
                    continue;
                },
                else => {
                    try writer.append('\\');
                    const length = std.unicode.utf8ByteSequenceLength(escaped) catch 1;
                    const end = @min(index + length, substitution.len);
                    try appendTransformed(writer, substitution[index..end], &state, full_case);
                    index = end - 1;
                    continue;
                },
            }
        }
        if (byte == '$') {
            // PCRE2/Perl whole-input substitutions.
            if (index + 1 < substitution.len) {
                switch (substitution[index + 1]) {
                    '`' => {
                        try appendTransformed(writer, input[0..slots[0]], &state, full_case);
                        index += 1;
                        continue;
                    },
                    '\'' => {
                        try appendTransformed(writer, input[slots[1]..], &state, full_case);
                        index += 1;
                        continue;
                    },
                    '+' => {
                        if (highestGroup(input, slots, program.capture_count)) |text| {
                            try appendTransformed(writer, text, &state, full_case);
                        }
                        index += 1;
                        continue;
                    },
                    '_' => {
                        try appendTransformed(writer, input, &state, full_case);
                        index += 1;
                        continue;
                    },
                    else => {},
                }
            }
            if (try parseSubstitutionGroup(substitution, &index, program, program.capture_count)) |group| {
                if (groupText(input, slots, group)) |text| {
                    try appendTransformed(writer, text, &state, full_case);
                }
            } else {
                try writer.append('$');
            }
            continue;
        }
        // Process the whole literal run so multi-byte UTF-8 sequences are
        // decoded and case-mapped as one character.
        var end = index;
        while (end < substitution.len and substitution[end] != '\\' and substitution[end] != '$') end += 1;
        try appendTransformed(writer, substitution[index..end], &state, full_case);
        index = end - 1;
    }
}

/// Expand `substitution` for a single match without searching. `slots` must
/// hold the whole-match and capture slots for `input` (as returned by `find`).
pub fn expandMatch(
    allocator: std.mem.Allocator,
    program: Program,
    input: []const u8,
    slots: []const usize,
    substitution: []const u8,
    full_case: bool,
) Error![]u8 {
    try validateSubstitutionFor(program, substitution);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = ListWriter{ .list = &out, .allocator = allocator };
    try appendSubstitution(&writer, input, substitution, slots, program, full_case);
    return out.toOwnedSlice(allocator);
}

pub const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    pub fn append(self: *ListWriter, byte: u8) Error!void {
        try self.list.append(self.allocator, byte);
    }
    pub fn appendSlice(self: *ListWriter, bytes: []const u8) Error!void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

pub const LengthWriter = struct {
    length: *usize,
    pub fn append(self: *LengthWriter, _: u8) Error!void {
        self.length.* += 1;
    }
    pub fn appendSlice(self: *LengthWriter, bytes: []const u8) Error!void {
        self.length.* += bytes.len;
    }
};

pub const BufferWriter = struct {
    output: []u8,
    len: usize = 0,
    pub fn append(self: *BufferWriter, byte: u8) Error!void {
        if (self.len >= self.output.len) return error.RegexLimitExceeded;
        self.output[self.len] = byte;
        self.len += 1;
    }
    pub fn appendSlice(self: *BufferWriter, bytes: []const u8) Error!void {
        if (bytes.len > self.output.len - self.len) {
            return error.RegexLimitExceeded;
        }
        @memcpy(self.output[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

/// One precomputed substitution piece. Literal slices borrow the caller's
/// substitution string; group references resolve against the match slots.
pub const Segment = union(enum) {
    literal: []const u8,
    group: u16,
    whole_start,
    whole_end,
    highest,
    input,
};

pub const Template = struct {
    pub const max_segments = 16;
    segments: [max_segments]Segment = undefined,
    count: u8 = 0,
};

/// Parse a substitution into segments once per replacement pass. Returns null
/// when the substitution uses backslash escapes or case transforms, or when it
/// needs more pieces than the stack template holds; those keep the general
/// expansion path.
pub fn parseTemplate(substitution: []const u8, program: Program) Error!?Template {
    if (std.mem.indexOfScalar(u8, substitution, '\\') != null) return null;
    var template = Template{};
    var index: usize = 0;
    while (index < substitution.len) {
        if (template.count == Template.max_segments) return null;
        if (substitution[index] != '$') {
            var end = index;
            while (end < substitution.len and substitution[end] != '$') end += 1;
            template.segments[template.count] = .{ .literal = substitution[index..end] };
            template.count += 1;
            index = end;
            continue;
        }
        if (index + 1 < substitution.len) {
            const special = substitution[index + 1];
            const kind: ?Segment = switch (special) {
                '`' => .whole_start,
                '\'' => .whole_end,
                '+' => .highest,
                '_' => .input,
                else => null,
            };
            if (kind) |segment| {
                template.segments[template.count] = segment;
                template.count += 1;
                index += 2;
                continue;
            }
        }
        const start = index;
        if (try parseSubstitutionGroup(substitution, &index, program, program.capture_count)) |group| {
            template.segments[template.count] = .{ .group = group };
            template.count += 1;
            index += 1;
        } else {
            template.segments[template.count] = .{ .literal = substitution[start..][0..1] };
            template.count += 1;
            // `parseSubstitutionGroup` advances to the last consumed
            // character (the second `$` for `$$`); the next piece starts
            // after it.
            index += 1;
        }
    }
    return template;
}

/// Expand a parsed template for one match.
pub fn appendTemplate(writer: anytype, input: []const u8, template: *const Template, slots: []const usize, program: Program) Error!void {
    for (template.segments[0..template.count]) |segment| {
        switch (segment) {
            .literal => |bytes| try writer.appendSlice(bytes),
            .group => |group| if (groupText(input, slots, group)) |text| try writer.appendSlice(text),
            .whole_start => try writer.appendSlice(input[0..slots[0]]),
            .whole_end => try writer.appendSlice(input[slots[1]..]),
            .highest => if (highestGroup(input, slots, program.capture_count)) |text| try writer.appendSlice(text),
            .input => try writer.appendSlice(input),
        }
    }
}
