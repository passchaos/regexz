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

const Error = model.Error;

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
        return .{
            .allocator = allocator,
            .arena = arena,
            .programs = programs,
            .sources = sources,
            .workspaces = workspaces,
            .limits = limits,
            .dfa = try set_dfa.Workspace.init(allocator, programs),
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
        const dfa_ptr: ?*set_dfa.Workspace = if (self.dfa) |*value| value else null;
        var use_dfa = false;
        if (!self.dfa_failed) {
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
