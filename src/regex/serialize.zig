//! Versioned binary serialization for compiled `Program`s.
//!
//! The format is little-endian and self-describing. `deserialize` validates
//! every instruction index and slot before returning, so a corrupt or
//! malicious blob fails with `error.InvalidRegex` instead of reaching the
//! execution engines. The deserializer allocates all slices in the supplied
//! allocator; use an arena and keep it alive for the program's lifetime.
const std = @import("std");
const model = @import("model.zig");
const classes = @import("classes.zig");
const Program = @import("compile.zig").Program;
const required_literals = @import("required_literals.zig");

const magic = "RGXZ";
const version: u16 = 4;
const max_instructions: u32 = 1 << 20;
const max_ranges: u32 = 1 << 20;
const max_names: u32 = 1 << 16;

const Tag = enum(u8) {
    accept,
    sub_accept,
    byte,
    literal_byte,
    literal_rune,
    consume,
    star,
    split,
    assertion,
    lookahead,
    lookaround,
    backref,
    atomic,
    conditional,
    conditional_assert,
    conditional_recursion,
    reset_start,
    grapheme,
    fail,
    accept_verb,
    prune,
    skip,
    commit,
    then,
    mark,
    callout,
    auto_callout,
    reset_captures,
    dispatch,
    call,
    ret,
    save,
    string_property,
    restore_pos,
    lookbehind_non_atomic,
    lookbehind_next,
    lookbehind_accept,
};

const Writer = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn byte(self: *Writer, value: u8) !void {
        try self.list.append(self.allocator, value);
    }
    fn boolean(self: *Writer, value: bool) !void {
        try self.byte(if (value) 1 else 0);
    }
    fn u16v(self: *Writer, value: u16) !void {
        var buffer: [2]u8 = undefined;
        std.mem.writeInt(u16, &buffer, value, .little);
        try self.list.appendSlice(self.allocator, &buffer);
    }
    fn u32v(self: *Writer, value: u32) !void {
        var buffer: [4]u8 = undefined;
        std.mem.writeInt(u32, &buffer, value, .little);
        try self.list.appendSlice(self.allocator, &buffer);
    }
    fn u64v(self: *Writer, value: u64) !void {
        var buffer: [8]u8 = undefined;
        std.mem.writeInt(u64, &buffer, value, .little);
        try self.list.appendSlice(self.allocator, &buffer);
    }
    fn bytes(self: *Writer, value: []const u8) !void {
        try self.u32v(@intCast(value.len));
        try self.list.appendSlice(self.allocator, value);
    }
    fn optionalBytes(self: *Writer, value: ?[]const u8) !void {
        if (value) |slice| {
            try self.boolean(true);
            try self.bytes(slice);
        } else {
            try self.boolean(false);
        }
    }
    fn set(self: *Writer, value: model.Set) !void {
        try self.u32v(@intCast(value.ranges.len));
        for (value.ranges) |range| {
            try self.u32v(range.first);
            try self.u32v(range.last);
        }
    }
    fn firstSet(self: *Writer, value: model.FirstSet) !void {
        try self.u64v(value.ascii[0]);
        try self.u64v(value.ascii[1]);
        try self.boolean(value.nonascii);
        try self.boolean(value.empty);
    }
};

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) !u8 {
        if (self.pos >= self.data.len) return error.InvalidRegex;
        const value = self.data[self.pos];
        self.pos += 1;
        return value;
    }
    fn boolean(self: *Reader) !bool {
        return switch (try self.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidRegex,
        };
    }
    fn u16v(self: *Reader) !u16 {
        if (self.data.len - self.pos < 2) return error.InvalidRegex;
        const value = std.mem.readInt(u16, self.data[self.pos..][0..2], .little);
        self.pos += 2;
        return value;
    }
    fn u32v(self: *Reader) !u32 {
        if (self.data.len - self.pos < 4) return error.InvalidRegex;
        const value = std.mem.readInt(u32, self.data[self.pos..][0..4], .little);
        self.pos += 4;
        return value;
    }
    fn u64v(self: *Reader) !u64 {
        if (self.data.len - self.pos < 8) return error.InvalidRegex;
        const value = std.mem.readInt(u64, self.data[self.pos..][0..8], .little);
        self.pos += 8;
        return value;
    }
    fn bytes(self: *Reader, allocator: std.mem.Allocator) ![]const u8 {
        const len = try self.u32v();
        if (len > self.data.len - self.pos) return error.InvalidRegex;
        const slice = self.data[self.pos..][0..len];
        self.pos += len;
        return allocator.dupe(u8, slice);
    }
    fn optionalBytes(self: *Reader, allocator: std.mem.Allocator) !?[]const u8 {
        if (!try self.boolean()) return null;
        return try self.bytes(allocator);
    }
    fn set(self: *Reader, allocator: std.mem.Allocator) !model.Set {
        const count = try self.u32v();
        if (count > max_ranges) return error.RegexLimitExceeded;
        const ranges = try allocator.alloc(model.Range, count);
        errdefer allocator.free(ranges);
        for (ranges) |*range| {
            const first = try self.u32v();
            const last = try self.u32v();
            if (first > 0x10ffff or last > 0x10ffff or first > last) return error.InvalidRegex;
            range.* = .{ .first = @intCast(first), .last = @intCast(last) };
        }
        return classes.fromRanges(ranges);
    }
    fn firstSet(self: *Reader) !model.FirstSet {
        return .{
            .ascii = .{ try self.u64v(), try self.u64v() },
            .nonascii = try self.boolean(),
            .empty = try self.boolean(),
        };
    }
};

