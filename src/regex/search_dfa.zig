//! Lazy leftmost-first search DFA for linear programs.
//!
//! The DFA is a priority-annotated subset construction over the Thompson NFA.
//! Every alternation/quantifier choice gets a bit position; a path's priority
//! is the OR of the right-branch bits it takes. Lower priority values win,
//! which reproduces Thompson/Pike leftmost-first semantics without tracking
//! thread order. `lookahead_set` instructions stay pending in a DFA state and
//! are evaluated against the rune being consumed (or EOF).
//!
//! Lookahead-free programs are determinized over input *bytes*: each rune set
//! is compiled to a UTF-8 byte automaton, so a scan is one flat table lookup
//! per byte with no per-rune decoding or binary search. Programs with
//! single-rune lookaheads keep the rune-level construction, where a pending
//! lookahead gates the rune consumed by its continuation.
//!
//! Capture programs use the same DFA for bounds: `save`/`reset_captures` are
//! zero-width and do not affect match priority, so the caller replays the
//! winning path on the matched slice to fill slots.
//!
//! The search is anchored per candidate start; the first-byte/literal-prefix
//! prefilters skip impossible starts. On state-cache exhaustion the caller
//! falls back to the interpreter.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const prefilter = @import("prefilter.zig");
const utf8_set = @import("utf8_set.zig");

pub const Match = struct { start: usize, end: usize };
const Error = std.mem.Allocator.Error || error{RegexLimitExceeded};

const no_priority = std.math.maxInt(u64);
const dead_state = std.math.maxInt(u32);
/// Byte-mode table entries: 0 = not prepared, `dead_state_byte` = dead,
/// otherwise `next id + 1` with `accept_bit` set when the target state
/// accepts. The bit lets the scan loop skip the priority load for the common
/// mid-rune case.
const dead_state_byte: u16 = 0x7FFF;
const accept_bit: u16 = 0x8000;
const state_mask: u16 = 0x7FFF;
const rune_max_states: usize = 64;
/// Byte determinization expands every rune into its UTF-8 length, so more
/// states are needed for the same program.
const byte_max_states: usize = 250;

const Mode = enum { rune, byte };

/// Deterministic 16-byte entry: `priority` first so the cache key has no
/// padding, then a packed `(pc, automaton state)` key.
const Entry = extern struct { priority: u64, key: u64 };

inline fn entryKey(pc: usize, state: u16) u64 {
    return (@as(u64, @intCast(pc)) << 16) | state;
}
inline fn entryPc(entry: Entry) usize {
    return @intCast(entry.key >> 16);
}
inline fn entryState(entry: Entry) u16 {
    return @intCast(entry.key & 0xFFFF);
}

const Prepared = struct { next: u32, accept: u64 };

/// Direct-mapped cache for non-ASCII (state, rune) transitions.
const unicode_cache_size: usize = 4096;
const UnicodeEntry = extern struct {
    key: u64 = std.math.maxInt(u64),
    accept: u64 = no_priority,
    next: u32 = 0,
    pad: u32 = 0,
};

inline fn unicodeSlot(key: u64) usize {
    return @intCast((key *% 0x9E3779B97F4A7C15) >> 52);
}

