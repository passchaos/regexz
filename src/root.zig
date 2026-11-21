//! Bounded regex engine with a linear RE2-style core and an extended
//! PCRE-style backtracking mode.
//!
//! Linear programs (no general lookaround, backreferences, atomic groups,
//! possessive quantifiers, conditionals, `\G`, or UCP word boundaries) run on
//! the Thompson NFA/DFA/Pike paths. Extended programs are marked
//! `Program.extended` and run on the bounded backtracking VM.
const std = @import("std");
pub const model = @import("regex/model.zig");
const parse_mod = @import("regex/parse.zig");
const compile_mod = @import("regex/compile.zig");
const prefilter = @import("regex/prefilter.zig");
const backtrack = @import("regex/backtrack.zig");
pub const Error = model.Error;
pub const Diagnostic = model.Diagnostic;
pub const DiagnosticKind = model.DiagnosticKind;
pub const Limits = model.Limits;
pub const Callout = model.Callout;
pub const CalloutAction = model.CalloutAction;
pub const CalloutSpec = model.CalloutSpec;
pub const Budget = @import("regex/budget.zig").Budget;
pub const BudgetError = @import("regex/budget.zig").Error;
pub const Workspace = @import("regex/execute.zig").Workspace;
pub const PartialResult = @import("regex/execute.zig").PartialResult;
const replace_mod = @import("regex/replace.zig");
pub const ReplaceWorkspace = replace_mod.Workspace;
pub const ReplaceFn = @import("regex/replace.zig").ReplaceFn;
pub const RegexSet = @import("regex/set.zig").RegexSet;
pub const Match = @import("regex/replace.zig").Match;
pub const StreamScanner = @import("regex/stream.zig").Scanner;
pub const StreamMatch = @import("regex/stream.zig").StreamMatch;
pub const StreamEmitFn = @import("regex/stream.zig").EmitFn;
const shapes = @import("regex/shapes.zig");
const byte_table = @import("regex/byte_table.zig");
const substitution_mod = @import("regex/substitution.zig");
pub const validateSubstitution = substitution_mod.validateSubstitution;
pub const validateSubstitutionFor = substitution_mod.validateSubstitutionFor;
pub const Program = @import("regex/compile.zig").Program;
/// Compile an already parsed model into a bounded program. Adapters use this
/// to lower an external AST without re-parsing pattern text.
pub const compileParsed = @import("regex/compile.zig").compile;
pub const comptime_regex = @import("regex/comptime_regex.zig");
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

/// Split around maximal runs of an ASCII `set+`, scanning each input byte
/// once instead of running a search per part.
fn splitAsciiSet(gpa: std.mem.Allocator, input: []const u8, set: model.Set, limit: usize) Error![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(gpa);
    if (limit == 0) return parts.toOwnedSlice(gpa);
    // A quarter of the input covers the common dense-separator case, so the
    // hot appends skip their capacity check; the list still grows if needed.
    try parts.ensureTotalCapacity(gpa, @min(@min(input.len / 4 + 1, 8192), limit));
    const table = byte_table.init(256, set);
    var last: usize = 0;
    var offset: usize = 0;
    while (offset < input.len and parts.items.len + 1 < limit) {
        while (offset < input.len and !table[input[offset]]) offset += 1;
        if (offset == input.len) break;
        const start = offset;
        while (offset < input.len and table[input[offset]]) offset += 1;
        if (parts.items.len == parts.capacity) try parts.ensureUnusedCapacity(gpa, 1);
        parts.appendAssumeCapacity(input[last..start]);
        last = offset;
    }
    if (parts.items.len == parts.capacity) try parts.ensureUnusedCapacity(gpa, 1);
    parts.appendAssumeCapacity(input[last..]);
    return parts.toOwnedSlice(gpa);
}

