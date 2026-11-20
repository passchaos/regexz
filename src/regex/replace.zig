//! Bounded capture-aware RE2 replacement used by xDS regex rewrites.
//!
//! Boolean matching stays on the linear Thompson engine. Replacement needs
//! capture boundaries and leftmost-first priority. Programs with captures use
//! an explicit backtracking stack with a hard work budget, which makes
//! pathological patterns fail closed instead of running unboundedly.
//! Capture-free programs can retry on the linear Pike-style search in
//! `pike.zig` when the budget is exhausted and `Limits.linear_fallback` is on.
const std = @import("std");
const byte_table = @import("byte_table.zig");
const model = @import("model.zig");
const Program = @import("compile.zig").Program;
const BoundedElement = @import("compile.zig").BoundedElement;
const UnboundedElement = @import("compile.zig").UnboundedElement;
const pike = @import("pike.zig");
const backtrack = @import("backtrack.zig");
const search_dfa = @import("search_dfa.zig");
const deferred_utf8 = @import("deferred_utf8_run.zig");
const utf8_run_search = @import("utf8_run_search.zig");
const prefilter = @import("prefilter.zig");
const shapes = @import("shapes.zig");
const zero_width = @import("zero_width.zig");
const fast_branch_mod = @import("fast_branch.zig");
const capture_run_mod = @import("capture_run.zig");
const capture_replay = @import("capture_replay.zig");
const subst = @import("substitution.zig");
const newline = @import("newline.zig");
const required_literals = @import("required_literals.zig");
const unicode = @import("unicode.zig");
const unset = std.math.maxInt(usize);
const AnchoredRun = struct { kind: model.Assertion, set: model.Set };

/// The deterministic shape selected at init. Unicode set runs switch to the
/// prepared state once their optional UTF-8 table is available.
pub const FastKind = enum {
    none,
    set_run,
    utf8_run,
    utf8_run_prepared,
    chain,
    anchored,
    line,
    delimited,
    word,
    trailing_space,
    line_delimited,
    number,
    capture_run,
    capture_unicode,
    run_chain,
    zero_width,
    literal_run,
    caseless_literal,
    literal_set,
    run_then_literal,
    fixed_sequence,
    line_start_run,
    bounded_sequence,
    unbounded_sequence,
};
pub const Error = model.Error;

const Choice = struct { pc: usize, pos: usize, trail_len: usize, limit: usize = unset, byte_loop: bool = false };
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
    if (needle.len == 2) return prefilter.indexOfPair(input, start, needle[0], needle[1]);
    var offset = start;
    while (prefilter.indexOfByte(input, offset, needle[0])) |found| {
        if (needle.len <= input.len - found and std.mem.eql(u8, input[found..][0..needle.len], needle)) return found;
        offset = found + 1;
    }
    return null;
}

/// Find `byte` at or after `start`. Delimiter pairs in tags and quoted
/// strings are short, where a scalar scan beats the vector search's setup;
/// long gaps still use the vector scan.
inline fn indexOfDelimiter(input: []const u8, start: usize, byte: u8) ?usize {
    const limit = @min(input.len, start + 32);
    var offset = start;
    while (offset < limit) : (offset += 1) {
        if (input[offset] == byte) return offset;
    }
    if (limit >= input.len) return null;
    return std.mem.indexOfScalarPos(u8, input, limit, byte);
}

/// Occurrences of `byte` in `input`, counted 16 bytes at a time.
fn countByte(input: []const u8, byte: u8) usize {
    const needle: @Vector(16, u8) = @splat(byte);
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + 16 <= input.len) : (offset += 16) {
        const raw: [16]u8 = input[offset..][0..16].*;
        const chunk: @Vector(16, u8) = @bitCast(raw);
        count += @popCount(@as(u16, @bitCast(chunk == needle)));
    }
    while (offset < input.len) : (offset += 1) {
        if (input[offset] == byte) count += 1;
    }
    return count;
}