const State = struct {
    entries: []const Entry,
    /// Minimum accept priority reachable without pending lookaheads.
    accept: u64 = no_priority,
    has_lookahead: bool = false,
    eof_accept: u64 = no_priority,
    eof_prepared: bool = false,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    program: Program,
    mode: Mode,
    bits: []u8,
    body_mask: []u64,
    body_left: []bool,
    loop_split: []bool,
    best_priority: []u64,
    best_epoch: []u32,
    /// First `best_priority` slot for each instruction; consuming instructions
    /// own one slot per UTF-8 automaton state.
    node_base: []u32,
    epoch: u32 = 0,
    work: std.ArrayList(Entry) = .empty,
    terminals: std.ArrayList(Entry) = .empty,
    next_entries: std.ArrayList(Entry) = .empty,
    states: std.ArrayList(State) = .empty,
    /// Flat [state][byte] tables: 0 = not prepared, `dead_state` = dead,
    /// otherwise next id + 1.
    ascii_table: std.ArrayList(u32) = .empty,
    accept_table: std.ArrayList(u64) = .empty,
    /// Byte-mode flat [state][256] transitions: 0 = not prepared,
    /// `dead_state_byte` = dead, otherwise `next id + 1` with `accept_bit`
    /// set when the target state accepts.
    byte_table: std.ArrayList(u16) = .empty,
    state_accept: std.ArrayList(u64) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    unicode_cache: []UnicodeEntry,
    automata: []?utf8_set.Automaton,
    arena: std.heap.ArenaAllocator,
    start_state: ?u32 = null,
    max_states: usize,
    first_filter: prefilter.FirstFilter,
    start_filter: ?prefilter.MultiFilter = null,

    /// Returns null when the program is not eligible for the search DFA.
    pub fn init(allocator: std.mem.Allocator, program: Program) std.mem.Allocator.Error!?Workspace {
        const mode = eligibility(program) orelse return null;
        const bits = (try assignBits(allocator, program)) orelse return null;
        errdefer allocator.free(bits);
        const count = program.instructions.len;
        const body_mask = try allocator.alloc(u64, count);
        errdefer allocator.free(body_mask);
        @memset(body_mask, 0);
        const body_left = try allocator.alloc(bool, count);
        errdefer allocator.free(body_left);
        @memset(body_left, false);
        const loop_split = try allocator.alloc(bool, count);
        errdefer allocator.free(loop_split);
        @memset(loop_split, false);
        try computeLoopMasks(allocator, program, bits, body_mask, body_left, loop_split);
        // Static choice-bit priorities are exact for alternations and simple
        // single-set loops, but a loop body with internal choices needs
        // iteration-aware priority tracking. Keep those programs on the
        // interpreter rather than risk a wrong leftmost-first end.
        for (body_mask) |mask| if (mask != 0) {
            allocator.free(bits);
            allocator.free(body_mask);
            allocator.free(body_left);
            allocator.free(loop_split);
            return null;
        };
        // An unbounded loop's exit must not run into a split/optional. The
        // static choice bits cannot represent the loop iteration order when a
        // later choice competes with an earlier loop exit.
        for (program.instructions, 0..) |instruction, index| {
            const exit = switch (instruction) {
                .star => |star| star.next,
                .split => |split| if (!split.alternation and loop_split[index])
                    (if (body_left[index]) split.right else split.left)
                else
                    continue,
                else => continue,
            };
            if (!try exitPathSafe(allocator, program, exit)) {
                allocator.free(bits);
                allocator.free(body_mask);
                allocator.free(body_left);
                allocator.free(loop_split);
                return null;
            }
        }
        // Lazy unbounded loops need an accept-only exit; otherwise a later
        // successful exit would be chosen over the first one.
        for (program.instructions, 0..) |instruction, index| {
            const split = switch (instruction) {
                .split => |value| value,
                else => continue,
            };
            if (split.alternation or !loop_split[index] or body_left[index]) continue;
            if (!try zeroWidthExitSafe(allocator, program, split.left)) {
                allocator.free(bits);
                allocator.free(body_mask);
                allocator.free(body_left);
                allocator.free(loop_split);
                return null;
            }
        }
        const automata = try allocator.alloc(?utf8_set.Automaton, count);
        errdefer allocator.free(automata);
        @memset(automata, null);
        var built: usize = 0;
        errdefer for (automata[0..built]) |*automaton| {
            if (automaton.*) |*value| value.deinit(allocator);
        };
        const node_base = try allocator.alloc(u32, count + 1);
        errdefer allocator.free(node_base);
        if (mode == .byte) {
            for (program.instructions, 0..) |instruction, index| {
                automata[index] = switch (instruction) {
                    .consume => |consume| try utf8_set.build(allocator, consume.set.ranges),
                    .star => |star| try utf8_set.build(allocator, star.set.ranges),
                    .literal_rune => |literal| blk: {
                        const range = [_]model.Range{.{ .first = literal.value, .last = literal.value }};
                        break :blk try utf8_set.build(allocator, &range);
                    },
                    else => null,
                };
                if (automata[index] != null) built = index + 1;
            }
        }
        var total: u64 = 0;
        for (program.instructions, 0..) |instruction, index| {
            node_base[index] = @intCast(total);
            total += switch (instruction) {
                .consume, .star, .literal_rune => if (automata[index]) |automaton| automaton.stateCount() else 1,
                else => 1,
            };
        }
        node_base[count] = @intCast(total);
        if (total > 1 << 20) {
            allocator.free(bits);
            allocator.free(body_mask);
            allocator.free(body_left);
            allocator.free(loop_split);
            for (automata) |*automaton| {
                if (automaton.*) |*value| value.deinit(allocator);
            }
            allocator.free(automata);
            allocator.free(node_base);
            return null;
        }
        const best_priority = try allocator.alloc(u64, @intCast(total));
        errdefer allocator.free(best_priority);
        @memset(best_priority, no_priority);
        const unicode_cache = try allocator.alloc(UnicodeEntry, if (mode == .rune) unicode_cache_size else 0);
        errdefer allocator.free(unicode_cache);
        @memset(unicode_cache, .{});
        const best_epoch = try allocator.alloc(u32, @intCast(total));
        errdefer allocator.free(best_epoch);
        @memset(best_epoch, 0);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        var work: std.ArrayList(Entry) = .empty;
        errdefer work.deinit(allocator);
        try work.ensureTotalCapacity(allocator, count * 2);
        var terminals: std.ArrayList(Entry) = .empty;
        errdefer terminals.deinit(allocator);
        try terminals.ensureTotalCapacity(allocator, count * 2);
        var next_entries: std.ArrayList(Entry) = .empty;
        errdefer next_entries.deinit(allocator);
        try next_entries.ensureTotalCapacity(allocator, count * 2);
        const start_filter = if (program.start_literals) |literals| prefilter.MultiFilter.init(literals) else null;
        return .{
            .allocator = allocator,
            .program = program,
            .mode = mode,
            .bits = bits,
            .body_mask = body_mask,
            .body_left = body_left,
            .loop_split = loop_split,
            .best_priority = best_priority,
            .best_epoch = best_epoch,
            .node_base = node_base,
            .work = work,
            .terminals = terminals,
            .next_entries = next_entries,
            .unicode_cache = unicode_cache,
            .automata = automata,
            .arena = arena,
            .max_states = if (mode == .byte) byte_max_states else rune_max_states,
            .first_filter = prefilter.FirstFilter.init(program.first),
            .start_filter = start_filter,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.bits);
        self.allocator.free(self.body_mask);
        self.allocator.free(self.body_left);
        self.allocator.free(self.loop_split);
        self.allocator.free(self.best_priority);
        self.allocator.free(self.best_epoch);
        self.allocator.free(self.node_base);
        self.work.deinit(self.allocator);
        self.terminals.deinit(self.allocator);
        self.next_entries.deinit(self.allocator);
        self.states.deinit(self.allocator);
        self.ascii_table.deinit(self.allocator);
        self.accept_table.deinit(self.allocator);
        self.byte_table.deinit(self.allocator);
        self.state_accept.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.allocator.free(self.unicode_cache);
        for (self.automata) |*automaton| {
            if (automaton.*) |*value| value.deinit(self.allocator);
        }
        self.allocator.free(self.automata);
        self.arena.deinit();
        self.* = undefined;
    }

    fn hasNonAsciiConsumer(program: Program) bool {
        for (program.instructions) |instruction| switch (instruction) {
            .consume => |consume| if (!consume.set.ascii_only) return true,
            .star => |star| if (!star.set.ascii_only) return true,
            .literal_rune => return true,
            else => {},
        };
        return false;
    }

    fn eligibility(program: Program) ?Mode {
        if (program.extended) return null;
        if (program.instructions.len == 0 or program.instructions.len > 2048) return null;
        var choices: usize = 0;
        var complex: usize = 0;
        var stars: usize = 0;
        var literals: usize = 0;
        var has_lookahead = false;
        for (program.instructions) |instruction| switch (instruction) {
            .accept, .consume, .literal_byte, .literal_rune, .split, .star, .save, .reset_captures, .lookahead, .sub_accept, .ret => {},
            else => return null,
        };
        for (program.instructions) |instruction| switch (instruction) {
            .split => {
                choices += 1;
                complex += 1;
            },
            .star => {
                choices += 1;
                stars += 1;
            },
            .literal_byte, .literal_rune => literals += 1,
            .lookahead => {
                complex += 1;
                has_lookahead = true;
            },
            else => {},
        };
        // A lone star/literal capture-free pattern is faster on the
        // interpreter's tight scan unless it needs per-rune Unicode set
        // membership, where the byte DFA avoids decode + binary search.
        if (complex == 0) {
            if (program.capture_count == 0) {
                if (has_lookahead or !hasNonAsciiConsumer(program)) return null;
            } else if (stars < 2 and !(stars >= 1 and literals >= 1)) {
                return null;
            }
        }
        if (choices > 64) return null;
        // Byte-level determinization only pays off for simple scans over
        // non-ASCII sets: it removes per-rune decoding but pays one accept
        // check per byte. Tokenizer-shaped programs (many alternation
        // branches) keep the rune construction, whose states accept per rune.
        if (has_lookahead or !hasNonAsciiConsumer(program) or choices > 8) return .rune;
        return .byte;
    }

    /// Assign a priority bit to every choice instruction. Pre-order, left
    /// first; ancestors receive more significant bits than descendants.
    fn assignBits(allocator: std.mem.Allocator, program: Program) std.mem.Allocator.Error!?[]u8 {
        const count = program.instructions.len;
        const bits = try allocator.alloc(u8, count);
        errdefer allocator.free(bits);
        @memset(bits, 0xFF);
        const seen = try allocator.alloc(bool, count);
        defer allocator.free(seen);
        @memset(seen, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(allocator);
        try stack.ensureTotalCapacity(allocator, count);
        var counter: usize = 0;
        try stack.append(allocator, @intCast(program.body));
        while (stack.pop()) |pc| {
            if (seen[pc]) continue;
            seen[pc] = true;
            switch (program.instructions[pc]) {
                .split => |split| {
                    if (counter >= 64) {
                        allocator.free(bits);
                        return null;
                    }
                    bits[pc] = @intCast(63 - counter);
                    counter += 1;
                    try stack.append(allocator, @intCast(split.right));
                    try stack.append(allocator, @intCast(split.left));
                },
                .star => |star| {
                    if (counter >= 64) {
                        allocator.free(bits);
                        return null;
                    }
                    bits[pc] = @intCast(63 - counter);
                    counter += 1;
                    try stack.append(allocator, @intCast(star.next));
                },
                .save => |save| try stack.append(allocator, @intCast(save.next)),
                .reset_captures => |reset| try stack.append(allocator, @intCast(reset.next)),
                .lookahead => |look| try stack.append(allocator, @intCast(look.next)),
                .consume => |consume| try stack.append(allocator, @intCast(consume.next)),
                .literal_byte => |literal| try stack.append(allocator, @intCast(literal.next)),
                .literal_rune => |literal| try stack.append(allocator, @intCast(literal.next)),
                .accept, .sub_accept, .ret => {},
                else => {
                    allocator.free(bits);
                    return null;
                },
            }
        }
        return bits;
    }

    fn successorSeen(program: Program, pc: usize, target: usize, seen: []bool, stack: *std.ArrayList(u32), allocator: std.mem.Allocator) std.mem.Allocator.Error!bool {
        if (seen[pc]) return false;
        seen[pc] = true;
        if (pc == target) return true;
        switch (program.instructions[pc]) {
            .split => |split| {
                try stack.append(allocator, @intCast(split.left));
                try stack.append(allocator, @intCast(split.right));
            },
            .star => |star| try stack.append(allocator, @intCast(star.next)),
            .consume => |consume| try stack.append(allocator, @intCast(consume.next)),
            .literal_byte => |literal| try stack.append(allocator, @intCast(literal.next)),
            .literal_rune => |literal| try stack.append(allocator, @intCast(literal.next)),
            .save => |save| try stack.append(allocator, @intCast(save.next)),
            .reset_captures => |reset| try stack.append(allocator, @intCast(reset.next)),
            .lookahead => |look| try stack.append(allocator, @intCast(look.next)),
            else => {},
        }
        return false;
    }

    fn reaches(allocator: std.mem.Allocator, program: Program, start: usize, target: usize) std.mem.Allocator.Error!bool {
        const count = program.instructions.len;
        const seen = try allocator.alloc(bool, count);
        defer allocator.free(seen);
        @memset(seen, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, @intCast(start));
        while (stack.pop()) |pc| {
            if (try successorSeen(program, pc, target, seen, &stack, allocator)) return true;
        }
        return false;
    }

    /// For every quantifier split, record which branch is the loop body and
    /// the set of priority bits assigned inside that body. Exiting the loop
    /// masks those bits so all exits tie and the greedy/lazy loop choice (the
    /// split's own bit) decides.
    /// Lazy loops prefer the first successful exit. A static priority bit
    /// cannot distinguish later exits, so a lazy unbounded loop is only safe
    /// on the DFA when its exit reaches accept without consuming or looping.
    fn zeroWidthExitSafe(allocator: std.mem.Allocator, program: Program, start: usize) std.mem.Allocator.Error!bool {
        const count = program.instructions.len;
        const seen = try allocator.alloc(bool, count);
        defer allocator.free(seen);
        @memset(seen, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, @intCast(start));
        while (stack.pop()) |pc| {
            if (seen[pc]) continue;
            seen[pc] = true;
            switch (program.instructions[pc]) {
                .split, .star, .dispatch, .consume, .literal_byte, .literal_rune, .grapheme, .byte => return false,
                .save => |save| try stack.append(allocator, @intCast(save.next)),
                .reset_captures => |reset| try stack.append(allocator, @intCast(reset.next)),
                .lookahead => |look| try stack.append(allocator, @intCast(look.next)),
                .accept, .sub_accept, .ret => {},
                else => return false,
            }
        }
        return true;
    }

    fn exitPathSafe(allocator: std.mem.Allocator, program: Program, start: usize) std.mem.Allocator.Error!bool {
        const count = program.instructions.len;
        const seen = try allocator.alloc(bool, count);
        defer allocator.free(seen);
        @memset(seen, false);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, @intCast(start));
        while (stack.pop()) |pc| {
            if (seen[pc]) continue;
            seen[pc] = true;
            switch (program.instructions[pc]) {
                .split, .dispatch => return false,
                .star => |star| try stack.append(allocator, @intCast(star.next)),
                .consume => |consume| try stack.append(allocator, @intCast(consume.next)),
                .literal_byte => |literal| try stack.append(allocator, @intCast(literal.next)),
                .literal_rune => |literal| try stack.append(allocator, @intCast(literal.next)),
                .save => |save| try stack.append(allocator, @intCast(save.next)),
                .reset_captures => |reset| try stack.append(allocator, @intCast(reset.next)),
                .lookahead => |look| try stack.append(allocator, @intCast(look.next)),
                .accept, .sub_accept, .ret => {},
                else => return false,
            }
        }
        return true;
    }

    fn computeLoopMasks(allocator: std.mem.Allocator, program: Program, bits: []const u8, body_mask: []u64, body_left: []bool, loop_split: []bool) std.mem.Allocator.Error!void {
        const count = program.instructions.len;
        const seen = try allocator.alloc(bool, count);
        defer allocator.free(seen);
        var stack: std.ArrayList(u32) = .empty;
        defer stack.deinit(allocator);
        for (program.instructions, 0..) |instruction, index| {
            const split = switch (instruction) {
                .split => |value| value,
                else => continue,
            };
            if (split.alternation) continue;
            const left_reaches = try reaches(allocator, program, split.left, index);
            const right_reaches = try reaches(allocator, program, split.right, index);
            if (left_reaches == right_reaches) continue;
            loop_split[index] = true;
            const left_is_body = left_reaches;
            const body = if (left_is_body) split.left else split.right;
            body_left[index] = left_is_body;
            @memset(seen, false);
            stack.clearRetainingCapacity();
            try stack.append(allocator, @intCast(body));
            var mask: u64 = 0;
            while (stack.pop()) |pc| {
                if (pc == index or seen[pc]) continue;
                seen[pc] = true;
                switch (program.instructions[pc]) {
                    .split => |value| {
                        const bit = bits[pc];
                        if (bit != 0xFF) mask |= @as(u64, 1) << @intCast(bit);
                        try stack.append(allocator, @intCast(value.left));
                        try stack.append(allocator, @intCast(value.right));
                    },
                    .star => |value| {
                        const bit = bits[pc];
                        if (bit != 0xFF) mask |= @as(u64, 1) << @intCast(bit);
                        try stack.append(allocator, @intCast(value.next));
                    },
                    .consume => |value| try stack.append(allocator, @intCast(value.next)),
                    .literal_byte => |value| try stack.append(allocator, @intCast(value.next)),
                    .literal_rune => |value| try stack.append(allocator, @intCast(value.next)),
                    .save => |value| try stack.append(allocator, @intCast(value.next)),
                    .reset_captures => |value| try stack.append(allocator, @intCast(value.next)),
                    .lookahead => |value| try stack.append(allocator, @intCast(value.next)),
                    else => {},
                }
            }
            body_mask[index] = mask;
        }
    }

    fn nextEpoch(self: *Workspace) void {
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.best_epoch, 0);
            self.epoch = 1;
        }
    }

    fn pushNode(self: *Workspace, pc: usize, state: u16, priority: u64) std.mem.Allocator.Error!void {
        const node = @as(usize, self.node_base[pc]) + state;
        if (self.best_epoch[node] != self.epoch) {
            self.best_epoch[node] = self.epoch;
            self.best_priority[node] = priority;
            try self.work.append(self.allocator, .{ .priority = priority, .key = entryKey(pc, state) });
        } else if (priority < self.best_priority[node]) {
            self.best_priority[node] = priority;
            try self.work.append(self.allocator, .{ .priority = priority, .key = entryKey(pc, state) });
        }
    }

    inline fn push(self: *Workspace, pc: usize, priority: u64) std.mem.Allocator.Error!void {
        return self.pushNode(pc, 0, priority);
    }

    /// Append a consuming node straight to the next state (mid-rune byte
    /// automaton states are not epsilon-expanded).
    fn pushTerminal(self: *Workspace, pc: usize, state: u16, priority: u64, list: *std.ArrayList(Entry)) std.mem.Allocator.Error!void {
        const node = @as(usize, self.node_base[pc]) + state;
        if (self.best_epoch[node] != self.epoch) {
            self.best_epoch[node] = self.epoch;
            self.best_priority[node] = priority;
            try list.append(self.allocator, .{ .priority = priority, .key = entryKey(pc, state) });
        } else if (priority < self.best_priority[node]) {
            self.best_priority[node] = priority;
            try list.append(self.allocator, .{ .priority = priority, .key = entryKey(pc, state) });
        }
    }

    /// Expand the worklist. When `follow_lookaheads` is true, lookaheads are
    /// evaluated against `rune` and their continuation is explored; otherwise
    /// they are emitted as pending terminals for the next DFA state.
    fn runClosure(
        self: *Workspace,
        follow_lookaheads: bool,
        rune: ?u21,
        terminals: *std.ArrayList(Entry),
        accept: *u64,
    ) std.mem.Allocator.Error!void {
        while (self.work.pop()) |entry| {
            const pc = entryPc(entry);
            switch (self.program.instructions[pc]) {
                .accept => {
                    accept.* = @min(accept.*, entry.priority);
                    // The accept must be a state entry so a state whose only
                    // continuation is accept is not treated as dead.
                    try terminals.append(self.allocator, entry);
                },
                .consume, .literal_byte, .literal_rune => try terminals.append(self.allocator, entry),
                .star => |star| {
                    try terminals.append(self.allocator, entry);
                    const bit = self.bits[pc];
                    const exit_priority = if (bit != 0xFF)
                        entry.priority | (@as(u64, 1) << @intCast(bit))
                    else
                        entry.priority;
                    try self.push(@intCast(star.next), exit_priority);
                },
                .split => |split| {
                    const bit = self.bits[pc];
                    var left_priority = entry.priority;
                    var right_priority = if (bit != 0xFF)
                        entry.priority | (@as(u64, 1) << @intCast(bit))
                    else
                        entry.priority;
                    if (!split.alternation) {
                        const mask = self.body_mask[pc];
                        if (mask != 0) {
                            if (self.body_left[pc]) {
                                right_priority &= ~mask;
                            } else {
                                left_priority &= ~mask;
                            }
                        }
                    }
                    try self.push(@intCast(split.left), left_priority);
                    try self.push(@intCast(split.right), right_priority);
                },
                .save => |save| try self.push(@intCast(save.next), entry.priority),
                .reset_captures => |reset| try self.push(@intCast(reset.next), entry.priority),
                .sub_accept, .ret => {},
                .lookahead => |look| {
                    if (follow_lookaheads) {
                        const matched = if (rune) |value| look.set.matches(value) else false;
                        if (matched != look.negative) try self.push(@intCast(look.next), entry.priority);
                    } else {
                        try terminals.append(self.allocator, entry);
                    }
                },
                else => unreachable,
            }
        }
    }

    fn entryLess(_: void, a: Entry, b: Entry) bool {
        return a.key < b.key or (a.key == b.key and a.priority < b.priority);
    }

    fn buildState(self: *Workspace, entries: []Entry) Error!u32 {
        std.mem.sort(Entry, entries, {}, entryLess);
        var count: usize = 0;
        var accept: u64 = no_priority;
        var has_lookahead = false;
        for (entries) |entry| {
            if (count != 0 and entries[count - 1].key == entry.key) continue;
            entries[count] = entry;
            count += 1;
            switch (self.program.instructions[entryPc(entry)]) {
                .accept => accept = @min(accept, entry.priority),
                .lookahead => has_lookahead = true,
                else => {},
            }
        }
        const sorted = entries[0..count];
        const key = std.mem.sliceAsBytes(sorted);
        if (self.index.get(key)) |id| return id;
        if (self.states.items.len >= self.max_states) return error.RegexLimitExceeded;
        const owned = try self.arena.allocator().dupe(Entry, sorted);
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, .{
            .entries = owned,
            .accept = accept,
            .has_lookahead = has_lookahead,
        });
        switch (self.mode) {
            .rune => {
                try self.ascii_table.appendNTimes(self.allocator, 0, 128);
                try self.accept_table.appendNTimes(self.allocator, no_priority, 128);
            },
            .byte => {
                try self.byte_table.appendNTimes(self.allocator, 0, 256);
                try self.state_accept.append(self.allocator, accept);
            },
        }
        try self.index.put(self.allocator, std.mem.sliceAsBytes(owned), id);
        return id;
    }

    fn startState(self: *Workspace) Error!u32 {
        if (self.start_state) |id| return id;
        self.nextEpoch();
        self.work.clearRetainingCapacity();
        try self.push(@intCast(self.program.body), 0);
        self.terminals.clearRetainingCapacity();
        var accept: u64 = no_priority;
        try self.runClosure(false, null, &self.terminals, &accept);
        const id = try self.buildState(self.terminals.items);
        self.start_state = id;
        return id;
    }

    inline fn prepare(self: *Workspace, state_id: u32, rune: u21) Error!Prepared {
        if (rune < 128) {
            const index = @as(usize, state_id) * 128 + rune;
            const cached = self.ascii_table.items[index];
            if (cached != 0) {
                return .{
                    .next = if (cached == dead_state) dead_state else cached - 1,
                    .accept = self.accept_table.items[index],
                };
            }
        } else {
            const key = (@as(u64, state_id) << 21) | rune;
            const entry = &self.unicode_cache[unicodeSlot(key)];
            if (entry.key == key) return .{ .next = entry.next, .accept = entry.accept };
        }
        return self.prepareSlow(state_id, rune);
    }

    fn prepareSlow(self: *Workspace, state_id: u32, rune: u21) Error!Prepared {
        self.nextEpoch();
        self.work.clearRetainingCapacity();
        for (self.states.items[state_id].entries) |entry| try self.pushNode(entryPc(entry), entryState(entry), entry.priority);
        self.terminals.clearRetainingCapacity();
        var accept: u64 = no_priority;
        try self.runClosure(true, rune, &self.terminals, &accept);
        // Keep only the winning priority for each terminal before the next
        // epoch overwrites `best_priority`.
        var terminal_count: usize = 0;
        for (self.terminals.items) |entry| {
            const pc = entryPc(entry);
            if (self.best_priority[@as(usize, self.node_base[pc]) + entryState(entry)] != entry.priority) continue;
            self.terminals.items[terminal_count] = entry;
            terminal_count += 1;
        }
        self.terminals.shrinkRetainingCapacity(terminal_count);

        self.nextEpoch();
        self.work.clearRetainingCapacity();
        for (self.terminals.items) |entry| {
            const pc = entryPc(entry);
            switch (self.program.instructions[pc]) {
                .consume => |consume| if (consume.set.matches(rune)) try self.push(@intCast(consume.next), entry.priority),
                .literal_byte => |literal| if (rune == literal.value) try self.push(@intCast(literal.next), entry.priority),
                .literal_rune => |literal| if (rune == literal.value) try self.push(@intCast(literal.next), entry.priority),
                .star => |star| if (star.set.matches(rune)) try self.push(pc, entry.priority),
                .accept, .lookahead => {},
                else => {},
            }
        }
        self.next_entries.clearRetainingCapacity();
        var ignored: u64 = no_priority;
        try self.runClosure(false, null, &self.next_entries, &ignored);
        const next = if (self.next_entries.items.len == 0) dead_state else try self.buildState(self.next_entries.items);
        const result = Prepared{ .next = next, .accept = accept };
        if (rune < 128) {
            const index = @as(usize, state_id) * 128 + rune;
            self.ascii_table.items[index] = if (next == dead_state) dead_state else next + 1;
            self.accept_table.items[index] = accept;
        } else {
            const key = (@as(u64, state_id) << 21) | rune;
            self.unicode_cache[unicodeSlot(key)] = .{
                .key = key,
                .accept = result.accept,
                .next = result.next,
                .pad = 0,
            };
        }
        return result;
    }

    /// Byte-mode transition: advance every consuming thread through its UTF-8
    /// automaton. Completed runes re-enter the epsilon closure; partial runes
    /// carry their automaton state into the next DFA state.
    fn prepareByte(self: *Workspace, state_id: u32, byte: u8) Error!u16 {
        self.nextEpoch();
        self.work.clearRetainingCapacity();
        self.next_entries.clearRetainingCapacity();
        for (self.states.items[state_id].entries) |entry| {
            const pc = entryPc(entry);
            switch (self.program.instructions[pc]) {
                .consume => |consume| {
                    const advanced = self.automata[pc].?.advance(entryState(entry), byte);
                    if (advanced == utf8_set.dead) continue;
                    if (advanced == utf8_set.accept) {
                        try self.push(@intCast(consume.next), entry.priority);
                    } else {
                        try self.pushTerminal(pc, advanced, entry.priority, &self.next_entries);
                    }
                },
                .literal_rune => |literal| {
                    const advanced = self.automata[pc].?.advance(entryState(entry), byte);
                    if (advanced == utf8_set.dead) continue;
                    if (advanced == utf8_set.accept) {
                        try self.push(@intCast(literal.next), entry.priority);
                    } else {
                        try self.pushTerminal(pc, advanced, entry.priority, &self.next_entries);
                    }
                },
                .star => {
                    const advanced = self.automata[pc].?.advance(entryState(entry), byte);
                    if (advanced == utf8_set.dead) continue;
                    if (advanced == utf8_set.accept) {
                        try self.push(pc, entry.priority);
                    } else {
                        try self.pushTerminal(pc, advanced, entry.priority, &self.next_entries);
                    }
                },
                .literal_byte => |literal| {
                    if (byte == literal.value) try self.push(@intCast(literal.next), entry.priority);
                },
                .accept => {},
                else => unreachable,
            }
        }
        var ignored: u64 = no_priority;
        try self.runClosure(false, null, &self.next_entries, &ignored);
        const next = if (self.next_entries.items.len == 0) dead_state else try self.buildState(self.next_entries.items);
        const encoded = encodeByteEntry(self, next);
        self.byte_table.items[@as(usize, state_id) * 256 + byte] = encoded;
        return encoded;
    }

    fn encodeByteEntry(self: *Workspace, next: u32) u16 {
        if (next == dead_state) return dead_state_byte;
        const base: u16 = @intCast(next + 1);
        return if (self.state_accept.items[next] != no_priority) base | accept_bit else base;
    }

    fn prepareEof(self: *Workspace, state_id: u32) std.mem.Allocator.Error!u64 {
        if (self.mode == .byte) return self.state_accept.items[state_id];
        if (self.states.items[state_id].eof_prepared) return self.states.items[state_id].eof_accept;
        self.nextEpoch();
        self.work.clearRetainingCapacity();
        for (self.states.items[state_id].entries) |entry| try self.pushNode(entryPc(entry), entryState(entry), entry.priority);
        self.terminals.clearRetainingCapacity();
        var accept: u64 = no_priority;
        try self.runClosure(true, null, &self.terminals, &accept);
        const state = &self.states.items[state_id];
        state.eof_accept = accept;
        state.eof_prepared = true;
        return accept;
    }

    fn recordMatch(best_end: *?usize, best_priority: *u64, offset: usize, accept: u64) void {
        if (accept == no_priority) return;
        if (best_end.* == null or accept < best_priority.*) {
            best_end.* = offset;
            best_priority.* = accept;
        } else if (accept == best_priority.*) {
            best_end.* = offset;
        }
    }

    fn anchoredByte(self: *Workspace, input: []const u8, start: usize) Error!?usize {
        var state = try self.startState();
        var offset = start;
        var best_end: usize = std.math.maxInt(usize);
        var best_priority: u64 = no_priority;
        const initial = self.state_accept.items[state];
        if (initial != no_priority) {
            best_end = offset;
            best_priority = initial;
        }
        while (offset < input.len) {
            const index = @as(usize, state) * 256 + input[offset];
            var cached = self.byte_table.items[index];
            if (cached == 0) cached = try self.prepareByte(state, input[offset]);
            if (cached == dead_state_byte) break;
            offset += 1;
            const next = (cached & state_mask) - 1;
            if (cached & accept_bit != 0) {
                const accept = self.state_accept.items[next];
                if (accept < best_priority) {
                    best_end = offset;
                    best_priority = accept;
                } else if (accept == best_priority) {
                    best_end = offset;
                }
            }
            state = next;
        }
        return if (best_end == std.math.maxInt(usize)) null else best_end;
    }

    inline fn anchored(self: *Workspace, input: []const u8, start: usize) Error!?usize {
        if (self.mode == .byte) return self.anchoredByte(input, start);
        var state = try self.startState();
        var offset = start;
        var best_end: ?usize = null;
        var best_priority: u64 = no_priority;
        while (true) {
            if (offset >= input.len) {
                const accept = try self.prepareEof(state);
                recordMatch(&best_end, &best_priority, offset, accept);
                break;
            }
            const byte = input[offset];
            if (byte < 0x80) {
                const index = @as(usize, state) * 128 + byte;
                const cached = self.ascii_table.items[index];
                if (cached != 0) {
                    const accept = self.accept_table.items[index];
                    if (accept != no_priority) {
                        if (best_end == null or accept < best_priority) {
                            best_end = offset;
                            best_priority = accept;
                        } else if (accept == best_priority) best_end = offset;
                    }
                    state = if (cached == dead_state) dead_state else cached - 1;
                    if (state == dead_state) break;
                    offset += 1;
                    continue;
                }
            }
            const rune = runeAt(input, offset) orelse {
                // Invalid UTF-8 cannot continue a rune-based path; the
                // position may still accept an empty match.
                const accept = try self.prepareEof(state);
                recordMatch(&best_end, &best_priority, offset, accept);
                break;
            };
            const prepared = try self.prepare(state, rune.value);
            recordMatch(&best_end, &best_priority, offset, prepared.accept);
            if (prepared.next == dead_state) break;
            state = prepared.next;
            offset += rune.len;
        }
        return best_end;
    }

    pub fn find(self: *Workspace, input: []const u8, search_start: usize) Error!?Match {
        if (search_start > input.len) return null;
        var start = search_start;
        while (start <= input.len) {
            if (self.program.literal_prefix) |prefix| {
                if (prefix.len != 0) start = indexOfLiteral(input, start, prefix) orelse return null;
            } else if (self.start_filter) |*filter| {
                start = filter.indexOf(input, start) orelse return null;
            } else if (self.program.skip_start) {
                if (start < input.len and !self.program.first.allowsByte(input[start])) {
                    start = self.first_filter.indexOf(input, start) orelse return null;
                }
                if (start == input.len) return null;
            }
            if (try self.anchored(input, start)) |end| return .{ .start = start, .end = end };
            if (start == input.len) break;
            start += runeLenAt(input, start);
        }
        return null;
    }
};

