//! Single-pass multi-pattern DFA for `RegexSet`.
//!
//! Patterns that the search DFA can model (no assertions, lookaround,
//! backreferences, or `\C`) are merged into one subset construction. A state
//! is a bitset of live NFA instructions; `accept_mask` records which patterns
//! reach `accept` at that position. Scanning is unanchored: the start state is
//! re-seeded before every transition, so every start position is covered.
//!
//! This is a reachability engine, not a leftmost-first engine: the set API
//! only needs to know whether each pattern matches anywhere. Patterns that
//! cannot be modeled stay on the per-pattern workspaces in `RegexSet`.
const std = @import("std");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;

const Error = std.mem.Allocator.Error || error{ RegexLimitExceeded, InvalidUtf8 };
const InitError = std.mem.Allocator.Error || error{RegexLimitExceeded};

const max_states: usize = 256;
const max_patterns: usize = 64;

const State = struct {
    bits: []const u64,
    accept_mask: u64,
    /// 0 = unprepared, `dead_state` = no continuation, otherwise next id + 1.
    ascii: [128]u32 = [_]u32{0} ** 128,
};

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    programs: []const Program,
    /// Pattern indices modeled by this DFA, in DFA bit order.
    included: []u16,
    /// Global instruction id base for each included pattern.
    offsets: []u32,
    /// Global instruction id -> included pattern slot.
    owners: []u16,
    total: usize,
    words: usize,
    live: []u64,
    next_bits: []u64,
    work: std.ArrayList(u32) = .empty,
    seen: []u32,
    epoch: u32 = 0,
    states: std.ArrayList(State) = .empty,
    index: std.StringHashMapUnmanaged(u32) = .empty,
    unicode: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    arena: std.heap.ArenaAllocator,
    start_state: u32,

    /// Build a combined DFA over the eligible subset of `programs`. Returns
    /// null when no program is eligible.
    pub fn init(allocator: std.mem.Allocator, programs: []const Program) InitError!?Workspace {
        var included: std.ArrayList(u16) = .empty;
        defer included.deinit(allocator);
        for (programs, 0..) |program, index| {
            if (included.items.len == max_patterns) break;
            if (eligible(program)) try included.append(allocator, @intCast(index));
        }
        if (included.items.len == 0) return null;

        var total: usize = 0;
        for (included.items) |pattern_index| total += programs[pattern_index].instructions.len;
        // Keep the combined bitset small enough that closure/state building
        // stays cheap; larger sets fall back to per-pattern search.
        if (total > 16384) return null;

        const offsets = try allocator.alloc(u32, included.items.len);
        errdefer allocator.free(offsets);
        var offset: usize = 0;
        for (included.items, 0..) |pattern_index, slot| {
            offsets[slot] = @intCast(offset);
            offset += programs[pattern_index].instructions.len;
        }
        const owners = try allocator.alloc(u16, total);
        errdefer allocator.free(owners);
        for (included.items, 0..) |pattern_index, slot| {
            @memset(owners[offsets[slot]..][0..programs[pattern_index].instructions.len], @intCast(slot));
        }
        const words = (total + 63) / 64;
        const live = try allocator.alloc(u64, words);
        errdefer allocator.free(live);
        @memset(live, 0);
        const next_bits = try allocator.alloc(u64, words);
        errdefer allocator.free(next_bits);
        @memset(next_bits, 0);
        const seen = try allocator.alloc(u32, total);
        errdefer allocator.free(seen);
        @memset(seen, 0);
        var work: std.ArrayList(u32) = .empty;
        errdefer work.deinit(allocator);
        try work.ensureTotalCapacity(allocator, total);
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        var self = Workspace{
            .allocator = allocator,
            .programs = programs,
            .included = try allocator.dupe(u16, included.items),
            .offsets = offsets,
            .owners = owners,
            .total = total,
            .words = words,
            .live = live,
            .next_bits = next_bits,
            .work = work,
            .seen = seen,
            .arena = arena,
            .start_state = 0,
        };
        errdefer allocator.free(self.included);
        errdefer self.states.deinit(allocator);
        errdefer self.index.deinit(allocator);
        errdefer self.unicode.deinit(allocator);
        self.start_state = try self.startState();
        return self;
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.included);
        self.allocator.free(self.offsets);
        self.allocator.free(self.owners);
        self.allocator.free(self.live);
        self.allocator.free(self.next_bits);
        self.work.deinit(self.allocator);
        self.allocator.free(self.seen);
        self.states.deinit(self.allocator);
        self.index.deinit(self.allocator);
        self.unicode.deinit(self.allocator);
        self.arena.deinit();
        self.* = undefined;
    }

    /// Whether the DFA models pattern `index`.
    pub fn covers(self: *const Workspace, index: usize) bool {
        for (self.included) |included| if (included == index) return true;
        return false;
    }

    /// Scan `input` once and OR the matched pattern indices into `matched`.
    /// Entries for patterns outside `included` are left untouched.
    pub fn scan(self: *Workspace, input: []const u8, matched: []bool) Error!void {
        var state = self.start_state;
        var mask = self.states.items[state].accept_mask;
        var offset: usize = 0;
        while (offset < input.len) {
            const rune = runeAt(input, offset) orelse return error.InvalidUtf8;
            state = try self.transition(state, rune.value);
            mask |= self.states.items[state].accept_mask;
            offset += rune.len;
            if (mask == allMask(self.included.len)) break;
        }
        var slot: usize = 0;
        while (slot < self.included.len) : (slot += 1) {
            if (mask & (@as(u64, 1) << @intCast(slot)) != 0) matched[self.included[slot]] = true;
        }
    }

    fn allMask(count: usize) u64 {
        if (count >= 64) return ~@as(u64, 0);
        return (@as(u64, 1) << @intCast(count)) - 1;
    }

    fn eligible(program: Program) bool {
        if (program.extended) return false;
        if (program.instructions.len == 0 or program.instructions.len > 2048) return false;
        for (program.instructions) |item| switch (item) {
            .accept, .consume, .literal_byte, .literal_rune, .split, .star, .save, .reset_captures, .sub_accept, .ret => {},
            else => return false,
        };
        return true;
    }

    fn nextEpoch(self: *Workspace) void {
        self.epoch +%= 1;
        if (self.epoch == 0) {
            @memset(self.seen, 0);
            self.epoch = 1;
        }
    }

    fn push(self: *Workspace, id: u32) std.mem.Allocator.Error!void {
        if (self.seen[id] == self.epoch) return;
        self.seen[id] = self.epoch;
        self.live[id / 64] |= @as(u64, 1) << @intCast(id % 64);
        try self.work.append(self.allocator, id);
    }

    fn instruction(self: *Workspace, id: u32) *const model.Instruction {
        const slot = self.owners[id];
        const base = self.offsets[slot];
        const pattern = self.included[slot];
        return &self.programs[pattern].instructions[id - base];
    }

    /// Expand epsilon transitions in `self.live` until stable.
    fn closure(self: *Workspace) std.mem.Allocator.Error!void {
        self.nextEpoch();
        self.work.clearRetainingCapacity();
        var id: u32 = 0;
        while (id < self.total) : (id += 1) {
            if (self.live[id / 64] & (@as(u64, 1) << @intCast(id % 64)) == 0) continue;
            self.seen[id] = self.epoch;
            try self.work.append(self.allocator, id);
        }
        while (self.work.pop()) |current| {
            switch (self.instruction(current).*) {
                .split => |split| {
                    const base = self.offsets[self.owners[current]];
                    try self.push(base + @as(u32, @intCast(split.left)));
                    try self.push(base + @as(u32, @intCast(split.right)));
                },
                .save => |save| try self.push(self.offsets[self.owners[current]] + @as(u32, @intCast(save.next))),
                .reset_captures => |reset| try self.push(self.offsets[self.owners[current]] + @as(u32, @intCast(reset.next))),
                .star => |star| try self.push(self.offsets[self.owners[current]] + @as(u32, @intCast(star.next))),
                else => {},
            }
        }
    }

    fn acceptMask(self: *Workspace) u64 {
        var mask: u64 = 0;
        var id: u32 = 0;
        while (id < self.total) : (id += 1) {
            if (self.live[id / 64] & (@as(u64, 1) << @intCast(id % 64)) == 0) continue;
            if (self.instruction(id).* == .accept) mask |= @as(u64, 1) << @intCast(self.owners[id]);
        }
        return mask;
    }

    fn startState(self: *Workspace) InitError!u32 {
        @memset(self.live, 0);
        for (self.included, 0..) |pattern_index, slot| {
            const body = self.programs[pattern_index].body;
            self.live[(self.offsets[slot] + @as(u32, @intCast(body))) / 64] |=
                @as(u64, 1) << @intCast((self.offsets[slot] + @as(u32, @intCast(body))) % 64);
        }
        try self.closure();
        return self.buildState();
    }

    fn buildState(self: *Workspace) InitError!u32 {
        const mask = self.acceptMask();
        const key = std.mem.sliceAsBytes(self.live);
        if (self.index.get(key)) |id| return id;
        if (self.states.items.len >= max_states) return error.RegexLimitExceeded;
        const owned = try self.arena.allocator().dupe(u64, self.live);
        const id: u32 = @intCast(self.states.items.len);
        try self.states.append(self.allocator, .{ .bits = owned, .accept_mask = mask });
        try self.index.put(self.allocator, std.mem.sliceAsBytes(owned), id);
        return id;
    }

    fn transition(self: *Workspace, state_id: u32, rune: u21) Error!u32 {
        if (rune < 128) {
            const cached = self.states.items[state_id].ascii[rune];
            if (cached != 0) return cached - 1;
        } else {
            const key = (@as(u64, state_id) << 21) | rune;
            if (self.unicode.get(key)) |cached| return cached;
        }
        @memset(self.next_bits, 0);
        const bits = self.states.items[state_id].bits;
        var word: usize = 0;
        while (word < self.words) : (word += 1) {
            var chunk = bits[word];
            while (chunk != 0) {
                const bit: u6 = @intCast(@ctz(chunk));
                chunk &= chunk - 1;
                const id: u32 = @intCast(word * 64 + bit);
                const base = self.offsets[self.owners[id]];
                switch (self.instruction(id).*) {
                    .consume => |consume| if (consume.set.matches(rune)) {
                        const target = base + @as(u32, @intCast(consume.next));
                        self.next_bits[target / 64] |= @as(u64, 1) << @intCast(target % 64);
                    },
                    .literal_byte => |literal| if (rune == literal.value) {
                        const target = base + @as(u32, @intCast(literal.next));
                        self.next_bits[target / 64] |= @as(u64, 1) << @intCast(target % 64);
                    },
                    .literal_rune => |literal| if (rune == literal.value) {
                        const target = base + @as(u32, @intCast(literal.next));
                        self.next_bits[target / 64] |= @as(u64, 1) << @intCast(target % 64);
                    },
                    .star => |star| if (star.set.matches(rune)) {
                        self.next_bits[id / 64] |= @as(u64, 1) << @intCast(id % 64);
                    },
                    else => {},
                }
            }
        }
        // Unanchored search: seed the start state at every position.
        for (self.states.items[self.start_state].bits, 0..) |start_word, index| {
            self.next_bits[index] |= start_word;
        }
        @memcpy(self.live, self.next_bits);
        try self.closure();
        const next = try self.buildState();
        if (rune < 128) {
            self.states.items[state_id].ascii[rune] = next + 1;
        } else {
            try self.unicode.put(self.allocator, (@as(u64, state_id) << 21) | rune, next);
        }
        return next;
    }
};

fn runeAt(input: []const u8, offset: usize) ?struct { value: u21, len: usize } {
    if (offset >= input.len) return null;
    const byte = input[offset];
    if (byte < 0x80) return .{ .value = byte, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(byte) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}
