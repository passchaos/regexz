//! Bounded PCRE-style backtracking VM for extended patterns.
//!
//! The linear engine in `execute.zig` cannot express general lookaround,
//! backreferences, atomic groups, possessive quantifiers, or conditionals.
//! Programs using those features are compiled with sub-program entry points
//! and executed here with an explicit choice stack, capture trail, step
//! budget, and recursion-depth limit.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const grapheme = @import("grapheme.zig");
const word_boundary = @import("word_boundary.zig");
const sentence_boundary = @import("sentence_boundary.zig");
const unset = std.math.maxInt(usize);

pub const Error = model.Error;

const Choice = struct { pc: usize, pos: usize, trail_len: usize, call_depth: usize, alternation: bool = false, mark: ?u16 = null, mark_pos: usize = 0 };
const Trail = struct { slot: u16, old: usize };
const CallFrame = struct { next: usize, group: u16 };
const Stop = union(enum) {
    /// Accept only when the whole input has been consumed.
    full,
    /// Accept at the first match end.
    find,
    /// Sub-run terminated by `sub_accept`; the optional target requires an
    /// exact end position (used by lookbehind).
    sub: ?usize,
};
const Barrier = enum { none, prune, skip, commit };

pub const Match = struct {
    start: usize,
    end: usize,
    /// Slots for the whole match (0,1) and every capture group. The slice
    /// points into the workspace and is valid until the next find call.
    slots: []const usize,
    /// Index of the last `(*MARK:name)` on the successful path.
    mark: ?u16 = null,
};

