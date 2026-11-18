//! Bounded capture-aware RE2 replacement used by xDS regex rewrites.
//!
//! Boolean matching stays on the linear Thompson engine. Replacement needs
//! capture boundaries and leftmost-first priority. Programs with captures use
//! an explicit backtracking stack with a hard work budget, which makes
//! pathological patterns fail closed instead of running unboundedly.
//! Capture-free programs can retry on the linear Pike-style search in
//! `pike.zig` when the budget is exhausted and `Limits.linear_fallback` is on.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const pike = @import("pike.zig");
const backtrack = @import("backtrack.zig");
const search_dfa = @import("search_dfa.zig");
const prefilter = @import("prefilter.zig");
const required_literals = @import("required_literals.zig");
const unicode = @import("unicode.zig");
const unset = std.math.maxInt(usize);
const max_tracked_captures: usize = 9;
pub const Error = model.Error;

const Choice = struct { pc: usize, pos: usize, trail_len: usize, limit: usize = unset };
const Trail = struct { slot: u16, old: usize };

pub const Match = struct {
    start: usize,
    end: usize,
    /// Slots for the whole match (0,1) and every capture group. The slice
    /// points into the workspace and is valid until the next find call.
    slots: []const usize,
    /// Name of the last `(*MARK:name)` on the successful path, if any.
    mark: ?[]const u8 = null,
    /// Text for capture `index` (0 is the whole match), or null when the
    /// group did not participate.
    pub fn group(self: Match, input: []const u8, index: usize) ?[]const u8 {
        if (index * 2 + 1 >= self.slots.len) return null;
        const begin = self.slots[index * 2];
        const end = self.slots[index * 2 + 1];
        if (begin == unset or end == unset or end < begin) return null;
        return input[begin..end];
    }
};

/// Callback used by `Workspace.replaceAllWithFn`. The returned slice must be
/// allocated with the provided allocator; the workspace frees it after
/// copying the bytes into the output.
pub const ReplaceFn = *const fn (
    context: ?*anyopaque,
    allocator: std.mem.Allocator,
    input: []const u8,
    match: Match,
) Error![]u8;