fn writeInstruction(writer: *Writer, instruction: model.Instruction) !void {
    switch (instruction) {
        .accept => try writer.byte(@intFromEnum(Tag.accept)),
        .sub_accept => try writer.byte(@intFromEnum(Tag.sub_accept)),
        .byte => |next| {
            try writer.byte(@intFromEnum(Tag.byte));
            try writer.u32v(@intCast(next));
        },
        .literal_byte => |literal| {
            try writer.byte(@intFromEnum(Tag.literal_byte));
            try writer.byte(literal.value);
            try writer.u32v(@intCast(literal.next));
        },
        .literal_rune => |literal| {
            try writer.byte(@intFromEnum(Tag.literal_rune));
            try writer.u32v(literal.value);
            try writer.u32v(@intCast(literal.next));
        },
        .consume => |consume| {
            try writer.byte(@intFromEnum(Tag.consume));
            try writer.set(consume.set);
            try writer.u32v(@intCast(consume.next));
        },
        .star => |star| {
            try writer.byte(@intFromEnum(Tag.star));
            try writer.set(star.set);
            try writer.u32v(@intCast(star.next));
            try writer.boolean(star.backtrack);
        },
        .split => |split| {
            try writer.byte(@intFromEnum(Tag.split));
            try writer.u32v(@intCast(split.left));
            try writer.u32v(@intCast(split.right));
            try writer.boolean(split.alternation);
            try writer.firstSet(split.first);
            try writer.boolean(split.skip);
        },
        .assertion => |assertion| {
            try writer.byte(@intFromEnum(Tag.assertion));
            try writer.byte(@intFromEnum(assertion.kind));
            try writer.u32v(@intCast(assertion.next));
        },
        .lookahead => |look| {
            try writer.byte(@intFromEnum(Tag.lookahead));
            try writer.set(look.set);
            try writer.boolean(look.negative);
            try writer.u32v(@intCast(look.next));
        },
        .lookaround => |look| {
            try writer.byte(@intFromEnum(Tag.lookaround));
            try writer.u32v(@intCast(look.child));
            try writer.boolean(look.negative);
            try writer.boolean(look.behind);
            try writer.u32v(@intCast(look.next));
        },
        .backref => |ref| {
            try writer.byte(@intFromEnum(Tag.backref));
            try writer.u16v(ref.group);
            try writer.u32v(@intCast(ref.next));
        },
        .atomic => |atom| {
            try writer.byte(@intFromEnum(Tag.atomic));
            try writer.u32v(@intCast(atom.child));
            try writer.u32v(@intCast(atom.next));
        },
        .conditional => |cond| {
            try writer.byte(@intFromEnum(Tag.conditional));
            try writer.u16v(cond.group);
            try writer.u32v(@intCast(cond.yes));
            try writer.u32v(@intCast(cond.no));
        },
        .conditional_assert => |cond| {
            try writer.byte(@intFromEnum(Tag.conditional_assert));
            try writer.u32v(@intCast(cond.child));
            try writer.boolean(cond.negative);
            try writer.boolean(cond.behind);
            try writer.u32v(@intCast(cond.yes));
            try writer.u32v(@intCast(cond.no));
        },
        .conditional_recursion => |cond| {
            try writer.byte(@intFromEnum(Tag.conditional_recursion));
            if (cond.group) |group| {
                try writer.boolean(true);
                try writer.u16v(group);
            } else {
                try writer.boolean(false);
            }
            try writer.u32v(@intCast(cond.yes));
            try writer.u32v(@intCast(cond.no));
        },
        .reset_start => |next| {
            try writer.byte(@intFromEnum(Tag.reset_start));
            try writer.u32v(@intCast(next));
        },
        .grapheme => |next| {
            try writer.byte(@intFromEnum(Tag.grapheme));
            try writer.u32v(@intCast(next));
        },
        .fail => try writer.byte(@intFromEnum(Tag.fail)),
        .accept_verb => try writer.byte(@intFromEnum(Tag.accept_verb)),
        .prune => |next| {
            try writer.byte(@intFromEnum(Tag.prune));
            try writer.u32v(@intCast(next));
        },
        .skip => |skip| {
            try writer.byte(@intFromEnum(Tag.skip));
            try writer.u32v(@intCast(skip.next));
            try writer.optionalBytes(skip.name);
        },
        .commit => |next| {
            try writer.byte(@intFromEnum(Tag.commit));
            try writer.u32v(@intCast(next));
        },
        .then => |next| {
            try writer.byte(@intFromEnum(Tag.then));
            try writer.u32v(@intCast(next));
        },
        .mark => |mark| {
            try writer.byte(@intFromEnum(Tag.mark));
            try writer.u16v(mark.index);
            try writer.u32v(@intCast(mark.next));
        },
        .callout => |callout| {
            try writer.byte(@intFromEnum(Tag.callout));
            try writer.u16v(callout.id);
            try writer.u32v(@intCast(callout.next));
        },
        .auto_callout => |next| {
            try writer.byte(@intFromEnum(Tag.auto_callout));
            try writer.u32v(@intCast(next));
        },
        .reset_captures => |reset| {
            try writer.byte(@intFromEnum(Tag.reset_captures));
            try writer.u16v(reset.first);
            try writer.u16v(reset.last);
            try writer.u32v(@intCast(reset.next));
        },
        .dispatch => |dispatch| {
            try writer.byte(@intFromEnum(Tag.dispatch));
            try writer.u16v(dispatch.table);
        },
        .call => |call| {
            try writer.byte(@intFromEnum(Tag.call));
            try writer.u16v(call.group);
            try writer.u32v(@intCast(call.child));
            try writer.u32v(@intCast(call.next));
        },
        .ret => try writer.byte(@intFromEnum(Tag.ret)),
        .save => |save| {
            try writer.byte(@intFromEnum(Tag.save));
            try writer.u16v(save.slot);
            try writer.u32v(@intCast(save.next));
        },
        .string_property => |property| {
            try writer.byte(@intFromEnum(Tag.string_property));
            try writer.byte(@intFromEnum(property.property));
            try writer.u32v(@intCast(property.next));
        },
        .restore_pos => |restore| {
            try writer.byte(@intFromEnum(Tag.restore_pos));
            try writer.u16v(restore.slot);
            try writer.u32v(@intCast(restore.next));
        },
        .lookbehind_non_atomic => |look| {
            try writer.byte(@intFromEnum(Tag.lookbehind_non_atomic));
            try writer.u32v(@intCast(look.child));
            try writer.u32v(@intCast(look.next));
            try writer.u32v(@intCast(look.scan_pc));
            try writer.u16v(look.target_slot);
            try writer.u16v(look.start_slot);
        },
        .lookbehind_next => |look| {
            try writer.byte(@intFromEnum(Tag.lookbehind_next));
            try writer.u32v(@intCast(look.child));
            try writer.u16v(look.target_slot);
            try writer.u16v(look.start_slot);
        },
        .lookbehind_accept => |look| {
            try writer.byte(@intFromEnum(Tag.lookbehind_accept));
            try writer.u16v(look.target_slot);
            try writer.u32v(@intCast(look.next));
        },
    }
}