const Position = struct {
    start: bool,
    end: bool,
    final_newline: bool,
    start_match: bool,
    previous: ?u21,
    next: ?u21,
    previous_rune: ?u21,
    next_rune: ?u21,
    input: []const u8,
    offset: usize,
    fn asciiWord(rune: ?u21) bool {
        const value = rune orelse return false;
        return value == '_' or (value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9');
    }
    fn unicodeWord(set: ?model.Set, rune: ?u21) bool {
        const value = rune orelse return false;
        const word_set = set orelse return false;
        return word_set.matches(value);
    }
    fn allows(self: Position, kind: model.Assertion, ucp_word: ?model.Set) bool {
        return switch (kind) {
            .start_text => self.start,
            .end_text => self.end,
            .end_text_or_newline => self.end or self.final_newline,
            .start_match => self.start_match,
            .start_line => self.start or self.previous == '\n',
            .end_line => self.end or self.next == '\n',
            .word_boundary => asciiWord(self.previous_rune) != asciiWord(self.next_rune),
            .no_word_boundary => asciiWord(self.previous_rune) == asciiWord(self.next_rune),
            .word_boundary_unicode => unicodeWord(ucp_word, self.previous_rune) != unicodeWord(ucp_word, self.next_rune),
            .no_word_boundary_unicode => unicodeWord(ucp_word, self.previous_rune) == unicodeWord(ucp_word, self.next_rune),
            .grapheme_boundary => grapheme.isBoundary(self.input, self.offset),
            .no_grapheme_boundary => !grapheme.isBoundary(self.input, self.offset),
            .word_boundary_uax29 => word_boundary.isBoundary(self.input, self.offset),
            .no_word_boundary_uax29 => !word_boundary.isBoundary(self.input, self.offset),
            .sentence_boundary => sentence_boundary.isBoundary(self.input, self.offset),
            .no_sentence_boundary => !sentence_boundary.isBoundary(self.input, self.offset),
            .word_start => !asciiWord(self.previous_rune) and asciiWord(self.next_rune),
            .no_word_start => !(!asciiWord(self.previous_rune) and asciiWord(self.next_rune)),
            .word_end => asciiWord(self.previous_rune) and !asciiWord(self.next_rune),
            .no_word_end => !(asciiWord(self.previous_rune) and !asciiWord(self.next_rune)),
            .word_start_unicode => !unicodeWord(ucp_word, self.previous_rune) and unicodeWord(ucp_word, self.next_rune),
            .no_word_start_unicode => !(!unicodeWord(ucp_word, self.previous_rune) and unicodeWord(ucp_word, self.next_rune)),
            .word_end_unicode => unicodeWord(ucp_word, self.previous_rune) and !unicodeWord(ucp_word, self.next_rune),
            .no_word_end_unicode => !(unicodeWord(ucp_word, self.previous_rune) and !unicodeWord(ucp_word, self.next_rune)),
        };
    }
};

fn runeAt(input: []const u8, offset: usize) ?struct { value: u21, len: usize } {
    if (offset >= input.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn runeLenAt(input: []const u8, offset: usize) usize {
    return if (runeAt(input, offset)) |rune| rune.len else 1;
}

fn runeBefore(input: []const u8, offset: usize) ?u21 {
    if (offset == 0) return null;
    var start = offset - 1;
    while (start > 0 and (input[start] & 0xc0) == 0x80) start -= 1;
    return if (runeAt(input, start)) |rune| rune.value else null;
}

fn position(input: []const u8, offset: usize, attempt_start: usize) Position {
    const final_newline = offset == input.len or
        (offset + 1 == input.len and input[offset] == '\n') or
        (offset + 2 == input.len and input[offset] == '\r' and input[offset + 1] == '\n');
    return .{
        .start = offset == 0,
        .end = offset == input.len,
        .final_newline = final_newline,
        .start_match = offset == attempt_start,
        .previous = if (offset == 0) null else input[offset - 1],
        .next = if (offset == input.len) null else input[offset],
        .previous_rune = runeBefore(input, offset),
        .input = input,
        .offset = offset,
        .next_rune = if (runeAt(input, offset)) |rune| rune.value else null,
    };
}

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    program: Program,
    limits: model.Limits,
    slots: []usize,
    /// Number of user-visible capture slots (hidden lookaround slots follow).
    user_slot_count: usize,
    best_slots: []usize,
    choices: std.ArrayList(Choice) = .empty,
    trail: std.ArrayList(Trail) = .empty,
    calls: std.ArrayList(CallFrame) = .empty,
    /// Frames returned by `.ret`; backtracking into a subroutine re-activates
    /// them. Both stacks are preallocated to `max_recursion_depth`.
    returns: std.ArrayList(CallFrame) = .empty,
    steps: usize = 0,
    depth: usize = 0,
    partial: bool = false,
    mark: ?u16 = null,
    mark_pos: usize = 0,
    best_mark: ?u16 = null,
    attempt_start: usize = 0,
    skip_pos: usize = 0,
    skip_armed: bool = false,
    commit_failed: bool = false,
    // Filled by `backtrack` so the hot loop avoids a tuple return.
    pending_pc: usize = 0,
    pending_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, program: Program, limits: model.Limits) std.mem.Allocator.Error!Workspace {
        const user_slot_count = 2 * (@as(usize, program.capture_count) + 1);
        const slot_count = user_slot_count + program.extra_slots;
        const slots = try allocator.alloc(usize, slot_count);
        @memset(slots, unset);
        errdefer allocator.free(slots);
        const best_slots = try allocator.alloc(usize, slot_count);
        @memset(best_slots, unset);
        errdefer allocator.free(best_slots);
        var calls: std.ArrayList(CallFrame) = .empty;
        errdefer calls.deinit(allocator);
        try calls.ensureTotalCapacity(allocator, limits.max_recursion_depth);
        var returns: std.ArrayList(CallFrame) = .empty;
        errdefer returns.deinit(allocator);
        try returns.ensureTotalCapacity(allocator, limits.max_recursion_depth);
        return .{
            .allocator = allocator,
            .program = program,
            .limits = limits,
            .slots = slots,
            .user_slot_count = user_slot_count,
            .best_slots = best_slots,
            .calls = calls,
            .returns = returns,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.choices.deinit(self.allocator);
        self.trail.deinit(self.allocator);
        self.calls.deinit(self.allocator);
        self.returns.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.allocator.free(self.best_slots);
        self.* = undefined;
    }

    fn resetRun(self: *Workspace, start: usize) void {
        self.choices.clearRetainingCapacity();
        self.trail.clearRetainingCapacity();
        self.calls.clearRetainingCapacity();
        self.returns.clearRetainingCapacity();
        @memset(self.slots, unset);
        self.slots[0] = start;
        self.depth = 0;
        self.mark = null;
        self.mark_pos = 0;
        self.best_mark = null;
    }

    fn inRecursion(self: *Workspace, group: ?u16) bool {
        if (group) |wanted| {
            for (self.calls.items) |frame| {
                if (frame.group == wanted) return true;
            }
            return false;
        }
        return self.calls.items.len > 0;
    }

    fn restoreCallDepth(self: *Workspace, depth: usize) void {
        while (self.calls.items.len > depth) _ = self.calls.pop();
        // Re-activate returned frames (LIFO, deepest first) until the target
        // depth is reached, then discard any deeper returned frames.
        while (self.calls.items.len < depth) {
            const frame = self.returns.pop() orelse break;
            self.calls.appendAssumeCapacity(frame);
        }
        while (self.calls.items.len + self.returns.items.len > depth) _ = self.returns.pop();
    }

    fn restoreTrail(self: *Workspace, to: usize) void {
        while (self.trail.items.len > to) {
            const entry = self.trail.pop().?;
            self.slots[entry.slot] = entry.old;
        }
    }

    fn pushTrail(self: *Workspace, slot: u16, old: usize) Error!void {
        if (self.trail.items.len >= self.limits.max_capture_trail) return error.RegexLimitExceeded;
        try self.trail.append(self.allocator, .{ .slot = slot, .old = old });
    }

    /// Backtrack to the most recent choice above `choice_base`. Returns false
    /// when the run is exhausted.
    fn backtrack(self: *Workspace, choice_base: usize, trail_base: usize, prune_base: ?usize, barrier: Barrier) bool {
        if (self.choices.items.len <= choice_base) {
            self.restoreTrail(trail_base);
            return false;
        }
        if (prune_base) |base| {
            if (self.choices.items.len <= base) {
                switch (barrier) {
                    .skip => self.skip_armed = true,
                    .commit => self.commit_failed = true,
                    else => {},
                }
                self.restoreTrail(trail_base);
                return false;
            }
        }
        const choice = self.choices.pop().?;
        self.restoreCallDepth(choice.call_depth);
        self.restoreTrail(choice.trail_len);
        self.mark = choice.mark;
        self.mark_pos = choice.mark_pos;
        self.pending_pc = choice.pc;
        self.pending_pos = choice.pos;
        return true;
    }

    fn lookaround(self: *Workspace, input: []const u8, child: usize, negative: bool, behind: bool, pos: usize) Error!bool {
        const trail_base = self.trail.items.len;
        const choice_base = self.choices.items.len;
        var matched = false;
        if (behind) {
            var start: usize = 0;
            while (start <= pos) : (start += runeLenAt(input, start)) {
                if (try self.run(input, child, start, .{ .sub = pos }, choice_base, trail_base) != null) {
                    matched = true;
                    break;
                }
            }
        } else {
            matched = try self.run(input, child, pos, .{ .sub = null }, choice_base, trail_base) != null;
        }
        self.choices.shrinkRetainingCapacity(choice_base);
        if (negative) {
            self.restoreTrail(trail_base);
            return !matched;
        }
        if (!matched) {
            self.restoreTrail(trail_base);
            return false;
        }
        return true;
    }

    fn atomic(self: *Workspace, input: []const u8, child: usize, pos: usize) Error!?usize {
        const trail_base = self.trail.items.len;
        const choice_base = self.choices.items.len;
        const call_base = self.calls.items.len;
        const return_base = self.returns.items.len;
        const result = try self.run(input, child, pos, .{ .sub = null }, choice_base, trail_base);
        self.choices.shrinkRetainingCapacity(choice_base);
        self.calls.shrinkRetainingCapacity(call_base);
        self.returns.shrinkRetainingCapacity(return_base);
        if (result == null) {
            self.restoreTrail(trail_base);
            return null;
        }
        return result;
    }

    fn backref(self: *Workspace, input: []const u8, group: u16, pos: usize) ?usize {
        const begin = self.slots[@as(usize, group) * 2];
        const end = self.slots[@as(usize, group) * 2 + 1];
        if (begin == unset or end == unset) {
            // PCRE2_MATCH_UNSET_BACKREF / JavaScript: an unset group behaves
            // like an empty capture.
            return if (self.limits.unset_backref_empty) pos else null;
        }
        if (end < begin) return null;
        const captured = input[begin..end];
        const available = input.len - pos;
        if (captured.len > available) {
            // The input ends inside the expected backreference text. It is a
            // partial match only when the available bytes are a prefix.
            if (std.mem.eql(u8, input[pos..], captured[0..available])) self.partial = true;
            return null;
        }
        if (!std.mem.eql(u8, input[pos..][0..captured.len], captured)) return null;
        return pos + captured.len;
    }

    fn run(
        self: *Workspace,
        input: []const u8,
        start_pc: usize,
        start_pos: usize,
        stop: Stop,
        choice_base: usize,
        trail_base: usize,
    ) Error!?usize {
        if (self.depth >= self.limits.max_recursion_depth) return error.RegexLimitExceeded;
        self.depth += 1;
        defer self.depth -= 1;

        var pc = start_pc;
        var pos = start_pos;
        var best_end: ?usize = null;
        var prune_base: ?usize = null;
        var barrier: Barrier = .none;
        while (true) {
            self.steps += 1;
            if (self.steps > self.limits.max_execution_steps) return error.RegexLimitExceeded;
            switch (self.program.instructions[pc]) {
                .accept => switch (stop) {
                    .full => if (pos == input.len) return pos,
                    .find => {
                        if (!self.limits.longest) return pos;
                        if (best_end == null or pos > best_end.?) {
                            best_end = pos;
                            self.best_mark = self.mark;
                            @memcpy(self.best_slots, self.slots);
                        }
                    },
                    .sub => unreachable,
                },
                .accept_verb => switch (stop) {
                    .full => if (pos == input.len) return pos,
                    .find, .sub => return pos,
                },
                .fail => {},
                .sub_accept => switch (stop) {
                    .sub => |target| if (target == null or pos == target.?) return pos,
                    else => unreachable,
                },
                .byte => |next| {
                    if (pos < input.len) {
                        pos += 1;
                        pc = next;
                        continue;
                    }
                    self.partial = true;
                },
                .literal_byte => |literal| {
                    if (pos < input.len) {
                        if (input[pos] == literal.value) {
                            pos += 1;
                            pc = literal.next;
                            continue;
                        }
                    } else self.partial = true;
                },
                .literal_rune => |literal| {
                    if (runeAt(input, pos)) |rune| {
                        if (rune.value == literal.value) {
                            pos += rune.len;
                            pc = literal.next;
                            continue;
                        }
                    } else if (pos >= input.len) self.partial = true;
                },
                .consume => |*consume| {
                    if (runeAt(input, pos)) |rune| {
                        if (consume.set.matches(rune.value)) {
                            pos += rune.len;
                            pc = consume.next;
                            continue;
                        }
                    } else if (pos >= input.len and consume.set.ranges.len != 0) self.partial = true;
                },
                .star => |*star| {
                    // Linear programs use the counting star in replace.zig;
                    // this per-iteration form keeps the VM exhaustive if a
                    // star ever reaches the extended engine.
                    if (runeAt(input, pos)) |rune| {
                        if (star.set.matches(rune.value)) {
                            if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                                return error.RegexLimitExceeded;
                            }
                            try self.choices.append(self.allocator, .{
                                .pc = star.next,
                                .pos = pos,
                                .trail_len = self.trail.items.len,
                                .call_depth = self.calls.items.len,
                                .mark = self.mark,
                                .mark_pos = self.mark_pos,
                            });
                            pos += rune.len;
                            continue;
                        }
                    }
                    pc = star.next;
                    continue;
                },
                .save => |*save| {
                    try self.pushTrail(save.slot, self.slots[save.slot]);
                    self.slots[save.slot] = pos;
                    pc = save.next;
                    continue;
                },
                .restore_pos => |*restore| {
                    pos = self.slots[restore.slot];
                    pc = restore.next;
                    continue;
                },
                .split => |*split| {
                    if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                        return error.RegexLimitExceeded;
                    }
                    try self.choices.append(self.allocator, .{
                        .pc = split.right,
                        .pos = pos,
                        .trail_len = self.trail.items.len,
                        .call_depth = self.calls.items.len,
                        .alternation = split.alternation,
                        .mark = self.mark,
                        .mark_pos = self.mark_pos,
                    });
                    pc = split.left;
                    continue;
                },
                .assertion => |*assertion| {
                    if (position(input, pos, self.attempt_start).allows(assertion.kind, self.program.ucp_word)) {
                        pc = assertion.next;
                        continue;
                    }
                },
                .lookahead => |look| {
                    const next = runeAt(input, pos);
                    const matched = if (next) |rune| look.set.matches(rune.value) else false;
                    if (matched != look.negative) {
                        pc = look.next;
                        continue;
                    }
                },
                .lookaround => |look| {
                    if (try self.lookaround(input, look.child, look.negative, look.behind, pos)) {
                        pc = look.next;
                        continue;
                    }
                },
                .backref => |ref| {
                    if (self.backref(input, ref.group, pos)) |end| {
                        pos = end;
                        pc = ref.next;
                        continue;
                    }
                },
                .atomic => |atom| {
                    if (try self.atomic(input, atom.child, pos)) |end| {
                        pos = end;
                        pc = atom.next;
                        continue;
                    }
                },
                .conditional => |cond| {
                    const begin = self.slots[@as(usize, cond.group) * 2];
                    pc = if (begin != unset) cond.yes else cond.no;
                    continue;
                },
                .conditional_assert => |cond| {
                    const matched = try self.lookaround(input, cond.child, cond.negative, cond.behind, pos);
                    pc = if (matched) cond.yes else cond.no;
                    continue;
                },
                .conditional_recursion => |cond| {
                    pc = if (self.inRecursion(cond.group)) cond.yes else cond.no;
                    continue;
                },
                .reset_start => |next| {
                    try self.pushTrail(0, self.slots[0]);
                    self.slots[0] = pos;
                    pc = next;
                    continue;
                },
                .grapheme => |next| {
                    if (pos < input.len) {
                        pos = grapheme.next(input, pos);
                        pc = next;
                        continue;
                    }
                    self.partial = true;
                },
                .string_property => |property| {
                    if (model.unicode.matchStringProperty(property.property, input, pos)) |next_pos| {
                        pos = next_pos;
                        pc = property.next;
                        continue;
                    }
                    self.partial = true;
                },
                .prune => |next| {
                    prune_base = self.choices.items.len;
                    barrier = .prune;
                    pc = next;
                    continue;
                },
                .skip => |*skip| {
                    prune_base = self.choices.items.len;
                    barrier = .skip;
                    var target = pos;
                    if (skip.name) |wanted| {
                        if (self.mark) |mark_index| {
                            const current = self.program.markName(mark_index) orelse "";
                            if (std.mem.eql(u8, current, wanted)) target = self.mark_pos;
                        }
                    }
                    self.skip_pos = target;
                    pc = skip.next;
                    continue;
                },
                .commit => |next| {
                    prune_base = self.choices.items.len;
                    barrier = .commit;
                    pc = next;
                    continue;
                },
                .mark => |*mark| {
                    self.mark = mark.index;
                    self.mark_pos = pos;
                    pc = mark.next;
                    continue;
                },
                .dispatch => |*dispatch| {
                    const branches = self.program.dispatches[dispatch.table].branches;
                    if (branches.len == 0) continue;
                    var index = branches.len;
                    while (index > 1) {
                        index -= 1;
                        if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                            return error.RegexLimitExceeded;
                        }
                        try self.choices.append(self.allocator, .{
                            .pc = branches[index],
                            .pos = pos,
                            .trail_len = self.trail.items.len,
                            .call_depth = self.calls.items.len,
                            .alternation = true,
                            .mark = self.mark,
                        });
                    }
                    pc = branches[0];
                    continue;
                },
                .reset_captures => |*reset| {
                    var slot = reset.first;
                    while (slot < reset.last) : (slot += 1) {
                        try self.pushTrail(slot, self.slots[slot]);
                        self.slots[slot] = unset;
                    }
                    pc = reset.next;
                    continue;
                },
                .auto_callout => |next| {
                    const proceed = if (self.limits.callout) |callback|
                        callback.function(callback.context, .{ .number = 255 }, pos) == .proceed
                    else
                        true;
                    if (proceed) {
                        pc = next;
                        continue;
                    }
                },
                .callout => |*callout| {
                    const proceed = if (self.limits.callout) |callback|
                        callback.function(callback.context, self.program.callouts[callout.id], pos) == .proceed
                    else
                        true;
                    if (proceed) {
                        pc = callout.next;
                        continue;
                    }
                    // A failing callout falls through to the backtrack path.
                },
                .then => |next| {
                    // Discard choices made inside the current alternative so
                    // that a later failure resumes at the next alternative
                    // instead of backtracking within this one.
                    var found = false;
                    var index = self.choices.items.len;
                    while (index > 0) {
                        index -= 1;
                        if (self.choices.items[index].alternation) {
                            self.choices.shrinkRetainingCapacity(index + 1);
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        // No enclosing alternation: behave like (*PRUNE).
                        prune_base = self.choices.items.len;
                        barrier = .prune;
                    }
                    pc = next;
                    continue;
                },
                .call => |*call| {
                    if (self.calls.items.len >= self.limits.max_recursion_depth) {
                        return error.RegexLimitExceeded;
                    }
                    self.calls.appendAssumeCapacity(.{ .next = call.next, .group = call.group });
                    pc = call.child;
                    continue;
                },
                .ret => {
                    const frame = self.calls.pop() orelse unreachable;
                    self.returns.appendAssumeCapacity(frame);
                    pc = frame.next;
                    continue;
                },
            }
            if (!self.backtrack(choice_base, trail_base, prune_base, barrier)) {
                if (best_end) |end| {
                    @memcpy(self.slots, self.best_slots);
                    self.mark = self.best_mark;
                    return end;
                }
                return null;
            }
            pc = self.pending_pc;
            pos = self.pending_pos;
        }
    }

    /// Full-match partiality for extended programs: `full` when the input
    /// matches, `partial` when it is a proper prefix of a possible match.
    pub fn partialMatch(self: *Workspace, input: []const u8) Error!model.PartialResult {
        self.steps = 0;
        self.resetRun(0);
        self.attempt_start = 0;
        self.commit_failed = false;
        self.skip_armed = false;
        self.partial = false;
        if (try self.run(input, self.program.body, 0, .full, 0, 0) != null) return .full;
        return if (self.partial) .partial else .none;
    }

    /// Full match against the entire input.
    pub fn fullMatch(self: *Workspace, input: []const u8) Error!bool {
        self.steps = 0;
        self.resetRun(0);
        self.attempt_start = 0;
        self.commit_failed = false;
        self.skip_armed = false;
        return (try self.run(input, self.program.body, 0, .full, 0, 0)) != null;
    }

    /// Leftmost-first search at or after `search_start`. `\G` anchors to
    /// `search_start`, matching the caller-driven global-search contract.
    pub fn find(self: *Workspace, input: []const u8, search_start: usize) Error!?Match {
        if (search_start > input.len) return null;
        self.steps = 0;
        self.attempt_start = search_start;
        self.commit_failed = false;
        var start = search_start;
        while (start <= input.len) {
            self.resetRun(start);
            if (try self.run(input, self.program.body, start, .find, 0, 0)) |end| {
                const match_start = if (self.slots[0] == unset) start else self.slots[0];
                return .{ .start = match_start, .end = end, .slots = self.slots[0..self.user_slot_count], .mark = self.mark };
            }
            if (self.commit_failed) return null;
            if (self.skip_armed) {
                self.skip_armed = false;
                if (self.skip_pos > start) {
                    start = self.skip_pos;
                    continue;
                }
            }
            if (start == input.len) break;
            start += runeLenAt(input, start);
        }
        return null;
    }
};