fn indexOfLiteral(input: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (start <= input.len) start else null;
    var offset = start;
    while (std.mem.indexOfScalarPos(u8, input, offset, needle[0])) |found| {
        if (needle.len <= input.len - found and std.mem.eql(u8, input[found..][0..needle.len], needle)) return found;
        offset = found + 1;
    }
    return null;
}

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    program: Program,
    limits: model.Limits,
    slots: []usize,
    best_slots: []usize,
    choices: std.ArrayList(Choice) = .empty,
    trail: std.ArrayList(Trail) = .empty,
    steps: usize = 0,
    pike_eligible: bool = false,
    pike_workspace: ?pike.Workspace = null,
    backtrack_workspace: ?backtrack.Workspace = null,
    search_dfa_workspace: ?search_dfa.Workspace = null,
    search_dfa_failed: bool = false,
    search_dfa_ineligible: bool = false,
    first_filter: prefilter.FirstFilter,

    pub fn init(
        allocator: std.mem.Allocator,
        program: Program,
        limits: model.Limits,
    ) std.mem.Allocator.Error!Workspace {
        const slot_count = 2 * (@as(usize, program.trackedCaptures()) + 1);
        const slots = try allocator.alloc(usize, slot_count);
        @memset(slots, unset);
        errdefer allocator.free(slots);
        const best_slots = try allocator.alloc(usize, slot_count);
        @memset(best_slots, unset);
        errdefer allocator.free(best_slots);
        return .{
            .allocator = allocator,
            .program = program,
            .limits = limits,
            .slots = slots,
            .best_slots = best_slots,
            .pike_eligible = pike.eligible(program),
            .first_filter = prefilter.FirstFilter.init(program.first),
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.pike_workspace) |*workspace| workspace.deinit();
        if (self.backtrack_workspace) |*workspace| workspace.deinit();
        if (self.search_dfa_workspace) |*workspace| workspace.deinit();
        self.choices.deinit(self.allocator);
        self.trail.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.allocator.free(self.best_slots);
        self.* = undefined;
    }

    /// Full-match partiality for extended programs, delegated to the
    /// backtracking VM.
    pub fn partialMatch(self: *Workspace, input: []const u8) Error!model.PartialResult {
        if (self.backtrack_workspace == null) {
            self.backtrack_workspace = try backtrack.Workspace.init(self.allocator, self.program, self.limits);
        }
        return self.backtrack_workspace.?.partialMatch(input);
    }

    /// Find the leftmost-first match at or after `search_start`.
    pub fn find(
        self: *Workspace,
        input: []const u8,
        search_start: usize,
    ) Error!?Match {
        self.steps = 0;
        return self.findInternal(input, search_start);
    }

    /// Replace every non-overlapping leftmost-first match. RE2 substitution
    /// syntax is used: `\0` is the whole match, `\1`..`\9` are capture groups,
    /// `\\` is a literal backslash, and any other `\x` is emitted literally.
    pub fn replaceAll(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
    ) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var writer = ListWriter{ .list = &out, .allocator = self.allocator };
        try self.replaceAllWith(&writer, input, substitution);
        return out.toOwnedSlice(self.allocator);
    }

    /// Compute the exact replacement length without materializing the output.
    pub fn replaceAllLen(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
    ) Error!usize {
        var length: usize = 0;
        var writer = LengthWriter{ .length = &length };
        try self.replaceAllWith(&writer, input, substitution);
        return length;
    }

    /// Write the replacement into a caller-owned buffer. The buffer must be at
    /// least as large as `replaceAllLen`; otherwise the work fails closed.
    pub fn replaceAllInto(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
        output: []u8,
    ) Error![]const u8 {
        var writer = BufferWriter{ .output = output };
        try self.replaceAllWith(&writer, input, substitution);
        return output[0..writer.len];
    }

    /// Replace every non-overlapping leftmost-first match using a callback.
    /// This is the dynamic counterpart of `replaceAll`: the callback sees the
    /// whole-match and capture slots and can build arbitrary replacement text.
    pub fn replaceAllWithFn(
        self: *Workspace,
        input: []const u8,
        context: ?*anyopaque,
        function: ReplaceFn,
    ) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        self.steps = 0;
        var search_start: usize = 0;
        while (search_start <= input.len) {
            const match = try self.findInternal(input, search_start) orelse break;
            try out.appendSlice(self.allocator, input[search_start..match.start]);
            const replacement = try function(context, self.allocator, input, match);
            defer self.allocator.free(replacement);
            try out.appendSlice(self.allocator, replacement);
            if (match.end > match.start) {
                search_start = match.end;
            } else {
                if (match.start == input.len) {
                    search_start = input.len + 1;
                    break;
                }
                const len = runeLenAt(input, match.start);
                try out.appendSlice(self.allocator, input[match.start..][0..len]);
                search_start = match.start + len;
            }
        }
        if (search_start <= input.len) {
            try out.appendSlice(self.allocator, input[search_start..]);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn replaceAllWith(
        self: *Workspace,
        writer: anytype,
        input: []const u8,
        substitution: []const u8,
    ) Error!void {
        try validateSubstitutionFor(self.program, substitution);
        self.steps = 0;
        var search_start: usize = 0;
        while (search_start <= input.len) {
            const match = try self.findInternal(input, search_start) orelse break;
            try writer.appendSlice(input[search_start..match.start]);
            try appendSubstitution(writer, input, substitution, match.slots, self.program, self.limits.full_case_mapping);
            if (match.end > match.start) {
                search_start = match.end;
            } else {
                if (match.start == input.len) {
                    search_start = input.len + 1;
                    break;
                }
                const len = runeLenAt(input, match.start);
                try writer.appendSlice(input[match.start..][0..len]);
                search_start = match.start + len;
            }
        }
        if (search_start <= input.len) {
            try writer.appendSlice(input[search_start..]);
        }
    }

    fn pikeFind(
        self: *Workspace,
        input: []const u8,
        search_start: usize,
    ) Error!?Match {
        if (self.pike_workspace == null) {
            self.pike_workspace = try pike.Workspace.init(self.allocator, self.program);
        }
        const found = try self.pike_workspace.?.find(self.program, input, search_start) orelse return null;
        // The Pike slots point into its workspace; copy them so the returned
        // Match follows the same lifetime contract as the backtracking path.
        const count = @min(self.slots.len, found.slots.len);
        @memcpy(self.slots[0..count], found.slots[0..count]);
        return .{ .start = found.start, .end = found.end, .slots = self.slots };
    }

    /// Replay the DFA-winning path to fill capture slots. Returns null when
    /// the replay disagrees with the DFA bounds or exhausts the budget; the
    /// caller then falls back to a full interpreter search.
    fn extractCaptures(self: *Workspace, input: []const u8, start: usize, end: usize) ?Match {
        @memset(self.slots, unset);
        self.slots[0] = start;
        const replay_end = self.run(input, start) catch return null;
        if (replay_end != end) return null;
        self.slots[0] = start;
        self.slots[1] = end;
        return .{ .start = start, .end = end, .slots = self.slots };
    }

    /// True when a multi-byte literal required by every match is absent from
    /// the remaining input. One-byte literals are skipped because their scan
    /// cost can exceed the VM work on match-heavy inputs.
    fn requiredLiteralMiss(self: *Workspace, input: []const u8, search_start: usize) bool {
        const literals = self.program.required_literals orelse return false;
        var useful = false;
        for (literals) |literal| {
            if (literal.len >= 2) {
                useful = true;
                break;
            }
        }
        if (!useful or input.len - search_start < 256) return false;
        return !required_literals.containsAny(input, search_start, literals);
    }

    fn findInternal(
        self: *Workspace,
        input: []const u8,
        search_start: usize,
    ) Error!?Match {
        if (search_start > input.len) return null;
        if (self.program.literal) |literal| {
            if (self.program.capture_count == 0) {
                const found = indexOfLiteral(input, search_start, literal) orelse return null;
                self.slots[0] = found;
                self.slots[1] = found + literal.len;
                return .{ .start = found, .end = found + literal.len, .slots = self.slots };
            }
        }
        if (self.program.extended) {
            if (self.requiredLiteralMiss(input, search_start)) return null;
            if (self.backtrack_workspace == null) {
                self.backtrack_workspace = try backtrack.Workspace.init(self.allocator, self.program, self.limits);
            }
            const found = try self.backtrack_workspace.?.find(input, search_start) orelse return null;
            return .{
                .start = found.start,
                .end = found.end,
                .slots = found.slots,
                .mark = if (found.mark) |index| self.program.markName(index) else null,
            };
        }
        // The priority search DFA finds leftmost-first bounds for linear
        // programs. For capture programs the DFA ignores zero-width `save`
        // instructions, so replay the winning path to fill the slots; a
        // disagreement falls back to the interpreter below.
        if (!self.limits.longest and !self.search_dfa_failed and !self.search_dfa_ineligible) {
            if (self.search_dfa_workspace == null) {
                self.search_dfa_workspace = search_dfa.Workspace.init(self.allocator, self.program) catch blk: {
                    self.search_dfa_failed = true;
                    break :blk null;
                };
                if (self.search_dfa_workspace == null and !self.search_dfa_failed) self.search_dfa_ineligible = true;
            }
            if (self.search_dfa_workspace) |*dfa| {
                const found = dfa.find(input, search_start) catch |err| switch (err) {
                    error.OutOfMemory, error.RegexLimitExceeded => blk: {
                        self.search_dfa_failed = true;
                        break :blk null;
                    },
                };
                if (found) |match| {
                    if (self.program.capture_count == 0) {
                        self.slots[0] = match.start;
                        self.slots[1] = match.end;
                        return .{ .start = match.start, .end = match.end, .slots = self.slots };
                    }
                    if (self.extractCaptures(input, match.start, match.end)) |capture_match| {
                        return capture_match;
                    }
                    // Extraction disagreed or exceeded the budget: fall back
                    // to the interpreter so captures stay exact.
                } else if (!self.search_dfa_failed) {
                    return null;
                }
            }
        }
        if (self.requiredLiteralMiss(input, search_start)) return null;
        var start = search_start;
        while (start <= input.len) {
            if (self.program.literal_prefix) |prefix| {
                if (prefix.len != 0) {
                    start = indexOfLiteral(input, start, prefix) orelse return null;
                }
            }
            if (self.program.skip_start) {
                // The pattern cannot match empty and no start rune here can
                // begin a match: skip bytes without entering the VM.
                if (start < input.len and !self.program.first.allowsByte(input[start])) {
                    start = self.first_filter.indexOf(input, start) orelse return null;
                }
                if (start == input.len) return null;
            }
            if (self.program.capture_count == 0) {
                self.slots[0] = start;
                self.slots[1] = unset;
            } else {
                @memset(self.slots, unset);
                self.slots[0] = start;
            }
            const result = if (self.program.capture_count == 0 and !self.limits.longest)
                self.runCaptureFree(input, start)
            else
                self.run(input, start);
            const end = result catch |err| {
                if (err == error.RegexLimitExceeded and self.pike_eligible and self.limits.linear_fallback and !self.limits.longest) {
                    return self.pikeFind(input, search_start);
                }
                return err;
            };
            if (end) |match_end| {
                return .{ .start = start, .end = match_end, .slots = self.slots };
            }
            if (start == input.len) break;
            start += runeLenAt(input, start);
        }
        return null;
    }

    /// Capture-free fast path: no slot trail, no per-instruction capture
    /// checks, and a small fixed choice stack. Falls back to `run` if the
    /// stack overflows.
    fn runCaptureFree(self: *Workspace, input: []const u8, start: usize) Error!?usize {
        // Slot 0 was set by the caller; the initial save is redundant.
        var pc = self.program.body;
        var pos = start;
        var choices: [128]Choice = undefined;
        var count: usize = 0;
        while (true) {
            self.steps += 1;
            if (self.steps > self.limits.max_execution_steps) return error.RegexLimitExceeded;
            switch (self.program.instructions[pc]) {
                .accept => {
                    self.slots[1] = pos;
                    return pos;
                },
                .byte => |next| if (pos < input.len) {
                    pos += 1;
                    pc = next;
                    continue;
                },
                .literal_byte => |literal| if (pos < input.len and input[pos] == literal.value) {
                    pos += 1;
                    pc = literal.next;
                    continue;
                },
                .literal_rune => |literal| if (runeAt(input, pos)) |rune| {
                    if (rune.value == literal.value) {
                        pos += rune.len;
                        pc = literal.next;
                        continue;
                    }
                },
                .consume => |*consume| if (consume.set.matchAdvance(input, pos)) |next| {
                    pos = next;
                    pc = consume.next;
                    continue;
                },
                .star => |*star| {
                    // Greedy scan with a single backtrack record: the VM
                    // retries the continuation one rune earlier on failure.
                    // The scan is capped by the remaining step budget so a
                    // long run cannot bypass the fail-closed limit.
                    const scan_start = pos;
                    const scan_budget = self.limits.max_execution_steps -| self.steps;
                    var consumed: usize = 0;
                    if (star.set.ascii_only) {
                        while (consumed < scan_budget and pos < input.len and input[pos] < 128 and star.set.matches(input[pos])) {
                            pos += 1;
                            consumed += 1;
                        }
                    } else {
                        while (consumed < scan_budget) {
                            const next = star.set.matchAdvance(input, pos) orelse break;
                            pos = next;
                            consumed += 1;
                        }
                    }
                    if (consumed == scan_budget and star.set.matchAdvance(input, pos) != null) return error.RegexLimitExceeded;
                    self.steps += consumed;
                    if (pos != scan_start and star.backtrack) {
                        if (count == choices.len) return self.run(input, start);
                        choices[count] = .{ .pc = pc, .pos = pos, .trail_len = 0, .limit = scan_start };
                        count += 1;
                    }
                    pc = star.next;
                    continue;
                },
                .dispatch => |*dispatch| {
                    const table = self.program.dispatches[dispatch.table];
                    const mask: u16 = if (pos >= input.len)
                        table.eof
                    else if (input[pos] < 128)
                        table.ascii[input[pos]]
                    else
                        table.nonascii;
                    if (mask != 0) {
                        const chosen: usize = @ctz(mask);
                        var index: usize = table.branches.len;
                        while (index > 0) {
                            index -= 1;
                            if (index == chosen) continue;
                            if (mask & (@as(u16, 1) << @intCast(index)) == 0) continue;
                            if (count == choices.len) return self.run(input, start);
                            choices[count] = .{ .pc = table.branches[index], .pos = pos, .trail_len = 0 };
                            count += 1;
                        }
                        pc = table.branches[chosen];
                        continue;
                    }
                },
                .save => |*save| {
                    // Capture-free matches end at the whole-program accept;
                    // fuse the final save to avoid one dispatch per match.
                    if (save.slot == 1 and save.next == self.program.accept and !self.limits.longest) {
                        self.slots[1] = pos;
                        return pos;
                    }
                    pc = save.next;
                    continue;
                },
                .split => |*split| {
                    if (split.skip and pos < input.len and !firstAllows(split.first, input[pos])) {
                        pc = split.right;
                        continue;
                    }
                    if (count == choices.len) return self.run(input, start);
                    choices[count] = .{ .pc = split.right, .pos = pos, .trail_len = 0 };
                    count += 1;
                    pc = split.left;
                    continue;
                },
                .assertion => |*assertion| if (position(input, pos).allows(assertion.kind)) {
                    pc = assertion.next;
                    continue;
                },
                .lookahead => |look| {
                    const next = runeAt(input, pos);
                    const matched = if (next) |rune| look.set.matches(rune.value) else false;
                    if (matched != look.negative) {
                        pc = look.next;
                        continue;
                    }
                },
                else => unreachable,
            }
            if (count == 0) return null;
            count -= 1;
            const choice = choices[count];
            if (choice.limit != unset) {
                // Retry the loop continuation one rune earlier.
                const prev = previousRuneStart(input, choice.pos);
                if (prev > choice.limit) {
                    if (count == choices.len) return self.run(input, start);
                    choices[count] = .{ .pc = choice.pc, .pos = prev, .trail_len = 0, .limit = choice.limit };
                    count += 1;
                }
                pc = self.program.instructions[choice.pc].star.next;
                pos = prev;
                continue;
            }
            pc = choice.pc;
            pos = choice.pos;
        }
    }

    fn run(self: *Workspace, input: []const u8, start: usize) Error!?usize {
        self.choices.clearRetainingCapacity();
        self.trail.clearRetainingCapacity();
        const capture_free = self.program.capture_count == 0;
        // Slot 0 was set by the caller; the initial save is redundant.
        var pc = self.program.body;
        var pos = start;
        var best_end: ?usize = null;
        while (true) {
            self.steps += 1;
            if (self.steps > self.limits.max_execution_steps) {
                return error.RegexLimitExceeded;
            }
            switch (self.program.instructions[pc]) {
                .accept => {
                    if (!self.limits.longest) return pos;
                    if (best_end == null or pos > best_end.?) {
                        best_end = pos;
                        @memcpy(self.best_slots, self.slots);
                    }
                },
                .byte => |next| {
                    if (pos < input.len) {
                        pos += 1;
                        pc = next;
                        continue;
                    }
                },
                .literal_byte => |literal| {
                    if (pos < input.len and input[pos] == literal.value) {
                        pos += 1;
                        pc = literal.next;
                        continue;
                    }
                },
                .literal_rune => |literal| {
                    if (runeAt(input, pos)) |rune| {
                        if (rune.value == literal.value) {
                            pos += rune.len;
                            pc = literal.next;
                            continue;
                        }
                    }
                },
                .consume => |*consume| {
                    if (consume.set.matchAdvance(input, pos)) |next| {
                        pos = next;
                        pc = consume.next;
                        continue;
                    }
                },
                .star => |*star| {
                    const scan_start = pos;
                    const scan_budget = self.limits.max_execution_steps -| self.steps;
                    var consumed: usize = 0;
                    if (star.set.ascii_only) {
                        while (consumed < scan_budget and pos < input.len and input[pos] < 128 and star.set.matches(input[pos])) {
                            pos += 1;
                            consumed += 1;
                        }
                    } else {
                        while (consumed < scan_budget) {
                            const next = star.set.matchAdvance(input, pos) orelse break;
                            pos = next;
                            consumed += 1;
                        }
                    }
                    if (consumed == scan_budget and star.set.matchAdvance(input, pos) != null) return error.RegexLimitExceeded;
                    self.steps += consumed;
                    if (pos != scan_start and star.backtrack) {
                        if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                            return error.RegexLimitExceeded;
                        }
                        try self.choices.append(self.allocator, .{
                            .pc = pc,
                            .pos = pos,
                            .trail_len = self.trail.items.len,
                            .limit = scan_start,
                        });
                    }
                    pc = star.next;
                    continue;
                },
                .reset_captures => |*reset| {
                    var slot = reset.first;
                    while (slot < reset.last) : (slot += 1) {
                        if (self.trail.items.len >= self.limits.max_capture_trail) return error.RegexLimitExceeded;
                        try self.trail.append(self.allocator, .{ .slot = slot, .old = self.slots[slot] });
                        self.slots[slot] = unset;
                    }
                    pc = reset.next;
                    continue;
                },
                .dispatch => |*dispatch| {
                    const table = self.program.dispatches[dispatch.table];
                    const mask: u16 = if (pos >= input.len)
                        table.eof
                    else if (input[pos] < 128)
                        table.ascii[input[pos]]
                    else
                        table.nonascii;
                    if (mask != 0) {
                        const chosen: usize = @ctz(mask);
                        var index: usize = table.branches.len;
                        while (index > 0) {
                            index -= 1;
                            if (index == chosen) continue;
                            if (mask & (@as(u16, 1) << @intCast(index)) == 0) continue;
                            if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                                return error.RegexLimitExceeded;
                            }
                            try self.choices.append(self.allocator, .{
                                .pc = table.branches[index],
                                .pos = pos,
                                .trail_len = self.trail.items.len,
                            });
                        }
                        pc = table.branches[chosen];
                        continue;
                    }
                },
                .save => |*save| {
                    // Capture-free programs only need the whole match. Slot 0
                    // is set by the caller and slot 1 is written on the accept
                    // path, so no trail entry is required.
                    if (capture_free) {
                        if (save.slot == 1) {
                            self.slots[1] = pos;
                            if (save.next == self.program.accept and !self.limits.longest) return pos;
                        }
                        pc = save.next;
                        continue;
                    }
                    if (self.trail.items.len >= self.limits.max_capture_trail) {
                        return error.RegexLimitExceeded;
                    }
                    try self.trail.append(self.allocator, .{
                        .slot = save.slot,
                        .old = self.slots[save.slot],
                    });
                    self.slots[save.slot] = pos;
                    pc = save.next;
                    continue;
                },
                .split => |*split| {
                    if (split.skip and pos < input.len and !firstAllows(split.first, input[pos])) {
                        pc = split.right;
                        continue;
                    }
                    if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                        return error.RegexLimitExceeded;
                    }
                    try self.choices.append(self.allocator, .{
                        .pc = split.right,
                        .pos = pos,
                        .trail_len = self.trail.items.len,
                    });
                    pc = split.left;
                    continue;
                },
                .assertion => |*assertion| {
                    if (position(input, pos).allows(assertion.kind)) {
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
                else => unreachable,
            }
            const choice = self.choices.pop() orelse {
                if (best_end) |end| {
                    @memcpy(self.slots, self.best_slots);
                    return end;
                }
                return null;
            };
            while (self.trail.items.len > choice.trail_len) {
                const entry = self.trail.pop().?;
                self.slots[entry.slot] = entry.old;
            }
            if (choice.limit != unset) {
                const prev = previousRuneStart(input, choice.pos);
                if (prev > choice.limit) {
                    if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                        return error.RegexLimitExceeded;
                    }
                    try self.choices.append(self.allocator, .{
                        .pc = choice.pc,
                        .pos = prev,
                        .trail_len = choice.trail_len,
                        .limit = choice.limit,
                    });
                }
                pc = self.program.instructions[choice.pc].star.next;
                pos = prev;
                continue;
            }
            pc = choice.pc;
            pos = choice.pos;
        }
    }
};

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
        if (byte == '$') _ = try parseSubstitutionGroup(substitution, &index, program, capture_count);
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