/// Split around occurrences of a pure literal, scanning with the standard
/// byte/pair search instead of creating a search workspace per part.
fn splitLiteral(gpa: std.mem.Allocator, input: []const u8, literal: []const u8, limit: usize) Error![][]const u8 {
    if (literal.len == 1) return splitByte(gpa, input, literal[0], limit);
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(gpa);
    if (limit == 0) return parts.toOwnedSlice(gpa);
    try parts.ensureTotalCapacity(gpa, @min(@min(input.len / 4 + 1, 8192), limit));
    var last: usize = 0;
    var offset: usize = 0;
    while (parts.items.len + 1 < limit) {
        const found = findLiteral(input, offset, literal) orelse break;
        if (parts.items.len == parts.capacity) try parts.ensureUnusedCapacity(gpa, 1);
        parts.appendAssumeCapacity(input[last..found]);
        last = found + literal.len;
        offset = last;
    }
    if (parts.items.len == parts.capacity) try parts.ensureUnusedCapacity(gpa, 1);
    parts.appendAssumeCapacity(input[last..]);
    return parts.toOwnedSlice(gpa);
}

/// Single-byte delimiter split. The exact count sizes the parts array, then
/// one mask pass extracts every delimiter lane. Sparse delimiters (lines)
/// pay a cheap count pass but avoid one filter setup per part.
fn splitByte(gpa: std.mem.Allocator, input: []const u8, byte: u8, limit: usize) Error![][]const u8 {
    return splitByteDense(gpa, input, byte, limit);
}

fn splitByteDense(gpa: std.mem.Allocator, input: []const u8, byte: u8, limit: usize) Error![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(gpa);
    if (limit == 0) return parts.toOwnedSlice(gpa);
    const wanted: usize = if (limit == std.math.maxInt(usize)) blk: {
        break :blk prefilter.countByte(input, byte);
    } else blk: {
        var total: usize = 0;
        var offset: usize = 0;
        while (total + 1 < limit) {
            const found = prefilter.indexOfByte(input, offset, byte) orelse break;
            total += 1;
            offset = found + 1;
        }
        break :blk total;
    };
    try parts.ensureTotalCapacity(gpa, wanted + 1);
    const Vec = @Vector(16, u8);
    const needle: Vec = @splat(byte);
    var last: usize = 0;
    var offset: usize = 0;
    while (offset + 64 <= input.len and parts.items.len < wanted) {
        const a: Vec = input[offset..][0..16].*;
        const b: Vec = input[offset + 16 ..][0..16].*;
        const c: Vec = input[offset + 32 ..][0..16].*;
        const d: Vec = input[offset + 48 ..][0..16].*;
        var bits: u64 = @as(u64, @as(u16, @bitCast(a == needle))) |
            (@as(u64, @as(u16, @bitCast(b == needle))) << 16) |
            (@as(u64, @as(u16, @bitCast(c == needle))) << 32) |
            (@as(u64, @as(u16, @bitCast(d == needle))) << 48);
        while (bits != 0 and parts.items.len < wanted) {
            const found = offset + @ctz(bits);
            parts.appendAssumeCapacity(input[last..found]);
            last = found + 1;
            bits &= bits - 1;
        }
        offset += 64;
    }
    while (parts.items.len < wanted) {
        const found = prefilter.indexOfByte(input, offset, byte) orelse break;
        parts.appendAssumeCapacity(input[last..found]);
        last = found + 1;
        offset = last;
    }
    parts.appendAssumeCapacity(input[last..]);
    return parts.toOwnedSlice(gpa);
}

inline fn findLiteral(input: []const u8, from: usize, literal: []const u8) ?usize {
    if (literal.len == 1) return std.mem.indexOfScalarPos(u8, input, from, literal[0]);
    return std.mem.indexOfPos(u8, input, from, literal);
}

