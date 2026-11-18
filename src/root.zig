//! Bounded regex engine with a linear RE2-style core and an extended
//! PCRE-style backtracking mode.
//!
//! Linear programs (no general lookaround, backreferences, atomic groups,
//! possessive quantifiers, conditionals, `\G`, or UCP word boundaries) run on
//! the Thompson NFA/DFA/Pike paths. Extended programs are marked
//! `Program.extended` and run on the bounded backtracking VM.
const std = @import("std");
const model = @import("regex/model.zig");
const parse_mod = @import("regex/parse.zig");
const compile_mod = @import("regex/compile.zig");
const backtrack = @import("regex/backtrack.zig");
pub const Error = model.Error;
pub const Limits = model.Limits;
pub const Callout = model.Callout;
pub const CalloutAction = model.CalloutAction;
pub const CalloutSpec = model.CalloutSpec;
pub const Budget = @import("regex/budget.zig").Budget;
pub const BudgetError = @import("regex/budget.zig").Error;
pub const Workspace = @import("regex/execute.zig").Workspace;
pub const PartialResult = @import("regex/execute.zig").PartialResult;
pub const ReplaceWorkspace = @import("regex/replace.zig").Workspace;
pub const ReplaceFn = @import("regex/replace.zig").ReplaceFn;
pub const RegexSet = @import("regex/set.zig").RegexSet;
pub const Match = @import("regex/replace.zig").Match;
pub const StreamScanner = @import("regex/stream.zig").Scanner;
pub const StreamMatch = @import("regex/stream.zig").StreamMatch;
pub const StreamEmitFn = @import("regex/stream.zig").EmitFn;
pub const validateSubstitution = @import("regex/replace.zig").validateSubstitution;
pub const validateSubstitutionFor = @import("regex/replace.zig").validateSubstitutionFor;
pub const Program = @import("regex/compile.zig").Program;
const unset = std.math.maxInt(usize);

/// Caller-owned capture slot buffer for `Regex.find`.
pub const Captures = struct {
    slots: []usize,
    pub fn init(gpa: std.mem.Allocator, program: Program) std.mem.Allocator.Error!Captures {
        const slots = try gpa.alloc(usize, 2 * (@as(usize, program.capture_count) + 1));
        @memset(slots, unset);
        return .{ .slots = slots };
    }
    pub fn deinit(self: *Captures, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
        self.* = undefined;
    }
    pub fn count(self: Captures) usize {
        return self.slots.len / 2 - 1;
    }
    pub fn group(self: Captures, input: []const u8, index: usize) ?[]const u8 {
        if (index * 2 + 1 >= self.slots.len) return null;
        const begin = self.slots[index * 2];
        const end = self.slots[index * 2 + 1];
        if (begin == unset or end == unset or end < begin) return null;
        return input[begin..end];
    }
};

fn runeLenAt(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return 1;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return 1;
    if (len > input.len - offset) return 1;
    _ = std.unicode.utf8Decode(input[offset..][0..len]) catch return 1;
    return len;
}