fn runeAt(input: []const u8, offset: usize) ?struct { value: u21, len: usize } {
    if (offset >= input.len) return null;
    const byte = input[offset];
    if (byte < 0x80) return .{ .value = byte, .len = 1 };
    if (byte < 0xE0) {
        if (offset + 1 >= input.len) return null;
        const b1 = input[offset + 1];
        if (b1 & 0xC0 != 0x80 or byte < 0xC2) return null;
        return .{ .value = (@as(u21, byte & 0x1F) << 6) | (b1 & 0x3F), .len = 2 };
    }
    if (byte < 0xF0) {
        if (offset + 2 >= input.len) return null;
        const b1 = input[offset + 1];
        const b2 = input[offset + 2];
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80) return null;
        if (byte == 0xE0 and b1 < 0xA0) return null;
        if (byte == 0xED and b1 >= 0xA0) return null;
        return .{
            .value = (@as(u21, byte & 0x0F) << 12) | (@as(u21, b1 & 0x3F) << 6) | (b2 & 0x3F),
            .len = 3,
        };
    }
    if (byte < 0xF5) {
        if (offset + 3 >= input.len) return null;
        const b1 = input[offset + 1];
        const b2 = input[offset + 2];
        const b3 = input[offset + 3];
        if (b1 & 0xC0 != 0x80 or b2 & 0xC0 != 0x80 or b3 & 0xC0 != 0x80) return null;
        if (byte == 0xF0 and b1 < 0x90) return null;
        if (byte == 0xF4 and b1 >= 0x90) return null;
        return .{
            .value = (@as(u21, byte & 0x07) << 18) | (@as(u21, b1 & 0x3F) << 12) |
                (@as(u21, b2 & 0x3F) << 6) | (b3 & 0x3F),
            .len = 4,
        };
    }
    return null;
}

fn runeLenAt(input: []const u8, offset: usize) usize {
    return if (runeAt(input, offset)) |rune| rune.len else 1;
}

fn indexOfLiteral(input: []const u8, start: usize, needle: []const u8) ?usize {
    if (needle.len == 0) return if (start <= input.len) start else null;
    var offset = start;
    while (std.mem.indexOfScalarPos(u8, input, offset, needle[0])) |found| {
        if (needle.len <= input.len - found and std.mem.eql(u8, input[found..][0..needle.len], needle)) return found;
        offset = found + 1;
    }
    return null;
}