/// Copy `input` to `output`, replacing every occurrence of `byte`. The
/// output has the same length as the input, so the caller must provide at
/// least `input.len` bytes.
fn replaceByteInto(input: []const u8, byte: u8, replacement: u8, output: []u8) Error![]u8 {
    if (output.len < input.len) return error.RegexLimitExceeded;
    const needle: @Vector(16, u8) = @splat(byte);
    const repl: @Vector(16, u8) = @splat(replacement);
    var offset: usize = 0;
    while (offset + 16 <= input.len) : (offset += 16) {
        const raw: [16]u8 = input[offset..][0..16].*;
        const chunk: @Vector(16, u8) = @bitCast(raw);
        output[offset..][0..16].* = @bitCast(@select(u8, chunk == needle, repl, chunk));
    }
    while (offset < input.len) : (offset += 1) {
        output[offset] = if (input[offset] == byte) replacement else input[offset];
    }
    return output[0..input.len];
}

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    program: Program,
    limits: model.Limits,
    /// Disjoint views into one allocation, with slots at its base.
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
    /// Cached capture-free DFA for the common find fast path.
    fast_dfa: ?*search_dfa.Workspace = null,
    /// A `set+` program over an ASCII-only set scans runs directly instead of
    /// entering the DFA.
    simple_set: ?model.Set = null,
    /// ASCII set runs whose capture saves have fixed start/end positions.
    capture_run: ?capture_run_mod.Plan = null,
    /// Lazily prove deterministic capture replay once per immutable program.
    capture_replay_plan: capture_replay.Plan = .unprepared,
    /// A `set+ separator set+ tail` program is found by scanning for the
    /// separator instead of running the DFA over the whole input.
    simple_chain: ?shapes.Chain = null,
    /// A captured chain of greedy runs (`(setA*)(setB*)(setC+)`) with
    /// pairwise-disjoint sets and a mandatory anchor run.
    run_chain: ?*RunChainState = null,
    /// A fixed literal prefix, one optional literal, a fixed middle and a
    /// trailing `set+` run (`https?://[^\s]+`).
    literal_run: ?*LiteralRunState = null,
    /// A `set+` program ending in a line/text-end assertion scans runs and
    /// checks the assertion once at each run end.
    simple_anchored: ?AnchoredRun = null,
    /// Multi-literal absence filter for wide start-literal alternations
    /// whose literals have distinct first bytes.
    pair_filter: ?*prefilter.PairSet = null,
    /// Absence filter for a whole-pattern case-folded literal (`(?i)STRASSE`).
    fold_filter: ?prefilter.FoldFilter = null,
    /// Pair-set SIMD filter for a whole-pattern literal alternation.
    literal_set_filter: ?prefilter.MultiFilter = null,
    /// `set+ literal` with a literal first byte outside the set.
    run_then_literal: ?RunThenLiteral = null,
    /// Fixed-width concatenation of single-rune sets and literal bytes.
    fixed_sequence: ?*FixedSequence = null,
    /// `(?m)^set+` in LF newline mode.
    line_start_run: ?LineStartRun = null,
    /// Bounded set-run concatenation with at least one variable-width run.
    bounded_sequence: ?*BoundedSequenceState = null,
    /// Unbounded run chain separated by literal bytes.
    unbounded_sequence: ?*UnboundedSequenceState = null,
    /// Byte membership tables for the chain fast path. `Set.matches` is a
    /// binary search over rune ranges; the per-byte chain scans run several
    /// lookups per input byte, so cache the answers once per workspace.
    chain_tables: ?ChainTables = null,
    /// Byte membership for the `set+` search path.
    simple_set_table: [256]bool = .{false} ** 256,
    /// Non-ASCII `set+` programs reuse the ASCII table and prepare optional
    /// UTF-8 transition rows after repeated probes or a long Unicode run.
    utf8_run: ?deferred_utf8.CompactRun = null,
    /// Dedicated scan for a dominant alternation branch (tokenizer shape).
    fast_branch: ?FastBranch = null,
    /// `(?m)^.*$`: match one line at a time with a newline scan.
    line_run: bool = false,
    /// `"[^"]*"` / `<[^>]+>`: match the next delimiter pair.
    delimited_run: ?shapes.Delimited = null,
    /// `\b\w+\b`: match the next whole word.
    word_run: bool = false,
    word_run_table: [256]bool = .{false} ** 256,
    /// `\s*$`: match the trailing whitespace run.
    trailing_space: bool = false,
    trailing_space_table: [256]bool = .{false} ** 256,
    /// `(?m)^[^d\n]+d`: match a key from the line start to the delimiter.
    line_delimited: ?shapes.LineDelimited = null,
    /// `-?\d+(?:\.\d+)?`: match a JSON-style number.
    number_run: bool = false,
    number_table: [256]bool = .{false} ** 256,
    /// The deterministic shape and its preparation state. `find` dispatches
    /// with one switch; Unicode set runs update it after preparing a table.
    fast_kind: FastKind = .none,
    /// The first set covers most of the alphabet, so the start prefilter
    /// barely skips. Programs with a nullable prefix (like `.*foo`) then
    /// restart the DFA at almost every position, and one required-literal
    /// absence scan is much cheaper than the search.
    weak_first: bool = false,
    /// The body starts with a single-set unbounded loop (`.*`, `\w*`, ...).
    /// After a failed interpreter search from `start`, no match can start
    /// inside the loop's run, so the next search starts at the run end.
    prefix_set: ?model.Set = null,
    /// The body begins with a mandatory `\A`/`^` (text start) assertion, so
    /// no match can start past offset zero.
    start_anchored: bool = false,
    /// The body begins with a mandatory multiline `^`, so every match starts
    /// at a line start and failed searches can jump to the next line.
    line_start_only: bool = false,
    first_filter: prefilter.FirstFilter,

    pub fn init(
        allocator: std.mem.Allocator,
        program: Program,
        limits: model.Limits,
    ) std.mem.Allocator.Error!Workspace {
        var effective = limits;
        effective.max_execution_steps = @min(effective.max_execution_steps, program.limit_match);
        effective.max_recursion_depth = @min(effective.max_recursion_depth, program.limit_depth);
        effective.max_backtrack_choices = @min(effective.max_backtrack_choices, program.limit_heap_choices);
        effective.max_capture_trail = @min(effective.max_capture_trail, program.limit_heap_choices);
        const slot_count = 2 * (@as(usize, program.trackedCaptures()) + 1);
        const slot_storage = try allocator.alloc(usize, slot_count * 2);
        @memset(slot_storage, unset);
        errdefer allocator.free(slot_storage);
        const slots = slot_storage[0..slot_count];
        const best_slots = slot_storage[slot_count..];
        const pair_filter = try buildPairFilter(allocator, program);
        const word_run_set = shapes.wordRun(program);
        var word_table: [256]bool = .{false} ** 256;
        if (word_run_set) |set| {
            word_table = byte_table.init(256, set);
        }
        errdefer if (pair_filter) |filter| allocator.destroy(filter);
        const simple_chain = if (limits.longest) null else shapes.chain(program);
        const set_run = if (limits.longest) null else shapes.setRun(program);
        const capture_run = if (limits.longest) null else capture_run_mod.Plan.init(program);
        // Captured run chains allocate their plan and anchor filter out of
        // line: the shape is uncommon and the state is larger than the
        // workspace's inline shape records. The single-run capture path takes
        // precedence, so its programs skip detection and the allocation.
        const run_chain: ?*RunChainState = if (limits.longest or capture_run != null) null else blk: {
            const plan = shapes.runChain(program) orelse break :blk null;
            const state = try allocator.create(RunChainState);
            state.plan = plan;
            for (plan.sets[0..plan.count], 0..) |set, index| {
                if (!plan.empty[index] and !set.ascii_only) {
                    state.use_cache = true;
                    break;
                }
            }
            if (plan.forward) {
                const first = plan.sets[0];
                state.filter = prefilter.FirstFilter.init(.{ .ascii = first.ascii, .nonascii = !first.ascii_only });
                state.filter.prepareRunePrefixes(first);
            } else if (plan.anchor != shapes.RunChain.no_anchor) {
                const anchor = plan.sets[plan.anchor];
                state.filter = prefilter.FirstFilter.init(.{ .ascii = anchor.ascii, .nonascii = !anchor.ascii_only });
                state.filter.prepareRunePrefixes(anchor);
            } else {
                // All runs are nullable; the scan starts at the search offset.
                state.filter = prefilter.FirstFilter.init(.{ .empty = true });
            }
            break :blk state;
        };
        errdefer if (run_chain) |state| allocator.destroy(state);
        const literal_run: ?*LiteralRunState = if (limits.longest) null else blk: {
            const shape = shapes.literalRun(program) orelse break :blk null;
            const state = try allocator.create(LiteralRunState);
            state.* = .{
                .shape = shape,
                .run = deferred_utf8.CompactRun.init(shape.set),
                .table = byte_table.init(256, shape.set),
            };
            break :blk state;
        };
        errdefer if (literal_run) |state| state.deinit(allocator);
        const utf8_run: ?deferred_utf8.CompactRun = if (set_run) |set|
            (if (set.ascii_only) null else deferred_utf8.CompactRun.init(set))
        else
            null;
        const simple_set: ?model.Set = if (set_run) |set| (if (set.ascii_only) set else null) else null;
        const simple_anchored = if (limits.longest) null else detectAnchoredRun(program);
        const line_run = shapes.lineRun(program);
        const delimited_run = shapes.delimitedRun(program);
        const trailing_space_set = shapes.trailingSpaceRun(program);
        const line_delimited = shapes.lineDelimitedRun(program);
        const number_run_set = shapes.numberRun(program);
        var number_table: [256]bool = .{false} ** 256;
        if (number_run_set) |set| {
            number_table = byte_table.init(256, set);
        }
        var trailing_table: [256]bool = .{false} ** 256;
        if (trailing_space_set) |set| {
            trailing_table = byte_table.init(256, set);
        }
        const zero_width_plan = if (limits.longest or program.notempty or program.notempty_atstart)
            null
        else
            program.zero_width;
        const run_then_literal: ?RunThenLiteral = if (limits.longest) null else detectRunThenLiteral(program);
        const line_start_run: ?LineStartRun = if (limits.longest) null else detectLineStartRun(program);
        const bounded_sequence: ?*BoundedSequenceState = if (limits.longest) null else blk: {
            const elements = program.bounded_sequence orelse break :blk null;
            const state = try allocator.create(BoundedSequenceState);
            errdefer allocator.destroy(state);
            state.* = .{};
            if (!state.build(elements)) {
                allocator.destroy(state);
                break :blk null;
            }
            break :blk state;
        };
        errdefer if (bounded_sequence) |state| allocator.destroy(state);
        const unbounded_sequence: ?*UnboundedSequenceState = if (limits.longest) null else blk: {
            const elements = program.unbounded_sequence orelse break :blk null;
            const state = try allocator.create(UnboundedSequenceState);
            errdefer allocator.destroy(state);
            state.* = .{};
            if (!state.build(elements)) {
                allocator.destroy(state);
                break :blk null;
            }
            break :blk state;
        };
        errdefer if (unbounded_sequence) |state| allocator.destroy(state);
        const fixed_sequence: ?*FixedSequence = if (limits.longest) null else blk: {
            const shape = detectFixedSequence(program) orelse break :blk null;
            const state = try allocator.create(FixedSequence);
            state.* = shape;
            state.buildTables();
            break :blk state;
        };
        errdefer if (fixed_sequence) |state| allocator.destroy(state);
        const fast_kind: FastKind = if (simple_set != null)
            .set_run
        else if (capture_run) |plan|
            (if (plan.set.ascii_only) .capture_run else .capture_unicode)
        else if (run_chain != null)
            .run_chain
        else if (zero_width_plan != null)
            .zero_width
        else if (program.caseless_literal != null and program.capture_count == 0 and !limits.longest)
            .caseless_literal
        else if (program.literal_set != null and program.capture_count == 0 and !limits.longest)
            .literal_set
        else if (utf8_run != null)
            .utf8_run
        else if (simple_chain != null)
            .chain
        else if (run_then_literal != null)
            .run_then_literal
        else if (fixed_sequence != null)
            .fixed_sequence
        else if (line_start_run != null)
            .line_start_run
        else if (bounded_sequence != null)
            .bounded_sequence
        else if (unbounded_sequence != null)
            .unbounded_sequence
        else if (literal_run != null)
            .literal_run
        else if (simple_anchored != null)
            .anchored
        else if (line_run)
            .line
        else if (delimited_run != null)
            .delimited
        else if (word_run_set != null)
            .word
        else if (trailing_space_set != null)
            .trailing_space
        else if (line_delimited != null)
            .line_delimited
        else if (number_run_set != null)
            .number
        else
            .none;
        const fast_branch: ?FastBranch = if (program.fast_branch) |plan| blk: {
            var value = FastBranch{
                .prior = prefilter.FirstFilter.init(plan.prior_first),
                .prefix = if (plan.prefix) |set| deferred_utf8.Run.init(set) else null,
                .run = deferred_utf8.Run.init(plan.run),
            };
            errdefer value.deinit(allocator);
            if (plan.later.len != 0) {
                const list = try allocator.alloc(LaterRun, plan.later.len);
                var initialized: usize = 0;
                errdefer {
                    for (list[0..initialized]) |*later| later.deinit(allocator);
                    allocator.free(list);
                }
                for (plan.later, 0..) |later, index| {
                    list[index] = .{
                        .kind = later.kind,
                        .prefix = if (later.prefix) |set| deferred_utf8.Run.init(set) else null,
                        .run = deferred_utf8.Run.init(later.run),
                        .tail = if (later.tail) |set| deferred_utf8.Run.init(set) else null,
                        .newline_branch = later.newline_branch,
                        .lookahead_branch = later.lookahead_branch,
                    };
                    initialized += 1;
                }
                for (list) |*later| {
                    if (later.prefix) |*prefix| {
                        for (0..128) |byte| {
                            if (prefix.ascii[byte]) value.later_first[byte] = true;
                        }
                    }
                    for (0..128) |byte| {
                        if (later.run.ascii[byte]) value.later_first[byte] = true;
                    }
                }
                value.later = list;
            }
            break :blk value;
        } else null;
        errdefer if (fast_branch) |*value| value.deinit(allocator);
        return .{
            .allocator = allocator,
            .program = program,
            .limits = effective,
            .slots = slots,
            .best_slots = best_slots,
            .pike_eligible = pike.eligible(program),
            .simple_set = simple_set,
            .capture_run = capture_run,
            .simple_set_table = blk: {
                var table: [256]bool = .{false} ** 256;
                if (set_run orelse (if (capture_run) |plan| plan.set else null)) |set| {
                    if (set.ascii_only) {
                        table = byte_table.init(256, set);
                    } else if (utf8_run != null) {
                        table[0..128].* = byte_table.init(128, set);
                    }
                }
                break :blk table;
            },
            .simple_chain = simple_chain,
            .simple_anchored = simple_anchored,
            .run_chain = run_chain,
            .literal_run = literal_run,
            .chain_tables = if (simple_chain) |chain| ChainTables.init(chain) else null,
            .line_run = line_run,
            .delimited_run = delimited_run,
            .word_run = word_run_set != null,
            .trailing_space = trailing_space_set != null,
            .trailing_space_table = trailing_table,
            .line_delimited = line_delimited,
            .number_run = number_run_set != null,
            .number_table = number_table,
            .fast_kind = fast_kind,
            .word_run_table = word_table,
            .utf8_run = utf8_run,
            .fast_branch = fast_branch,
            .weak_first = @as(usize, @popCount(program.first.ascii[0])) + @popCount(program.first.ascii[1]) >= 48,
            .prefix_set = detectPrefixSet(program),
            .start_anchored = startsAtTextStart(program),
            .line_start_only = startsAtLineStart(program),
            .first_filter = prefilter.FirstFilter.init(if (capture_run) |plan|
                .{ .ascii = plan.set.ascii, .nonascii = !plan.set.ascii_only, .empty = false }
            else
                program.first),
            .pair_filter = pair_filter,
            .fold_filter = if (program.caseless_literal) |literal| prefilter.FoldFilter.init(literal) else null,
            .literal_set_filter = if (program.literal_set) |literals| literalSetFilter(literals) else null,
            .run_then_literal = run_then_literal,
            .fixed_sequence = fixed_sequence,
            .line_start_run = line_start_run,
            .bounded_sequence = bounded_sequence,
            .unbounded_sequence = unbounded_sequence,
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.pair_filter) |filter| self.allocator.destroy(filter);
        if (self.run_chain) |state| self.allocator.destroy(state);
        if (self.literal_run) |state| state.deinit(self.allocator);
        if (self.fixed_sequence) |state| self.allocator.destroy(state);
        if (self.bounded_sequence) |state| self.allocator.destroy(state);
        if (self.unbounded_sequence) |state| self.allocator.destroy(state);
        if (self.utf8_run) |*value| value.deinit(self.allocator);
        if (self.fast_branch) |*value| value.deinit(self.allocator);
        if (self.pike_workspace) |*workspace| workspace.deinit();
        if (self.backtrack_workspace) |*workspace| workspace.deinit();
        if (self.search_dfa_workspace) |*workspace| workspace.deinit();
        self.choices.deinit(self.allocator);
        self.trail.deinit(self.allocator);
        self.allocator.free(self.slots.ptr[0 .. self.slots.len + self.best_slots.len]);
        self.* = undefined;
    }

    /// Whether searches are decided by scanning for a separator/delimiter,
    /// which costs one vector scan per pattern rather than a full-input DFA
    /// pass. A set made only of these shapes does not need the combined DFA.
    pub fn usesSeparatorScan(self: *const Workspace) bool {
        return self.fast_kind == .chain or self.fast_kind == .delimited;
    }

    /// Full match for extended programs, delegated to the backtracking VM.
    pub fn fullMatch(self: *Workspace, input: []const u8) Error!bool {
        if (self.backtrack_workspace == null) {
            self.backtrack_workspace = try backtrack.Workspace.init(self.allocator, self.program, self.limits);
        }
        return self.backtrack_workspace.?.fullMatch(input);
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
        if (self.start_anchored and search_start != 0) return null;
        switch (self.fast_kind) {
            .none => {
                if (self.fast_branch) |*branch| {
                    if (self.findFastBranch(branch, input, search_start)) |match| return match;
                }
            },
            .set_run => return self.findSetRun(self.simple_set.?, input, search_start),
            .utf8_run => return self.findSetRunUtf8(&self.utf8_run.?, input, search_start),
            .utf8_run_prepared => return self.findPreparedSetRunUtf8(&self.utf8_run.?, input, search_start),
            .chain => return self.findChain(&self.simple_chain.?, input, search_start),
            .literal_run => return self.findLiteralRun(self.literal_run.?, input, search_start),
            .anchored => return self.findAnchoredRun(self.simple_anchored.?, input, search_start),
            .line => return self.findLineRun(input, search_start),
            .delimited => return self.findDelimitedRun(self.delimited_run.?, input, search_start),
            .word => return self.findWordRun(input, search_start),
            .trailing_space => return self.findTrailingSpaceRun(input, search_start),
            .line_delimited => return self.findLineDelimitedRun(self.line_delimited.?, input, search_start),
            .number => return self.findNumberRun(input, search_start),
            .capture_run => return self.findCaptureRun(input, search_start),
            .capture_unicode => return self.findCaptureUnicodeRun(input, search_start),
            .run_chain => {
                // The scan bails out on starts inside a run and malformed
                // UTF-8, so a miss falls through to the general engine.
                if (self.findRunChain(self.run_chain.?, input, search_start)) |match| return match;
            },
            .zero_width => {
                if (self.findZeroWidth(&self.program.zero_width.?, input, search_start)) |match| return match;
            },
            .caseless_literal => {
                if (self.findCaselessLiteral(input, search_start)) |match| return match;
            },
            .literal_set => return self.findLiteralSet(input, search_start),
            .run_then_literal => return self.findRunThenLiteral(&self.run_then_literal.?, input, search_start),
            .fixed_sequence => return self.findFixedSequence(self.fixed_sequence.?, input, search_start),
            .line_start_run => return self.findLineStartRun(&self.line_start_run.?, input, search_start),
            .bounded_sequence => return self.findBoundedSequence(self.bounded_sequence.?, input, search_start),
            .unbounded_sequence => return self.findUnboundedSequence(self.unbounded_sequence.?, input, search_start),
        }
        // Every match must start at a start-literal occurrence, so the first
        // occurrence bounds the leftmost match start and the DFA can skip
        // the prefix before it.
        var from = search_start;
        if (self.pair_filter) |filter| {
            from = filter.indexOfAny(input, search_start) orelse return null;
        }
        if (self.fold_filter) |filter| {
            from = filter.indexOf(input, from) orelse return null;
        }
        if (self.fast_dfa) |dfa| {
            if (self.requiredByteMiss(input, from)) return null;
            if (self.weak_first and self.requiredLiteralMiss(input, from)) return null;
            const found = (try dfa.find(input, from)) orelse return null;
            self.slots[0] = found.start;
            self.slots[1] = found.end;
            return .{ .start = found.start, .end = found.end, .slots = self.slots };
        }
        return self.findInternal(input, from);
    }

    /// Replace every non-overlapping leftmost-first match. RE2 substitution
    /// syntax is used: `\0` is the whole match, `\1`..`\9` are capture groups,
    /// `\\` is a literal backslash, and any other `\x` is emitted literally.
    pub fn replaceAll(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
    ) Error![]u8 {
        // A pure ASCII `set+` matches maximal runs, and a literal substitution
        // needs no expansion, so the whole pass is one table scan.
        if (self.fast_kind == .set_run and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
            return self.replaceSetRun(input, substitution, std.math.maxInt(usize));
        }
        // A pure literal pattern matches exactly its occurrences; scan them
        // with the literal search and append the gaps directly.
        if (self.program.literal) |literal| {
            if (literal.len != 0 and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
                if (literal.len == 1 and substitution.len == 1) {
                    return self.replaceByteAlloc(input, literal[0], substitution[0]);
                }
                return self.replaceAllLiteral(input, literal, substitution);
            }
        }
        // An edge-only zero-width plan matches at a handful of text edges, so
        // a length pass is cheap and one exact allocation replaces the
        // ArrayList's growth and shrink copies.
        if (self.program.zero_width) |plan| {
            if (edgeOnlyPlan(plan)) {
                const length = try self.replaceAllLen(input, substitution);
                const exact = try self.allocator.alloc(u8, length);
                errdefer self.allocator.free(exact);
                const written = try self.replaceAllInto(input, substitution, exact);
                if (written.len == length) return exact;
                self.allocator.free(exact);
            }
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var writer = subst.ListWriter{ .list = &out, .allocator = self.allocator };
        try self.replaceAllWith(&writer, input, substitution, std.math.maxInt(usize));
        return out.toOwnedSlice(self.allocator);
    }

    /// Every path asserts only text edges, so the match set is bounded by the
    /// text start, the final newline and the text end.
    fn edgeOnlyPlan(plan: zero_width.Plan) bool {
        for (plan.paths[0..plan.count]) |path| {
            if (!path.edge_fast) return false;
        }
        return true;
    }

    /// A one-byte literal and a one-byte substitution keep the output the
    /// same size as the input, so the whole pass is a vector translate
    /// instead of one gap copy plus one substitution copy per occurrence.
    fn replaceByteAlloc(self: *Workspace, input: []const u8, byte: u8, replacement: u8) Error![]u8 {
        const out = try self.allocator.alloc(u8, input.len);
        errdefer self.allocator.free(out);
        _ = try replaceByteInto(input, byte, replacement, out);
        return out;
    }

    /// `replacen` variant: the translate stops replacing after `limit`
    /// occurrences, so no separate counting pass is needed. A chunk is only
    /// translated while at least one full chunk of replacements remains; the
    /// scalar tail applies the exact remaining limit.
    fn replaceByteAllocLimit(
        self: *Workspace,
        input: []const u8,
        byte: u8,
        replacement: u8,
        limit: usize,
    ) Error![]u8 {
        const out = try self.allocator.alloc(u8, input.len);
        errdefer self.allocator.free(out);
        var remaining = limit;
        const needle: @Vector(16, u8) = @splat(byte);
        const repl: @Vector(16, u8) = @splat(replacement);
        var offset: usize = 0;
        while (offset + 16 <= input.len and remaining >= 16) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: @Vector(16, u8) = @bitCast(raw);
            const matches = chunk == needle;
            out[offset..][0..16].* = @bitCast(@select(u8, matches, repl, chunk));
            remaining -= @popCount(@as(u16, @bitCast(matches)));
        }
        while (offset < input.len) : (offset += 1) {
            if (remaining != 0 and input[offset] == byte) {
                out[offset] = replacement;
                remaining -= 1;
            } else {
                out[offset] = input[offset];
            }
        }
        return out;
    }

    fn replaceAllLiteral(self: *Workspace, input: []const u8, literal: []const u8, substitution: []const u8) Error![]u8 {
        return self.replaceLiteral(input, literal, substitution, std.math.maxInt(usize));
    }

    fn replaceLiteral(self: *Workspace, input: []const u8, literal: []const u8, substitution: []const u8, limit: usize) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, input.len);
        var last: usize = 0;
        var offset: usize = 0;
        var replaced: usize = 0;
        // A substitution no longer than the literal never grows the output,
        // so the reserved capacity always fits.
        const bounded = substitution.len <= literal.len;
        while (replaced < limit) : (replaced += 1) {
            const found = indexOfLiteral(input, offset, literal) orelse break;
            if (bounded) {
                out.appendSliceAssumeCapacity(input[last..found]);
                out.appendSliceAssumeCapacity(substitution);
            } else {
                try out.appendSlice(self.allocator, input[last..found]);
                try out.appendSlice(self.allocator, substitution);
            }
            last = found + literal.len;
            offset = last;
        }
        if (bounded) {
            out.appendSliceAssumeCapacity(input[last..]);
        } else {
            try out.appendSlice(self.allocator, input[last..]);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn replaceSetRun(self: *Workspace, input: []const u8, substitution: []const u8, limit: usize) Error![]u8 {
        const table = &self.simple_set_table;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, input.len);
        var last: usize = 0;
        var offset: usize = 0;
        var replaced: usize = 0;
        // A zero- or one-byte substitution never grows the output: every run
        // removes at least one byte, so the reserved capacity always fits.
        const bounded = substitution.len <= 1;
        while (offset < input.len and replaced < limit) {
            while (offset < input.len and !table[input[offset]]) offset += 1;
            if (offset == input.len) break;
            const start = offset;
            while (offset < input.len and table[input[offset]]) offset += 1;
            if (bounded) {
                out.appendSliceAssumeCapacity(input[last..start]);
                if (substitution.len == 1) out.appendAssumeCapacity(substitution[0]);
            } else {
                try out.appendSlice(self.allocator, input[last..start]);
                try out.appendSlice(self.allocator, substitution);
            }
            last = offset;
            replaced += 1;
        }
        if (bounded) {
            out.appendSliceAssumeCapacity(input[last..]);
        } else {
            try out.appendSlice(self.allocator, input[last..]);
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn replaceSetRunLen(self: *Workspace, input: []const u8, substitution: []const u8) Error!usize {
        const table = &self.simple_set_table;
        var runs: usize = 0;
        var run_bytes: usize = 0;
        var offset: usize = 0;
        while (offset < input.len) {
            while (offset < input.len and !table[input[offset]]) offset += 1;
            if (offset == input.len) break;
            const start = offset;
            while (offset < input.len and table[input[offset]]) offset += 1;
            runs += 1;
            run_bytes += offset - start;
        }
        const added = std.math.mul(usize, runs, substitution.len) catch return error.RegexLimitExceeded;
        return input.len - run_bytes + added;
    }

    fn replaceSetRunInto(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
        output: []u8,
    ) Error![]const u8 {
        const table = &self.simple_set_table;
        var write: usize = 0;
        var last: usize = 0;
        var offset: usize = 0;
        while (offset < input.len) {
            while (offset < input.len and !table[input[offset]]) offset += 1;
            if (offset == input.len) break;
            const start = offset;
            while (offset < input.len and table[input[offset]]) offset += 1;
            const gap = start - last;
            if (gap > output.len - write) return error.RegexLimitExceeded;
            @memcpy(output[write..][0..gap], input[last..start]);
            write += gap;
            if (substitution.len > output.len - write) return error.RegexLimitExceeded;
            @memcpy(output[write..][0..substitution.len], substitution);
            write += substitution.len;
            last = offset;
        }
        const tail = input.len - last;
        if (tail > output.len - write) return error.RegexLimitExceeded;
        @memcpy(output[write..][0..tail], input[last..]);
        write += tail;
        return output[0..write];
    }

    /// Replace at most `limit` non-overlapping leftmost-first matches.
    pub fn replacen(
        self: *Workspace,
        input: []const u8,
        limit: usize,
        substitution: []const u8,
    ) Error![]u8 {
        if (self.fast_kind == .set_run and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
            return self.replaceSetRun(input, substitution, limit);
        }
        if (self.program.literal) |literal| {
            if (literal.len != 0 and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
                if (literal.len == 1 and substitution.len == 1) {
                    return self.replaceByteAllocLimit(input, literal[0], substitution[0], limit);
                }
                return self.replaceLiteral(input, literal, substitution, limit);
            }
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var writer = subst.ListWriter{ .list = &out, .allocator = self.allocator };
        try self.replaceAllWith(&writer, input, substitution, limit);
        return out.toOwnedSlice(self.allocator);
    }

    /// Compute the exact replacement length without materializing the output.
    pub fn replaceAllLen(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
    ) Error!usize {
        if (self.fast_kind == .set_run and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
            return self.replaceSetRunLen(input, substitution);
        }
        if (self.program.literal) |literal| {
            if (literal.len != 0 and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
                return self.replaceLiteralLen(input, literal, substitution);
            }
        }
        var length: usize = 0;
        var writer = subst.LengthWriter{ .length = &length };
        try self.replaceAllWith(&writer, input, substitution, std.math.maxInt(usize));
        return length;
    }

    fn replaceLiteralLen(self: *Workspace, input: []const u8, literal: []const u8, substitution: []const u8) Error!usize {
        _ = self;
        var count: usize = 0;
        if (literal.len == 1) {
            count = countByte(input, literal[0]);
        } else {
            var offset: usize = 0;
            while (indexOfLiteral(input, offset, literal)) |found| {
                count += 1;
                offset = found + literal.len;
            }
        }
        const removed = std.math.mul(usize, count, literal.len) catch return error.RegexLimitExceeded;
        const added = std.math.mul(usize, count, substitution.len) catch return error.RegexLimitExceeded;
        return input.len - removed + added;
    }

    /// Write the replacement into a caller-owned buffer. The buffer must be at
    /// least as large as `replaceAllLen`; otherwise the work fails closed.
    pub fn replaceAllInto(
        self: *Workspace,
        input: []const u8,
        substitution: []const u8,
        output: []u8,
    ) Error![]const u8 {
        if (self.fast_kind == .set_run and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
            return self.replaceSetRunInto(input, substitution, output);
        }
        if (self.program.literal) |literal| {
            if (literal.len != 0 and std.mem.indexOfAny(u8, substitution, "\\$") == null) {
                if (literal.len == 1 and substitution.len == 1) {
                    return replaceByteInto(input, literal[0], substitution[0], output);
                }
                return self.replaceLiteralInto(input, literal, substitution, output);
            }
        }
        var writer = subst.BufferWriter{ .output = output };
        try self.replaceAllWith(&writer, input, substitution, std.math.maxInt(usize));
        return output[0..writer.len];
    }

    fn replaceLiteralInto(
        self: *Workspace,
        input: []const u8,
        literal: []const u8,
        substitution: []const u8,
        output: []u8,
    ) Error![]const u8 {
        _ = self;
        var write: usize = 0;
        var last: usize = 0;
        var offset: usize = 0;
        while (indexOfLiteral(input, offset, literal)) |found| {
            const gap = found - last;
            if (gap > output.len - write) return error.RegexLimitExceeded;
            @memcpy(output[write..][0..gap], input[last..found]);
            write += gap;
            if (substitution.len > output.len - write) return error.RegexLimitExceeded;
            @memcpy(output[write..][0..substitution.len], substitution);
            write += substitution.len;
            last = found + literal.len;
            offset = last;
        }
        const tail = input.len - last;
        if (tail > output.len - write) return error.RegexLimitExceeded;
        @memcpy(output[write..][0..tail], input[last..]);
        write += tail;
        return output[0..write];
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
        var first_match = true;
        while (search_start <= input.len) {
            const match = try self.findInternal(input, search_start) orelse break;
            if (first_match) {
                // Start near the output size without overallocating when the
                // first match replaces the entire input.
                try out.ensureTotalCapacity(self.allocator, input.len - (match.end - match.start));
                first_match = false;
            }
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
        limit: usize,
    ) Error!void {
        try subst.validateSubstitutionFor(self.program, substitution);
        // A substitution with no `$` or `\` expands to itself; skip the
        // per-match parse in that common case. Otherwise parse the
        // substitution into segments once so each match only appends slices.
        const literal_substitution = std.mem.indexOfAny(u8, substitution, "\\$") == null;
        var template: ?subst.Template = if (literal_substitution)
            null
        else
            try subst.parseTemplate(substitution, self.program);
        self.steps = 0;
        var search_start: usize = 0;
        var replaced: usize = 0;
        while (search_start <= input.len and replaced < limit) {
            const match = try self.findInternal(input, search_start) orelse break;
            replaced += 1;
            if (@TypeOf(writer) == *subst.ListWriter) {
                if (replaced == 1) {
                    // Length and caller-buffer writers need no allocation.
                    // Subtract the first match so whole-input replacements
                    // keep their small output allocation.
                    try writer.list.ensureTotalCapacity(writer.allocator, input.len - (match.end - match.start));
                }
            }
            try writer.appendSlice(input[search_start..match.start]);
            if (literal_substitution) {
                try writer.appendSlice(substitution);
            } else if (template) |*value| {
                try subst.appendTemplate(writer, input, value, match.slots, self.program);
            } else {
                try subst.appendSubstitution(writer, input, substitution, match.slots, self.program, self.limits.full_case_mapping);
            }
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
        if (capture_replay.linear(.{
            .instructions = self.program.instructions,
            .body = self.program.body,
            .slots = self.slots,
            .steps = &self.steps,
            .max_steps = self.limits.max_execution_steps,
            .forced_runs = self.capture_replay_plan.prepare(self.program.instructions, self.program.body),
        }, input, start, end)) |matched| {
            if (matched) {
                self.slots[0] = start;
                self.slots[1] = end;
                return .{ .start = start, .end = end, .slots = self.slots };
            }
        }
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

    /// Absence check for the DFA path: a single one-byte required literal is
    /// ruled out with one SIMD byte scan. On no-match input that replaces the
    /// whole engine pass; on match-heavy input the scan stops at the first
    /// occurrence, so the per-call cost stays small.
    fn requiredByteMiss(self: *Workspace, input: []const u8, search_start: usize) bool {
        const literals = self.program.required_literals orelse return false;
        if (literals.len != 1 or literals[0].len != 1) return false;
        if (input.len - search_start < 256) return false;
        return !required_literals.containsByte(input, search_start, literals[0][0]);
    }

    /// Leftmost-first search honoring `(*NOTEMPTY)` and
    /// `(*NOTEMPTY_ATSTART)`: rejected empty matches advance by one rune.
    fn findInternal(self: *Workspace, input: []const u8, search_start: usize) Error!?Match {
        // The deterministic fast paths above never consume the step budget,
        // so the reset lives here instead of on every find call.
        self.steps = 0;
        var start = search_start;
        while (true) {
            const match = (try self.findOnce(input, start)) orelse return null;
            if (match.start == match.end and
                (self.program.notempty or (self.program.notempty_atstart and match.start == search_start)))
            {
                if (match.start >= input.len) return null;
                start = match.start + runeLenAt(input, match.start);
                continue;
            }
            return match;
        }
    }

    fn findOnce(
        self: *Workspace,
        input: []const u8,
        search_start: usize,
    ) Error!?Match {
        if (search_start > input.len) return null;
        if (self.start_anchored and search_start != 0) return null;
        switch (self.fast_kind) {
            .none => {
                if (self.fast_branch) |*branch| {
                    if (self.findFastBranch(branch, input, search_start)) |match| return match;
                }
            },
            .set_run => return self.findSetRun(self.simple_set.?, input, search_start),
            .utf8_run => return self.findSetRunUtf8(&self.utf8_run.?, input, search_start),
            .utf8_run_prepared => return self.findPreparedSetRunUtf8(&self.utf8_run.?, input, search_start),
            .chain => return self.findChain(&self.simple_chain.?, input, search_start),
            .literal_run => return self.findLiteralRun(self.literal_run.?, input, search_start),
            .anchored => return self.findAnchoredRun(self.simple_anchored.?, input, search_start),
            .line => return self.findLineRun(input, search_start),
            .delimited => return self.findDelimitedRun(self.delimited_run.?, input, search_start),
            .word => return self.findWordRun(input, search_start),
            .trailing_space => return self.findTrailingSpaceRun(input, search_start),
            .line_delimited => return self.findLineDelimitedRun(self.line_delimited.?, input, search_start),
            .number => return self.findNumberRun(input, search_start),
            .capture_run => return self.findCaptureRun(input, search_start),
            .capture_unicode => return self.findCaptureUnicodeRun(input, search_start),
            .run_chain => {
                // The scan bails out on starts inside a run and malformed
                // UTF-8, so a miss falls through to the general engine.
                if (self.findRunChain(self.run_chain.?, input, search_start)) |match| return match;
            },
            .zero_width => {
                if (self.findZeroWidth(&self.program.zero_width.?, input, search_start)) |match| return match;
            },
            .caseless_literal => {
                if (self.findCaselessLiteral(input, search_start)) |match| return match;
            },
            .literal_set => return self.findLiteralSet(input, search_start),
            .run_then_literal => return self.findRunThenLiteral(&self.run_then_literal.?, input, search_start),
            .fixed_sequence => return self.findFixedSequence(self.fixed_sequence.?, input, search_start),
            .line_start_run => return self.findLineStartRun(&self.line_start_run.?, input, search_start),
            .bounded_sequence => return self.findBoundedSequence(self.bounded_sequence.?, input, search_start),
            .unbounded_sequence => return self.findUnboundedSequence(self.unbounded_sequence.?, input, search_start),
        }
        var from = search_start;
        if (self.pair_filter) |filter| {
            from = filter.indexOfAny(input, search_start) orelse return null;
        }
        if (self.fold_filter) |filter| {
            from = filter.indexOf(input, from) orelse return null;
        }
        if (self.program.literal) |literal| {
            if (self.program.capture_count == 0) {
                const found = indexOfLiteral(input, from, literal) orelse return null;
                self.slots[0] = found;
                self.slots[1] = found + literal.len;
                return .{ .start = found, .end = found + literal.len, .slots = self.slots };
            }
        }
        if (self.program.extended) {
            if (self.requiredLiteralMiss(input, from)) return null;
            if (self.backtrack_workspace == null) {
                self.backtrack_workspace = try backtrack.Workspace.init(self.allocator, self.program, self.limits);
            }
            const found = try self.backtrack_workspace.?.find(input, from) orelse return null;
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
            if (self.requiredByteMiss(input, from)) return null;
            // A nullable first set disables the start prefilter, so patterns
            // like `.*foo` restart the DFA at every position. One literal
            // scan rules the whole search out when the literal is absent.
            if (self.weak_first and self.requiredLiteralMiss(input, from)) return null;
            if (self.search_dfa_workspace == null) {
                self.search_dfa_workspace = search_dfa.Workspace.init(self.allocator, self.program) catch blk: {
                    self.search_dfa_failed = true;
                    break :blk null;
                };
                if (self.search_dfa_workspace == null and !self.search_dfa_failed) self.search_dfa_ineligible = true;
            }
            if (self.fast_dfa == null and self.search_dfa_workspace != null and
                self.program.capture_count == 0 and self.program.literal == null and
                !self.program.extended and !self.limits.longest and
                !self.program.notempty and !self.program.notempty_atstart)
            {
                self.fast_dfa = &self.search_dfa_workspace.?;
            }
            if (self.search_dfa_workspace) |*dfa| {
                const found = dfa.find(input, from) catch |err| switch (err) {
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
        if (self.requiredLiteralMiss(input, from)) return null;
        var start = from;
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
            start = if (self.line_start_only)
                nextLineStart(input, start) orelse return null
            else
                self.nextSearchStart(input, start);
        }
        return null;
    }

    /// Next start position after a failed search. When the body begins with a
    /// single-set loop, the failed scan covered the whole run, so every start
    /// inside it would follow the same continuation and also fail.
    fn nextSearchStart(self: *Workspace, input: []const u8, start: usize) usize {
        if (self.prefix_set) |set| {
            var pos = start;
            if (set.ascii_only) {
                while (pos < input.len and set.matches(input[pos])) pos += 1;
            } else {
                while (set.matchAdvance(input, pos)) |advanced| pos = advanced;
            }
            if (pos > start) return pos;
        }
        return start + runeLenAt(input, start);
    }

    fn findCaptureRun(self: *Workspace, input: []const u8, search_start: usize) Error!?Match {
        const span = (try self.capture_run.?.find(
            &self.simple_set_table,
            &self.first_filter,
            input,
            search_start,
            self.slots,
            &self.steps,
            self.limits.max_execution_steps,
            self.limits.linear_fallback,
        )) orelse return null;
        return .{ .start = span.start, .end = span.end, .slots = self.slots };
    }

    fn findCaptureUnicodeRun(self: *Workspace, input: []const u8, search_start: usize) Error!?Match {
        if (search_start >= input.len) return null;
        const from = if (self.program.literal_prefix) |prefix|
            indexOfLiteral(input, search_start, prefix) orelse return null
        else
            search_start;
        const span = (try self.capture_run.?.findUnicode(
            &self.first_filter,
            input,
            from,
            self.slots,
            &self.steps,
            self.limits.max_execution_steps,
            self.limits.linear_fallback,
        )) orelse return null;
        return .{ .start = span.start, .end = span.end, .slots = self.slots };
    }

    /// `(setA*)(setB*)...(setZ*)`: each run is maximal and the sets are
    /// pairwise disjoint. When a mandatory run exists it anchors the match
    /// end: the next anchor rune determines the run, a backward walk places
    /// the preceding captures and a forward walk extends the trailing
    /// nullable runs. A chain with no mandatory run matches at the search
    /// offset and extends greedily. A start inside a run or malformed UTF-8
    /// falls back to the general engine.
    fn findRunChain(self: *Workspace, state: *RunChainState, input: []const u8, search_start: usize) ?Match {
        return if (state.use_cache)
            self.findRunChainInner(true, state, input, search_start)
        else
            self.findRunChainInner(false, state, input, search_start);
    }

    inline fn findRunChainInner(self: *Workspace, comptime cached: bool, state: *RunChainState, input: []const u8, search_start: usize) ?Match {
        const plan = &state.plan;
        if (plan.forward) {
            // Overlapping sets: the first run is mandatory and every
            // mandatory run is separated from its predecessors, so the
            // greedy maxima are complete. A failed mandatory run cannot be
            // rescued by backtracking, so the general engine decides.
            var scan = search_start;
            while (scan < input.len) {
                const candidate = state.filter.indexOfRuneCandidates(input, scan) orelse return null;
                const rune = runeAt(input, candidate) orelse return null;
                if (!state.member(cached, rune.value, 0)) {
                    scan = candidate + rune.len;
                    continue;
                }
                var pos: [shapes.RunChain.max_items + 1]usize = undefined;
                pos[0] = candidate;
                var item: usize = 0;
                while (item < plan.count) : (item += 1) {
                    if (plan.empty[item]) {
                        pos[item + 1] = pos[item];
                        continue;
                    }
                    const end = state.runEndCached(cached, input, pos[item], item) orelse return null;
                    if (end == pos[item] and plan.minimum[item] != 0) return null;
                    pos[item + 1] = end;
                }
                self.fillRunChainSlots(plan, &pos, candidate, pos[plan.count]);
                return .{ .start = candidate, .end = pos[plan.count], .slots = self.slots };
            }
            return null;
        }
        if (plan.anchor == shapes.RunChain.no_anchor) {
            // Every run is nullable: the leftmost match starts at the search
            // offset and the greedy runs extend from there.
            if (search_start > input.len) return null;
            var pos: [shapes.RunChain.max_items + 1]usize = undefined;
            pos[0] = search_start;
            var item: usize = 0;
            while (item < plan.count) : (item += 1) {
                if (plan.empty[item]) {
                    pos[item + 1] = pos[item];
                    continue;
                }
                pos[item + 1] = state.runEndCached(cached, input, pos[item], item) orelse return null;
            }
            self.fillRunChainSlots(plan, &pos, search_start, pos[plan.count]);
            return .{ .start = search_start, .end = pos[plan.count], .slots = self.slots };
        }
        const anchor = plan.anchor;
        var scan = search_start;
        while (scan < input.len) {
            const candidate = state.filter.indexOfRuneCandidates(input, scan) orelse return null;
            const rune = runeAt(input, candidate) orelse return null;
            if (!state.member(cached, rune.value, anchor)) {
                scan = candidate + rune.len;
                continue;
            }
            var end = candidate + rune.len;
            var members: usize = 1;
            while (end < input.len) {
                const next = runeAt(input, end) orelse return null;
                if (!state.member(cached, next.value, anchor)) break;
                end += next.len;
                members += 1;
            }
            if (members < plan.minimum[anchor]) {
                scan = end;
                continue;
            }
            var pos: [shapes.RunChain.max_items + 1]usize = undefined;
            pos[anchor] = candidate;
            pos[anchor + 1] = end;
            var index = anchor;
            var retry = false;
            while (index > 0) {
                index -= 1;
                if (plan.empty[index]) {
                    pos[index] = pos[index + 1];
                    continue;
                }
                var start = pos[index + 1];
                var count: usize = 0;
                while (start > 0) {
                    const previous = runeBefore(input, start) orelse return null;
                    if (!state.member(cached, previous.value, index)) break;
                    start = previous.start;
                    count += 1;
                }
                if (count < plan.minimum[index]) {
                    retry = true;
                    break;
                }
                pos[index] = start;
            }
            if (retry) {
                scan = end;
                continue;
            }
            // A start inside a run would need the run clamped to the search
            // offset; the general engine owns that case.
            if (pos[0] < search_start) return null;
            var cursor = end;
            var trailing = anchor + 1;
            while (trailing < plan.count) : (trailing += 1) {
                pos[trailing] = cursor;
                if (!plan.empty[trailing]) {
                    cursor = state.runEndCached(cached, input, cursor, trailing) orelse return null;
                }
                pos[trailing + 1] = cursor;
            }
            self.fillRunChainSlots(plan, &pos, pos[0], cursor);
            return .{ .start = pos[0], .end = cursor, .slots = self.slots };
        }
        return null;
    }

    inline fn fillRunChainSlots(self: *Workspace, plan: *const shapes.RunChain, pos: *const [shapes.RunChain.max_items + 1]usize, start: usize, end: usize) void {
        var item: usize = 0;
        while (item < plan.count) : (item += 1) {
            if (plan.empty[item]) {
                self.slots[plan.start_slots[item]] = pos[item];
                self.slots[plan.end_slots[item]] = pos[item];
            } else {
                self.slots[plan.start_slots[item]] = pos[item];
                self.slots[plan.end_slots[item]] = pos[item + 1];
            }
        }
        self.slots[plan.match_start_slot] = start;
        self.slots[plan.match_end_slot] = end;
    }

    /// Zero-width assertions: edge assertions can only hold at the text
    /// edges or next to a line break, and ASCII word assertions at word-run
    /// edges, so enumerate those positions per alternation path instead of
    /// restarting the interpreter at every offset. Word paths are evaluated
    /// first so their usually-nearby candidates bound the line scans; ties
    /// are resolved by the plan order, which is the alternation order.
    fn findZeroWidth(self: *Workspace, plan: *const zero_width.Plan, input: []const u8, search_start: usize) ?Match {
        if (search_start > input.len) return null;
        var best_offset: usize = input.len;
        var best_index: usize = 0;
        var found = false;
        var pass: usize = 0;
        while (pass < 2) : (pass += 1) {
            for (plan.paths[0..plan.count], 0..) |*path, index| {
                const word = zero_width.wordMode(path) != .none;
                if ((pass == 0) != word) continue;
                const limit = if (found) best_offset else input.len;
                const candidate = self.zeroWidthCandidate(path, input, search_start, limit) orelse continue;
                if (!found or candidate < best_offset or (candidate == best_offset and index < best_index)) {
                    best_offset = candidate;
                    best_index = index;
                    found = true;
                }
            }
        }
        if (!found) return null;
        const path = &plan.paths[best_index];
        @memset(self.slots, unset);
        self.slots[0] = best_offset;
        self.slots[1] = best_offset;
        for (path.slots[0..path.slot_count]) |slot| self.slots[slot] = best_offset;
        return .{ .start = best_offset, .end = best_offset, .slots = self.slots };
    }

    fn zeroWidthCandidate(self: *Workspace, path: *const zero_width.Path, input: []const u8, search_start: usize, limit: usize) ?usize {
        switch (zero_width.wordMode(path)) {
            .none => {
                if (path.assertion_count == 0) return if (search_start <= limit) search_start else null;
                if (path.edge_fast) {
                    // Text-edge assertions only hold at the start, the final
                    // newline start and the end, so no line scan is needed.
                    if (search_start == 0 and self.zeroWidthAllows(path, input, 0)) return 0;
                    if (finalNewlineStart(input, self.program.newline)) |final| {
                        if (final >= search_start and final <= limit and self.zeroWidthAllows(path, input, final)) return final;
                    }
                    if (input.len >= search_start and input.len <= limit and self.zeroWidthAllows(path, input, input.len)) return input.len;
                    return null;
                }
                if (search_start <= limit and self.zeroWidthAllows(path, input, search_start)) return search_start;
                const mode = self.program.newline;
                // A break is at most two bytes (CRLF); start the scan far
                // enough back to include a break that ends at the search
                // offset (already checked above).
                var scan = search_start -| 2;
                while (nextLineBreak(input, scan, mode, limit)) |line_break| {
                    const start = line_break.start;
                    if (start > limit) break;
                    const after = start + line_break.len;
                    if (start > search_start and self.zeroWidthAllows(path, input, start)) return start;
                    if (after > search_start and after <= limit and self.zeroWidthAllows(path, input, after)) return after;
                    scan = after;
                }
                if (input.len > search_start and input.len <= limit and self.zeroWidthAllows(path, input, input.len)) return input.len;
                return null;
            },
            .boundary => {
                var from = search_start;
                while (nextWordBoundary(input, from)) |candidate| {
                    if (candidate > limit) return null;
                    if (self.zeroWidthAllows(path, input, candidate)) return candidate;
                    from = candidate + 1;
                }
                return null;
            },
            .non_boundary => {
                var from = search_start;
                while (nextNonBoundary(input, from)) |candidate| {
                    if (candidate > limit) return null;
                    if (self.zeroWidthAllows(path, input, candidate)) return candidate;
                    from = candidate + 1;
                }
                return null;
            },
        }
    }

    fn zeroWidthAllows(self: *Workspace, path: *const zero_width.Path, input: []const u8, offset: usize) bool {
        if (path.word_only) {
            const previous = offset > 0 and wordByte(input[offset - 1]);
            const next = offset < input.len and wordByte(input[offset]);
            const boundary = previous != next;
            for (path.assertions[0..path.assertion_count]) |kind| {
                switch (kind) {
                    .word_boundary => if (!boundary) return false,
                    .no_word_boundary => if (boundary) return false,
                    else => unreachable,
                }
            }
            return true;
        }
        const at = position(input, offset, self.program.newline);
        for (path.assertions[0..path.assertion_count]) |kind| {
            if (!at.allows(kind)) return false;
        }
        return true;
    }

    /// `set+` over an ASCII-only set: skip to the next member with the SIMD
    /// first-byte filter, then extend the run. The shape is deterministic, so
    /// no DFA state or backtracking stack is involved.
    fn findSetRun(self: *Workspace, set: model.Set, input: []const u8, search_start: usize) ?Match {
        _ = set;
        const table = &self.simple_set_table;
        var offset = search_start;
        // Match-dense input spends its time in short gaps, where a scalar scan
        // beats the vector filter's setup; long gaps switch to the SIMD scan.
        const scalar_limit = @min(input.len, offset + 32);
        while (offset < scalar_limit and !table[input[offset]]) offset += 1;
        if (offset >= scalar_limit) {
            if (offset >= input.len) return null;
            offset = self.first_filter.indexOf(input, offset) orelse return null;
        }
        const start = offset;
        offset += 1;
        while (offset < input.len and table[input[offset]]) offset += 1;
        self.slots[0] = start;
        self.slots[1] = offset;
        return .{ .start = start, .end = offset, .slots = self.slots };
    }

    /// Try the dominant alternation branch at `search_start`. Returns null
    /// when an earlier branch could start here or this branch does not match;
    /// the general engine then decides.
    /// `(?m)^.*$`: the match is the whole line at the next line start.
    fn findLineRun(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        if (search_start > input.len) return null;
        var start = search_start;
        if (start > 0 and input[start - 1] != '\n') {
            start = nextLineStart(input, start) orelse return null;
        }
        if (start > input.len) return null;
        const end = std.mem.indexOfScalarPos(u8, input, start, '\n') orelse input.len;
        self.slots[0] = start;
        self.slots[1] = end;
        return .{ .start = start, .end = end, .slots = self.slots };
    }

    /// `"[^"]*"` / `<[^>]+>`: the match is the next delimiter pair.
    fn findDelimitedRun(self: *Workspace, delimited: shapes.Delimited, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (true) {
            const open = indexOfDelimiter(input, search, delimited.open) orelse return null;
            const close = indexOfDelimiter(input, open + 1, delimited.close) orelse return null;
            if (!delimited.non_empty or close > open + 1) {
                self.slots[0] = open;
                self.slots[1] = close + 1;
                return .{ .start = open, .end = close + 1, .slots = self.slots };
            }
            // Empty inner run: the `+` form does not match, retry after open.
            search = open + 1;
        }
    }

    /// `\b\w+\b`: the match is the next whole word. The trailing boundary
    /// holds automatically once the run ends; only the leading one needs a
    /// check, and a run entered from the middle is skipped whole.
    fn findWordRun(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        const table = &self.word_run_table;
        var offset = search_start;
        while (offset < input.len) {
            while (offset < input.len and !table[input[offset]]) offset += 1;
            if (offset >= input.len) return null;
            if (offset > 0 and table[input[offset - 1]]) {
                // Started inside a word: no boundary here, skip the run.
                while (offset < input.len and table[input[offset]]) offset += 1;
                continue;
            }
            const start = offset;
            while (offset < input.len and table[input[offset]]) offset += 1;
            self.slots[0] = start;
            self.slots[1] = offset;
            return .{ .start = start, .end = offset, .slots = self.slots };
        }
        return null;
    }

    /// `\s*$`: the match is the trailing whitespace run, so scan back from
    /// the end to the first non-space byte.
    fn findTrailingSpaceRun(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        if (search_start > input.len) return null;
        var start = input.len;
        while (start > search_start and self.trailing_space_table[input[start - 1]]) start -= 1;
        self.slots[0] = start;
        self.slots[1] = input.len;
        return .{ .start = start, .end = input.len, .slots = self.slots };
    }

    /// `(?m)^[^d\n]+d`: scan each line from its start to the first delimiter.
    fn findLineDelimitedRun(self: *Workspace, delimited: shapes.LineDelimited, input: []const u8, search_start: usize) ?Match {
        var start = search_start;
        if (start > 0 and input[start - 1] != '\n') {
            start = nextLineStart(input, start) orelse return null;
        }
        while (start <= input.len) {
            var offset = start;
            while (offset < input.len and input[offset] != delimited.delimiter and input[offset] != '\n') {
                offset += 1;
            }
            if (offset > start and offset < input.len and input[offset] == delimited.delimiter) {
                self.slots[0] = start;
                self.slots[1] = offset + 1;
                return .{ .start = start, .end = offset + 1, .slots = self.slots };
            }
            if (offset >= input.len) return null;
            start = nextLineStart(input, offset) orelse return null;
        }
        return null;
    }

    /// `-?\d+(?:\.\d+)?`: sign, digit run, and an optional fraction whose
    /// dot must be followed by at least one digit.
    fn findNumberRun(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        const table = &self.number_table;
        var offset = search_start;
        while (offset < input.len) : (offset += 1) {
            const start = offset;
            var end = offset;
            if (input[start] == '-') {
                if (start + 1 >= input.len or !table[input[start + 1]]) continue;
                end = start + 1;
            } else if (!table[input[start]]) continue;
            while (end < input.len and table[input[end]]) end += 1;
            if (end + 1 < input.len and input[end] == '.' and table[input[end + 1]]) {
                end += 1;
                while (end < input.len and table[input[end]]) end += 1;
            }
            self.slots[0] = start;
            self.slots[1] = end;
            return .{ .start = start, .end = end, .slots = self.slots };
        }
        return null;
    }

    inline fn foldAsciiByte(byte: u8) u8 {
        return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
    }

    /// A pure `(?i)` literal. The folded pair filter proposes the earliest
    /// possible start; ASCII windows are verified here instead of entering
    /// the DFA, and windows with a non-ASCII byte fall back to it for
    /// Unicode simple folding.
    fn findCaselessLiteral(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        const literal = self.program.caseless_literal.?;
        for (literal) |byte| if (byte >= 0x80) return null;
        const filter = self.fold_filter orelse return null;
        var search = search_start;
        while (true) {
            const start = filter.indexOf(input, search) orelse return null;
            if (start + literal.len > input.len) return null;
            var matched = true;
            for (literal, 0..) |literal_byte, index| {
                const byte = input[start + index];
                if (byte >= 0x80) return null;
                if (foldAsciiByte(byte) != foldAsciiByte(literal_byte)) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                self.slots[0] = start;
                self.slots[1] = start + literal.len;
                return .{ .start = start, .end = start + literal.len, .slots = self.slots };
            }
            search = start + 1;
        }
    }

    /// A pure alternation of exact literals. The pair/first filter proposes
    /// the earliest candidate; the alternatives are checked in source order
    /// at that position, which is exactly leftmost-first for literals.
    fn findLiteralSet(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        const literals = self.program.literal_set.?;
        var search = search_start;
        while (search < input.len) {
            const start = if (self.literal_set_filter) |*filter|
                filter.indexOf(input, search) orelse return null
            else if (self.pair_filter) |filter|
                filter.indexOfAny(input, search) orelse return null
            else
                self.first_filter.indexOf(input, search) orelse return null;
            for (literals) |literal| {
                if (start + literal.len <= input.len and std.mem.eql(u8, input[start..][0..literal.len], literal)) {
                    self.slots[0] = start;
                    self.slots[1] = start + literal.len;
                    return .{ .start = start, .end = start + literal.len, .slots = self.slots };
                }
            }
            search = start + 1;
        }
        return null;
    }

    /// `set+ literal` where the literal's first byte is not a member, so the
    /// run ends exactly at the literal. The required literal is searched
    /// directly and the match start is the maximal run before it.
    fn findRunThenLiteral(self: *Workspace, state: *const RunThenLiteral, input: []const u8, search_start: usize) ?Match {
        const literal = state.literal[0..state.literal_len];
        const set = state.set;
        var search = search_start;
        while (true) {
            const found = indexOfLiteral(input, search, literal) orelse return null;
            if (found == search_start or found == 0) {
                search = found + 1;
                continue;
            }
            if (!set.matches(@as(u21, input[found - 1]))) {
                search = found + 1;
                continue;
            }
            var start = found - 1;
            while (start > 0 and set.matches(@as(u21, input[start - 1]))) start -= 1;
            if (start < search_start) start = search_start;
            self.slots[0] = start;
            self.slots[1] = found + literal.len;
            return .{ .start = start, .end = found + literal.len, .slots = self.slots };
        }
    }

    /// Fixed-width concatenation of single-rune sets and literal bytes.
    /// The first element drives the candidate scan; each candidate checks
    /// the remaining bytes with byte tables.
    fn findFixedSequence(self: *Workspace, state: *const FixedSequence, input: []const u8, search_start: usize) ?Match {
        const len: usize = state.len;
        if (search_start > input.len or input.len - search_start < len) return null;
        const first_literal = state.literal[0];
        const first_value = state.value[0];
        const limit = input.len - len;
        var start = search_start;
        while (start <= limit) : (start += 1) {
            if (first_literal) {
                if (input[start] != first_value) continue;
            } else if (!state.tables[first_value][input[start]]) continue;
            var index: usize = 1;
            while (index < len) : (index += 1) {
                const byte = input[start + index];
                if (state.literal[index]) {
                    if (byte != state.value[index]) break;
                } else if (!state.tables[state.value[index]][byte]) break;
            }
            if (index == len) {
                self.slots[0] = start;
                self.slots[1] = start + len;
                return .{ .start = start, .end = start + len, .slots = self.slots };
            }
        }
        return null;
    }

    /// `(?m)^set+`: the match starts exactly at a line start, so each line
    /// start only needs the maximal run scan; lines that start outside the
    /// set are skipped with a newline search.
    fn findLineStartRun(self: *Workspace, state: *const LineStartRun, input: []const u8, search_start: usize) ?Match {
        const table = &state.table;
        var line = search_start;
        if (line > 0 and input[line - 1] != '\n') {
            line = std.mem.indexOfScalarPos(u8, input, line, '\n') orelse return null;
            line += 1;
        }
        while (line < input.len) {
            if (table[input[line]]) {
                var end = line + 1;
                while (end < input.len and table[input[end]]) end += 1;
                self.slots[0] = line;
                self.slots[1] = end;
                return .{ .start = line, .end = end, .slots = self.slots };
            }
            line = std.mem.indexOfScalarPos(u8, input, line, '\n') orelse return null;
            line += 1;
        }
        return null;
    }

    /// Bounded set-run concatenation. Candidates are scanned on the first
    /// element; the matcher consumes each run greedily and backtracks down
    /// to its minimum, matching the engine's greedy order. A small step
    /// budget bails to the general engine on pathological shapes.
    fn findBoundedSequence(self: *Workspace, state: *const BoundedSequenceState, input: []const u8, search_start: usize) ?Match {
        if (search_start >= input.len) return null;
        const first = state.elements[0];
        const table = &state.tables[first.set];
        var start = search_start;
        while (start < input.len) : (start += 1) {
            if (!table[input[start]]) continue;
            // The greedy walk decides the common case without recursion;
            // only ambiguous candidates need the backtracking matcher.
            if (matchBoundedGreedy(state, input, start)) |end| {
                self.slots[0] = start;
                self.slots[1] = end;
                return .{ .start = start, .end = end, .slots = self.slots };
            }
            var budget: usize = 64;
            if (matchBounded(state, input, start, 0, &budget)) |end| {
                self.slots[0] = start;
                self.slots[1] = end;
                return .{ .start = start, .end = end, .slots = self.slots };
            }
        }
        return null;
    }

    fn matchBoundedGreedy(state: *const BoundedSequenceState, input: []const u8, start: usize) ?usize {
        var pos = start;
        var index: usize = 0;
        while (index < state.len) : (index += 1) {
            const element = state.elements[index];
            const table = &state.tables[element.set];
            var count: usize = 0;
            const limit = @min(@as(usize, element.max), input.len - pos);
            while (count < limit and table[input[pos + count]]) count += 1;
            if (count < element.min) return null;
            pos += count;
        }
        return pos;
    }

    fn matchBounded(state: *const BoundedSequenceState, input: []const u8, pos: usize, index: usize, budget: *usize) ?usize {
        if (budget.* == 0) return null;
        budget.* -= 1;
        if (index == state.len) return pos;
        const element = state.elements[index];
        const table = &state.tables[element.set];
        var count: usize = 0;
        const limit = @min(@as(usize, element.max), input.len - pos);
        while (count < limit and table[input[pos + count]]) count += 1;
        if (count < element.min) return null;
        while (count >= element.min) : (count -= 1) {
            if (matchBounded(state, input, pos + count, index + 1, budget)) |end| return end;
        }
        return null;
    }

    /// Unbounded run chain: each run is maximal and the following literal's
    /// first byte is outside the run set, so the flat walk needs no
    /// backtracking.
    fn findUnboundedSequence(self: *Workspace, state: *const UnboundedSequenceState, input: []const u8, search_start: usize) ?Match {
        if (search_start >= input.len) return null;
        var start = search_start;
        while (start < input.len) : (start += 1) {
            if (!state.first_table[input[start]]) continue;
            var pos = start;
            var index: usize = 0;
            while (index < state.len) : (index += 1) {
                const element = state.elements[index];
                switch (element.kind) {
                    .run => {
                        const table = &state.tables[element.value];
                        const begin = pos;
                        while (pos < input.len and table[input[pos]]) pos += 1;
                        if (pos == begin) break;
                    },
                    .literal => {
                        const bytes = state.literal_bytes[element.value..][0..element.len];
                        if (pos + bytes.len > input.len or !std.mem.eql(u8, input[pos..][0..bytes.len], bytes)) break;
                        pos += bytes.len;
                    },
                    .optional => {
                        if (pos < input.len and input[pos] == element.value) pos += 1;
                    },
                }
            }
            if (index == state.len) {
                self.slots[0] = start;
                self.slots[1] = pos;
                return .{ .start = start, .end = pos, .slots = self.slots };
            }
        }
        return null;
    }

    fn findFastBranch(self: *Workspace, branch: *FastBranch, input: []const u8, search_start: usize) ?Match {
        if (search_start >= input.len) return null;
        if (branch.prior.first.allowsByte(input[search_start])) return null;
        // Greedy optional prefix first: one prefix rune followed by a run.
        if (branch.prefix) |*prefix| {
            if (prefix.runeAt(self.allocator, input, search_start)) |prefix_len| {
                const next = search_start + prefix_len;
                // A non-ASCII rune is validated by `runEnd` itself, which
                // saves re-walking it; ASCII keeps the cheaper table gate so
                // failed prefix attempts do not enter the run scan.
                if (next < input.len and
                    (input[next] >= 0x80 or branch.run.runeAt(self.allocator, input, next) != null))
                {
                    const end = branch.run.runEndAsciiFirst(self.allocator, input, next);
                    if (end > next) {
                        self.slots[0] = search_start;
                        self.slots[1] = end;
                        return .{ .start = search_start, .end = end, .slots = self.slots };
                    }
                }
            }
        }
        if (input[search_start] >= 0x80 or branch.run.runeAt(self.allocator, input, search_start) != null) {
            const end = branch.run.runEndAsciiFirst(self.allocator, input, search_start);
            if (end > search_start) {
                self.slots[0] = search_start;
                self.slots[1] = end;
                return .{ .start = search_start, .end = end, .slots = self.slots };
            }
        }
        // The dominant branch failed and every earlier branch is ruled out;
        // try the following branches that have a direct scan.
        if (branch.later) |later_list| {
            if (!branch.later_first[input[search_start]]) return null;
            for (later_list) |*later| {
                switch (later.kind) {
                    .single => {
                        // The direct scans use the ASCII tables; non-ASCII
                        // tokens stay on the DFA, which is faster for them.
                        if (input[search_start] >= 0x80) continue;
                        const len = later.run.runeAt(self.allocator, input, search_start) orelse continue;
                        const end = search_start + len;
                        self.slots[0] = search_start;
                        self.slots[1] = end;
                        return .{ .start = search_start, .end = end, .slots = self.slots };
                    },
                    .run => {
                        if (input[search_start] >= 0x80) continue;
                        if (later.run.runeAt(self.allocator, input, search_start) == null) continue;
                        const end = later.run.runEnd(self.allocator, input, search_start);
                        self.slots[0] = search_start;
                        self.slots[1] = end;
                        return .{ .start = search_start, .end = end, .slots = self.slots };
                    },
                    .prefix_run_tail => {
                        var pos = search_start;
                        if (later.prefix) |*prefix| {
                            if (prefix.runeAt(self.allocator, input, pos)) |len| pos += len;
                        }
                        if (pos >= input.len or input[pos] >= 0x80) continue;
                        if (later.run.runeAt(self.allocator, input, pos) == null) continue;
                        var end = later.run.runEnd(self.allocator, input, pos);
                        if (later.tail) |*tail| end = tail.runEnd(self.allocator, input, end);
                        self.slots[0] = search_start;
                        self.slots[1] = end;
                        return .{ .start = search_start, .end = end, .slots = self.slots };
                    },
                    .whitespace => {
                        // `\s*[\r\n]+` matches through the last newline in
                        // the whitespace run; `\s+(?!\S)` backtracks one
                        // space when the run is followed by text, and the
                        // bare `\s+` takes the whole run otherwise.
                        const end = later.run.runEnd(self.allocator, input, search_start);
                        if (end == search_start) continue;
                        var match_end = end;
                        if (later.newline_branch) {
                            var last_newline: ?usize = null;
                            var scan = search_start;
                            while (scan < end) : (scan += 1) {
                                if (input[scan] == '\n' or input[scan] == '\r') last_newline = scan;
                            }
                            if (last_newline) |at| {
                                match_end = at + 1;
                            } else if (later.lookahead_branch and end < input.len and end - search_start >= 2) {
                                match_end = end - 1;
                            }
                        } else if (later.lookahead_branch and end < input.len and end - search_start >= 2) {
                            match_end = end - 1;
                        }
                        self.slots[0] = search_start;
                        self.slots[1] = match_end;
                        return .{ .start = search_start, .end = match_end, .slots = self.slots };
                    },
                }
            }
        }
        return null;
    }

    fn findSetRunUtf8(self: *Workspace, utf8: *deferred_utf8.CompactRun, input: []const u8, search_start: usize) ?Match {
        const found = utf8_run_search.findDeferred(utf8, self.allocator, &self.simple_set_table, &self.first_filter, input, search_start);
        if (found.prepared) self.fast_kind = .utf8_run_prepared;
        const span = found.span orelse return null;
        self.slots[0] = span.start;
        self.slots[1] = span.end;
        return .{ .start = span.start, .end = span.end, .slots = self.slots };
    }

    fn findPreparedSetRunUtf8(self: *Workspace, utf8: *const deferred_utf8.CompactRun, input: []const u8, search_start: usize) ?Match {
        const span = utf8_run_search.findPrepared(&utf8.table.?, &self.first_filter, input, search_start) orelse return null;
        self.slots[0] = span.start;
        self.slots[1] = span.end;
        return .{ .start = span.start, .end = span.end, .slots = self.slots };
    }

    /// `setA+ separator setB+ tail` search. The separator cannot start a
    /// `setA` run and the tail cannot start a `setB` run, so each separator
    /// occurrence determines the match: the first non-`setA` rune before it
    /// is the start, and the first non-`setB` rune after it is the end.
    fn findChain(self: *Workspace, chain: *const shapes.Chain, input: []const u8, search_start: usize) ?Match {
        if (chain.separator_set) |set_s| return self.findChainSet(chain, set_s, input, search_start);
        var scan = search_start;
        while (true) {
            const separator_at = indexOfLiteral(input, scan, chain.separator[0..chain.separator_len]) orelse return null;
            if (self.chainMatch(chain, input, separator_at, separator_at + chain.separator_len, search_start)) |match| return match;
            scan = separator_at + 1;
        }
    }

    /// `literal [optional] literal set+`: anchor on the fixed prefix, verify
    /// the optional byte and the middle, then scan the maximal run. The ASCII
    /// membership table answers the common case; a non-ASCII byte switches to
    /// the deferred UTF-8 run scan.
    fn findLiteralRun(self: *Workspace, state: *LiteralRunState, input: []const u8, search_start: usize) ?Match {
        const shape = &state.shape;
        var search = search_start;
        while (true) {
            const start = indexOfLiteral(input, search, shape.prefix) orelse return null;
            var pos = start + shape.prefix.len;
            if (shape.optional) |byte| {
                if (pos < input.len and input[pos] == byte) pos += 1;
            }
            const middle = shape.middle[0..shape.middle_len];
            if (middle.len <= input.len - pos and std.mem.eql(u8, input[pos..][0..middle.len], middle)) {
                pos += middle.len;
                if (pos < input.len) {
                    var end = pos;
                    while (end < input.len and input[end] < 0x80 and state.table[input[end]]) end += 1;
                    if (end < input.len and input[end] >= 0x80) end = state.run.runEnd(self.allocator, input, end);
                    if (end > pos) {
                        self.slots[0] = start;
                        self.slots[1] = end;
                        return .{ .start = start, .end = end, .slots = self.slots };
                    }
                }
            }
            search = start + 1;
        }
    }

    /// Chain with a set-run separator (`\w+\s+\w+`): each separator run is
    /// tried in order, and the whole run is skipped when it fails. The SIMD
    /// separator filter jumps between candidates, and the cached byte tables
    /// answer membership without the rune-range binary search.
    fn findChainSet(self: *Workspace, chain: *const shapes.Chain, set_s: model.Set, input: []const u8, search_start: usize) ?Match {
        const tables = if (self.chain_tables) |*value| value else return self.findChainSetSlow(chain, set_s, input, search_start);
        var scan = search_start;
        while (scan < input.len) {
            var run_start: ?usize = null;
            var pos = scan;
            while (pos < input.len and !tables.s[input[pos]]) {
                if (tables.a[input[pos]]) {
                    if (run_start == null) run_start = pos;
                } else run_start = null;
                pos += 1;
            }
            if (pos >= input.len) return null;
            const separator_at = pos;
            while (pos < input.len and tables.s[input[pos]]) pos += 1;
            const separator_end = pos;
            if (chain.star_a) {
                if (run_start) |start| {
                    if (separator_at - start >= chain.min_a) {
                        if (self.chainMatchFrom(chain, input, start, separator_at, separator_end)) |match| return match;
                    }
                }
            } else if (separator_at >= chain.min_a) {
                const start = separator_at - chain.min_a;
                if (start >= search_start and allSetBytes(&tables.a, input[start..separator_at])) {
                    if (self.chainMatchFrom(chain, input, start, separator_at, separator_end)) |match| return match;
                }
            }
            scan = separator_end;
        }
        return null;
    }

    /// Table-free fallback for callers without a cached chain table.
    fn findChainSetSlow(self: *Workspace, chain: *const shapes.Chain, set_s: model.Set, input: []const u8, search_start: usize) ?Match {
        var scan = search_start;
        while (scan < input.len) {
            var run_start: ?usize = null;
            var pos = scan;
            while (pos < input.len and !set_s.matches(input[pos])) {
                if (chain.set_a.matches(input[pos])) {
                    if (run_start == null) run_start = pos;
                } else run_start = null;
                pos += 1;
            }
            if (pos >= input.len) return null;
            const separator_at = pos;
            while (pos < input.len and set_s.matches(input[pos])) pos += 1;
            const separator_end = pos;
            if (chain.star_a) {
                if (run_start) |start| {
                    if (separator_at - start >= chain.min_a) {
                        if (self.chainMatchFrom(chain, input, start, separator_at, separator_end)) |match| return match;
                    }
                }
            } else if (self.chainMatch(chain, input, separator_at, separator_end, search_start)) |match| {
                return match;
            }
            scan = separator_end;
        }
        return null;
    }

    /// Try the match determined by one separator occurrence: the run before
    /// it (unbounded, or a fixed count for shapes like `\d{3}-\d{4}`), the
    /// run after it, and the literal tail.
    fn chainMatch(self: *Workspace, chain: *const shapes.Chain, input: []const u8, separator_at: usize, separator_end: usize, search_start: usize) ?Match {
        var start: usize = undefined;
        if (chain.star_a) {
            start = chainRunStart(input, chain.set_a, separator_at, search_start);
            if (separator_at - start < chain.min_a) return null;
        } else {
            if (separator_at < chain.min_a) return null;
            start = separator_at - chain.min_a;
            if (start < search_start) return null;
            const matched = if (self.chain_tables) |*tables|
                allSetBytes(&tables.a, input[start..separator_at])
            else
                allSetMatches(chain.set_a, input[start..separator_at]);
            if (!matched) return null;
        }
        return self.chainMatchFrom(chain, input, start, separator_at, separator_end);
    }

    fn chainMatchFrom(self: *Workspace, chain: *const shapes.Chain, input: []const u8, start: usize, separator_at: usize, separator_end: usize) ?Match {
        const run_from = separator_end;
        var match_end: usize = 0;
        var run_end: usize = run_from;
        if (chain.set_b) |set_b| {
            if (chain.star_b) {
                run_end = if (self.chain_tables) |*tables|
                    chainRunEndTable(input, &tables.b, run_from, set_b)
                else
                    chainRunEnd(input, set_b, run_from);
                if (run_end - run_from < chain.min_b) return null;
            } else {
                run_end = run_from + chain.min_b;
                if (run_end > input.len) return null;
                const matched = if (self.chain_tables) |*tables|
                    allSetBytes(&tables.b, input[run_from..run_end])
                else
                    allSetMatches(set_b, input[run_from..run_end]);
                if (!matched) return null;
            }
            if (!tailMatches(input, run_end, chain.tail[0..chain.tail_len])) return null;
            match_end = run_end + chain.tail_len;
        } else {
            if (!tailMatches(input, run_from, chain.tail[0..chain.tail_len])) return null;
            match_end = run_from + chain.tail_len;
        }
        self.slots[0] = start;
        self.slots[1] = match_end;
        if (chain.slot_a != 0) {
            self.slots[chain.slot_a] = start;
            self.slots[chain.slot_a + 1] = separator_at;
        }
        if (chain.slot_b != 0) {
            self.slots[chain.slot_b] = run_from;
            self.slots[chain.slot_b + 1] = run_end;
        }
        return .{ .start = start, .end = match_end, .slots = self.slots };
    }

    /// `set+` ending in a line/text-end assertion: the only candidate end is
    /// the maximal run end, so scan runs and check the assertion once. When
    /// it fails, every start inside the run fails too and the scan resumes
    /// after the run.
    fn findAnchoredRun(self: *Workspace, anchored: AnchoredRun, input: []const u8, search_start: usize) ?Match {
        const set = anchored.set;
        const kind = anchored.kind;
        var offset = search_start;
        while (offset < input.len) {
            if (!set.matches(input[offset])) {
                offset = self.first_filter.indexOf(input, offset) orelse return null;
                if (offset >= input.len) return null;
                if (!set.matches(input[offset])) {
                    offset += 1;
                    continue;
                }
            }
            const start = offset;
            while (offset < input.len and set.matches(input[offset])) offset += 1;
            if (position(input, offset, self.program.newline).allows(kind)) {
                self.slots[0] = start;
                self.slots[1] = offset;
                return .{ .start = start, .end = offset, .slots = self.slots };
            }
            if (offset >= input.len) return null;
            offset += 1;
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
                    // A greedy `\C+` loop is a split whose left branch is the
                    // same single `.byte` looping back. Every byte matches, so
                    // consume the whole tail with one backtrack record.
                    if (!split.alternation) {
                        const body = self.program.instructions[split.left];
                        if (body == .byte and body.byte == pc) {
                            const scan_start = pos;
                            if (pos < input.len) {
                                if (count == choices.len) return self.run(input, start);
                                choices[count] = .{
                                    .pc = split.right,
                                    .pos = input.len,
                                    .trail_len = 0,
                                    .limit = scan_start,
                                    .byte_loop = true,
                                };
                                count += 1;
                                pos = input.len;
                            }
                            pc = split.right;
                            continue;
                        }
                    }
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
                .assertion => |*assertion| if (position(input, pos, self.program.newline).allows(assertion.kind)) {
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
            if (choice.byte_loop) {
                // Retry the loop exit one byte earlier.
                if (choice.pos > choice.limit) {
                    const prev = choice.pos - 1;
                    if (count == choices.len) return self.run(input, start);
                    choices[count] = .{
                        .pc = choice.pc,
                        .pos = prev,
                        .trail_len = 0,
                        .limit = choice.limit,
                        .byte_loop = true,
                    };
                    count += 1;
                    pc = choice.pc;
                    pos = prev;
                    continue;
                }
                continue;
            }
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
        // Keep the hot loop's budget and instruction table in locals: the
        // choice/trail appends may alias `self`, which would otherwise force
        // a reload on every step.
        const instructions = self.program.instructions;
        const max_steps = self.limits.max_execution_steps;
        var steps = self.steps;
        defer self.steps = steps;
        // Slot 0 was set by the caller; the initial save is redundant.
        var pc = self.program.body;
        var pos = start;
        var best_end: ?usize = null;
        while (true) {
            steps += 1;
            if (steps > max_steps) {
                return error.RegexLimitExceeded;
            }
            switch (instructions[pc]) {
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
                    // ASCII-only sets never match a non-ASCII byte, so the
                    // common case skips the UTF-8 decode in `matchAdvance`.
                    if (consume.set.ascii_only) {
                        if (pos < input.len and consume.set.matches(input[pos])) {
                            pos += 1;
                            pc = consume.next;
                            continue;
                        }
                    } else if (consume.set.matchAdvance(input, pos)) |next| {
                        pos = next;
                        pc = consume.next;
                        continue;
                    }
                },
                .star => |*star| {
                    const scan_start = pos;
                    const scan_budget = max_steps -| steps;
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
                    steps += consumed;
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
                    // Greedy `\C+` loop: consume the tail with one choice.
                    if (!split.alternation) {
                        const body = instructions[split.left];
                        if (body == .byte and body.byte == pc) {
                            const scan_start = pos;
                            if (pos < input.len) {
                                if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                                    return error.RegexLimitExceeded;
                                }
                                try self.choices.append(self.allocator, .{
                                    .pc = split.right,
                                    .pos = input.len,
                                    .trail_len = self.trail.items.len,
                                    .limit = scan_start,
                                    .byte_loop = true,
                                });
                                pos = input.len;
                            }
                            pc = split.right;
                            continue;
                        }
                    }
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
                    if (position(input, pos, self.program.newline).allows(assertion.kind)) {
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
            if (choice.byte_loop) {
                if (choice.pos > choice.limit) {
                    const prev = choice.pos - 1;
                    if (self.choices.items.len >= self.limits.max_backtrack_choices) {
                        return error.RegexLimitExceeded;
                    }
                    try self.choices.append(self.allocator, .{
                        .pc = choice.pc,
                        .pos = prev,
                        .trail_len = choice.trail_len,
                        .limit = choice.limit,
                        .byte_loop = true,
                    });
                    pc = choice.pc;
                    pos = prev;
                    continue;
                }
                continue;
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
                pc = instructions[choice.pc].star.next;
                pos = prev;
                continue;
            }
            pc = choice.pc;
            pos = choice.pos;
        }
    }
};

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

/// Build the multi-literal absence filter for wide start-literal
/// alternations whose literals do not share a first byte (the multi-literal
/// start filter handles the shared case).
fn buildPairFilter(allocator: std.mem.Allocator, program: Program) std.mem.Allocator.Error!?*prefilter.PairSet {
    const literals = program.start_literals orelse return null;
    if (literals.len < 2) return null;
    if (prefilter.MultiFilter.init(literals) != null) return null;
    const set = prefilter.PairSet.init(literals) orelse return null;
    const filter = try allocator.create(prefilter.PairSet);
    filter.* = set;
    return filter;
}

/// `save0 -> consume(set) -> star(set) -> assertion -> save1 -> accept`
/// where the assertion is a line/text-end check and the set cannot consume a
/// newline. Then only the maximal run end can satisfy the assertion.
fn detectAnchoredRun(program: Program) ?AnchoredRun {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len != 8) return null;
    if (program.accept != 0 or program.start != 7 or program.body != 6) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret or std.meta.activeTag(ins[3]) != .save or
        std.meta.activeTag(ins[4]) != .assertion or std.meta.activeTag(ins[5]) != .star or
        std.meta.activeTag(ins[6]) != .consume or std.meta.activeTag(ins[7]) != .save) return null;
    const save1 = ins[3].save;
    if (save1.slot != 1 or save1.next != program.accept) return null;
    const assertion = ins[4].assertion;
    if (assertion.next != 3) return null;
    const star = ins[5].star;
    if (star.next != 4) return null;
    const consume = ins[6].consume;
    if (consume.next != 5) return null;
    const save0 = ins[7].save;
    if (save0.slot != 0 or save0.next != 6) return null;
    if (!shapes.sameSet(consume.set, star.set)) return null;
    switch (assertion.kind) {
        .end_line, .end_text, .end_text_or_newline => {},
        else => return null,
    }
    if (!consume.set.ascii_only) return null;
    if (consume.set.matches('\n') or consume.set.matches('\r')) return null;
    return .{ .kind = assertion.kind, .set = consume.set };
}

/// Whether the body begins with a mandatory multiline `^`.
fn startsAtLineStart(program: Program) bool {
    const ins = program.instructions;
    var pc = program.body;
    var steps: usize = 0;
    while (steps < 8) : (steps += 1) {
        if (pc >= ins.len) return false;
        switch (ins[pc]) {
            .save => |save| pc = save.next,
            .reset_captures => |reset| pc = reset.next,
            .assertion => |assertion| return assertion.kind == .start_line,
            else => return false,
        }
    }
    return false;
}

/// First line start after `start`.
fn nextLineStart(input: []const u8, start: usize) ?usize {
    const found = prefilter.indexOfByte(input, start, '\n') orelse return null;
    return found + 1;
}

/// Whether the body begins with a mandatory text-start assertion (`\A` or
/// `^` outside multiline mode).
fn startsAtTextStart(program: Program) bool {
    const ins = program.instructions;
    var pc = program.body;
    var steps: usize = 0;
    while (steps < 8) : (steps += 1) {
        if (pc >= ins.len) return false;
        switch (ins[pc]) {
            .save => |save| pc = save.next,
            .reset_captures => |reset| pc = reset.next,
            .assertion => |assertion| return assertion.kind == .start_text,
            else => return false,
        }
    }
    return false;
}

/// The single-set unbounded loop that starts the program body, if any.
fn detectPrefixSet(program: Program) ?model.Set {
    const ins = program.instructions;
    if (program.body >= ins.len) return null;
    switch (ins[program.body]) {
        .star => |star| return star.set,
        .split => |split| {
            if (singleSetLoop(ins, split.left, program.body)) |set| return set;
            if (singleSetLoop(ins, split.right, program.body)) |set| return set;
            return null;
        },
        .consume => |consume| {
            // `set+` over a multi-member set: the mandatory member followed
            // by the loop over the same set. The run from a failed start
            // reaches the same continuation, so later starts inside it fail
            // too.
            if (consume.next >= ins.len or std.meta.activeTag(ins[consume.next]) != .star) return null;
            const star = ins[consume.next].star;
            if (!shapes.sameSet(consume.set, star.set)) return null;
            return consume.set;
        },
        else => return null,
    }
}

fn singleSetLoop(ins: []const model.Instruction, start: usize, target: usize) ?model.Set {
    if (start >= ins.len) return null;
    return switch (ins[start]) {
        .consume => |consume| if (consume.next == target) consume.set else null,
        else => null,
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

/// Decode the rune ending at `end`. Null for malformed or truncated UTF-8,
/// which makes the caller fall back to the general engine.
fn runeBefore(input: []const u8, end: usize) ?struct { value: u21, start: usize } {
    if (end == 0 or end > input.len) return null;
    var start = end - 1;
    var steps: usize = 0;
    while ((input[start] & 0xC0) == 0x80) {
        if (steps == 3 or start == 0) return null;
        start -= 1;
        steps += 1;
    }
    if (end - start > 4) return null;
    const value = std.unicode.utf8Decode(input[start..end]) catch return null;
    return .{ .value = value, .start = start };
}

inline fn wordByte(byte: u8) bool {
    return byte == '_' or
        (byte >= 'a' and byte <= 'z') or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= '0' and byte <= '9');
}

/// Next position at or after `from` where the ASCII word-ness changes.
fn nextWordBoundary(input: []const u8, from: usize) ?usize {
    if (from > input.len) return null;
    var cursor = from;
    var previous = cursor > 0 and wordByte(input[cursor - 1]);
    while (cursor < input.len) {
        const next = wordByte(input[cursor]);
        if (previous != next) return cursor;
        previous = next;
        cursor += runeLenAt(input, cursor);
    }
    return if (previous) input.len else null;
}

/// Next position at or after `from` where the ASCII word-ness is unchanged.
fn nextNonBoundary(input: []const u8, from: usize) ?usize {
    if (from > input.len) return null;
    var cursor = from;
    var previous = cursor > 0 and wordByte(input[cursor - 1]);
    while (cursor < input.len) {
        const next = wordByte(input[cursor]);
        if (previous == next) return cursor;
        previous = next;
        cursor += runeLenAt(input, cursor);
    }
    return if (!previous) input.len else null;
}

/// Start of a line break that ends at the text end, if any.
fn finalNewlineStart(input: []const u8, mode: model.Newline) ?usize {
    if (input.len == 0) return null;
    const last = input[input.len - 1];
    return switch (mode) {
        .lf => if (last == '\n') input.len - 1 else null,
        .cr => if (last == '\r') input.len - 1 else null,
        .nul => if (last == 0) input.len - 1 else null,
        .crlf => if (input.len >= 2 and input[input.len - 2] == '\r' and last == '\n') input.len - 2 else null,
        .anycrlf => blk: {
            if (input.len >= 2 and input[input.len - 2] == '\r' and last == '\n') break :blk input.len - 2;
            if (last == '\r') break :blk input.len - 1;
            if (last == '\n') break :blk input.len - 1;
            break :blk null;
        },
        .any => null,
    };
}

const LineBreak = struct { start: usize, len: usize };

/// Next line break at or after `from` for the program's newline convention.
/// `(*ANY)` is rejected at compile time because its Unicode breaks need
/// rune-level scanning.
fn nextLineBreak(input: []const u8, from: usize, mode: model.Newline, limit: usize) ?LineBreak {
    // Only break starts at or before `limit` can produce a candidate that
    // beats the current best, so the scan window is bounded there.
    const end = @min(limit + 1, input.len);
    if (from >= end) return null;
    const window = input[0..end];
    var offset = from;
    while (offset < end) {
        switch (mode) {
            .lf => {
                const found = prefilter.indexOfByte(window, offset, '\n') orelse return null;
                return .{ .start = found, .len = 1 };
            },
            .cr => {
                const found = prefilter.indexOfByte(window, offset, '\r') orelse return null;
                return .{ .start = found, .len = 1 };
            },
            .nul => {
                const found = prefilter.indexOfByte(window, offset, 0) orelse return null;
                return .{ .start = found, .len = 1 };
            },
            .crlf => {
                const found = prefilter.indexOfByte(window, offset, '\r') orelse return null;
                if (found + 1 < input.len and input[found + 1] == '\n') return .{ .start = found, .len = 2 };
                offset = found + 1;
            },
            .anycrlf => {
                const cr = prefilter.indexOfByte(window, offset, '\r');
                const lf = prefilter.indexOfByte(window, offset, '\n');
                const found = @min(cr orelse end, lf orelse end);
                if (found >= end) return null;
                if (input[found] == '\r') {
                    return .{ .start = found, .len = if (found + 1 < input.len and input[found + 1] == '\n') 2 else 1 };
                }
                // A `\n` preceded by `\r` belongs to the pair already returned.
                if (found > 0 and input[found - 1] == '\r') {
                    offset = found + 1;
                    continue;
                }
                return .{ .start = found, .len = 1 };
            },
            .any => return null,
        }
    }
    return null;
}

fn runeLenAt(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return 1;
    if (input[offset] < 0x80) return 1;
    return if (runeAt(input, offset)) |rune| rune.len else 1;
}

/// Start of the maximal `set` run ending at `separator_at`, clamped to
/// `floor`. Bytes outside an ASCII-only set never match, so the backward
/// scan is byte-wise in that case.
/// A dominant alternation branch (`set? setB+`) with its UTF-8 automata.
/// When the byte at the search start cannot begin an earlier branch, this
/// branch alone decides the match, so a dedicated run scan replaces the DFA.
const LaterRun = struct {
    kind: fast_branch_mod.LaterKind,
    prefix: ?deferred_utf8.Run,
    run: deferred_utf8.Run,
    tail: ?deferred_utf8.Run,
    newline_branch: bool = false,
    lookahead_branch: bool = false,

    fn deinit(self: *LaterRun, allocator: std.mem.Allocator) void {
        if (self.prefix) |*prefix| prefix.deinit(allocator);
        self.run.deinit(allocator);
        if (self.tail) |*tail| tail.deinit(allocator);
    }
};

/// The multi-literal pair filter is best for sparse first-byte sets; wider
/// sets use the nibble-table candidate filter from `PairSet` instead.
fn literalSetFilter(literals: []const []const u8) ?prefilter.MultiFilter {
    var seen = [_]bool{false} ** 256;
    var distinct: usize = 0;
    for (literals) |literal| {
        const byte = literal[0];
        if (!seen[byte]) {
            seen[byte] = true;
            distinct += 1;
            if (distinct > 8) return null;
        }
    }
    return prefilter.MultiFilter.initAny(literals);
}

/// `save0 -> consume(set) -> star(set) -> literal bytes -> save1 -> accept`
/// where the literal is non-empty, the set is ASCII-only, and the literal's
/// first byte is not a member.
const RunThenLiteral = struct {
    set: model.Set,
    literal: [64]u8 = undefined,
    literal_len: u8 = 0,
};

fn detectRunThenLiteral(program: Program) ?RunThenLiteral {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len < 7 or program.accept != 0) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (program.start >= ins.len) return null;
    const whole = ins[program.start];
    if (std.meta.activeTag(whole) != .save or whole.save.slot != 0 or whole.save.next != program.body) return null;
    if (program.body >= ins.len) return null;
    const consume = ins[program.body];
    if (std.meta.activeTag(consume) != .consume) return null;
    const set = consume.consume.set;
    if (!set.ascii_only or set.ranges.len == 0) return null;
    const star_index = consume.consume.next;
    if (star_index >= ins.len) return null;
    const star_ins = ins[star_index];
    if (std.meta.activeTag(star_ins) != .star) return null;
    if (!shapes.sameSet(set, star_ins.star.set)) return null;
    var state = RunThenLiteral{ .set = set };
    var pc = star_ins.star.next;
    while (pc < ins.len and std.meta.activeTag(ins[pc]) == .literal_byte) {
        if (state.literal_len == state.literal.len) return null;
        state.literal[state.literal_len] = ins[pc].literal_byte.value;
        state.literal_len += 1;
        pc = ins[pc].literal_byte.next;
    }
    if (state.literal_len == 0 or pc >= ins.len) return null;
    const save1 = ins[pc];
    if (std.meta.activeTag(save1) != .save or save1.save.slot != 1 or save1.save.next != program.accept) return null;
    if (set.matches(@as(u21, state.literal[0]))) return null;
    return state;
}

/// Pure concatenation of single-rune sets and literal bytes with a fixed
/// width, for example `\d{4}-\d{2}-\d{2}`.
const FixedSequence = struct {
    const max_len = 64;
    const max_sets = 8;

    literal: [max_len]bool = undefined,
    value: [max_len]u8 = undefined,
    len: u8 = 0,
    sets: [max_sets]model.Set = undefined,
    set_count: u8 = 0,
    tables: [max_sets][256]bool = undefined,

    fn buildTables(self: *FixedSequence) void {
        for (self.sets[0..self.set_count], 0..) |set, index| {
            self.tables[index] = byte_table.init(256, set);
        }
    }
};

fn detectFixedSequence(program: Program) ?FixedSequence {
    if (program.capture_count != 0 or program.extended or program.literal != null) return null;
    const ins = program.instructions;
    if (ins.len < 6 or program.accept != 0) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (program.start >= ins.len) return null;
    const whole = ins[program.start];
    if (std.meta.activeTag(whole) != .save or whole.save.slot != 0 or whole.save.next != program.body) return null;
    var state = FixedSequence{};
    var saw_set = false;
    var pc = program.body;
    while (pc < ins.len) {
        switch (ins[pc]) {
            .consume => |consume| {
                const set = consume.set;
                if (!set.ascii_only or set.ranges.len == 0) return null;
                var set_index: u8 = 0;
                while (set_index < state.set_count) : (set_index += 1) {
                    if (shapes.sameSet(state.sets[set_index], set)) break;
                }
                if (set_index == state.set_count) {
                    if (state.set_count == state.sets.len) return null;
                    state.sets[state.set_count] = set;
                    state.set_count += 1;
                }
                if (state.len == state.literal.len) return null;
                state.literal[state.len] = false;
                state.value[state.len] = set_index;
                state.len += 1;
                saw_set = true;
                pc = consume.next;
            },
            .literal_byte => |literal| {
                if (state.len == state.literal.len) return null;
                state.literal[state.len] = true;
                state.value[state.len] = literal.value;
                state.len += 1;
                pc = literal.next;
            },
            .save => |save| {
                if (save.slot != 1 or save.next != program.accept) return null;
                pc = save.next;
                break;
            },
            else => return null,
        }
    }
    if (!saw_set or state.len < 2 or pc != program.accept) return null;
    return state;
}

/// `save0 -> assertion(start_line) -> consume(set) -> star(set) -> save1`
/// in LF newline mode with an ASCII-only set.
const LineStartRun = struct {
    set: model.Set,
    table: [256]bool = undefined,
};

fn detectLineStartRun(program: Program) ?LineStartRun {
    if (program.capture_count != 0 or program.extended or program.newline != .lf) return null;
    const ins = program.instructions;
    if (ins.len != 8 or program.accept != 0 or program.start != 7 or program.body != 6) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    const save1 = ins[3];
    if (std.meta.activeTag(save1) != .save or save1.save.slot != 1 or save1.save.next != program.accept) return null;
    const star = ins[4];
    if (std.meta.activeTag(star) != .star or star.star.next != 3 or star.star.backtrack) return null;
    const consume = ins[5];
    if (std.meta.activeTag(consume) != .consume or consume.consume.next != 4) return null;
    const assertion = ins[6];
    if (std.meta.activeTag(assertion) != .assertion or assertion.assertion.kind != .start_line or
        assertion.assertion.next != 5) return null;
    const save0 = ins[7];
    if (std.meta.activeTag(save0) != .save or save0.save.slot != 0 or save0.save.next != 6) return null;
    const set = consume.consume.set;
    if (!set.ascii_only or set.ranges.len == 0) return null;
    if (!shapes.sameSet(set, star.star.set)) return null;
    return .{ .set = set, .table = byte_table.init(256, set) };
}

const BoundedSequenceState = struct {
    const max_elements = 32;
    const max_sets = 8;
    const Element = struct { set: u8, min: u8, max: u8 };

    elements: [max_elements]Element = undefined,
    len: u8 = 0,
    tables: [max_sets][256]bool = undefined,
    set_count: u8 = 0,

    fn build(self: *BoundedSequenceState, source: []const BoundedElement) bool {
        if (source.len > self.elements.len) return false;
        var sets: [max_sets]model.Set = undefined;
        for (source) |element| {
            var set_index: u8 = 0;
            while (set_index < self.set_count) : (set_index += 1) {
                if (shapes.sameSet(sets[set_index], element.set)) break;
            }
            if (set_index == self.set_count) {
                if (self.set_count == sets.len) return false;
                sets[self.set_count] = element.set;
                self.tables[self.set_count] = byte_table.init(256, element.set);
                self.set_count += 1;
            }
            self.elements[self.len] = .{ .set = set_index, .min = element.min, .max = element.max };
            self.len += 1;
        }
        return true;
    }
};

const UnboundedSequenceState = struct {
    const max_elements = 32;
    const max_sets = 8;
    const max_literal_bytes = 64;
    const Kind = enum(u8) { run, literal, optional };
    const Element = struct { kind: Kind, value: u8, len: u8 };

    elements: [max_elements]Element = undefined,
    len: u8 = 0,
    tables: [max_sets][256]bool = undefined,
    set_count: u8 = 0,
    literal_bytes: [max_literal_bytes]u8 = undefined,
    literal_len: u8 = 0,
    first_table: [256]bool = .{false} ** 256,

    fn build(self: *UnboundedSequenceState, source: []const UnboundedElement) bool {
        if (source.len > self.elements.len) return false;
        var sets: [max_sets]model.Set = undefined;
        for (source) |element| {
            switch (element) {
                .run => |set| {
                    var set_index: u8 = 0;
                    while (set_index < self.set_count) : (set_index += 1) {
                        if (shapes.sameSet(sets[set_index], set)) break;
                    }
                    if (set_index == self.set_count) {
                        if (self.set_count == sets.len) return false;
                        sets[self.set_count] = set;
                        self.tables[self.set_count] = byte_table.init(256, set);
                        self.set_count += 1;
                    }
                    self.elements[self.len] = .{ .kind = .run, .value = set_index, .len = 0 };
                },
                .literal => |bytes| {
                    if (bytes.len == 0 or bytes.len > std.math.maxInt(u8)) return false;
                    if (self.literal_len + bytes.len > self.literal_bytes.len) return false;
                    @memcpy(self.literal_bytes[self.literal_len..][0..bytes.len], bytes);
                    self.elements[self.len] = .{
                        .kind = .literal,
                        .value = self.literal_len,
                        .len = @intCast(bytes.len),
                    };
                    self.literal_len += @intCast(bytes.len);
                },
                .optional => |byte| {
                    self.elements[self.len] = .{ .kind = .optional, .value = byte, .len = 0 };
                },
            }
            self.len += 1;
        }
        if (self.len == 0) return false;
        switch (self.elements[0].kind) {
            .run => self.first_table = self.tables[self.elements[0].value],
            .literal => self.first_table[self.literal_bytes[self.elements[0].value]] = true,
            .optional => {
                self.first_table[self.elements[0].value] = true;
                if (self.len > 1) {
                    const next = self.elements[1];
                    switch (next.kind) {
                        .run => self.first_table = mergeTables(self.first_table, self.tables[next.value]),
                        .literal => self.first_table[self.literal_bytes[next.value]] = true,
                        .optional => return false,
                    }
                }
            },
        }
        return true;
    }

    fn mergeTables(a: [256]bool, b: [256]bool) [256]bool {
        var result = a;
        for (&result, b) |*slot, byte| slot.* = slot.* or byte;
        return result;
    }
};

const FastBranch = struct {
    prior: prefilter.FirstFilter,
    prefix: ?deferred_utf8.Run,
    run: deferred_utf8.Run,
    /// Branches after the dominant one, scanned directly when it fails.
    later: ?[]LaterRun = null,
    /// ASCII first bytes of the later plans; other bytes skip the scan.
    later_first: [256]bool = .{false} ** 256,

    fn deinit(self: *FastBranch, allocator: std.mem.Allocator) void {
        if (self.prefix) |*prefix| prefix.deinit(allocator);
        self.run.deinit(allocator);
        if (self.later) |list| {
            for (list) |*later| later.deinit(allocator);
            allocator.free(list);
        }
        self.* = undefined;
    }
};

/// Fixed-prefix literal-run plan. Heap-allocated so workspaces without the
/// shape stay small; the UTF-8 run table is prepared lazily.
const LiteralRunState = struct {
    shape: shapes.LiteralRun,
    run: deferred_utf8.CompactRun,
    table: [256]bool,

    fn deinit(self: *LiteralRunState, allocator: std.mem.Allocator) void {
        self.run.deinit(allocator);
        allocator.destroy(self);
    }
};

/// Captured run-chain plan plus the anchor run's candidate-byte filter.
/// Heap-allocated so workspaces without the shape stay small.
const RunChainState = struct {
    plan: shapes.RunChain,
    filter: prefilter.FirstFilter,
    /// Rune -> set membership bitmask cache. The plan's sets are immutable,
    /// so entries never need invalidation. Used only when a run set has
    /// non-ASCII members, where `Set.matches` is a range binary search.
    cache_keys: [64]u32 = [_]u32{no_rune} ** 64,
    cache_masks: [64]u8 = [_]u8{0} ** 64,
    use_cache: bool = false,

    inline fn member(self: *RunChainState, comptime cached: bool, rune: u21, index: usize) bool {
        if (!cached) return self.plan.sets[index].matches(rune);
        const slot: usize = @intCast((@as(u32, rune) *% 0x9E3779B1) >> 26);
        const key: u32 = rune;
        var mask = self.cache_masks[slot];
        if (self.cache_keys[slot] != key) {
            mask = 0;
            for (self.plan.sets[0..self.plan.count], 0..) |set, set_index| {
                if (self.plan.empty[set_index]) continue;
                if (set.matches(rune)) mask |= @as(u8, 1) << @intCast(set_index);
            }
            self.cache_keys[slot] = key;
            self.cache_masks[slot] = mask;
        }
        return mask & (@as(u8, 1) << @intCast(index)) != 0;
    }

    inline fn runEndCached(self: *RunChainState, comptime cached: bool, input: []const u8, start: usize, index: usize) ?usize {
        var end = start;
        while (end < input.len) {
            const rune = runeAt(input, end) orelse return null;
            if (!self.member(cached, rune.value, index)) break;
            end += rune.len;
        }
        return end;
    }
};
const no_rune: u32 = std.math.maxInt(u32);

/// Byte membership tables and a SIMD separator filter for the chain fast
/// path. Table lookups replace `Set.matches` calls in the per-byte scans;
/// the SIMD filter jumps straight to the next separator candidate.
const ChainTables = struct {
    a: [256]bool,
    s: [256]bool,
    b: [256]bool,

    fn init(chain: shapes.Chain) ChainTables {
        const empty = model.Set{ .ranges = &.{} };
        var tables: ChainTables = undefined;
        fillSetBytes(&tables.a, chain.set_a);
        fillSetBytes(&tables.s, chain.separator_set orelse empty);
        fillSetBytes(&tables.b, chain.set_b orelse empty);
        return tables;
    }
};

fn fillSetBytes(table: *[256]bool, set: model.Set) void {
    table.* = byte_table.init(256, set);
}

fn allSetBytes(table: *const [256]bool, bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!table[byte]) return false;
    }
    return true;
}

fn allSetMatches(set: model.Set, bytes: []const u8) bool {
    for (bytes) |byte| {
        if (!set.matches(byte)) return false;
    }
    return true;
}

/// Maximal `set` run end, using the byte table when the set is ASCII-only.
fn chainRunEndTable(input: []const u8, table: *const [256]bool, from: usize, set: model.Set) usize {
    if (!set.ascii_only) return chainRunEnd(input, set, from);
    var pos = from;
    while (pos < input.len and table[input[pos]]) pos += 1;
    return pos;
}

fn chainRunStart(input: []const u8, set: model.Set, separator_at: usize, floor: usize) usize {
    var pos = separator_at;
    if (set.ascii_only) {
        while (pos > floor and set.matches(input[pos - 1])) pos -= 1;
        return pos;
    }
    while (pos > floor) {
        const prev = previousRuneStart(input, pos);
        if (prev < floor) break;
        const rune = runeAt(input, prev) orelse break;
        if (!set.matches(rune.value)) break;
        pos = prev;
    }
    return pos;
}

/// End of the maximal `set` run starting at `from`.
fn chainRunEnd(input: []const u8, set: model.Set, from: usize) usize {
    var pos = from;
    if (set.ascii_only) {
        while (pos < input.len and set.matches(input[pos])) pos += 1;
    } else {
        while (set.matchAdvance(input, pos)) |advanced| pos = advanced;
    }
    return pos;
}

fn tailMatches(input: []const u8, at: usize, tail: []const u8) bool {
    if (tail.len > input.len - at) return false;
    return std.mem.eql(u8, input[at..][0..tail.len], tail);
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
