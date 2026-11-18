//! Deduplicated epsilon closures bound work by input runes times program size.
//! Programs without assertions, lookahead, or `\C` also use a bounded lazy
//! DFA cache for repeated full-match evaluation.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const budget_mod = @import("budget.zig");
pub const Stats = struct { input_bytes: usize = 0, states_visited: usize = 0 };
pub const PartialResult = model.PartialResult;
const Position = struct {
    start: bool,
    end: bool,
    final_newline: bool,
    previous: ?u21,
    next: ?u21,
    fn word(rune: ?u21) bool {
        const value = rune orelse return false;
        return value == '_' or (value >= 'a' and value <= 'z') or (value >= 'A' and value <= 'Z') or (value >= '0' and value <= '9');
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
            .grapheme_boundary, .no_grapheme_boundary, .word_boundary_uax29, .no_word_boundary_uax29, .sentence_boundary, .no_sentence_boundary => false,
        };
    }
};
const dfa_dead: u32 = std.math.maxInt(u32);
const dfa_max_states: usize = 64;
/// Inputs at least this long use the DFA on the first call. Shorter inputs
/// use it after a few calls so one-shot matching does not pay construction.
const dfa_min_input: usize = 4096;
const dfa_warmup_calls: usize = 2;
const DfaState = struct {
    instructions: []const u32,
    /// 0 = unknown, `dfa_dead` = dead, otherwise state id + 1.
    ascii: [128]u32,
    accept: bool,
};
const Dfa = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    states: std.ArrayList(DfaState) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    unicode: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    scratch: []u32,
    seen: []u32,
    epoch: u32 = 0,
    start_state: ?u32 = null,
    fn init(allocator: std.mem.Allocator, instruction_count: usize) std.mem.Allocator.Error!Dfa {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const scratch = try allocator.alloc(u32, instruction_count);
        errdefer allocator.free(scratch);
        const seen = try allocator.alloc(u32, instruction_count);
        @memset(seen, 0);
        return .{ .allocator = allocator, .arena = arena, .scratch = scratch, .seen = seen };
    }
    fn deinit(self: *Dfa) void {
        self.states.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.unicode.deinit(self.allocator);
        self.allocator.free(self.scratch);
        self.allocator.free(self.seen);
        self.arena.deinit();
        self.* = undefined;
    }
};
/// Reusable matching scratch space. A workspace is bound to the program it
/// was initialized with (storage is sized from its instruction count) and must
/// not be shared between threads.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    storage: []u32,
    seen: []u32,
    epoch: u32 = 0,
    stats: Stats = .{},
    budget: ?budget_mod.Budget = null,
    partial: bool = false,
    dfa: ?Dfa = null,
    dfa_calls: usize = 0,
    dfa_failed: bool = false,
    pub fn init(allocator: std.mem.Allocator, program: Program) std.mem.Allocator.Error!Workspace {
        const storage = try allocator.alloc(u32, program.instructions.len * 6);
        errdefer allocator.free(storage);
        const seen = try allocator.alloc(u32, program.instructions.len * 5);
        @memset(seen, 0);
        return .{ .allocator = allocator, .storage = storage, .seen = seen };
    }
    pub fn deinit(self: *Workspace) void {
        if (self.dfa) |*dfa| dfa.deinit();
        self.allocator.free(self.storage);
        self.allocator.free(self.seen);
        self.* = undefined;
    }
    fn push(self: *Workspace, seen: []u32, stack: []u32, count: *usize, index: usize) void {
        if (seen[index] == self.epoch) return;
        seen[index] = self.epoch;
        stack[count.*] = @intCast(index);
        count.* += 1;
    }
    fn add(self: *Workspace, program: Program, index: usize, input: []const u8, offset: usize, context: Position, list: []u32, count: *usize, stack: []u32, seen: []u32) budget_mod.Error!void {
        var pending: usize = 0;
        self.push(seen, stack, &pending, index);
        while (pending != 0) {
            pending -= 1;
            const current = stack[pending];
            self.stats.states_visited += 1;
            if (self.stats.states_visited & 4095 == 0) if (self.budget) |budget| try budget.check();
            switch (program.instructions[current]) {
                .accept, .consume, .byte, .literal_byte, .literal_rune => {
                    list[count.*] = current;
                    count.* += 1;
                },
                .star => |*star| {
                    // Zero occurrences are always available; the star itself
                    // remains a live consuming thread.
                    self.push(seen, stack, &pending, star.next);
                    list[count.*] = current;
                    count.* += 1;
                },
                .reset_captures => |*reset| self.push(seen, stack, &pending, reset.next),
                .dispatch => |*dispatch| {
                    for (program.dispatches[dispatch.table].branches) |branch| self.push(seen, stack, &pending, branch);
                },
                .split => |*split| {
                    self.push(seen, stack, &pending, split.right);
                    self.push(seen, stack, &pending, split.left);
                },
                .save => |*save| self.push(seen, stack, &pending, save.next),
                .assertion => |*assertion| if (context.allows(assertion.kind)) self.push(seen, stack, &pending, assertion.next),
                .lookahead => |look| {
                    const next = if (offset < input.len) runeAt(input, offset) else null;
                    const matched = if (next) |value| look.set.matches(value.value) else false;
                    if (matched != look.negative) self.push(seen, stack, &pending, look.next);
                },
                else => unreachable,
            }
        }
    }
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
    fn dfaPush(self: *Workspace, index: usize, stack: []u32, count: *usize) void {
        const dfa = &self.dfa.?;
        if (dfa.seen[index] == dfa.epoch) return;
        dfa.seen[index] = dfa.epoch;
        stack[count.*] = @intCast(index);
        count.* += 1;
    }
    fn dfaClosure(self: *Workspace, program: Program, index: usize, list: []u32, count: *usize) void {
        const n = program.instructions.len;
        const stack = self.storage[n * 5 ..][0..n];
        var pending: usize = 0;
        self.dfaPush(index, stack, &pending);
        while (pending != 0) {
            pending -= 1;
            const current = stack[pending];
            switch (program.instructions[current]) {
                .accept, .consume, .literal_byte, .literal_rune => {
                    list[count.*] = current;
                    count.* += 1;
                },
                .star => |*star| {
                    self.dfaPush(star.next, stack, &pending);
                    list[count.*] = current;
                    count.* += 1;
                },
                .reset_captures => |*reset| self.dfaPush(reset.next, stack, &pending),
                .dispatch => |*dispatch| {
                    for (program.dispatches[dispatch.table].branches) |branch| self.dfaPush(branch, stack, &pending);
                },
                .split => |*split| {
                    self.dfaPush(split.right, stack, &pending);
                    self.dfaPush(split.left, stack, &pending);
                },
                .save => |*save| self.dfaPush(save.next, stack, &pending),
                else => unreachable,
            }
        }
    }
    fn dfaNextEpoch(self: *Workspace) void {
        const dfa = &self.dfa.?;
        dfa.epoch +%= 1;
        if (dfa.epoch == 0) {
            @memset(dfa.seen, 0);
            dfa.epoch = 1;
        }
    }
    fn dfaGetState(self: *Workspace, program: Program, list: []u32) std.mem.Allocator.Error!u32 {
        const dfa = &self.dfa.?;
        std.mem.sort(u32, list, {}, struct {
            fn less(_: void, a: u32, b: u32) bool {
                return a < b;
            }
        }.less);
        const scratch = dfa.scratch[0..list.len];
        for (list, 0..) |value, index| scratch[index] = value;
        const key = std.mem.sliceAsBytes(scratch);
        if (dfa.index.get(key)) |id| return id;
        if (dfa.states.items.len >= dfa_max_states) return error.OutOfMemory;
        const owned = try dfa.arena.allocator().dupe(u32, scratch);
        var state: DfaState = .{ .instructions = owned, .accept = false, .ascii = [_]u32{0} ** 128 };
        for (owned) |index| switch (program.instructions[index]) {
            .accept => {
                state.accept = true;
                break;
            },
            else => {},
        };
        const id: u32 = @intCast(dfa.states.items.len);
        try dfa.states.append(dfa.allocator, state);
        try dfa.index.put(dfa.allocator, std.mem.sliceAsBytes(owned), id);
        return id;
    }
    fn dfaStartState(self: *Workspace, program: Program) std.mem.Allocator.Error!u32 {
        const dfa = &self.dfa.?;
        if (dfa.start_state) |id| return id;
        self.dfaNextEpoch();
        var count: usize = 0;
        const list = self.storage[0..program.instructions.len];
        self.dfaClosure(program, program.start, list, &count);
        const id = try self.dfaGetState(program, list[0..count]);
        dfa.start_state = id;
        return id;
    }
    fn dfaTransition(self: *Workspace, program: Program, state_id: u32, rune: u21) std.mem.Allocator.Error!u32 {
        const dfa = &self.dfa.?;
        if (rune < 128) {
            const cached = dfa.states.items[state_id].ascii[@intCast(rune)];
            if (cached != 0) return if (cached == dfa_dead) dfa_dead else cached - 1;
        } else {
            const key = (@as(u64, state_id) << 21) | rune;
            if (dfa.unicode.get(key)) |cached| return if (cached == dfa_dead) dfa_dead else cached - 1;
        }
        const instructions = dfa.states.items[state_id].instructions;
        self.dfaNextEpoch();
        var count: usize = 0;
        const list = self.storage[0..program.instructions.len];
        for (instructions) |index| {
            switch (program.instructions[index]) {
                .consume => |*consume| if (consume.set.matches(rune)) self.dfaClosure(program, consume.next, list, &count),
                .star => |*star| if (star.set.matches(rune)) self.dfaClosure(program, index, list, &count),
                .literal_byte => |literal| if (rune == @as(u21, literal.value)) self.dfaClosure(program, literal.next, list, &count),
                .literal_rune => |literal| if (rune == literal.value) self.dfaClosure(program, literal.next, list, &count),
                .accept => {},
                else => unreachable,
            }
        }
        const next: u32 = if (count == 0) dfa_dead else try self.dfaGetState(program, list[0..count]);
        const cached: u32 = if (next == dfa_dead) dfa_dead else next + 1;
        if (rune < 128) {
            dfa.states.items[state_id].ascii[@intCast(rune)] = cached;
        } else {
            try dfa.unicode.put(dfa.allocator, (@as(u64, state_id) << 21) | rune, cached);
        }
        return next;
    }
    fn executeDfa(self: *Workspace, program: Program, input: []const u8) std.mem.Allocator.Error!bool {
        const dfa = &self.dfa.?;
        var state = try self.dfaStartState(program);
        var offset: usize = 0;
        while (offset < input.len) {
            const rune = runeAt(input, offset) orelse return false;
            state = try self.dfaTransition(program, state, rune.value);
            if (state == dfa_dead) return false;
            offset += rune.len;
        }
        return dfa.states.items[state].accept;
    }
    fn tryDfa(self: *Workspace, program: Program, input: []const u8) ?bool {
        if (self.dfa == null) {
            self.dfa = Dfa.init(self.allocator, program.instructions.len) catch {
                self.dfa_failed = true;
                return null;
            };
        }
        return self.executeDfa(program, input) catch {
            self.dfa_failed = true;
            return null;
        };
    }
    pub fn matches(self: *Workspace, program: Program, input: []const u8) bool {
        self.stats = .{ .input_bytes = input.len };
        if (program.literal) |literal| return std.mem.eql(u8, literal, input);
        if (program.dfa_eligible and !self.dfa_failed) {
            const use_dfa = input.len >= dfa_min_input or self.dfa_calls >= dfa_warmup_calls;
            if (use_dfa) {
                if (self.tryDfa(program, input)) |result| return result;
            } else {
                self.dfa_calls += 1;
            }
        }
        return self.execute(program, input, null) catch unreachable;
    }
    pub fn matchesWithBudget(self: *Workspace, program: Program, input: []const u8, budget: budget_mod.Budget) budget_mod.Error!bool {
        return self.execute(program, input, budget);
    }
    /// Force the Thompson NFA path, bypassing the lazy DFA. Useful for
    /// differential tests and for callers that want deterministic work.
    pub fn matchesNfa(self: *Workspace, program: Program, input: []const u8) bool {
        return self.execute(program, input, null) catch unreachable;
    }
    /// Full-match partiality: `full` when the input matches, `partial` when
    /// it is a proper prefix of some match, `none` otherwise.
    pub fn partialMatch(self: *Workspace, program: Program, input: []const u8) PartialResult {
        const full = self.execute(program, input, null) catch unreachable;
        if (full) return .full;
        return if (self.partial) .partial else .none;
    }
    fn execute(self: *Workspace, program: Program, input: []const u8, budget: ?budget_mod.Budget) budget_mod.Error!bool {
        const n = program.instructions.len;
        std.debug.assert(self.storage.len >= n * 6 and self.seen.len >= n * 5);
        self.stats = .{ .input_bytes = input.len };
        self.budget = budget;
        self.partial = false;
        if (budget) |active| try active.check();
        if (program.literal) |literal| {
            if (std.mem.eql(u8, literal, input)) return true;
            self.partial = input.len < literal.len and std.mem.startsWith(u8, literal, input);
            return false;
        }
        @memset(self.seen, 0);
        var counts = [_]usize{0} ** 5;
        const stack = self.storage[n * 5 ..][0..n];
        self.epoch = 1;
        try self.add(program, program.start, input, 0, position(input, 0), self.storage[0..n], &counts[0], stack, self.seen[0..n]);
        // Rune transitions advance 1..4 bytes; \C advances exactly one.
        // Five rotating buckets retain only future positions without letting
        // a 4-byte transition overwrite the list being consumed.
        for (0..input.len + 1) |offset| {
            if (offset & 4095 == 0) if (budget) |active| try active.check();
            const slot = offset % 5;
            const count = counts[slot];
            counts[slot] = 0;
            if (count == 0) continue;
            const rune = if (offset < input.len) runeAt(input, offset) else null;
            for (self.storage[slot * n ..][0..count]) |index| {
                if (offset == input.len) switch (program.instructions[index]) {
                    .accept => return true,
                    .consume, .literal_byte, .literal_rune, .byte, .star => self.partial = true,
                    else => {},
                };
                const continuation, const advance = switch (program.instructions[index]) {
                    .accept => if (offset == input.len) return true else continue,
                    .byte => |next| if (offset < input.len) .{ next, @as(usize, 1) } else continue,
                    .literal_byte => |literal| if (offset < input.len and input[offset] == literal.value) .{ literal.next, @as(usize, 1) } else continue,
                    .literal_rune => |literal| if (rune) |value|
                        if (value.value == literal.value) .{ literal.next, value.len } else continue
                    else
                        continue,
                    .consume => |*consume| if (rune) |value|
                        if (consume.set.matches(value.value)) .{ consume.next, value.len } else continue
                    else
                        continue,
                    .star => |*star| if (rune) |value|
                        if (star.set.matches(value.value)) .{ index, value.len } else continue
                    else
                        continue,
                    else => unreachable,
                };
                const destination = offset + advance;
                const bucket = destination % 5;
                if (destination >= std.math.maxInt(u32)) {
                    @memset(self.seen, 0);
                    self.epoch = 1;
                } else {
                    self.epoch = @intCast(destination + 1);
                }
                try self.add(program, continuation, input, destination, position(input, destination), self.storage[bucket * n ..][0..n], &counts[bucket], stack, self.seen[bucket * n ..][0..n]);
            }
        }
        return false;
    }
};
