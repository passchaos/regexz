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
const utf8_set = @import("utf8_set.zig");
const prefilter = @import("prefilter.zig");
const shapes = @import("shapes.zig");
const newline = @import("newline.zig");
const required_literals = @import("required_literals.zig");
const unicode = @import("unicode.zig");
const unset = std.math.maxInt(usize);
const AnchoredRun = struct { kind: model.Assertion, set: model.Set };
const max_tracked_captures: usize = 9;
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
    /// Cached capture-free DFA for the common find fast path.
    fast_dfa: ?*search_dfa.Workspace = null,
    /// A `set+` program over an ASCII-only set scans runs directly instead of
    /// entering the DFA.
    simple_set: ?model.Set = null,
    /// A `set+ separator set+ tail` program is found by scanning for the
    /// separator instead of running the DFA over the whole input.
    simple_chain: ?shapes.Chain = null,
    /// A `set+` program ending in a line/text-end assertion scans runs and
    /// checks the assertion once at each run end.
    simple_anchored: ?AnchoredRun = null,
    /// Multi-literal absence filter for wide start-literal alternations
    /// whose literals have distinct first bytes.
    pair_filter: ?*prefilter.PairSet = null,
    /// Absence filter for a whole-pattern case-folded literal (`(?i)STRASSE`).
    fold_filter: ?prefilter.FoldFilter = null,
    /// Byte membership tables for the chain fast path. `Set.matches` is a
    /// binary search over rune ranges; the per-byte chain scans run several
    /// lookups per input byte, so cache the answers once per workspace.
    chain_tables: ?ChainTables = null,
    /// Expanded UTF-8 automaton for a non-ASCII `set+` program (`\p{Han}+`):
    /// one 256-entry transition row per state.
    utf8_run: ?Utf8Run = null,
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
        const slots = try allocator.alloc(usize, slot_count);
        @memset(slots, unset);
        errdefer allocator.free(slots);
        const best_slots = try allocator.alloc(usize, slot_count);
        @memset(best_slots, unset);
        errdefer allocator.free(best_slots);
        const pair_filter = try buildPairFilter(allocator, program);
        errdefer if (pair_filter) |filter| allocator.destroy(filter);
        const simple_chain = if (limits.longest) null else shapes.chain(program);
        const set_run = if (limits.longest) null else shapes.setRun(program);
        const utf8_run: ?Utf8Run = if (set_run) |set|
            (if (set.ascii_only) null else try Utf8Run.init(allocator, set))
        else
            null;
        errdefer if (utf8_run) |*value| value.deinit(allocator);
        return .{
            .allocator = allocator,
            .program = program,
            .limits = effective,
            .slots = slots,
            .best_slots = best_slots,
            .pike_eligible = pike.eligible(program),
            .simple_set = if (set_run) |set| (if (set.ascii_only) set else null) else null,
            .simple_chain = simple_chain,
            .simple_anchored = if (limits.longest) null else detectAnchoredRun(program),
            .chain_tables = if (simple_chain) |chain| ChainTables.init(chain) else null,
            .utf8_run = utf8_run,
            .weak_first = @as(usize, @popCount(program.first.ascii[0])) + @popCount(program.first.ascii[1]) >= 48,
            .prefix_set = detectPrefixSet(program),
            .start_anchored = startsAtTextStart(program),
            .line_start_only = startsAtLineStart(program),
            .first_filter = prefilter.FirstFilter.init(program.first),
            .pair_filter = pair_filter,
            .fold_filter = if (program.caseless_literal) |literal| prefilter.FoldFilter.init(literal) else null,
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.pair_filter) |filter| self.allocator.destroy(filter);
        if (self.utf8_run) |*value| value.deinit(self.allocator);
        if (self.pike_workspace) |*workspace| workspace.deinit();
        if (self.backtrack_workspace) |*workspace| workspace.deinit();
        if (self.search_dfa_workspace) |*workspace| workspace.deinit();
        self.choices.deinit(self.allocator);
        self.trail.deinit(self.allocator);
        self.allocator.free(self.slots);
        self.allocator.free(self.best_slots);
        self.* = undefined;
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
        self.steps = 0;
        if (self.start_anchored and search_start != 0) return null;
        if (self.simple_set) |set| return self.findSetRun(set, input, search_start);
        if (self.utf8_run) |*utf8| return self.findSetRunUtf8(utf8, input, search_start);
        if (self.simple_chain) |*chain| return self.findChain(chain, input, search_start);
        if (self.simple_anchored) |anchored_run| return self.findAnchoredRun(anchored_run, input, search_start);
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
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var writer = ListWriter{ .list = &out, .allocator = self.allocator };
        try self.replaceAllWith(&writer, input, substitution, std.math.maxInt(usize));
        return out.toOwnedSlice(self.allocator);
    }

    /// Replace at most `limit` non-overlapping leftmost-first matches.
    pub fn replacen(
        self: *Workspace,
        input: []const u8,
        limit: usize,
        substitution: []const u8,
    ) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        var writer = ListWriter{ .list = &out, .allocator = self.allocator };
        try self.replaceAllWith(&writer, input, substitution, limit);
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
        try self.replaceAllWith(&writer, input, substitution, std.math.maxInt(usize));
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
        try self.replaceAllWith(&writer, input, substitution, std.math.maxInt(usize));
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
        limit: usize,
    ) Error!void {
        try validateSubstitutionFor(self.program, substitution);
        // A substitution with no `$` or `\` expands to itself; skip the
        // per-match parse in that common case.
        const literal_substitution = std.mem.indexOfAny(u8, substitution, "\\$") == null;
        self.steps = 0;
        var search_start: usize = 0;
        var replaced: usize = 0;
        while (search_start <= input.len and replaced < limit) {
            const match = try self.findInternal(input, search_start) orelse break;
            replaced += 1;
            try writer.appendSlice(input[search_start..match.start]);
            if (literal_substitution) {
                try writer.appendSlice(substitution);
            } else {
                try appendSubstitution(writer, input, substitution, match.slots, self.program, self.limits.full_case_mapping);
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
        if (self.replayLinear(input, start, end)) |matched| {
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

    /// Deterministic replay for a straight-line program of saves, literals,
    /// and greedy set runs whose continuation cannot start with a member.
    /// Such a run is forced to its maximal length, so no choice or trail
    /// bookkeeping is needed. Returns null when the shape is not covered;
    /// otherwise whether the walk ended exactly at `end`.
    fn replayLinear(self: *Workspace, input: []const u8, start: usize, end: usize) ?bool {
        const instructions = self.program.instructions;
        const max_steps = self.limits.max_execution_steps;
        var steps = self.steps;
        defer self.steps = steps;
        @memset(self.slots, unset);
        var pc = self.program.body;
        var pos = start;
        // Belt-and-braces cap for malformed zero-width cycles; the real
        // limit is the interpreter budget, which the fallback path enforces.
        const step_limit = (end - start) + instructions.len + 16;
        var walked: usize = 0;
        while (true) {
            walked += 1;
            if (walked > step_limit) return null;
            steps += 1;
            if (steps > max_steps) return null;
            switch (instructions[pc]) {
                .save => |save| {
                    self.slots[save.slot] = pos;
                    pc = save.next;
                },
                .literal_byte => |literal| {
                    if (pos >= input.len or input[pos] != literal.value) return false;
                    pos += 1;
                    pc = literal.next;
                },
                .literal_rune => |literal| {
                    const rune = runeAt(input, pos) orelse return false;
                    if (rune.value != literal.value) return false;
                    pos += rune.len;
                    pc = literal.next;
                },
                .byte => |next| {
                    if (pos >= input.len) return false;
                    pos += 1;
                    pc = next;
                },
                .consume => |consume| {
                    if (consume.set.ascii_only) {
                        if (pos >= input.len or !consume.set.matches(input[pos])) return false;
                        pos += 1;
                    } else {
                        pos = consume.set.matchAdvance(input, pos) orelse return false;
                    }
                    pc = consume.next;
                },
                .star => |star| {
                    // The greedy run is forced when the next consuming
                    // instruction is the accept or a literal outside the set.
                    var next = star.next;
                    while (true) {
                        switch (instructions[next]) {
                            .save => |save| next = save.next,
                            .accept => break,
                            .literal_byte => |literal| {
                                if (star.set.matches(literal.value)) return null;
                                break;
                            },
                            .literal_rune => |literal| {
                                if (star.set.matches(literal.value)) return null;
                                break;
                            },
                            else => return null,
                        }
                    }
                    var consumed: usize = 0;
                    if (star.set.ascii_only) {
                        while (pos < input.len and star.set.matches(input[pos])) {
                            pos += 1;
                            consumed += 1;
                        }
                    } else {
                        while (star.set.matchAdvance(input, pos)) |advanced| {
                            pos = advanced;
                            consumed += 1;
                        }
                    }
                    steps += consumed;
                    if (steps > max_steps) return null;
                    pc = star.next;
                },
                .accept => return pos == end,
                else => return null,
            }
        }
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
        if (self.simple_set) |set| return self.findSetRun(set, input, search_start);
        if (self.utf8_run) |*utf8| return self.findSetRunUtf8(utf8, input, search_start);
        if (self.simple_chain) |*chain| return self.findChain(chain, input, search_start);
        if (self.simple_anchored) |anchored_run| return self.findAnchoredRun(anchored_run, input, search_start);
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

    /// `set+` over an ASCII-only set: skip to the next member with the SIMD
    /// first-byte filter, then extend the run. The shape is deterministic, so
    /// no DFA state or backtracking stack is involved.
    fn findSetRun(self: *Workspace, set: model.Set, input: []const u8, search_start: usize) ?Match {
        var offset = search_start;
        // Match-dense input spends its time in short gaps, where a scalar scan
        // beats the vector filter's setup; long gaps switch to the SIMD scan.
        const scalar_limit = @min(input.len, offset + 32);
        while (offset < scalar_limit and !set.matches(input[offset])) offset += 1;
        if (offset >= scalar_limit) {
            if (offset >= input.len) return null;
            offset = self.first_filter.indexOf(input, offset) orelse return null;
        }
        const start = offset;
        offset += 1;
        while (offset < input.len and set.matches(input[offset])) offset += 1;
        self.slots[0] = start;
        self.slots[1] = offset;
        return .{ .start = start, .end = offset, .slots = self.slots };
    }

    /// `set+` for a non-ASCII set: walk the UTF-8 automaton one byte per
    /// transition. The first-byte filter skips spans that cannot start a
    /// member rune; `accept` marks a complete in-set rune.
    fn findSetRunUtf8(self: *Workspace, utf8: *const Utf8Run, input: []const u8, search_start: usize) ?Match {
        const table = utf8.table;
        var offset = search_start;
        var state: u16 = 0;
        var rune_start = search_start;
        while (offset < input.len) {
            if (state == 0) {
                offset = self.first_filter.indexOf(input, offset) orelse return null;
                rune_start = offset;
            }
            const next = table[@as(usize, state) * 256 + input[offset]];
            if (next == utf8_set.accept) break;
            if (next == utf8_set.dead) {
                state = 0;
                offset += 1;
                continue;
            }
            state = next;
            offset += 1;
        }
        if (offset >= input.len) return null;
        const start = rune_start;
        var end = offset + 1;
        var rune_begin = end;
        state = 0;
        while (end < input.len) {
            const next = table[@as(usize, state) * 256 + input[end]];
            if (next == utf8_set.accept) {
                state = 0;
                end += 1;
                rune_begin = end;
            } else if (next == utf8_set.dead) {
                end = rune_begin;
                break;
            } else {
                state = next;
                end += 1;
            }
        }
        if (state != 0) end = rune_begin;
        self.slots[0] = start;
        self.slots[1] = end;
        return .{ .start = start, .end = end, .slots = self.slots };
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
    // PCRE2 also accepts Perl's angle-bracket group syntax `$<name>`.
    if (next == '<') {
        const name_start = start + 1;
        const close = std.mem.indexOfScalarPos(u8, substitution, name_start, '>') orelse return error.InvalidRegex;
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
        if (byte == '$') {
            if (index + 1 < substitution.len) {
                switch (substitution[index + 1]) {
                    '`', '\'', '+', '_' => {
                        index += 1;
                        continue;
                    },
                    else => {},
                }
            }
            _ = try parseSubstitutionGroup(substitution, &index, program, capture_count);
        }
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

fn highestGroup(input: []const u8, slots: []const usize, capture_count: u16) ?[]const u8 {
    var group: u16 = capture_count;
    while (group > 0) : (group -= 1) {
        if (groupText(input, slots, group)) |text| return text;
    }
    return null;
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
            // PCRE2/Perl whole-input substitutions.
            if (index + 1 < substitution.len) {
                switch (substitution[index + 1]) {
                    '`' => {
                        try appendTransformed(writer, input[0..slots[0]], &state, full_case);
                        index += 1;
                        continue;
                    },
                    '\'' => {
                        try appendTransformed(writer, input[slots[1]..], &state, full_case);
                        index += 1;
                        continue;
                    },
                    '+' => {
                        if (highestGroup(input, slots, program.capture_count)) |text| {
                            try appendTransformed(writer, text, &state, full_case);
                        }
                        index += 1;
                        continue;
                    },
                    '_' => {
                        try appendTransformed(writer, input, &state, full_case);
                        index += 1;
                        continue;
                    },
                    else => {},
                }
            }
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

/// Expand `substitution` for a single match without searching. `slots` must
/// hold the whole-match and capture slots for `input` (as returned by `find`).
pub fn expandMatch(
    allocator: std.mem.Allocator,
    program: Program,
    input: []const u8,
    slots: []const usize,
    substitution: []const u8,
    full_case: bool,
) Error![]u8 {
    try validateSubstitutionFor(program, substitution);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var writer = ListWriter{ .list = &out, .allocator = allocator };
    try appendSubstitution(&writer, input, substitution, slots, program, full_case);
    return out.toOwnedSlice(allocator);
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

fn runeLenAt(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return 1;
    if (input[offset] < 0x80) return 1;
    return if (runeAt(input, offset)) |rune| rune.len else 1;
}

/// Start of the maximal `set` run ending at `separator_at`, clamped to
/// `floor`. Bytes outside an ASCII-only set never match, so the backward
/// scan is byte-wise in that case.
/// Expanded UTF-8 automaton for a non-ASCII `set+` program. Each state owns a
/// 256-entry transition row, so the run scan is one table load per byte.
const Utf8Run = struct {
    table: []u16,

    fn init(allocator: std.mem.Allocator, set: model.Set) std.mem.Allocator.Error!Utf8Run {
        var automaton = try utf8_set.build(allocator, set.ranges);
        defer automaton.deinit(allocator);
        const states = automaton.stateCount();
        const table = try allocator.alloc(u16, states * 256);
        errdefer allocator.free(table);
        for (0..states) |state| {
            for (0..256) |byte| {
                table[state * 256 + byte] = automaton.advance(@intCast(state), @intCast(byte));
            }
        }
        return .{ .table = table };
    }

    fn deinit(self: *Utf8Run, allocator: std.mem.Allocator) void {
        allocator.free(self.table);
        self.* = undefined;
    }
};

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
    for (0..256) |byte| table[byte] = set.matches(@intCast(byte));
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