/// Iterator over non-overlapping matches. Returned `Match.slots` points into
/// the iterator and is valid until the next `next` call.
pub const Matches = struct {
    input: []const u8,
    /// Owned workspace for `Regex.findAll`; unused when `borrowed` is set.
    owned: ?*ReplaceWorkspace = null,
    /// Caller workspace for `Regex.findAllWith`.
    borrowed: ?*ReplaceWorkspace = null,
    /// Program id when the owned workspace came from the process pool.
    pool_id: u64 = 0,
    offset: usize = 0,
    done: bool = false,
    pub fn next(self: *Matches) Error!?Match {
        if (self.done) return null;
        const workspace = self.borrowed orelse self.owned.?;
        const found = try workspace.find(self.input, self.offset) orelse {
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
        if (self.borrowed == null) {
            if (self.owned) |workspace| {
                if (self.pool_id != 0) {
                    returnPooledWorkspace(self.pool_id, workspace);
                } else {
                    destroyWorkspace(workspace);
                }
            }
        }
        self.* = undefined;
    }
};
/// Parse and compile into caller-owned storage. There is no `Program.deinit`:
/// the returned program borrows its set ranges and literal bytes from `gpa`,
/// so `gpa` must be an arena (or otherwise outlive the program and be released
/// as a whole). `Regex.init` manages that arena automatically.
pub fn compile(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Program {
    const parsed = try parse_mod.parse(gpa, pattern, limits);
    return compile_mod.compile(gpa, parsed, limits);
}

/// A program together with the arena that owns all of its storage.
pub const OwnedProgram = struct {
    arena: std.heap.ArenaAllocator,
    program: Program,
    pub fn deinit(self: *OwnedProgram) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Compile into an internal arena. Use this when the program must outlive the
/// call site without a caller-managed arena; `deinit` releases everything.
pub fn compileOwned(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!OwnedProgram {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const program = try compile(arena.allocator(), pattern, limits);
    return .{ .arena = arena, .program = program };
}

/// Escape `literal` so that compiling the result matches the literal bytes.
/// The escaped set matches Rust `regex::escape`: `\ . + * ? ( ) | [ ] { } ^
/// $ # & - ~`.
pub fn escape(gpa: std.mem.Allocator, literal: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (literal) |byte| {
        switch (byte) {
            '\\', '.', '+', '*', '?', '(', ')', '|', '[', ']', '{', '}', '^', '$', '#', '&', '-', '~' => try out.append(gpa, '\\'),
            else => {},
        }
        try out.append(gpa, byte);
    }
    return out.toOwnedSlice(gpa);
}

/// Compile and, on failure, report where compilation stopped.
///
/// The offset is a byte index into the pattern (identical to the input unless
/// `\Q...\E` rewriting changed its length). Compile-stage failures (node or
/// instruction limits) report the end of the pattern. Returns `null` when the
/// pattern compiles or the failure is out of memory.
pub fn diagnose(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) ?Diagnostic {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diagnostic: Diagnostic = .{};
    const parsed = parse_mod.parseWithDiagnostic(arena.allocator(), pattern, limits, &diagnostic) catch |err| {
        return if (err == error.OutOfMemory) null else diagnostic;
    };
    _ = compile_mod.compile(arena.allocator(), parsed, limits) catch |err| {
        return switch (err) {
            error.OutOfMemory => null,
            error.RegexLimitExceeded => .{ .offset = pattern.len, .kind = .limit },
            error.UnsupportedRegexFeature => .{ .offset = 0, .kind = .unsupported },
            error.InvalidRegex => .{ .offset = 0, .kind = .syntax },
        };
    };
    return null;
}

var next_program_id: std.atomic.Value(u64) = .init(1);

fn nextProgramId() u64 {
    return next_program_id.fetchAdd(1, .monotonic);
}

/// Single process-wide pooled workspace for `Regex.findAll` when the caller
/// uses a process-lifetime allocator. The owning iterator returns its
/// workspace here so the next call starts with warmed search caches.
const PooledWorkspace = struct { program_id: u64, workspace: *ReplaceWorkspace };
var pooled_mutex: std.atomic.Mutex = .unlocked;
var pooled_workspace: ?PooledWorkspace = null;

fn poolLock() void {
    while (!pooled_mutex.tryLock()) std.Thread.yield() catch {};
}

fn poolUnlock() void {
    pooled_mutex.unlock();
}

fn poolable(gpa: std.mem.Allocator) bool {
    return gpa.vtable == std.heap.page_allocator.vtable or gpa.vtable == std.heap.smp_allocator.vtable;
}

fn sameAllocator(a: std.mem.Allocator, b: std.mem.Allocator) bool {
    // Pooling is limited to the stateless page/smp allocators, where the
    // vtable identifies the allocator; their `ptr` field is undefined.
    return a.vtable == b.vtable;
}

/// Take the pooled workspace when it belongs to `id`. A replacement result
/// is allocated with the workspace's allocator and freed by the caller, so
/// callers that return allocations pass their allocator as `required` and
/// never receive a workspace whose allocations belong to another one.
/// Release a workspace allocated with its own allocator. The struct is large
/// (the inline byte tables), so the pool stores pointers instead of copying
/// it through every take and return.
fn destroyWorkspace(workspace: *ReplaceWorkspace) void {
    const allocator = workspace.allocator;
    workspace.deinit();
    allocator.destroy(workspace);
}

fn takePooledWorkspace(id: u64, required: ?std.mem.Allocator) ?*ReplaceWorkspace {
    if (id == 0) return null;
    poolLock();
    const entry = pooled_workspace;
    var taken = false;
    var stale: ?*ReplaceWorkspace = null;
    if (entry) |value| {
        if (value.program_id == id) {
            if (required == null or sameAllocator(value.workspace.allocator, required.?)) {
                pooled_workspace = null;
                taken = true;
            }
        } else {
            // The workspace belongs to a program that is no longer using the
            // slot; drop it instead of leaving a dangling entry behind.
            pooled_workspace = null;
            stale = value.workspace;
        }
    }
    poolUnlock();
    if (taken) return entry.?.workspace;
    if (stale) |value| destroyWorkspace(value);
    return null;
}

fn returnPooledWorkspace(id: u64, workspace: *ReplaceWorkspace) void {
    if (id == 0) {
        destroyWorkspace(workspace);
        return;
    }
    poolLock();
    if (pooled_workspace == null) {
        pooled_workspace = .{ .program_id = id, .workspace = workspace };
        poolUnlock();
        return;
    }
    poolUnlock();
    destroyWorkspace(workspace);
}

fn clearPooledWorkspace(id: u64) void {
    if (id == 0) return;
    poolLock();
    const entry = pooled_workspace;
    if (entry != null and entry.?.program_id == id) pooled_workspace = null;
    poolUnlock();
    const value = entry orelse return;
    if (value.program_id != id) return;
    destroyWorkspace(value.workspace);
}

const CompileBlock = struct { allocator: std.mem.Allocator, bytes: []u8 };
const max_pooled_blocks: usize = 8;
const max_pooled_bytes: usize = 768 * 1024;
var block_mutex: std.atomic.Mutex = .unlocked;
var block_pool: [max_pooled_blocks]?CompileBlock = .{null} ** max_pooled_blocks;
var pooled_block_bytes: usize = 0;

fn blockLock() void {
    while (!block_mutex.tryLock()) std.Thread.yield() catch {};
}

fn blockUnlock() void {
    block_mutex.unlock();
}

fn blockPoolable(gpa: std.mem.Allocator) bool {
    return gpa.vtable == std.heap.page_allocator.vtable or gpa.vtable == std.heap.smp_allocator.vtable;
}

fn takeCompileBlock(gpa: std.mem.Allocator, size: usize) ?[]u8 {
    if (!blockPoolable(gpa)) return null;
    blockLock();
    for (&block_pool) |*entry| {
        if (entry.*) |value| {
            if (value.bytes.len == size and value.allocator.vtable == gpa.vtable) {
                entry.* = null;
                pooled_block_bytes -= value.bytes.len;
                blockUnlock();
                return value.bytes;
            }
        }
    }
    blockUnlock();
    return null;
}

fn returnCompileBlock(gpa: std.mem.Allocator, bytes: []u8) void {
    if (!blockPoolable(gpa)) {
        gpa.free(bytes);
        return;
    }
    blockLock();
    if (pooled_block_bytes + bytes.len <= max_pooled_bytes) {
        for (&block_pool) |*entry| {
            if (entry.* == null) {
                entry.* = .{ .allocator = gpa, .bytes = bytes };
                pooled_block_bytes += bytes.len;
                blockUnlock();
                return;
            }
        }
    }
    blockUnlock();
    gpa.free(bytes);
}

pub const Regex = struct {
    arena: std.heap.ArenaAllocator,
    /// Fast-path storage for small compilations; null when `arena` owns the
    /// program instead.
    block: ?[]u8 = null,
    allocator: std.mem.Allocator,
    program: Program,
    /// Process-unique identity for the workspace pool.
    program_id: u64 = 0,
    limits: Limits,
    /// Persistent linear workspace; owns the lazy DFA cache. Allocated on
    /// first use so the `Regex` value stays small and cheap to return.
    workspace: ?*Workspace = null,
    /// Persistent search/replace workspace, created on first use.
    replace_workspace: ?*ReplaceWorkspace = null,
    mutex: std.atomic.Mutex = .unlocked,
    fn lock(self: *Regex) void {
        while (!self.mutex.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *Regex) void {
        self.mutex.unlock();
    }
    const compile_block_size: usize = 16 * 1024;
    const medium_block_size: usize = 64 * 1024;
    const large_block_size: usize = 256 * 1024;

    pub fn init(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Regex {
        // Small patterns fit in one fixed block, avoiding the arena's multiple
        // page allocations. Long patterns and Unicode-class patterns need
        // larger blocks; very large patterns compile in an arena.
        if (pattern.len > 1024) return initArena(gpa, pattern, limits);
        if (std.mem.indexOf(u8, pattern, "\\p") != null or std.mem.indexOf(u8, pattern, "\\P") != null) {
            return compileWithBlock(gpa, pattern, limits, large_block_size);
        }
        if (pattern.len > 64) return compileWithBlock(gpa, pattern, limits, medium_block_size);
        return compileWithBlock(gpa, pattern, limits, compile_block_size);
    }

    fn compileWithBlock(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits, size: usize) Error!Regex {
        if (takeCompileBlock(gpa, size)) |block| return compileInBlock(gpa, block, pattern, limits);
        const block = gpa.alloc(u8, size) catch return initArena(gpa, pattern, limits);
        return compileInBlock(gpa, block, pattern, limits);
    }

    fn compileInBlock(gpa: std.mem.Allocator, block: []u8, pattern: []const u8, limits: Limits) Error!Regex {
        var fba = std.heap.FixedBufferAllocator.init(block);
        const parsed = parse_mod.parse(fba.allocator(), pattern, limits) catch |err| {
            returnCompileBlock(gpa, block);
            if (err == error.OutOfMemory) return initArena(gpa, pattern, limits);
            return err;
        };
        const program = compile_mod.compile(fba.allocator(), parsed, limits) catch |err| {
            returnCompileBlock(gpa, block);
            if (err == error.OutOfMemory) return initArena(gpa, pattern, limits);
            return err;
        };
        return .{
            .arena = std.heap.ArenaAllocator.init(gpa),
            .block = block,
            .allocator = gpa,
            .program = program,
            .program_id = nextProgramId(),
            .limits = limits,
        };
    }

    fn initArena(gpa: std.mem.Allocator, pattern: []const u8, limits: Limits) Error!Regex {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const parsed = try parse_mod.parse(arena.allocator(), pattern, limits);
        const program = try compile_mod.compile(arena.allocator(), parsed, limits);
        return .{ .arena = arena, .allocator = gpa, .program = program, .program_id = nextProgramId(), .limits = limits };
    }

    pub fn deinit(self: *Regex) void {
        clearPooledWorkspace(self.program_id);
        if (self.workspace) |workspace| {
            workspace.deinit();
            self.allocator.destroy(workspace);
        }
        if (self.replace_workspace) |workspace| {
            workspace.deinit();
            self.allocator.destroy(workspace);
        }
        if (self.block) |block| returnCompileBlock(self.allocator, block);
        self.arena.deinit();
        self.* = undefined;
    }
    fn ensureWorkspace(self: *Regex) Error!*Workspace {
        if (self.workspace == null) {
            const workspace = try self.allocator.create(Workspace);
            errdefer self.allocator.destroy(workspace);
            workspace.* = try Workspace.init(self.allocator, self.program);
            self.workspace = workspace;
        }
        return self.workspace.?;
    }
    fn ensureReplaceWorkspace(self: *Regex) Error!*ReplaceWorkspace {
        if (self.replace_workspace == null) {
            const workspace = try self.allocator.create(ReplaceWorkspace);
            errdefer self.allocator.destroy(workspace);
            workspace.* = try ReplaceWorkspace.init(self.allocator, self.program, self.limits);
            self.replace_workspace = workspace;
        }
        return self.replace_workspace.?;
    }
    pub fn matches(self: *Regex, gpa: std.mem.Allocator, input: []const u8) Error!bool {
        if (self.program.literal) |literal| {
            if (!std.mem.eql(u8, literal, input)) return false;
            return !(input.len == 0 and (self.program.notempty or self.program.notempty_atstart));
        }
        _ = gpa;
        self.lock();
        defer self.unlock();
        if (self.program.extended) {
            const workspace = try self.ensureReplaceWorkspace();
            return workspace.fullMatch(input);
        }
        const workspace = try self.ensureWorkspace();
        return workspace.matchesBorrowed(&self.program, input);
    }
    /// Reuse a caller-owned workspace without taking the internal lock.
    /// The workspace may prepare optional execution caches on demand.
    pub fn matchesWithWorkspace(self: *const Regex, workspace: *Workspace, input: []const u8) bool {
        return workspace.matchesBorrowed(&self.program, input);
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
        return .{
            .start = found.start,
            .end = found.end,
            .slots = captures.slots,
            .mark = found.mark,
        };
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
        const pool_id: u64 = if (poolable(gpa)) self.program_id else 0;
        if (pool_id != 0) {
            if (takePooledWorkspace(pool_id, null)) |workspace| {
                return .{ .input = input, .owned = workspace, .pool_id = pool_id };
            }
        }
        const workspace = try gpa.create(ReplaceWorkspace);
        errdefer gpa.destroy(workspace);
        workspace.* = try ReplaceWorkspace.init(gpa, self.program, self.limits);
        return .{ .input = input, .owned = workspace, .pool_id = pool_id };
    }
    /// Iterate with a caller-owned workspace. The workspace must have been
    /// initialized from this regex's program and limits; the iterator does not
    /// free it, so repeated calls reuse its warmed search caches.
    pub fn findAllWith(self: *const Regex, workspace: *ReplaceWorkspace, input: []const u8) Matches {
        _ = self;
        return .{
            .input = input,
            .borrowed = workspace,
        };
    }
    /// Split `input` around matches. The returned slice is allocated in `gpa`;
    /// its elements are slices of `input`.
    pub fn split(self: *const Regex, gpa: std.mem.Allocator, input: []const u8) Error![][]const u8 {
        if (self.splitSetRun()) |set| return splitAsciiSet(gpa, input, set, std.math.maxInt(usize));
        if (self.splitLiteralRun()) |literal| return splitLiteral(gpa, input, literal, std.math.maxInt(usize));
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
    /// Split `input` around at most `limit` matches; the last part receives
    /// the unmatched remainder. `limit == 0` returns no parts.
    pub fn splitn(self: *const Regex, gpa: std.mem.Allocator, input: []const u8, limit: usize) Error![][]const u8 {
        if (self.splitSetRun()) |set| return splitAsciiSet(gpa, input, set, limit);
        if (self.splitLiteralRun()) |literal| return splitLiteral(gpa, input, literal, limit);
        var parts: std.ArrayList([]const u8) = .empty;
        errdefer parts.deinit(gpa);
        if (limit == 0) return parts.toOwnedSlice(gpa);
        var iterator = try self.findAll(gpa, input);
        defer iterator.deinit();
        var last: usize = 0;
        while (parts.items.len + 1 < limit) {
            const match = (try iterator.next()) orelse break;
            try parts.append(gpa, input[last..match.start]);
            last = match.end;
        }
        try parts.append(gpa, input[last..]);
        return parts.toOwnedSlice(gpa);
    }
    /// The set of a pure ASCII `set+` program, whose matches are exactly the
    /// maximal runs. `split` can then scan the input once instead of running
    /// a full search per part.
    fn splitSetRun(self: *const Regex) ?model.Set {
        if (self.limits.longest) return null;
        const set = shapes.setRun(self.program) orelse return null;
        return if (set.ascii_only) set else null;
    }
    /// A pure literal pattern, whose matches are exactly its occurrences.
    fn splitLiteralRun(self: *const Regex) ?[]const u8 {
        if (self.limits.longest) return null;
        const literal = self.program.literal orelse return null;
        return if (literal.len == 0) null else literal;
    }
    /// Expand a replacement template for one match without searching again.
    pub fn expandMatch(self: *const Regex, gpa: std.mem.Allocator, input: []const u8, match: Match, substitution: []const u8) Error![]u8 {
        return substitution_mod.expandMatch(gpa, self.program, input, match.slots, substitution, self.limits.full_case_mapping);
    }
    pub fn replaceAll(self: *const Regex, gpa: std.mem.Allocator, input: []const u8, substitution: []const u8) Error![]u8 {
        const pool_id: u64 = if (poolable(gpa)) self.program_id else 0;
        if (takePooledWorkspace(pool_id, gpa)) |workspace| {
            defer returnPooledWorkspace(pool_id, workspace);
            return workspace.replaceAll(input, substitution);
        }
        const workspace = try gpa.create(ReplaceWorkspace);
        errdefer gpa.destroy(workspace);
        workspace.* = try ReplaceWorkspace.init(gpa, self.program, self.limits);
        defer returnPooledWorkspace(pool_id, workspace);
        return workspace.replaceAll(input, substitution);
    }
    /// Replace at most `limit` matches.
    pub fn replacen(self: *const Regex, gpa: std.mem.Allocator, input: []const u8, limit: usize, substitution: []const u8) Error![]u8 {
        const pool_id: u64 = if (poolable(gpa)) self.program_id else 0;
        if (takePooledWorkspace(pool_id, gpa)) |workspace| {
            defer returnPooledWorkspace(pool_id, workspace);
            return workspace.replacen(input, limit, substitution);
        }
        const workspace = try gpa.create(ReplaceWorkspace);
        errdefer gpa.destroy(workspace);
        workspace.* = try ReplaceWorkspace.init(gpa, self.program, self.limits);
        defer returnPooledWorkspace(pool_id, workspace);
        return workspace.replacen(input, limit, substitution);
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
    _ = @import("regex/utf8_set.zig");
    _ = @import("regex/utf8_allocation_tests.zig");
    _ = @import("regex/budget_tests.zig");
    _ = @import("regex/engine_tests.zig");
    _ = @import("regex/borrowed_program_tests.zig");
    _ = @import("regex/byte_table_tests.zig");
    _ = @import("regex/range_mask_tests.zig");
    _ = @import("regex/dfa_allocation_tests.zig");
    _ = @import("regex/dfa_scratch_tests.zig");
    _ = @import("regex/literal_workspace_tests.zig");
    _ = @import("regex/capture_run_tests.zig");
    _ = @import("regex/utf8_prefix_tests.zig");
    _ = @import("regex/capture_storage_tests.zig");
    _ = @import("regex/capture_replay_tests.zig");
    _ = @import("regex/capture_nullable_tests.zig");
    _ = @import("regex/run_chain_tests.zig");
    _ = @import("regex/zero_width_tests.zig");
    _ = @import("regex/prefilter_tests.zig");
    _ = @import("regex/nibble_filter_tests.zig");
    _ = @import("regex/rune_cache_tests.zig");
    _ = @import("regex/search_cache_tests.zig");
    _ = @import("regex/search_graph_tests.zig");
    _ = @import("regex/deferred_run_tests.zig");
    _ = @import("regex/deferred_workspace_tests.zig");
    _ = @import("regex/deferred_search_tests.zig");
    _ = @import("regex/set_identity_tests.zig");
    _ = @import("regex/extended_tests.zig");
    _ = @import("regex/api_tests.zig");
    _ = @import("regex/set_tests.zig");
    _ = @import("regex/required_literals_tests.zig");
    _ = @import("regex/emoji_tests.zig");
    _ = @import("regex/grapheme_assertion_tests.zig");
    _ = @import("regex/word_boundary_tests.zig");
    _ = @import("regex/sentence_boundary_tests.zig");
    _ = @import("regex/non_atomic_tests.zig");
    _ = @import("regex/script_run_tests.zig");
    _ = @import("regex/scan_substring_tests.zig");
    _ = @import("regex/newline_tests.zig");
    _ = @import("regex/notempty_tests.zig");
    _ = @import("regex/char_names_tests.zig");
    _ = @import("regex/replace.zig");
    _ = @import("regex/stream_tests.zig");
    _ = @import("regex/serialize_tests.zig");
}
