//! Multi-pattern matching.
//!
//! `RegexSet` compiles a list of independent patterns and reports which of
//! them match anywhere in the input. Patterns without assertions or extended
//! features share one unanchored DFA scan; every pattern also keeps its own
//! workspace for `isMatch` and for fallback when the combined DFA cannot model
//! it (or hits its state cap).
const std = @import("std");
const model = @import("model.zig");
const parse_mod = @import("parse.zig");
const compile_mod = @import("compile.zig");
const replace = @import("replace.zig");
const set_dfa = @import("set_dfa.zig");
const nibble_filter = @import("nibble_filter.zig");

const Error = model.Error;
const Vec = @Vector(16, u8);

inline fn laneMask(mask: @Vector(16, bool)) u16 {
    return @bitCast(mask);
}

/// One vector pass over the input for every simple chain separator
/// (`set+ sep`). Each pattern's own chain search scans the input for its
/// separator, so a set of them otherwise scans the same bytes once per
/// pattern. The filter only qualifies when each pattern's match is decided
/// by a single separator byte preceded by an ASCII `set_a` run.
const ChainSetFilter = struct {
    const max_separators = 16;
    const Entry = struct {
        set_a: model.Set,
        min_a: u8,
    };

    /// Separator byte -> pattern index + 1; 0 marks a non-separator byte.
    pattern_of: [256]u8 = [_]u8{0} ** 256,
    /// Nibble-table candidate filter, used when the target has a byte-table
    /// shuffle instruction.
    bytes: nibble_filter.ByteFilter = undefined,
    /// Byte-splat fallback for targets without a byte-table shuffle.
    splats: [max_separators]Vec = undefined,
    entries: []const Entry,
    count: u8 = 0,

    fn init(arena: std.mem.Allocator, workspaces: []const replace.Workspace) Error!?ChainSetFilter {
        if (workspaces.len == 0 or workspaces.len > std.math.maxInt(u8)) return null;
        var filter = ChainSetFilter{ .entries = &.{} };
        var separator_bytes: [max_separators]u8 = undefined;
        for (workspaces, 0..) |*workspace, index| {
            if (workspace.fast_kind != .chain) return null;
            const chain = workspace.simple_chain orelse return null;
            if (chain.separator_set != null or chain.separator_len != 1) return null;
            if (chain.set_b != null or chain.tail_len != 0 or !chain.star_a) return null;
            if (!chain.set_a.ascii_only) return null;
            const separator = chain.separator[0];
            if (filter.pattern_of[separator] != 0 or filter.count == max_separators) return null;
            filter.pattern_of[separator] = @intCast(index + 1);
            filter.splats[filter.count] = @splat(separator);
            separator_bytes[filter.count] = separator;
            filter.count += 1;
        }
        if (nibble_filter.supported) filter.bytes = nibble_filter.ByteFilter.init(separator_bytes[0..filter.count]);
        const entries = try arena.alloc(Entry, workspaces.len);
        for (workspaces, 0..) |*workspace, index| {
            const chain = workspace.simple_chain.?;
            entries[index] = .{ .set_a = chain.set_a, .min_a = chain.min_a };
        }
        filter.entries = entries;
        return filter;
    }

    inline fn candidates(self: *const ChainSetFilter, chunk: Vec) @Vector(16, bool) {
        if (nibble_filter.supported) return self.bytes.candidates(chunk);
        var mask = chunk == self.splats[0];
        var index: usize = 1;
        while (index < self.count) : (index += 1) mask = mask | (chunk == self.splats[index]);
        return mask;
    }

    /// Mark every pattern with a separator occurrence whose preceding
    /// `set_a` run, floored at `start`, is at least `min_a` bytes long.
    fn scan(self: *const ChainSetFilter, input: []const u8, start: usize, matched: []bool) void {
        const limit = @min(matched.len, self.entries.len);
        if (limit == 0) return;
        var remaining = limit;
        var offset = start;
        // Independent candidate computations per iteration: the nibble
        // lookups are latency-bound, so parallel chunks fill the pipeline.
        while (offset + 64 <= input.len) : (offset += 64) {
            var bits: u64 = 0;
            inline for (0..4) |chunk_index| {
                const chunk: Vec = input[offset + chunk_index * 16 ..][0..16].*;
                bits |= @as(u64, laneMask(self.candidates(chunk))) << (chunk_index * 16);
            }
            remaining = self.drain(input, start, offset, bits, matched, limit, remaining);
            if (remaining == 0) return;
        }
        while (offset + 16 <= input.len) : (offset += 16) {
            const chunk: Vec = input[offset..][0..16].*;
            remaining = self.drain(input, start, offset, laneMask(self.candidates(chunk)), matched, limit, remaining);
            if (remaining == 0) return;
        }
        while (offset < input.len) : (offset += 1) {
            if (self.pattern_of[input[offset]] == 0) continue;
            if (self.tryMatch(input, start, offset, matched, limit)) {
                remaining -= 1;
                if (remaining == 0) return;
            }
        }
    }

    inline fn drain(
        self: *const ChainSetFilter,
        input: []const u8,
        floor: usize,
        base: usize,
        bits_in: anytype,
        matched: []bool,
        limit: usize,
        remaining_in: usize,
    ) usize {
        var remaining = remaining_in;
        var bits = bits_in;
        while (bits != 0) {
            const lane: usize = @ctz(bits);
            bits &= bits - 1;
            if (self.tryMatch(input, floor, base + lane, matched, limit)) {
                remaining -= 1;
                if (remaining == 0) return 0;
            }
        }
        return remaining;
    }

    fn tryMatch(self: *const ChainSetFilter, input: []const u8, floor: usize, at: usize, matched: []bool, limit: usize) bool {
        const slot = self.pattern_of[input[at]];
        if (slot == 0) return false;
        const index: usize = slot - 1;
        if (index >= limit or matched[index]) return false;
        const entry = &self.entries[index];
        var run_start = at;
        while (run_start > floor and entry.set_a.matches(input[run_start - 1])) run_start -= 1;
        if (at - run_start < entry.min_a) return false;
        matched[index] = true;
        return true;
    }
};