fn readInstruction(reader: *Reader, allocator: std.mem.Allocator) !model.Instruction {
    const tag_value = try reader.byte();
    if (tag_value > @intFromEnum(Tag.lookbehind_accept)) return error.InvalidRegex;
    const tag: Tag = @enumFromInt(tag_value);
    return switch (tag) {
        .accept => .accept,
        .sub_accept => .sub_accept,
        .byte => .{ .byte = @intCast(try reader.u32v()) },
        .literal_byte => .{ .literal_byte = .{ .value = try reader.byte(), .next = @intCast(try reader.u32v()) } },
        .literal_rune => .{ .literal_rune = .{ .value = @intCast(try reader.u32v()), .next = @intCast(try reader.u32v()) } },
        .consume => .{ .consume = .{ .set = try reader.set(allocator), .next = @intCast(try reader.u32v()) } },
        .star => .{ .star = .{ .set = try reader.set(allocator), .next = @intCast(try reader.u32v()), .backtrack = try reader.boolean() } },
        .split => .{ .split = .{
            .left = @intCast(try reader.u32v()),
            .right = @intCast(try reader.u32v()),
            .alternation = try reader.boolean(),
            .first = try reader.firstSet(),
            .skip = try reader.boolean(),
        } },
        .assertion => blk: {
            const kind_value = try reader.byte();
            if (kind_value > @intFromEnum(model.Assertion.no_word_end_unicode)) return error.InvalidRegex;
            break :blk .{ .assertion = .{
                .kind = @enumFromInt(kind_value),
                .next = @intCast(try reader.u32v()),
            } };
        },
        .lookahead => .{ .lookahead = .{ .set = try reader.set(allocator), .negative = try reader.boolean(), .next = @intCast(try reader.u32v()) } },
        .lookaround => .{ .lookaround = .{
            .child = @intCast(try reader.u32v()),
            .negative = try reader.boolean(),
            .behind = try reader.boolean(),
            .next = @intCast(try reader.u32v()),
        } },
        .backref => .{ .backref = .{ .group = try reader.u16v(), .next = @intCast(try reader.u32v()) } },
        .atomic => .{ .atomic = .{ .child = @intCast(try reader.u32v()), .next = @intCast(try reader.u32v()) } },
        .conditional => .{ .conditional = .{ .group = try reader.u16v(), .yes = @intCast(try reader.u32v()), .no = @intCast(try reader.u32v()) } },
        .conditional_assert => .{ .conditional_assert = .{
            .child = @intCast(try reader.u32v()),
            .negative = try reader.boolean(),
            .behind = try reader.boolean(),
            .yes = @intCast(try reader.u32v()),
            .no = @intCast(try reader.u32v()),
        } },
        .conditional_recursion => .{ .conditional_recursion = .{
            .group = if (try reader.boolean()) try reader.u16v() else null,
            .yes = @intCast(try reader.u32v()),
            .no = @intCast(try reader.u32v()),
        } },
        .reset_start => .{ .reset_start = @intCast(try reader.u32v()) },
        .grapheme => .{ .grapheme = @intCast(try reader.u32v()) },
        .fail => .fail,
        .accept_verb => .accept_verb,
        .prune => .{ .prune = @intCast(try reader.u32v()) },
        .skip => .{ .skip = .{ .next = @intCast(try reader.u32v()), .name = try reader.optionalBytes(allocator) } },
        .commit => .{ .commit = @intCast(try reader.u32v()) },
        .then => .{ .then = @intCast(try reader.u32v()) },
        .mark => .{ .mark = .{ .index = try reader.u16v(), .next = @intCast(try reader.u32v()) } },
        .callout => .{ .callout = .{ .id = try reader.u16v(), .next = @intCast(try reader.u32v()) } },
        .auto_callout => .{ .auto_callout = @intCast(try reader.u32v()) },
        .reset_captures => .{ .reset_captures = .{ .first = try reader.u16v(), .last = try reader.u16v(), .next = @intCast(try reader.u32v()) } },
        .dispatch => .{ .dispatch = .{ .table = try reader.u16v() } },
        .call => .{ .call = .{ .group = try reader.u16v(), .child = @intCast(try reader.u32v()), .next = @intCast(try reader.u32v()) } },
        .ret => .ret,
        .save => .{ .save = .{ .slot = try reader.u16v(), .next = @intCast(try reader.u32v()) } },
        .string_property => blk: {
            const property_value = try reader.byte();
            if (property_value > @intFromEnum(model.StringProperty.rgi_emoji_zwj_sequence)) return error.InvalidRegex;
            break :blk .{ .string_property = .{
                .property = @enumFromInt(property_value),
                .next = @intCast(try reader.u32v()),
            } };
        },
        .restore_pos => .{ .restore_pos = .{
            .slot = try reader.u16v(),
            .next = @intCast(try reader.u32v()),
        } },
        .lookbehind_non_atomic => .{ .lookbehind_non_atomic = .{
            .child = @intCast(try reader.u32v()),
            .next = @intCast(try reader.u32v()),
            .scan_pc = @intCast(try reader.u32v()),
            .target_slot = try reader.u16v(),
            .start_slot = try reader.u16v(),
        } },
        .lookbehind_next => .{ .lookbehind_next = .{
            .child = @intCast(try reader.u32v()),
            .target_slot = try reader.u16v(),
            .start_slot = try reader.u16v(),
        } },
        .lookbehind_accept => .{ .lookbehind_accept = .{
            .target_slot = try reader.u16v(),
            .next = @intCast(try reader.u32v()),
        } },
    };
}