/// Iterator over non-overlapping matches. Returned `Match.slots` points into
/// the iterator and is valid until the next `next` call.
pub const Matches = struct {
    input: []const u8,
    workspace: ReplaceWorkspace,
    offset: usize = 0,
    done: bool = false,
    pub fn next(self: *Matches) Error!?Match {
        if (self.done) return null;
        const found = try self.workspace.find(self.input, self.offset) orelse {
            self.done = true;
            return null;
        };
        if (found.end > found.start) {
            self.offset = found.end;
        } else if (found.start == self.input.len) {
            self.done = true;
        } else {
            self.offset = found.start + runeLenAt(self.input, found.start);
        }
        return found;
    }
    pub fn deinit(self: *Matches) void {
        self.workspace.deinit();
        self.* = undefined;
    }
};
/// Small programs are matched from a stack-backed workspace so the common
/// one-shot `Regex.matches` path performs no heap allocation.
const stack_workspace_bytes = 8192;
/// Parse and compile into caller-owned storage. There is no `Program.deinit`:
/// the returned program borrows its set ranges and literal bytes from `gpa`,
/// so `gpa` must be an arena (or otherwise outlive the program and be released
/// as a whole). `Regex.init` manages that arena automatically.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Program {
    const parsed = try parse_mod.parse(gpa, pattern, limits);
    return compile_mod.compile(gpa, parsed, limits);
}
pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
    program: Program,
    limits: Limits,
    /// Persistent linear workspace; owns the lazy DFA cache.
    workspace: ?Workspace = null,
    /// Persistent search/replace workspace, created on first use.
    replace_workspace: ?ReplaceWorkspace = null,
    mutex: std.atomic.Mutex = .unlocked,
    fn lock(self: *Regex) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *Regex) void {
        self.mutex.unlock();
    }
    pub fn init(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const parsed = try parse_mod.parse(arena.allocator(), pattern, limits);
        const program = try compile_mod.compile(arena.allocator(), parsed, limits);
        return .{ .arena = arena, .allocator = gpa, .program = program, .limits = limits };
    }
    pub fn deinit(self: *Regex) void {
        if (self.workspace) |*workspace| workspace.deinit();
        if (self.replace_workspace) |*workspace| workspace.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
    fn ensureWorkspace(self: *Regex) Error!*Workspace {
        if (self.workspace == null) self.workspace = try Workspace.init(self.allocator, self.program);
        return &self.workspace.?;
    }
    fn ensureReplaceWorkspace(self: *Regex) Error!*ReplaceWorkspace {
        if (self.replace_workspace == null) {
            self.replace_workspace = try ReplaceWorkspace.init(self.allocator, self.program, self.limits);
        }
        return &self.replace_workspace.?;
    }
    pub fn matches(self: *Regex, gpa: std.mem.Allocator, input: []const u8) Error!bool {
        if (self.program.literal) |literal| return std.mem.eql(u8, literal, input);
        if (self.program.extended) {
            var workspace = try backtrack.Workspace.init(gpa, self.program, self.limits);
            defer workspace.deinit();
            return workspace.fullMatch(input);
        }
        self.lock();
        defer self.unlock();
        const workspace = try self.ensureWorkspace();
        return workspace.matches(self.program, input);
    }
    /// Reuse a caller-owned workspace. This is the allocation-free hot path
    /// for repeated matching of linear programs.
    pub fn matchesWithWorkspace(self: *const Regex, workspace: *Workspace, input: []const u8) bool {
        return workspace.matches(self.program, input);
    }
    /// Full-match partiality: whether the input matches, is a proper prefix
    /// of some match, or cannot be extended to a match. Extended programs
    /// return `error.UnsupportedRegexFeature`.
    pub fn partialMatch(self: *Regex, gpa: std.mem.Allocator, input: []const u8) Error!PartialResult {
        if (self.program.extended) {
            _ = gpa;
            self.lock();
            defer self.unlock();
            const workspace = try self.ensureReplaceWorkspace();
            return workspace.partialMatch(input);
        }
        if (self.program.literal) |literal| {
            if (std.mem.eql(u8, literal, input)) return .full;
            return if (input.len < literal.len and std.mem.startsWith(u8, literal, input)) .partial else .none;
        }
        _ = gpa;
        self.lock();
        defer self.unlock();
        const workspace = try self.ensureWorkspace();
        return workspace.partialMatch(self.program, input);
    }
    pub fn groupIndex(self: *const Regex, name: []const u8) ?u16 {
        return self.program.groupIndex(name);
    }
    pub fn groupName(self: *const Regex, index: u16) ?[]const u8 {
        return self.program.groupName(index);
    }
    /// Leftmost-first search at or after `start`, copying captures into
    /// `captures`.
    pub fn findFrom(self: *Regex, gpa: std.mem.Allocator, input: []const u8, start: usize, captures: *Captures) Error!?Match {
        _ = gpa;
        self.lock();
        defer self.unlock();
        const workspace = try self.ensureReplaceWorkspace();
        const found = try workspace.find(input, start) orelse return null;
        std.debug.assert(found.slots.len == captures.slots.len);
        @memcpy(captures.slots, found.slots);
        return .{ .start = found.start, .end = found.end, .slots = captures.slots };
    }
    pub fn find(self: *Regex, gpa: std.mem.Allocator, input: []const u8, captures: *Captures) Error!?Match {
        return self.findFrom(gpa, input, 0, captures);
    }
    /// Partial match: true if the pattern matches anywhere in the input.
    pub fn isMatch(self: *Regex, gpa: std.mem.Allocator, input: []const u8) Error!bool {
        _ = gpa;
        self.lock();
        defer self.unlock();
        const workspace = try self.ensureReplaceWorkspace();
        return (try workspace.find(input, 0)) != null;
    }
    pub fn findAll(self: *const Regex, gpa: std.mem.Allocator, input: []const u8) Error!Matches {
        return .{
            .input = input,
            .workspace = try ReplaceWorkspace.init(gpa, self.program, self.limits),
        };
    }
    /// Split `input` around matches. The returned slice is allocated in `gpa`;
    /// its elements are slices of `input`.
    pub fn split(self: *const Regex, gpa: std.mem.Allocator, input: []const u8) Error![][]const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(gpa);
        var iterator = try self.findAll(gpa, input);
        defer iterator.deinit();
        var last: usize = 0;
        while (try iterator.next()) |match| {
            try parts.append(gpa, input[last..match.start]);
            last = match.end;
        }
        try parts.append(gpa, input[last..]);
        return parts.toOwnedSlice(gpa);
    }
    pub fn replaceAll(self: *const Regex, gpa: std.mem.Allocator, input: []const u8, substitution: []const u8) Error![]u8 {
        var workspace = try ReplaceWorkspace.init(gpa, self.program, self.limits);
        defer workspace.deinit();
        return workspace.replaceAll(input, substitution);
    }

    pub fn replaceAllWithFn(
        self: *const Regex,
        gpa: std.mem.Allocator,
        input: []const u8,
        context: ?*anyopaque,
        function: ReplaceFn,
    ) Error![]u8 {
        var workspace = try ReplaceWorkspace.init(gpa, self.program, self.limits);
        defer workspace.deinit();
        return workspace.replaceAllWithFn(input, context, function);
    }
};
test {
    _ = @import("regex/tests.zig");
    _ = @import("regex/budget_tests.zig");
    _ = @import("regex/engine_tests.zig");
    _ = @import("regex/extended_tests.zig");
    _ = @import("regex/api_tests.zig");
    _ = @import("regex/set_tests.zig");
    _ = @import("regex/required_literals_tests.zig");
    _ = @import("regex/emoji_tests.zig");
    _ = @import("regex/grapheme_assertion_tests.zig");
    _ = @import("regex/word_boundary_tests.zig");
    _ = @import("regex/sentence_boundary_tests.zig");
    _ = @import("regex/non_atomic_tests.zig");
    _ = @import("regex/char_names_tests.zig");
    _ = @import("regex/replace.zig");
    _ = @import("regex/stream_tests.zig");
    _ = @import("regex/serialize_tests.zig");
}