pub const RegexSet = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    programs: []compile_mod.Program,
    /// The original pattern strings, copied into the arena.
    sources: []const []const u8,
    workspaces: []replace.Workspace,
    limits: model.Limits,
    /// Single-pass DFA over the subset of patterns it can model.
    dfa: ?set_dfa.Workspace = null,
    dfa_failed: bool = false,
    /// Every pattern decides its search with a separator/delimiter scan, so
    /// the per-pattern workspaces are cheaper than one combined DFA pass and
    /// no DFA is built.
    prefer_individual: bool = false,
    /// All patterns are `set+ separator` chains, so one combined vector scan
    /// replaces one separator scan per pattern. Allocated from the arena to
    /// keep the set handle small.
    chain_filter: ?*ChainSetFilter = null,

    /// Compile `patterns` into a set. Every pattern shares one arena; the
    /// per-pattern workspaces are allocated from `allocator`.
    pub fn init(
        allocator: std.mem.Allocator,
        pattern_list: []const []const u8,
        limits: model.Limits,
    ) Error!RegexSet {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const programs = try allocator.alloc(compile_mod.Program, pattern_list.len);
        errdefer allocator.free(programs);
        const sources = try arena.allocator().alloc([]const u8, pattern_list.len);
        for (pattern_list, 0..) |pattern, index| {
            sources[index] = try arena.allocator().dupe(u8, pattern);
            const parsed = try parse_mod.parse(arena.allocator(), pattern, limits);
            programs[index] = try compile_mod.compile(arena.allocator(), parsed, limits);
        }
        const workspaces = try allocator.alloc(replace.Workspace, pattern_list.len);
        errdefer allocator.free(workspaces);
        var initialized: usize = 0;
        errdefer for (workspaces[0..initialized]) |*workspace| workspace.deinit();
        for (programs, 0..) |program, index| {
            workspaces[index] = try replace.Workspace.init(allocator, program, limits);
            initialized += 1;
        }
        var prefer_individual = pattern_list.len != 0;
        for (workspaces) |*workspace| {
            if (!workspace.usesSeparatorScan()) {
                prefer_individual = false;
                break;
            }
        }
        const chain_filter: ?*ChainSetFilter = if (prefer_individual) blk: {
            const filter = try ChainSetFilter.init(arena.allocator(), workspaces) orelse break :blk null;
            const stored = try arena.allocator().create(ChainSetFilter);
            stored.* = filter;
            break :blk stored;
        } else null;
        return .{
            .allocator = allocator,
            .arena = arena,
            .programs = programs,
            .sources = sources,
            .workspaces = workspaces,
            .limits = limits,
            .prefer_individual = prefer_individual,
            .chain_filter = chain_filter,
            .dfa = if (prefer_individual) null else try set_dfa.Workspace.init(allocator, programs),
        };
    }

    pub fn deinit(self: *RegexSet) void {
        if (self.dfa) |*dfa| dfa.deinit();
        for (self.workspaces) |*workspace| workspace.deinit();
        self.allocator.free(self.workspaces);
        self.allocator.free(self.programs);
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn count(self: RegexSet) usize {
        return self.programs.len;
    }

    /// The original pattern strings, in set order.
    pub fn patterns(self: RegexSet) []const []const u8 {
        return self.sources;
    }

    /// Set `matched[i]` for every pattern that matches anywhere in `input`.
    /// Only the first `matched.len` patterns are reported when the buffer is
    /// shorter than `count()`.
    pub fn matches(self: *RegexSet, input: []const u8, matched: []bool) Error!void {
        return self.matchesAt(input, 0, matched);
    }

    /// Set `matched[i]` for every pattern that matches at or after `start`.
    pub fn matchesAt(self: *RegexSet, input: []const u8, start: usize, matched: []bool) Error!void {
        const limit = @min(matched.len, self.programs.len);
        @memset(matched[0..limit], false);
        if (start > input.len) return;
        if (self.chain_filter) |filter| {
            filter.scan(input, start, matched[0..limit]);
            return;
        }
        const dfa_ptr: ?*set_dfa.Workspace = if (self.dfa) |*value| value else null;
        var use_dfa = false;
        if (!self.prefer_individual and !self.dfa_failed) {
            if (dfa_ptr) |dfa| {
                if (dfa.scanFrom(input, start, matched[0..limit])) |_| {
                    use_dfa = true;
                } else |err| {
                    // Invalid UTF-8 is input-specific; keep the DFA for later
                    // calls. A state-cache failure disables it permanently.
                    if (err != error.InvalidUtf8) self.dfa_failed = true;
                    @memset(matched[0..limit], false);
                }
            }
        }
        for (self.workspaces[0..limit], 0..) |*workspace, index| {
            if (use_dfa and dfa_ptr.?.covers(index)) continue;
            matched[index] = (try workspace.find(input, start)) != null;
        }
    }

    /// Whether pattern `index` matches anywhere in `input`.
    pub fn isMatch(self: *RegexSet, input: []const u8, index: usize) Error!bool {
        if (index >= self.workspaces.len) return false;
        return (try self.workspaces[index].find(input, 0)) != null;
    }

    /// Append the indices of matching patterns to `indices`, preserving
    /// pattern order.
    pub fn matchIndices(self: *RegexSet, input: []const u8, indices: *std.ArrayList(usize)) Error!void {
        var stack: [64]bool = undefined;
        const pattern_count = self.programs.len;
        const matched = if (pattern_count <= stack.len)
            stack[0..pattern_count]
        else
            try self.allocator.alloc(bool, pattern_count);
        defer if (pattern_count > stack.len) self.allocator.free(matched);
        try self.matches(input, matched);
        for (matched, 0..) |value, index| {
            if (value) try indices.append(self.allocator, index);
        }
    }
};