pub fn serialize(program: Program, allocator: std.mem.Allocator) model.Error![]u8 {
    if (program.instructions.len > max_instructions or
        program.group_names.len > max_names or
        program.marks.len > max_names or
        program.callouts.len > max_names or
        program.dispatches.len > max_names)
    {
        return error.RegexLimitExceeded;
    }
    var writer = Writer{ .allocator = allocator };
    errdefer writer.list.deinit(allocator);
    try writer.list.appendSlice(allocator, magic);
    try writer.u16v(version);
    var flags: u16 = 0;
    if (program.dfa_eligible) flags |= 1;
    if (program.extended) flags |= 2;
    if (program.skip_start) flags |= 4;
    try writer.u16v(flags);
    try writer.u32v(@intCast(program.instructions.len));
    try writer.u32v(@intCast(program.start));
    try writer.u32v(@intCast(program.body));
    try writer.u32v(@intCast(program.accept));
    try writer.u16v(program.capture_count);
    try writer.u16v(program.extra_slots);
    try writer.firstSet(program.first);
    try writer.optionalBytes(program.literal);
    try writer.optionalBytes(program.literal_prefix);
    try writer.u32v(if (program.required_literals) |literals| @intCast(literals.len) else 0);
    if (program.required_literals) |literals| {
        for (literals) |literal| try writer.bytes(literal);
    }
    try writer.u32v(@intCast(program.group_names.len));
    for (program.group_names) |entry| {
        try writer.u16v(entry.index);
        try writer.bytes(entry.name);
    }
    try writer.u32v(@intCast(program.marks.len));
    for (program.marks) |name| try writer.bytes(name);
    try writer.u32v(@intCast(program.callouts.len));
    for (program.callouts) |callout| {
        try writer.u32v(callout.number);
        try writer.optionalBytes(callout.name);
    }
    if (program.ucp_word) |set| {
        try writer.boolean(true);
        try writer.set(set);
    } else {
        try writer.boolean(false);
    }
    try writer.u32v(@intCast(program.dispatches.len));
    for (program.dispatches) |dispatch| {
        try writer.u32v(@intCast(dispatch.branches.len));
        for (dispatch.branches) |branch| try writer.u32v(@intCast(branch));
        for (dispatch.ascii) |value| try writer.u16v(value);
        try writer.u16v(dispatch.nonascii);
        try writer.u16v(dispatch.eof);
    }
    for (program.instructions) |instruction| try writeInstruction(&writer, instruction);
    return writer.list.toOwnedSlice(allocator);
}

pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) model.Error!Program {
    var reader = Reader{ .data = bytes };
    if (bytes.len < magic.len or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.InvalidRegex;
    reader.pos = magic.len;
    if (try reader.u16v() != version) return error.InvalidRegex;
    const flags = try reader.u16v();
    const count = try reader.u32v();
    if (count > max_instructions) return error.RegexLimitExceeded;
    const start = try reader.u32v();
    const body = try reader.u32v();
    const accept = try reader.u32v();
    const capture_count = try reader.u16v();
    const extra_slots = try reader.u16v();
    const first = try reader.firstSet();
    const literal = try reader.optionalBytes(allocator);
    const literal_prefix = try reader.optionalBytes(allocator);
    const required_count = try reader.u32v();
    if (required_count > required_literals.max_literals) return error.RegexLimitExceeded;
    const required: ?[]const []const u8 = if (required_count == 0) null else blk: {
        const literals = try allocator.alloc([]const u8, required_count);
        for (literals) |*item| {
            item.* = try reader.bytes(allocator);
            if (item.*.len == 0 or item.*.len > required_literals.max_literal_len) return error.InvalidRegex;
        }
        break :blk literals;
    };
    const group_count = try reader.u32v();
    if (group_count > max_names) return error.RegexLimitExceeded;
    const group_names = try allocator.alloc(model.GroupName, group_count);
    for (group_names) |*entry| {
        entry.index = try reader.u16v();
        entry.name = try reader.bytes(allocator);
    }
    const mark_count = try reader.u32v();
    if (mark_count > max_names) return error.RegexLimitExceeded;
    const marks = try allocator.alloc([]const u8, mark_count);
    for (marks) |*name| name.* = try reader.bytes(allocator);
    const callout_count = try reader.u32v();
    if (callout_count > max_names) return error.RegexLimitExceeded;
    const callouts = try allocator.alloc(model.CalloutSpec, callout_count);
    for (callouts) |*callout| {
        callout.number = try reader.u32v();
        callout.name = try reader.optionalBytes(allocator);
    }
    const ucp_word = if (try reader.boolean()) try reader.set(allocator) else null;
    const dispatch_count = try reader.u32v();
    if (dispatch_count > max_names) return error.RegexLimitExceeded;
    const dispatches = try allocator.alloc(model.Dispatch, dispatch_count);
    for (dispatches) |*dispatch| {
        const branch_count = try reader.u32v();
        if (branch_count > max_instructions) return error.RegexLimitExceeded;
        const branches = try allocator.alloc(usize, branch_count);
        for (branches) |*branch| branch.* = @intCast(try reader.u32v());
        dispatch.branches = branches;
        for (&dispatch.ascii) |*value| value.* = try reader.u16v();
        dispatch.nonascii = try reader.u16v();
        dispatch.eof = try reader.u16v();
    }
    const instructions = try allocator.alloc(model.Instruction, count);
    for (instructions) |*instruction| instruction.* = try readInstruction(&reader, allocator);
    if (reader.pos != bytes.len) return error.InvalidRegex;
    const program = Program{
        .instructions = instructions,
        .start = @intCast(start),
        .body = @intCast(body),
        .accept = @intCast(accept),
        .capture_count = capture_count,
        .extra_slots = extra_slots,
        .literal = literal,
        .literal_prefix = literal_prefix,
        .required_literals = required,
        .dfa_eligible = flags & 1 != 0,
        .extended = flags & 2 != 0,
        .group_names = group_names,
        .ucp_word = ucp_word,
        .marks = marks,
        .callouts = callouts,
        .dispatches = dispatches,
        .first = first,
        .skip_start = flags & 4 != 0,
    };
    try validate(program);
    return program;
}

fn validate(program: Program) model.Error!void {
    const count = program.instructions.len;
    const slot_count = 2 * (@as(usize, program.capture_count) + 1) + program.extra_slots;
    if (program.start >= count or program.body >= count or program.accept >= count) return error.InvalidRegex;
    for (program.instructions) |instruction| switch (instruction) {
        .accept, .sub_accept, .fail, .accept_verb, .ret => {},
        .byte => |next| if (next >= count) return error.InvalidRegex,
        .literal_byte => |literal| if (literal.next >= count) return error.InvalidRegex,
        .literal_rune => |literal| if (literal.next >= count) return error.InvalidRegex,
        .consume => |consume| if (consume.next >= count) return error.InvalidRegex,
        .star => |star| if (star.next >= count) return error.InvalidRegex,
        .split => |split| if (split.left >= count or split.right >= count) return error.InvalidRegex,
        .assertion => |assertion| if (assertion.next >= count) return error.InvalidRegex,
        .lookahead => |look| if (look.next >= count) return error.InvalidRegex,
        .lookaround => |look| if (look.child >= count or look.next >= count) return error.InvalidRegex,
        .backref => |ref| if (ref.next >= count or ref.group > program.capture_count) return error.InvalidRegex,
        .atomic => |atom| if (atom.child >= count or atom.next >= count) return error.InvalidRegex,
        .conditional => |cond| if (cond.yes >= count or cond.no >= count or cond.group > program.capture_count) return error.InvalidRegex,
        .conditional_assert => |cond| if (cond.child >= count or cond.yes >= count or cond.no >= count) return error.InvalidRegex,
        .conditional_recursion => |cond| if (cond.yes >= count or cond.no >= count) return error.InvalidRegex,
        .reset_start => |next| if (next >= count) return error.InvalidRegex,
        .grapheme => |next| if (next >= count) return error.InvalidRegex,
        .prune => |next| if (next >= count) return error.InvalidRegex,
        .skip => |skip| if (skip.next >= count) return error.InvalidRegex,
        .commit => |next| if (next >= count) return error.InvalidRegex,
        .then => |next| if (next >= count) return error.InvalidRegex,
        .mark => |mark| if (mark.next >= count or mark.index >= program.marks.len) return error.InvalidRegex,
        .callout => |callout| if (callout.next >= count or callout.id >= program.callouts.len) return error.InvalidRegex,
        .auto_callout => |next| if (next >= count) return error.InvalidRegex,
        .reset_captures => |reset| if (reset.next >= count or reset.first > reset.last or reset.last > slot_count) return error.InvalidRegex,
        .dispatch => |dispatch| if (dispatch.table >= program.dispatches.len) return error.InvalidRegex,
        .call => |call| if (call.child >= count or call.next >= count) return error.InvalidRegex,
        .save => |save| if (save.next >= count or save.slot >= slot_count) return error.InvalidRegex,
        .string_property => |property| if (property.next >= count) return error.InvalidRegex,
        .restore_pos => |restore| if (restore.next >= count or restore.slot >= slot_count) return error.InvalidRegex,
        .lookbehind_non_atomic => |look| if (look.child >= count or look.next >= count or look.scan_pc >= count or look.target_slot >= slot_count or look.start_slot >= slot_count) return error.InvalidRegex,
        .lookbehind_next => |look| if (look.child >= count or look.target_slot >= slot_count or look.start_slot >= slot_count) return error.InvalidRegex,
        .lookbehind_accept => |look| if (look.next >= count or look.target_slot >= slot_count) return error.InvalidRegex,
    };
    for (program.dispatches) |dispatch| {
        for (dispatch.branches) |branch| {
            if (branch >= count) return error.InvalidRegex;
        }
    }
}
