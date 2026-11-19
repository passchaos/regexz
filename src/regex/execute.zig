//! Deduplicated epsilon closures bound work by input runes times program size.
//! Programs without assertions, lookahead, or `\C` also use a bounded lazy
//! DFA cache for repeated full-match evaluation.
const std = @import("std");
const byte_table = @import("byte_table.zig");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const budget_mod = @import("budget.zig");
const newline = @import("newline.zig");
const shapes = @import("shapes.zig");
const utf8_run_mod = @import("utf8_run.zig");
const rune_cache = @import("rune_cache.zig");
pub const Stats = struct { input_bytes: usize = 0, states_visited: usize = 0 };
pub const PartialResult = model.PartialResult;
const Position = struct {
    start: bool,
    end: bool,
    final_newline: bool,
    line_before: bool,
    line_after: bool,
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
            .start_line => self.start or self.line_before,
            .end_line => self.end or self.line_after,
            .word_boundary, .word_boundary_unicode => boundary,
            .no_word_boundary, .no_word_boundary_unicode => !boundary,
            // Grapheme boundary assertions are extended-only and evaluated by
            // the backtracking VM.
            .grapheme_boundary, .no_grapheme_boundary, .word_boundary_uax29, .no_word_boundary_uax29, .sentence_boundary, .no_sentence_boundary, .word_start, .no_word_start, .word_end, .no_word_end, .word_start_unicode, .no_word_start_unicode, .word_end_unicode, .no_word_end_unicode => false,
        };
    }
};
const dfa_dead: u32 = std.math.maxInt(u32);
/// ASCII table sentinels: both are >= `ascii_dead`, so the scan loop checks
/// them with one comparison.
const ascii_dead: u32 = std.math.maxInt(u32) - 1;
const ascii_unprepared: u32 = std.math.maxInt(u32);
const dfa_max_states: usize = 64;
/// Direct-mapped cache for non-ASCII (state, rune) transitions.
const UnicodeEntry = rune_cache.Entry;
/// Inputs at least this long use the DFA on the first call. Shorter inputs
/// use it after a few calls so one-shot matching does not pay construction.
const dfa_min_input: usize = 4096;
const dfa_warmup_calls: usize = 2;
const DfaState = struct {
    instructions: []const u32,
    accept: bool,
};
const Dfa = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    states: std.ArrayList(DfaState) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    /// Flat [state][byte] table: `ascii_unprepared` = unknown,
    /// `ascii_dead` = dead, otherwise the target's row offset
    /// (`state id * stride`), which keeps the scan loop's address on one add.
    /// ASCII-only programs use 256-entry rows whose high half is dead, so the
    /// scan needs no `byte < 0x80` branch; other programs use 128-entry rows
    /// and decode non-ASCII runes.
    ascii_table: std.ArrayList(u32) = .empty,
    unicode_cache: []UnicodeEntry,
    scratch: []u32,
    seen: []u32,
    epoch: u32 = 0,
    start_state: ?u32 = null,
    ascii_only: bool = false,
    row_shift: u5 = 7,
    /// Fits in the existing tail padding, preserving the workspace layout.
    unicode_collisions: u8 = 0,
    fn init(allocator: std.mem.Allocator, instruction_count: usize, ascii_only: bool, long_input: bool) std.mem.Allocator.Error!Dfa {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const buffers = try allocator.alloc(u32, instruction_count * 2);
        errdefer allocator.free(buffers);
        const scratch = buffers[0..instruction_count];
        const seen = buffers[instruction_count..];
        @memset(seen, 0);
        const unicode_cache: []UnicodeEntry = if (ascii_only) &.{} else try allocator.alloc(UnicodeEntry, if (long_input) rune_cache.maximum_size else rune_cache.initial_size);
        errdefer allocator.free(unicode_cache);
        @memset(unicode_cache, .{});
        return .{
            .allocator = allocator,
            .arena = arena,
            .unicode_cache = unicode_cache,
            .scratch = scratch,
            .seen = seen,
            .ascii_only = ascii_only,
            .row_shift = if (ascii_only) 8 else 7,
        };
    }
    fn deinit(self: *Dfa) void {
        self.states.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.ascii_table.deinit(self.allocator);
        self.allocator.free(self.unicode_cache);
        self.allocator.free(self.scratch.ptr[0 .. self.scratch.len + self.seen.len]);
        self.arena.deinit();
        self.* = undefined;
    }
};
/// Reusable matching scratch space. A workspace is bound to the program it
/// was initialized with (storage is sized from its instruction count) and must
/// not be shared between threads.
pub const Workspace = struct {
    allocator: std.mem.Allocator,
    /// Disjoint views into one allocation; storage starts at its base.
    storage: []u32,
    seen: []u32,
    epoch: u32 = 0,
    stats: Stats = .{},
    budget: ?budget_mod.Budget = null,
    partial: bool = false,
    dfa: ?Dfa = null,
    dfa_calls: usize = 0,
    dfa_failed: bool = false,
    /// A `set+` program over an ASCII-only set full-matches with a byte
    /// table, which beats the lazy DFA on both short and long inputs.
    simple_set: bool = false,
    simple_table: [256]bool = .{false} ** 256,
    /// `(?:setA+ setB)+` over disjoint ASCII sets: one pass over a pair of
    /// byte tables decides a full match.
    simple_loop: bool = false,
    loop_a: [256]bool = .{false} ** 256,
    loop_b: [256]bool = .{false} ** 256,
    /// Non-ASCII `set+` (`\p{Han}+`): one expanded UTF-8 automaton decides a
    /// full match with one table load per byte instead of the DFA.
    utf8_run: ?utf8_run_mod.Utf8Run = null,
    /// Non-ASCII `(?:set+ sep)+` (`(?:\p{Han}+\n)+`): runs of `set`
    /// separated by one literal byte.
    utf8_loop: ?Utf8Loop = null,

    const Utf8Loop = struct { run: utf8_run_mod.Utf8Run, separator: u8 };
    pub fn init(allocator: std.mem.Allocator, program: Program) std.mem.Allocator.Error!Workspace {
        const count = program.instructions.len;
        const buffers = try allocator.alloc(u32, count * 11);
        var workspace = Workspace{
            .allocator = allocator,
            .storage = buffers[0 .. count * 6],
            .seen = buffers[count * 6 ..],
        };
        errdefer workspace.deinit();
        @memset(workspace.seen, 0);
        if (shapes.setRun(program)) |set| {
            if (set.ascii_only) {
                workspace.simple_set = true;
                workspace.simple_table = byte_table.init(256, set);
            }
        }
        if (shapes.setLoop(program)) |loop| {
            workspace.simple_loop = true;
            workspace.loop_a = byte_table.init(256, loop.a);
            workspace.loop_b = byte_table.init(256, loop.b);
        }
        if (shapes.setRun(program)) |set| {
            if (!set.ascii_only) {
                workspace.utf8_run = try utf8_run_mod.Utf8Run.init(allocator, set);
            }
        }
        if (shapes.utf8Loop(program)) |loop| {
            workspace.utf8_loop = .{
                .run = try utf8_run_mod.Utf8Run.init(allocator, loop.run),
                .separator = loop.separator,
            };
        }
        return workspace;
    }
    pub fn deinit(self: *Workspace) void {
        if (self.utf8_run) |*run| run.deinit(self.allocator);
        if (self.utf8_loop) |*loop| loop.run.deinit(self.allocator);
        if (self.dfa) |*dfa| dfa.deinit();
        self.allocator.free(self.storage.ptr[0 .. self.storage.len + self.seen.len]);
        self.* = undefined;
    }
    fn push(self: *Workspace, seen: []u32, stack: []u32, count: *usize, index: usize) void {
        if (seen[index] == self.epoch) return;
        seen[index] = self.epoch;
        stack[count.*] = @intCast(index);
        count.* += 1;
    }
    fn add(self: *Workspace, program: *const Program, index: usize, input: []const u8, offset: usize, context: Position, list: []u32, count: *usize, stack: []u32, seen: []u32) budget_mod.Error!void {
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
                    // A positive lookahead at EOF could be satisfied by a
                    // future rune, so the subject is a partial match.
                    if (next == null and offset == input.len and !look.negative and look.set.ranges.len != 0) {
                        self.partial = true;
                    }
                    if (matched != look.negative) self.push(seen, stack, &pending, look.next);
                },
                else => unreachable,
            }
        }
    }
    fn position(input: []const u8, offset: usize, newline_mode: model.Newline) Position {
        return .{
            .start = offset == 0,
            .end = offset == input.len,
            .final_newline = newline.final(input, offset, input.len, newline_mode),
            .line_before = newline.before(input, offset, newline_mode),
            .line_after = newline.after(input, offset, newline_mode),
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
    fn dfaClosure(self: *Workspace, program: *const Program, index: usize, list: []u32, count: *usize) void {
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
    fn dfaGetState(self: *Workspace, program: *const Program, list: []u32) std.mem.Allocator.Error!u32 {
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
        var state: DfaState = .{ .instructions = owned, .accept = false };
        for (owned) |index| switch (program.instructions[index]) {
            .accept => {
                state.accept = true;
                break;
            },
            else => {},
        };
        const id: u32 = @intCast(dfa.states.items.len);
        try dfa.states.append(dfa.allocator, state);
        if (dfa.ascii_only) {
            // Non-ASCII bytes can never match, so pre-fill the high half as
            // dead and keep the scan loop branch-free for ASCII input.
            try dfa.ascii_table.appendNTimes(dfa.allocator, ascii_unprepared, 128);
            try dfa.ascii_table.appendNTimes(dfa.allocator, ascii_dead, 128);
        } else {
            try dfa.ascii_table.appendNTimes(dfa.allocator, ascii_unprepared, 128);
        }
        try dfa.index.put(dfa.allocator, std.mem.sliceAsBytes(owned), id);
        return id;
    }
    fn dfaStartState(self: *Workspace, program: *const Program) std.mem.Allocator.Error!u32 {
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
    fn dfaTransition(self: *Workspace, comptime shift: u5, program: *const Program, state_id: u32, rune: u21) std.mem.Allocator.Error!u32 {
        const dfa = &self.dfa.?;
        const stride: u32 = @as(u32, 1) << shift;
        if (rune < 128) {
            const cached = dfa.ascii_table.items[(@as(usize, state_id) << shift) + rune];
            if (cached != ascii_unprepared) return if (cached == ascii_dead) dfa_dead else cached >> shift;
        } else if (shift == 8) {
            // Non-ASCII bytes are pre-filled dead; nothing can match.
            return dfa_dead;
        } else {
            const key = (@as(u64, state_id) << 21) | rune;
            const entry = &dfa.unicode_cache[rune_cache.slot(key, dfa.unicode_cache.len)];
            if (entry.key == key) return if (entry.next == dfa_dead) dfa_dead else entry.next - 1;
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
        if (rune < 128) {
            // Store the target's row offset so the scan loop can index with
            // one add instead of a shift plus add on the critical path.
            dfa.ascii_table.items[(@as(usize, state_id) << shift) + rune] = if (next == dfa_dead) ascii_dead else next * stride;
        } else if (shift == 7) {
            rune_cache.put(dfa.allocator, &dfa.unicode_cache, &dfa.unicode_collisions, (@as(u64, state_id) << 21) | rune, if (next == dfa_dead) dfa_dead else next + 1);
        }
        return next;
    }
    fn executeDfa(self: *Workspace, program: *const Program, input: []const u8) std.mem.Allocator.Error!bool {
        const dfa = &self.dfa.?;
        // Table entries are row offsets, so the hot loop's next address is one
        // add away from the loaded value.
        const start = try self.dfaStartState(program);
        var offset: usize = 0;
        if (dfa.ascii_only) {
            var row: u32 = start << 8;
            // Rows cover all 256 byte values with the high half pre-filled
            // dead, so the scan needs no ASCII branch or rune decoding.
            while (offset < input.len) {
                const cached = dfa.ascii_table.items[@as(usize, row) + input[offset]];
                if (cached >= ascii_dead) {
                    if (cached == ascii_dead) return false;
                    const next = try self.dfaTransition(8, program, row >> 8, input[offset]);
                    if (next == dfa_dead) return false;
                    row = next << 8;
                    offset += 1;
                    continue;
                }
                row = cached;
                offset += 1;
            }
            return dfa.states.items[row >> 8].accept;
        }
        var row: u32 = start << 7;
        while (offset < input.len) {
            const byte = input[offset];
            if (byte < 0x80) {
                const cached = dfa.ascii_table.items[@as(usize, row) + byte];
                if (cached >= ascii_dead) {
                    if (cached == ascii_dead) return false;
                } else {
                    row = cached;
                    offset += 1;
                    continue;
                }
            }
            const rune = runeAt(input, offset) orelse return false;
            const next = try self.dfaTransition(7, program, row >> 7, rune.value);
            if (next == dfa_dead) return false;
            row = next << 7;
            offset += rune.len;
        }
        return dfa.states.items[row >> 7].accept;
    }
    fn tryDfa(self: *Workspace, program: *const Program, input: []const u8) ?bool {
        if (self.dfa == null) {
            var ascii_only = true;
            for (program.instructions) |instruction| switch (instruction) {
                .consume => |consume| if (!consume.set.ascii_only) {
                    ascii_only = false;
                },
                .star => |star| if (!star.set.ascii_only) {
                    ascii_only = false;
                },
                .literal_rune => |literal| if (literal.value >= 0x80) {
                    ascii_only = false;
                },
                .byte => ascii_only = false,
                else => {},
            };
            self.dfa = Dfa.init(self.allocator, program.instructions.len, ascii_only, input.len >= dfa_min_input) catch {
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
        return self.matchesBorrowed(&program, input);
    }
    /// Match with an immutable program reference, avoiding the value API's
    /// whole-Program copy when the compiler does not inline the call.
    pub fn matchesBorrowed(self: *Workspace, program: *const Program, input: []const u8) bool {
        if (!self.matchesUnchecked(program, input)) return false;
        return !(input.len == 0 and (program.notempty or program.notempty_atstart));
    }
    fn matchesUnchecked(self: *Workspace, program: *const Program, input: []const u8) bool {
        self.stats = .{ .input_bytes = input.len };
        if (program.literal) |literal| return std.mem.eql(u8, literal, input);
        if (self.simple_set) {
            if (input.len == 0) return false;
            const table = &self.simple_table;
            for (input) |byte| {
                if (!table[byte]) return false;
            }
            return true;
        }
        if (self.simple_loop) return self.matchesSetLoop(input);
        if (self.utf8_run) |*run| {
            if (input.len == 0) return false;
            return run.runEnd(input, 0) == input.len;
        }
        if (self.utf8_loop) |*loop| return self.matchesUtf8Loop(loop, input);
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
    fn matchesSetLoop(self: *Workspace, input: []const u8) bool {
        var offset: usize = 0;
        while (true) {
            if (offset >= input.len or !self.loop_a[input[offset]]) return false;
            while (offset < input.len and self.loop_a[input[offset]]) offset += 1;
            if (offset >= input.len or !self.loop_b[input[offset]]) return false;
            offset += 1;
            if (offset >= input.len) return true;
        }
    }

    fn matchesUtf8Loop(self: *Workspace, loop: *const Utf8Loop, input: []const u8) bool {
        _ = self;
        if (input.len == 0) return false;
        var offset: usize = 0;
        while (true) {
            const run_end = loop.run.runEnd(input, offset);
            if (run_end == offset) return false;
            if (run_end >= input.len or input[run_end] != loop.separator) return false;
            offset = run_end + 1;
            if (offset == input.len) return true;
        }
    }

    pub fn matchesWithBudget(self: *Workspace, program: Program, input: []const u8, budget: budget_mod.Budget) budget_mod.Error!bool {
        if (!try self.execute(&program, input, budget)) return false;
        return !(input.len == 0 and (program.notempty or program.notempty_atstart));
    }
    /// Force the Thompson NFA path, bypassing the lazy DFA. Useful for
    /// differential tests and for callers that want deterministic work.
    pub fn matchesNfa(self: *Workspace, program: Program, input: []const u8) bool {
        if (!(self.execute(&program, input, null) catch unreachable)) return false;
        return !(input.len == 0 and (program.notempty or program.notempty_atstart));
    }
    /// Full-match partiality: `full` when the input matches, `partial` when
    /// it is a proper prefix of some match, `none` otherwise.
    pub fn partialMatch(self: *Workspace, program: Program, input: []const u8) PartialResult {
        if (self.simple_set) {
            const table = &self.simple_table;
            for (input) |byte| if (!table[byte]) return .none;
            return if (input.len == 0) .partial else .full;
        }
        const full = self.execute(&program, input, null) catch unreachable;
        if (full) return .full;
        return if (self.partial) .partial else .none;
    }
    fn execute(self: *Workspace, program: *const Program, input: []const u8, budget: ?budget_mod.Budget) budget_mod.Error!bool {
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
        try self.add(program, program.start, input, 0, position(input, 0, program.newline), self.storage[0..n], &counts[0], stack, self.seen[0..n]);
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
                try self.add(program, continuation, input, destination, position(input, destination, program.newline), self.storage[bucket * n ..][0..n], &counts[bucket], stack, self.seen[bucket * n ..][0..n]);
            }
        }
        return false;
    }
};