fn appendGroup(writer: anytype, input: []const u8, slots: []const usize, group: u16) Error!void {
    if (groupText(input, slots, group)) |text| try writer.appendSlice(text);
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

fn appendSubstitution(
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

const ListWriter = struct {
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fn append(self: *ListWriter, byte: u8) Error!void {
        try self.list.append(self.allocator, byte);
    }
    fn appendSlice(self: *ListWriter, bytes: []const u8) Error!void {
        try self.list.appendSlice(self.allocator, bytes);
    }
};

const LengthWriter = struct {
    length: *usize,
    fn append(self: *LengthWriter, _: u8) Error!void {
        self.length.* += 1;
    }
    fn appendSlice(self: *LengthWriter, bytes: []const u8) Error!void {
        self.length.* += bytes.len;
    }
};

const BufferWriter = struct {
    output: []u8,
    len: usize = 0,
    fn append(self: *BufferWriter, byte: u8) Error!void {
        if (self.len >= self.output.len) return error.RegexLimitExceeded;
        self.output[self.len] = byte;
        self.len += 1;
    }
    fn appendSlice(self: *BufferWriter, bytes: []const u8) Error!void {
        if (bytes.len > self.output.len - self.len) {
            return error.RegexLimitExceeded;
        }
        @memcpy(self.output[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

const Position = struct {
    start: bool,
    end: bool,
    final_newline: bool,
    previous: ?u21,
    next: ?u21,
    fn word(rune: ?u21) bool {
        const value = rune orelse return false;
        return value == '_' or
            (value >= 'a' and value <= 'z') or
            (value >= 'A' and value <= 'Z') or
            (value >= '0' and value <= '9');
    }
    fn allows(self: Position, assertion: model.Assertion) bool {
        const boundary = word(self.previous) != word(self.next);
        return switch (assertion) {
            .start_text, .start_match => self.start,
            .end_text => self.end,
            .end_text_or_newline => self.end or self.final_newline,
            .start_line => self.start or self.previous == '\n',
            .end_line => self.end or self.next == '\n',
            .word_boundary, .word_boundary_unicode => boundary,
            .no_word_boundary, .no_word_boundary_unicode => !boundary,
            // Grapheme boundary assertions are extended-only and evaluated by
            // the backtracking VM.
            .grapheme_boundary, .no_grapheme_boundary, .word_boundary_uax29, .no_word_boundary_uax29, .sentence_boundary, .no_sentence_boundary, .word_start, .no_word_start, .word_end, .no_word_end, .word_start_unicode, .no_word_start_unicode, .word_end_unicode, .no_word_end_unicode => false,
        };
    }
};

fn position(input: []const u8, offset: usize) Position {
    const final_newline = offset == input.len or
        (offset + 1 == input.len and input[offset] == '\n') or
        (offset + 2 == input.len and input[offset] == '\r' and input[offset + 1] == '\n');
    return .{
        .start = offset == 0,
        .end = offset == input.len,
        .final_newline = final_newline,
        .previous = if (offset == 0) null else input[offset - 1],
        .next = if (offset == input.len) null else input[offset],
    };
}

fn runeAt(input: []const u8, offset: usize) ?struct { value: u21, len: usize } {
    if (offset >= input.len) return null;
    const byte = input[offset];
    if (byte < 0x80) return .{ .value = byte, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(byte) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn runeLenAt(input: []const u8, offset: usize) usize {
    return if (runeAt(input, offset)) |rune| rune.len else 1;
}

/// Start of the rune immediately before `offset`, or `offset` when the byte
/// before is not a valid continuation sequence. Callers only pass offsets on
/// rune boundaries produced by the VM.
fn previousRuneStart(input: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    var start = offset - 1;
    var steps: usize = 0;
    while (start != 0 and steps < 3 and (input[start] & 0xC0) == 0x80) : (steps += 1) start -= 1;
    return start;
}

fn firstAllows(first: model.FirstSet, byte: u8) bool {
    return first.allowsByte(byte);
}

test {
    _ = @import("replace_tests.zig");
}
