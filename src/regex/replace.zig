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
const RunShape = @import("compile.zig").RunShape;
const LineMarkerShape = @import("compile.zig").LineMarkerShape;
const EscapedDelimitedShape = @import("compile.zig").EscapedDelimitedShape;
const PrefixRunShape = @import("compile.zig").PrefixRunShape;
const ChainLoopShape = @import("compile.zig").ChainLoopShape;
const OptionalTailShape = @import("compile.zig").OptionalTailShape;
const BoundedLoopShape = @import("compile.zig").BoundedLoopShape;
const NumberShape = @import("compile.zig").NumberShape;
const LineHeadingShape = @import("compile.zig").LineHeadingShape;
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
    set_run_min,
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
    literal_multi,
    literal_multi_distinct,
    literal_pair,
    literal_bytes,
    literal_first,
    caseless_literal_set,
    repeated_literal,
    run_then_literal,
    fixed_sequence,
    line_start_run,
    bounded_sequence,
    unbounded_sequence,
    unbounded_sequence_fused,
    star_literal,
    prefix_run,
    chain_loop,
    optional_tail,
    bounded_loop,
    signed_number,
    line_heading,
    line_marker,
    escaped_delimited,
    word_alternation,
    email,
    blank_lines,
    run_literals,
    prefix_run_literal,
    delimited_any,
    delimited_tail,
    wrapped_run,
    paired,
    line_key,
    line_bracket,
    windows_path,
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
    /// Minimum count for a `set{min,}` program (1 for a plain `set+`).
    simple_set_min: u8 = 1,
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
    /// Splat candidate filter for a small whole-pattern literal alternation.
    literal_set_multi: ?prefilter.MultiFilter = null,
    /// Nibble candidate filter for a wide whole-pattern literal alternation.
    literal_set_pair: ?*prefilter.PairSet = null,
    /// Every literal-set branch is one byte, so a first-byte hit is the
    /// whole match.
    literal_set_single: bool = false,
    /// Folded candidate filter for a whole-pattern caseless literal
    /// alternation (`(?i)alpha|gamma`).
    caseless_literal_set: ?prefilter.MultiFilter = null,
    /// A whole-pattern fixed literal repetition (`(?:ab)+`).
    repeated_literal: ?RepeatedLiteralState = null,
    /// `set+ literal` with a literal first byte outside the set.
    run_then_literal: ?RunThenLiteral = null,
    /// Fixed-width concatenation of single-rune sets and literal bytes.
    fixed_sequence: ?*FixedSequence = null,
    /// `(?m)^set+` in LF newline mode.
    line_start_run: ?LineStartRun = null,
    /// Byte table for the anchored-run set when it is ASCII-only.
    anchored_table: [256]bool = .{false} ** 256,
    anchored_ascii: bool = false,
    /// Bounded set-run concatenation with at least one variable-width run.
    bounded_sequence: ?*BoundedSequenceState = null,
    /// Unbounded run chain separated by literal bytes.
    unbounded_sequence: ?*UnboundedSequenceState = null,
    /// `set* literal` with a greedy nullable star.
    star_literal: ?*StarLiteralState = null,
    /// One set byte followed by a greedy unbounded run.
    prefix_run: ?PrefixRunState = null,
    /// A run followed by a greedy repetition of `separator run`.
    chain_loop: ?ChainLoopState = null,
    /// A run, an optional `separator run` group, then a literal byte.
    optional_tail: ?OptionalTailState = null,
    /// A bounded run followed by a greedy repetition of a bounded group.
    bounded_loop: ?BoundedLoopState = null,
    /// A sign set followed by digits and an optional fraction.
    signed_number: ?SignedNumberState = null,
    /// `(?m)^X{min,max} Y.*$` in LF newline mode.
    line_heading: ?*LineHeadingState = null,
    /// `(?m)^space* marker literal` (`(?m)^\s*[-*+] `).
    line_marker: ?*LineMarkerState = null,
    /// `quote (?: escape any | [^quote escape])* quote`.
    escaped_delimited: ?EscapedDelimitedState = null,
    /// `\b (?:word|word|...) \b` with ASCII word boundaries.
    word_alternation: ?WordAlternationState = null,
    /// `\b local+ @ domain+ \. tld{min,} \b`.
    email: ?EmailState = null,
    /// `(?m)^\s*$` in LF mode.
    blank_lines: ?BlankLinesState = null,
    /// `run+ literal-alternation` (`\d+(?:px|em|rem|%)`).
    run_literals: ?RunLiteralsState = null,
    /// `prefix-set run+ literal` (`[?&]\w+=`).
    prefix_run_literal: ?PrefixRunLiteralState = null,
    /// `open any*? close` (`<!--[\s\S]*?-->`).
    delimited_any: ?DelimitedAnyState = null,
    /// `quote body+ quote space* literal` (`"[^"]+"\s*:`).
    delimited_tail: ?DelimitedTailState = null,
    /// `open body+ close` with multi-byte literals (`\$\{[^}]+\}`).
    wrapped_run: ?WrappedRunState = null,
    /// `open1 body1+ close1 open2 body2+ close2` (markdown links).
    paired: ?PairedState = null,
    /// `(?m)^space* run+ literal` (YAML keys).
    line_key: ?LineKeyState = null,
    /// `(?m)^\[ run+ \]$` (TOML tables).
    line_bracket: ?LineBracketState = null,
    /// `letters : \ run+` (Windows paths).
    windows_path: ?WindowsPathState = null,
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
        const literal_set = program.literal_set;
        const literal_set_fast = literal_set != null and program.capture_count == 0 and !limits.longest;
        var pair_filter = try buildPairFilter(allocator, program);
        var literal_set_multi: ?prefilter.MultiFilter = null;
        var literal_set_pair: ?*prefilter.PairSet = null;
        if (literal_set_fast) {
            if (prefilter.literalSetMulti(literal_set.?)) |filter| {
                literal_set_multi = filter;
            } else if (pair_filter != null and sameLiterals(program.start_literals.?, literal_set.?)) {
                // The generic start-literal filter scans the same branches;
                // reuse it instead of allocating a second pair set.
                literal_set_pair = pair_filter;
                pair_filter = null;
            } else if (prefilter.PairSet.init(literal_set.?)) |set| {
                const filter = try allocator.create(prefilter.PairSet);
                filter.* = set;
                literal_set_pair = filter;
            }
        }
        errdefer if (literal_set_pair) |filter| allocator.destroy(filter);
        var literal_set_single = false;
        if (literal_set_fast) {
            literal_set_single = true;
            for (literal_set.?) |literal| {
                if (literal.len != 1) literal_set_single = false;
            }
        }
        const caseless_literal_set: ?prefilter.MultiFilter = if (limits.longest) null else blk: {
            const literals = program.caseless_literal_set orelse break :blk null;
            break :blk prefilter.MultiFilter.initAny(literals);
        };
        const repeated_literal: ?RepeatedLiteralState = if (limits.longest) null else blk: {
            const bytes = program.repeated_literal orelse break :blk null;
            var state = RepeatedLiteralState{ .literal_len = @intCast(bytes.len) };
            @memcpy(state.literal[0..bytes.len], bytes);
            break :blk state;
        };
        const word_run_set = shapes.wordRun(program);
        var word_table: [256]bool = .{false} ** 256;
        if (word_run_set) |set| {
            word_table = byte_table.init(256, set);
        }
        errdefer if (pair_filter) |filter| allocator.destroy(filter);
        const simple_chain = if (limits.longest) null else shapes.chain(program);
        const set_run = if (limits.longest) null else (shapes.setRun(program) orelse program.optional_run);
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
        const simple_run: ?RunShape = if (limits.longest) null else program.simple_run;
        const simple_set: ?model.Set = if (simple_run) |plan|
            plan.set
        else if (set_run) |set|
            (if (set.ascii_only) set else null)
        else
            null;
        const simple_set_min: u8 = if (simple_run) |plan| plan.min else 1;
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
        const line_heading: ?*LineHeadingState = if (limits.longest) null else blk: {
            const shape = program.line_heading orelse break :blk null;
            const state = try allocator.create(LineHeadingState);
            errdefer allocator.destroy(state);
            state.* = .{
                .byte = shape.byte,
                .min = shape.min,
                .max = shape.max,
                .space = byte_table.init(256, shape.space),
                .run = deferred_utf8.Run.init(shape.set),
            };
            state.run.prepare_after = std.math.maxInt(u16);
            break :blk state;
        };
        errdefer if (line_heading) |state| {
            state.run.deinit(allocator);
            allocator.destroy(state);
        };
        const line_marker: ?*LineMarkerState = if (limits.longest) null else blk: {
            const shape = program.line_marker orelse break :blk null;
            const state = try allocator.create(LineMarkerState);
            errdefer allocator.destroy(state);
            var marker_first = model.FirstSet{};
            for (shape.marker.ranges) |range| {
                var byte: u32 = range.first;
                while (byte <= range.last and byte < 0x80) : (byte += 1) {
                    marker_first.ascii[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
                }
            }
            state.* = .{
                .space = byte_table.init(256, shape.space),
                .marker = byte_table.init(256, shape.marker),
                .trailing = byte_table.init(256, shape.trailing),
                .trailing_run = shape.trailing_run,
                .marker_filter = prefilter.FirstFilter.init(marker_first),
            };
            break :blk state;
        };
        errdefer if (line_marker) |state| allocator.destroy(state);
        const escaped_delimited: ?EscapedDelimitedState = if (limits.longest)
            null
        else if (program.escaped_delimited) |shape|
            .{ .quote = shape.quote, .escape = shape.escape }
        else
            null;
        const word_alternation: ?WordAlternationState = if (limits.longest)
            null
        else if (program.word_alternation) |shape| blk: {
            const filter = prefilter.MultiFilter.initAny(shape.filter_literals) orelse break :blk null;
            break :blk .{
                .filter = filter,
                .literals = shape.literals,
                .caseless = shape.caseless,
            };
        } else null;
        const email: ?EmailState = if (limits.longest) null else blk: {
            const shape = program.email orelse break :blk null;
            break :blk .{
                .local = byte_table.init(256, shape.local),
                .domain = byte_table.init(256, shape.domain),
                .tld = byte_table.init(256, shape.tld),
                .tld_min = shape.tld_min,
            };
        };
        const blank_lines: ?BlankLinesState = if (limits.longest or program.notempty or
            program.notempty_atstart)
            null
        else if (program.blank_lines) |shape|
            .{ .space = byte_table.init(256, shape.space) }
        else
            null;
        const run_literals: ?RunLiteralsState = if (limits.longest) null else blk: {
            const shape = program.run_literals orelse break :blk null;
            var first_bytes = [_]bool{false} ** 256;
            for (shape.literals) |literal| first_bytes[literal[0]] = true;
            break :blk .{
                .run = byte_table.init(256, shape.run),
                .filter = prefilter.FirstFilter.init(prefilter.firstSetOf(shape.run)),
                .literals = shape.literals,
                .first_bytes = first_bytes,
            };
        };
        const prefix_run_literal: ?PrefixRunLiteralState = if (limits.longest) null else blk: {
            const shape = program.prefix_run_literal orelse break :blk null;
            break :blk .{
                .prefix_filter = prefilter.FirstFilter.init(prefilter.firstSetOf(shape.prefix)),
                .run = byte_table.init(256, shape.run),
                .literal = shape.literal,
            };
        };
        const delimited_any: ?DelimitedAnyState = if (limits.longest) null else blk: {
            const shape = program.delimited_any orelse break :blk null;
            break :blk .{ .open = shape.open, .close = shape.close };
        };
        const delimited_tail: ?DelimitedTailState = if (limits.longest) null else blk: {
            const shape = program.delimited_tail orelse break :blk null;
            break :blk .{
                .quote = shape.quote,
                .body = byte_table.init(256, shape.body),
                .space = byte_table.init(256, shape.space),
                .literal = shape.literal,
            };
        };
        const wrapped_run: ?WrappedRunState = if (limits.longest) null else blk: {
            const shape = program.wrapped_run orelse break :blk null;
            break :blk .{
                .open = shape.open,
                .close = shape.close,
                .body = byte_table.init(256, shape.body),
            };
        };
        const paired: ?PairedState = if (limits.longest) null else blk: {
            const shape = program.paired orelse break :blk null;
            break :blk .{
                .open1 = shape.open1,
                .close1 = shape.close1,
                .open2 = shape.open2,
                .close2 = shape.close2,
                .body1 = byte_table.init(256, shape.body1),
                .body2 = byte_table.init(256, shape.body2),
            };
        };
        const line_key: ?LineKeyState = if (limits.longest) null else blk: {
            const shape = program.line_key orelse break :blk null;
            break :blk .{
                .space = byte_table.init(256, shape.space),
                .run = byte_table.init(256, shape.run),
                .literal = shape.literal,
            };
        };
        const line_bracket: ?LineBracketState = if (limits.longest) null else blk: {
            const shape = program.line_bracket orelse break :blk null;
            break :blk .{ .run = byte_table.init(256, shape.run) };
        };
        const windows_path: ?WindowsPathState = if (limits.longest) null else blk: {
            const shape = program.windows_path orelse break :blk null;
            break :blk .{
                .letters = byte_table.init(256, shape.letters),
                .run = byte_table.init(256, shape.run),
            };
        };
        const anchored_table: [256]bool = if (simple_anchored) |anchored|
            (if (anchored.set.ascii_only) byte_table.init(256, anchored.set) else .{false} ** 256)
        else
            .{false} ** 256;
        const anchored_ascii = if (simple_anchored) |anchored| anchored.set.ascii_only else false;
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
                state.deinit(allocator);
                allocator.destroy(state);
                break :blk null;
            }
            break :blk state;
        };
        errdefer if (unbounded_sequence) |state| {
            state.deinit(allocator);
            allocator.destroy(state);
        };
        const signed_number: ?SignedNumberState = if (limits.longest) null else blk: {
            const shape = program.signed_number orelse break :blk null;
            break :blk .{
                .table_sign = byte_table.init(256, shape.sign),
                .table_digits = byte_table.init(256, shape.digits),
                .table_exponent_marker = byte_table.init(256, shape.exponent_marker),
                .table_exponent_sign = byte_table.init(256, shape.exponent_sign),
                .table_exponent_digits = byte_table.init(256, shape.exponent_digits),
                .fraction = shape.fraction,
                .exponent = shape.exponent,
                .optional_sign = shape.optional_sign,
                .exponent_has_sign = shape.exponent_has_sign,
            };
        };
        const bounded_loop: ?BoundedLoopState = if (limits.longest) null else blk: {
            const shape = program.bounded_loop orelse break :blk null;
            break :blk .{
                .table_a = byte_table.init(256, shape.set_a),
                .table_b = byte_table.init(256, shape.set_b),
                .min_a = shape.min_a,
                .max_a = shape.max_a,
                .min_b = shape.min_b,
                .max_b = shape.max_b,
                .separator = shape.separator,
                .min_groups = shape.min_groups,
            };
        };
        const optional_tail: ?OptionalTailState = if (limits.longest) null else blk: {
            const shape = program.optional_tail orelse break :blk null;
            break :blk .{
                .table_a = byte_table.init(256, shape.set_a),
                .table_b = byte_table.init(256, shape.set_b),
                .separator = shape.separator,
                .literal = shape.literal,
            };
        };
        const chain_loop: ?ChainLoopState = if (limits.longest) null else blk: {
            const shape = program.chain_loop orelse break :blk null;
            break :blk .{
                .table_a = byte_table.init(256, shape.set_a),
                .table_b = byte_table.init(256, shape.set_b),
                .separator = shape.separator[0],
                .min_groups = shape.min_groups,
            };
        };
        const prefix_run: ?PrefixRunState = if (limits.longest) null else blk: {
            const shape = program.prefix_run orelse break :blk null;
            const first = prefilter.firstSetOf(shape.set_a);
            break :blk .{
                .table_a = byte_table.bits(shape.set_a),
                .table_b = byte_table.bits(shape.set_b),
                .min_b = shape.min_b,
                .first_filter = prefilter.FirstFilter.init(first),
                .dense = @as(usize, @popCount(first.ascii[0])) + @popCount(first.ascii[1]) >= 48,
            };
        };
        const star_literal: ?*StarLiteralState = if (limits.longest) null else blk: {
            const shape = detectStarLiteral(program) orelse break :blk null;
            const state = try allocator.create(StarLiteralState);
            errdefer allocator.destroy(state);
            state.* = .{
                .run = deferred_utf8.Run.init(shape.set),
                .dot = shapes.isDotExceptNewline(shape.set),
            };
            state.run.prepare_after = std.math.maxInt(u16);
            state.literal = shape.literal;
            state.literal_len = shape.literal_len;
            break :blk state;
        };
        errdefer if (star_literal) |state| {
            state.run.deinit(allocator);
            allocator.destroy(state);
        };
        const fixed_sequence: ?*FixedSequence = if (limits.longest) null else blk: {
            const shape = detectFixedSequence(program) orelse break :blk null;
            const state = try allocator.create(FixedSequence);
            state.* = shape;
            state.buildTables();
            break :blk state;
        };
        errdefer if (fixed_sequence) |state| allocator.destroy(state);
        const fast_kind: FastKind = if (simple_set != null)
            (if (simple_set_min == 1) .set_run else .set_run_min)
        else if (capture_run) |plan|
            (if (plan.set.ascii_only) .capture_run else .capture_unicode)
        else if (run_chain != null)
            .run_chain
        else if (zero_width_plan != null)
            .zero_width
        else if (program.caseless_literal != null and program.capture_count == 0 and !limits.longest)
            .caseless_literal
        else if (program.literal_set != null and program.capture_count == 0 and !limits.longest)
            (if (literal_set_single)
                .literal_bytes
            else if (literal_set_multi) |filter|
                (if (filter.shared_first) .literal_multi else .literal_multi_distinct)
            else if (literal_set_pair != null)
                .literal_pair
            else
                .literal_first)
        else if (caseless_literal_set != null)
            .caseless_literal_set
        else if (repeated_literal != null)
            .repeated_literal
        else if (utf8_run != null)
            .utf8_run
        else if (windows_path != null)
            .windows_path
        else if (simple_chain != null)
            .chain
        else if (run_then_literal != null)
            .run_then_literal
        else if (fixed_sequence != null)
            .fixed_sequence
        else if (line_start_run != null)
            .line_start_run
        else if (line_heading != null)
            .line_heading
        else if (line_marker != null)
            .line_marker
        else if (escaped_delimited != null)
            .escaped_delimited
        else if (word_alternation != null)
            .word_alternation
        else if (email != null)
            .email
        else if (blank_lines != null)
            .blank_lines
        else if (delimited_any != null)
            .delimited_any
        else if (delimited_tail != null)
            .delimited_tail
        else if (wrapped_run != null)
            .wrapped_run
        else if (paired != null)
            .paired
        else if (line_key != null)
            .line_key
        else if (line_bracket != null)
            .line_bracket
        else if (run_literals != null)
            .run_literals
        else if (prefix_run_literal != null)
            .prefix_run_literal
        else if (bounded_sequence != null)
            .bounded_sequence
        else if (unbounded_sequence) |state|
            (if (state.has_fuse) .unbounded_sequence_fused else .unbounded_sequence)
        else if (star_literal != null)
            .star_literal
        else if (prefix_run != null)
            .prefix_run
        else if (chain_loop != null)
            .chain_loop
        else if (optional_tail != null)
            .optional_tail
        else if (bounded_loop != null)
            .bounded_loop
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
        else if (signed_number != null)
            .signed_number
        else
            .none;
        const fast_branch: ?FastBranch = if (program.fast_branch) |plan| blk: {
            var value = FastBranch{
                .prior = prefilter.FirstFilter.init(plan.prior_first),
                .prefix = if (plan.prefix) |set| deferred_utf8.Run.init(set) else null,
                .run = deferred_utf8.Run.init(plan.run),
                .cjk = plan.run.covers(0x4E00, 0x9FFF),
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
                        .bare_branch = later.bare_branch,
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
            .simple_set_min = simple_set_min,
            .capture_run = capture_run,
            .simple_set_table = blk: {
                var table: [256]bool = .{false} ** 256;
                if (simple_set orelse set_run orelse (if (capture_run) |plan| plan.set else null)) |set| {
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
            .literal_set_multi = literal_set_multi,
            .literal_set_pair = literal_set_pair,
            .literal_set_single = literal_set_single,
            .caseless_literal_set = caseless_literal_set,
            .repeated_literal = repeated_literal,
            .run_then_literal = run_then_literal,
            .fixed_sequence = fixed_sequence,
            .line_start_run = line_start_run,
            .anchored_table = anchored_table,
            .anchored_ascii = anchored_ascii,
            .bounded_sequence = bounded_sequence,
            .unbounded_sequence = unbounded_sequence,
            .star_literal = star_literal,
            .prefix_run = prefix_run,
            .chain_loop = chain_loop,
            .optional_tail = optional_tail,
            .bounded_loop = bounded_loop,
            .signed_number = signed_number,
            .line_heading = line_heading,
            .line_marker = line_marker,
            .escaped_delimited = escaped_delimited,
            .word_alternation = word_alternation,
            .email = email,
            .blank_lines = blank_lines,
            .run_literals = run_literals,
            .prefix_run_literal = prefix_run_literal,
            .delimited_any = delimited_any,
            .delimited_tail = delimited_tail,
            .wrapped_run = wrapped_run,
            .paired = paired,
            .line_key = line_key,
            .line_bracket = line_bracket,
            .windows_path = windows_path,
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.pair_filter) |filter| self.allocator.destroy(filter);
        if (self.literal_set_pair) |filter| self.allocator.destroy(filter);
        if (self.run_chain) |state| self.allocator.destroy(state);
        if (self.literal_run) |state| state.deinit(self.allocator);
        if (self.fixed_sequence) |state| self.allocator.destroy(state);
        if (self.bounded_sequence) |state| self.allocator.destroy(state);
        if (self.unbounded_sequence) |state| {
            state.deinit(self.allocator);
            self.allocator.destroy(state);
        }
        if (self.star_literal) |state| {
            state.run.deinit(self.allocator);
            self.allocator.destroy(state);
        }
        if (self.line_marker) |state| self.allocator.destroy(state);
        if (self.line_heading) |state| {
            state.run.deinit(self.allocator);
            self.allocator.destroy(state);
        }
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

    /// Find the leftmost-first match at or after `search_start`. The hot
    /// short-match scanners are inlined here so their code does not depend on
    /// the inlining budget of the full dispatch, which keeps growing.
    pub fn find(
        self: *Workspace,
        input: []const u8,
        search_start: usize,
    ) Error!?Match {
        if (self.start_anchored and search_start != 0) return null;
        if (self.fast_kind == .set_run) return self.findSetRun(self.simple_set.?, input, search_start);
        if (self.fast_kind == .none) {
            if (self.fast_branch) |*branch| {
                if (self.findFastBranch(branch, input, search_start)) |match| return match;
            }
        }
        return @call(.never_inline, findDispatch, .{ self, input, search_start });
    }

    fn findDispatch(
        self: *Workspace,
        input: []const u8,
        search_start: usize,
    ) Error!?Match {
        switch (self.fast_kind) {
            .set_run => unreachable,
            .set_run_min => return self.findSetRunMin(input, search_start),
            // `find` already tried the dominant branch; a miss falls through
            // to the general engine.
            .none => {},
            .utf8_run => return self.findSetRunUtf8(&self.utf8_run.?, input, search_start),
            .utf8_run_prepared => return self.findPreparedSetRunUtf8(&self.utf8_run.?, input, search_start),
            .chain => return self.findChain(&self.simple_chain.?, input, search_start),
            .literal_run => return self.findLiteralRun(self.literal_run.?, input, search_start),
            .anchored => return if (self.anchored_ascii)
                self.findAnchoredRun(true, self.simple_anchored.?, input, search_start)
            else
                self.findAnchoredRun(false, self.simple_anchored.?, input, search_start),
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
            .caseless_literal => switch (self.findCaselessLiteral(input, search_start)) {
                .found => |match| return match,
                .absent => return null,
                .fallback => {},
            },
            .literal_multi => return self.findLiteralMultiShared(input, search_start),
            .literal_multi_distinct => {
                if (!self.findLiteralMultiDistinct(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .literal_pair => {
                if (!self.findLiteralPair(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .literal_bytes => {
                if (!self.findLiteralBytes(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .literal_first => return self.findLiteralFirst(input, search_start),
            .caseless_literal_set => {
                if (!self.findCaselessLiteralSet(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .repeated_literal => return self.findRepeatedLiteral(&self.repeated_literal.?, input, search_start),
            .run_then_literal => return self.findRunThenLiteral(&self.run_then_literal.?, input, search_start),
            .fixed_sequence => return self.findFixedSequence(self.fixed_sequence.?, input, search_start),
            .line_start_run => return self.findLineStartRun(&self.line_start_run.?, input, search_start),
            .bounded_sequence => return self.findBoundedSequence(self.bounded_sequence.?, input, search_start),
            .unbounded_sequence => return self.findUnboundedSequence(false, self.unbounded_sequence.?, input, search_start),
            .unbounded_sequence_fused => return self.findUnboundedSequence(true, self.unbounded_sequence.?, input, search_start),
            .star_literal => return self.findStarLiteral(self.star_literal.?, input, search_start),
            .prefix_run => return self.findPrefixRun(&self.prefix_run.?, input, search_start),
            .chain_loop => return self.findChainLoop(&self.chain_loop.?, input, search_start),
            .optional_tail => return self.findOptionalTail(&self.optional_tail.?, input, search_start),
            .bounded_loop => return self.findBoundedLoop(&self.bounded_loop.?, input, search_start),
            .signed_number => return self.findSignedNumber(&self.signed_number.?, input, search_start),
            .line_heading => return self.findLineHeading(self.line_heading.?, input, search_start),
            .line_marker => return self.findLineMarker(self.line_marker.?, input, search_start),
            .escaped_delimited => return self.findEscapedDelimited(&self.escaped_delimited.?, input, search_start),
            .word_alternation => return self.findWordAlternation(&self.word_alternation.?, input, search_start),
            .email => return self.findEmail(&self.email.?, input, search_start),
            .blank_lines => return self.findBlankLines(&self.blank_lines.?, input, search_start),
            .run_literals => return self.findRunLiterals(&self.run_literals.?, input, search_start),
            .prefix_run_literal => return self.findPrefixRunLiteral(&self.prefix_run_literal.?, input, search_start),
            .delimited_any => return self.findDelimitedAny(&self.delimited_any.?, input, search_start),
            .delimited_tail => return self.findDelimitedTail(&self.delimited_tail.?, input, search_start),
            .wrapped_run => return self.findWrappedRun(&self.wrapped_run.?, input, search_start),
            .paired => return self.findPaired(&self.paired.?, input, search_start),
            .line_key => return self.findLineKey(&self.line_key.?, input, search_start),
            .line_bracket => return self.findLineBracket(&self.line_bracket.?, input, search_start),
            .windows_path => return self.findWindowsPath(&self.windows_path.?, input, search_start),
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
            .set_run_min => return self.findSetRunMin(input, search_start),
            .utf8_run => return self.findSetRunUtf8(&self.utf8_run.?, input, search_start),
            .utf8_run_prepared => return self.findPreparedSetRunUtf8(&self.utf8_run.?, input, search_start),
            .chain => return self.findChain(&self.simple_chain.?, input, search_start),
            .literal_run => return self.findLiteralRun(self.literal_run.?, input, search_start),
            .anchored => return if (self.anchored_ascii)
                self.findAnchoredRun(true, self.simple_anchored.?, input, search_start)
            else
                self.findAnchoredRun(false, self.simple_anchored.?, input, search_start),
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
            .caseless_literal => switch (self.findCaselessLiteral(input, search_start)) {
                .found => |match| return match,
                .absent => return null,
                .fallback => {},
            },
            .literal_multi => return self.findLiteralMultiShared(input, search_start),
            .literal_multi_distinct => {
                if (!self.findLiteralMultiDistinct(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .literal_pair => {
                if (!self.findLiteralPair(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .literal_bytes => {
                if (!self.findLiteralBytes(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .literal_first => return self.findLiteralFirst(input, search_start),
            .caseless_literal_set => {
                if (!self.findCaselessLiteralSet(input, search_start)) return null;
                return .{ .start = self.slots[0], .end = self.slots[1], .slots = self.slots };
            },
            .repeated_literal => return self.findRepeatedLiteral(&self.repeated_literal.?, input, search_start),
            .run_then_literal => return self.findRunThenLiteral(&self.run_then_literal.?, input, search_start),
            .fixed_sequence => return self.findFixedSequence(self.fixed_sequence.?, input, search_start),
            .line_start_run => return self.findLineStartRun(&self.line_start_run.?, input, search_start),
            .bounded_sequence => return self.findBoundedSequence(self.bounded_sequence.?, input, search_start),
            .unbounded_sequence => return self.findUnboundedSequence(false, self.unbounded_sequence.?, input, search_start),
            .unbounded_sequence_fused => return self.findUnboundedSequence(true, self.unbounded_sequence.?, input, search_start),
            .star_literal => return self.findStarLiteral(self.star_literal.?, input, search_start),
            .prefix_run => return self.findPrefixRun(&self.prefix_run.?, input, search_start),
            .chain_loop => return self.findChainLoop(&self.chain_loop.?, input, search_start),
            .optional_tail => return self.findOptionalTail(&self.optional_tail.?, input, search_start),
            .bounded_loop => return self.findBoundedLoop(&self.bounded_loop.?, input, search_start),
            .signed_number => return self.findSignedNumber(&self.signed_number.?, input, search_start),
            .line_heading => return self.findLineHeading(self.line_heading.?, input, search_start),
            .line_marker => return self.findLineMarker(self.line_marker.?, input, search_start),
            .escaped_delimited => return self.findEscapedDelimited(&self.escaped_delimited.?, input, search_start),
            .word_alternation => return self.findWordAlternation(&self.word_alternation.?, input, search_start),
            .email => return self.findEmail(&self.email.?, input, search_start),
            .blank_lines => return self.findBlankLines(&self.blank_lines.?, input, search_start),
            .run_literals => return self.findRunLiterals(&self.run_literals.?, input, search_start),
            .prefix_run_literal => return self.findPrefixRunLiteral(&self.prefix_run_literal.?, input, search_start),
            .delimited_any => return self.findDelimitedAny(&self.delimited_any.?, input, search_start),
            .delimited_tail => return self.findDelimitedTail(&self.delimited_tail.?, input, search_start),
            .wrapped_run => return self.findWrappedRun(&self.wrapped_run.?, input, search_start),
            .paired => return self.findPaired(&self.paired.?, input, search_start),
            .line_key => return self.findLineKey(&self.line_key.?, input, search_start),
            .line_bracket => return self.findLineBracket(&self.line_bracket.?, input, search_start),
            .windows_path => return self.findWindowsPath(&self.windows_path.?, input, search_start),
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
    inline fn findSetRun(self: *Workspace, set: model.Set, input: []const u8, search_start: usize) ?Match {
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

    /// `set{min,}` with `min > 1`: maximal runs shorter than the minimum are
    /// skipped whole, because every start inside them fails too.
    fn findSetRunMin(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        if (!self.first_filter.first.nonascii and
            (self.first_filter.range_count != 0 or
                (self.first_filter.count != 0 and !self.first_filter.too_many)))
        {
            return self.findSetRunMinPairs(input, search_start);
        }
        const table = &self.simple_set_table;
        const min = self.simple_set_min;
        var search = search_start;
        while (search < input.len) {
            var offset = search;
            const scalar_limit = @min(input.len, offset + 32);
            while (offset < scalar_limit and !table[input[offset]]) offset += 1;
            if (offset >= scalar_limit) {
                if (offset >= input.len) return null;
                offset = self.first_filter.indexOf(input, offset) orelse return null;
            }
            const start = offset;
            offset += 1;
            while (offset < input.len and table[input[offset]]) offset += 1;
            if (offset - start >= min) {
                self.slots[0] = start;
                self.slots[1] = offset;
                return .{ .start = start, .end = offset, .slots = self.slots };
            }
            search = offset;
        }
        return null;
    }

    /// `set{min,}` pair scan: a SIMD test finds the first position whose next
    /// byte is also a member, so runs below the minimum are rejected in
    /// 16-byte blocks instead of one table lookup per byte.
    fn findSetRunMinPairs(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        const table = &self.simple_set_table;
        const min = self.simple_set_min;
        const Vec = @Vector(16, u8);
        var search = search_start;
        while (search + 1 < input.len) {
            var offset = search;
            var candidate: ?usize = null;
            while (offset + 17 <= input.len) : (offset += 16) {
                const chunk: Vec = input[offset..][0..16].*;
                const next: Vec = input[offset + 1 ..][0..16].*;
                const mask = self.first_filter.memberMask(chunk) & self.first_filter.memberMask(next);
                const bits: u16 = @bitCast(mask);
                if (bits != 0) {
                    candidate = offset + @ctz(bits);
                    break;
                }
            }
            if (candidate == null) {
                var index = offset;
                while (index + 1 < input.len) : (index += 1) {
                    if (table[input[index]] and table[input[index + 1]]) {
                        candidate = index;
                        break;
                    }
                }
            }
            const start = candidate orelse return null;
            var end = start + 2;
            while (end < input.len and table[input[end]]) end += 1;
            if (end - start >= min) {
                self.slots[0] = start;
                self.slots[1] = end;
                return .{ .start = start, .end = end, .slots = self.slots };
            }
            search = end;
        }
        return null;
    }

    /// Try the dominant alternation branch at `search_start`. Returns null
    /// when an earlier branch could start here or this branch does not match;
    /// the general engine then decides.
    /// `quote (?: escape any | [^quote escape])* quote`: the body set is
    /// exactly the complement of the quote and escape bytes, so scanning for
    /// the closing quote only has to honor escape sequences and valid UTF-8.
    fn findEscapedDelimited(self: *Workspace, state: *const EscapedDelimitedState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const open = prefilter.indexOfByte(input, search, state.quote) orelse return null;
            var pos = open + 1;
            var failed = false;
            while (pos < input.len) {
                const byte = input[pos];
                if (byte == state.quote) {
                    self.slots[0] = open;
                    self.slots[1] = pos + 1;
                    return .{ .start = open, .end = pos + 1, .slots = self.slots };
                }
                if (byte == state.escape) {
                    if (pos + 1 >= input.len) {
                        failed = true;
                        break;
                    }
                    const next = input[pos + 1];
                    if (next < 0x80) {
                        // `.` excludes the LF newline.
                        if (next == '\n') {
                            failed = true;
                            break;
                        }
                        pos += 2;
                    } else {
                        const length = std.unicode.utf8ByteSequenceLength(next) catch {
                            failed = true;
                            break;
                        };
                        if (pos + 1 + length > input.len) {
                            failed = true;
                            break;
                        }
                        _ = std.unicode.utf8Decode(input[pos + 1 ..][0..length]) catch {
                            failed = true;
                            break;
                        };
                        pos += 1 + length;
                    }
                    continue;
                }
                if (byte < 0x80) {
                    pos += 1;
                    continue;
                }
                const length = std.unicode.utf8ByteSequenceLength(byte) catch {
                    failed = true;
                    break;
                };
                if (pos + length > input.len) {
                    failed = true;
                    break;
                }
                _ = std.unicode.utf8Decode(input[pos..][0..length]) catch {
                    failed = true;
                    break;
                };
                pos += length;
            }
            if (!failed) return null;
            search = open + 1;
        }
        return null;
    }

    /// `\b (?:word|word|...) \b`: a folded two-byte pair scan proposes the
    /// next candidate start, then the shared word boundaries and the
    /// alternatives are verified in source order. Pair candidates are rare,
    /// and verification handles non-ASCII fold peers exactly.
    fn findWordAlternation(self: *Workspace, state: *const WordAlternationState, input: []const u8, search_start: usize) ?Match {
        const Vec = @Vector(16, u8);
        const fold: Vec = @splat(0x20);
        var offset = search_start;
        if (state.filter.pair_nibble) |*nibble| {
            // One pass over the text; failed candidates do not restart the
            // scan, so dense pair collisions stay cheap. Two chunks per
            // iteration overlap their table lookups.
            while (offset + 33 <= input.len) : (offset += 32) {
                const a_first: Vec = @as(Vec, @bitCast(@as([16]u8, input[offset..][0..16].*))) | fold;
                const a_second: Vec = @as(Vec, @bitCast(@as([16]u8, input[offset + 1 ..][0..16].*))) | fold;
                const b_first: Vec = @as(Vec, @bitCast(@as([16]u8, input[offset + 16 ..][0..16].*))) | fold;
                const b_second: Vec = @as(Vec, @bitCast(@as([16]u8, input[offset + 17 ..][0..16].*))) | fold;
                const a_bits: u16 = @bitCast(nibble.candidates(a_first, a_second));
                const b_bits: u16 = @bitCast(nibble.candidates(b_first, b_second));
                if (a_bits != 0) {
                    var bits = a_bits;
                    while (bits != 0) {
                        const lane = @ctz(bits);
                        bits &= bits - 1;
                        if (self.matchWordAlternation(state, input, offset + lane)) |match| return match;
                    }
                }
                if (b_bits != 0) {
                    var bits = b_bits;
                    while (bits != 0) {
                        const lane = @ctz(bits);
                        bits &= bits - 1;
                        if (self.matchWordAlternation(state, input, offset + 16 + lane)) |match| return match;
                    }
                }
            }
            while (offset + 17 <= input.len) : (offset += 16) {
                const first_raw: [16]u8 = input[offset..][0..16].*;
                const second_raw: [16]u8 = input[offset + 1 ..][0..16].*;
                const first: Vec = @as(Vec, @bitCast(first_raw)) | fold;
                const second: Vec = @as(Vec, @bitCast(second_raw)) | fold;
                var bits: u16 = @bitCast(nibble.candidates(first, second));
                while (bits != 0) {
                    const lane = @ctz(bits);
                    bits &= bits - 1;
                    if (self.matchWordAlternation(state, input, offset + lane)) |match| return match;
                }
            }
        }
        while (offset < input.len) {
            const at = state.filter.indexOfPairCandidate(input, offset) orelse return null;
            if (self.matchWordAlternation(state, input, at)) |match| return match;
            offset = at + 1;
        }
        return null;
    }

    inline fn matchWordAlternation(self: *Workspace, state: *const WordAlternationState, input: []const u8, at: usize) ?Match {
        if (!wordBoundaryAt(input, at)) return null;
        for (state.literals) |literal| {
            const end = wordLiteralEnd(input, at, literal, state.caseless) orelse continue;
            if (!wordBoundaryAt(input, end)) continue;
            self.slots[0] = at;
            self.slots[1] = end;
            return .{ .start = at, .end = end, .slots = self.slots };
        }
        return null;
    }

    inline fn asciiWordByte(byte: u8) bool {
        return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z') or
            (byte >= '0' and byte <= '9') or byte == '_';
    }

    /// ASCII `\b` at `pos`: exactly one side is a word byte. A non-ASCII
    /// byte is not a word byte under the ASCII assertion.
    inline fn wordBoundaryAt(input: []const u8, pos: usize) bool {
        const before = pos > 0 and asciiWordByte(input[pos - 1]);
        const after = pos < input.len and asciiWordByte(input[pos]);
        return before != after;
    }

    /// End offset of `literal` at `offset`, folding ASCII case and accepting
    /// the non-ASCII simple-fold peers U+017F (s) and U+212A (k).
    inline fn wordLiteralEnd(input: []const u8, offset: usize, literal: []const u8, caseless: bool) ?usize {
        var pos = offset;
        for (literal) |expected| {
            if (pos >= input.len) return null;
            if (caseless) {
                if (expected == 's' and pos + 2 <= input.len and input[pos] == 0xC5 and input[pos + 1] == 0xBF) {
                    pos += 2;
                    continue;
                }
                if (expected == 'k' and pos + 3 <= input.len and input[pos] == 0xE2 and
                    input[pos + 1] == 0x84 and input[pos + 2] == 0xAA)
                {
                    pos += 3;
                    continue;
                }
                if (foldAsciiByte(input[pos]) != expected) return null;
            } else if (input[pos] != expected) return null;
            pos += 1;
        }
        return pos;
    }

    /// `\b local+ @ domain+ \. tld{min,} \b`: each `@` bounds one candidate
    /// local run. The match starts at the first boundary inside the run, and
    /// the domain is resolved by walking dots from the end, which mirrors the
    /// greedy `domain+ \.` backtracking.
    fn findEmail(self: *Workspace, state: *const EmailState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const at = prefilter.indexOfByte(input, search, '@') orelse return null;
            var start = at;
            while (start > search and state.local[input[start - 1]]) start -= 1;
            while (start < at and !wordBoundaryAt(input, start)) start += 1;
            if (start < at) {
                var end = at + 1;
                while (end < input.len and state.domain[input[end]]) end += 1;
                var dot = end;
                while (dot > at + 2) {
                    dot -= 1;
                    if (input[dot] != '.') continue;
                    var tail = dot + 1;
                    while (tail < input.len and state.tld[input[tail]]) tail += 1;
                    if (tail - (dot + 1) < state.tld_min) continue;
                    if (!wordBoundaryAt(input, tail)) continue;
                    self.slots[0] = start;
                    self.slots[1] = tail;
                    return .{ .start = start, .end = tail, .slots = self.slots };
                }
            }
            search = at + 1;
        }
        return null;
    }

    /// `(?m)^\s*$` in LF mode: at each line start the greedy whitespace run
    /// either reaches the text end or ends at the last line break inside the
    /// run, which is the final `$` position the engine backtracks to.
    fn findBlankLines(self: *Workspace, state: *const BlankLinesState, input: []const u8, search_start: usize) ?Match {
        if (search_start > input.len) return null;
        var line = search_start;
        if (line > 0 and input[line - 1] != '\n') line = nextLineStart(input, line) orelse return null;
        while (line <= input.len) {
            var pos = line;
            while (pos < input.len and state.space[input[pos]]) pos += 1;
            if (pos == input.len) {
                self.slots[0] = line;
                self.slots[1] = pos;
                return .{ .start = line, .end = pos, .slots = self.slots };
            }
            var end = pos;
            while (end > line) {
                end -= 1;
                if (input[end] == '\n') {
                    self.slots[0] = line;
                    self.slots[1] = end;
                    return .{ .start = line, .end = end, .slots = self.slots };
                }
            }
            line = nextLineStart(input, pos) orelse return null;
        }
        return null;
    }

    /// `run+ literal-alternation`: the run is maximal and every alternative
    /// starts outside the run set, so a failed suffix rejects the whole run.
    fn findRunLiterals(self: *Workspace, state: *const RunLiteralsState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            // Dense runs sit a few bytes apart; probe scalar first and only
            // pay the vector setup after a long gap.
            var at = search;
            const probe_end = @min(input.len, search + 16);
            while (at < probe_end and !state.run[input[at]]) at += 1;
            if (at == probe_end) {
                at = state.filter.indexOf(input, probe_end) orelse return null;
            }
            var end = at;
            while (end < input.len and state.run[input[end]]) end += 1;
            if (end < input.len and state.first_bytes[input[end]]) {
                for (state.literals) |literal| {
                    if (end + literal.len <= input.len and std.mem.eql(u8, input[end..][0..literal.len], literal)) {
                        self.slots[0] = at;
                        self.slots[1] = end + literal.len;
                        return .{ .start = at, .end = end + literal.len, .slots = self.slots };
                    }
                }
            }
            search = end;
        }
        return null;
    }

    /// `prefix-set run+ literal`: the literal is outside the run set, so a
    /// failed check rejects every start inside the run.
    fn findPrefixRunLiteral(self: *Workspace, state: *const PrefixRunLiteralState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const at = state.prefix_filter.indexOf(input, search) orelse return null;
            var end = at + 1;
            while (end < input.len and state.run[input[end]]) end += 1;
            if (end > at + 1 and end < input.len and input[end] == state.literal) {
                self.slots[0] = at;
                self.slots[1] = end + 1;
                return .{ .start = at, .end = end + 1, .slots = self.slots };
            }
            search = end;
        }
        return null;
    }

    /// `open any*? close`: the lazy body ends at the first close after the
    /// open. A missing close rejects every later open as well.
    fn findDelimitedAny(self: *Workspace, state: *const DelimitedAnyState, input: []const u8, search_start: usize) ?Match {
        const open = indexOfBytes(input, search_start, state.open) orelse return null;
        const close = indexOfBytes(input, open + state.open.len, state.close) orelse return null;
        self.slots[0] = open;
        self.slots[1] = close + state.close.len;
        return .{ .start = open, .end = close + state.close.len, .slots = self.slots };
    }

    /// `quote body+ quote space* literal`: the quote bounds the body run, so
    /// each candidate needs one local check. A failed check resumes at the
    /// body end, which may itself be the next opening quote.
    fn findDelimitedTail(self: *Workspace, state: *const DelimitedTailState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const open = prefilter.indexOfByte(input, search, state.quote) orelse return null;
            var pos = open + 1;
            const body_start = pos;
            while (pos < input.len and state.body[input[pos]]) pos += 1;
            const body_end = pos;
            if (body_end > body_start and body_end < input.len and input[body_end] == state.quote) {
                var tail = body_end + 1;
                while (tail < input.len and state.space[input[tail]]) tail += 1;
                if (tail < input.len and input[tail] == state.literal) {
                    self.slots[0] = open;
                    self.slots[1] = tail + 1;
                    return .{ .start = open, .end = tail + 1, .slots = self.slots };
                }
            }
            // The body end may itself be the next opening quote.
            search = body_end;
        }
        return null;
    }

    /// `open body+ close`: the body excludes the close's first byte, so a
    /// failed close check rejects the run and the scan resumes after the open.
    fn findWrappedRun(self: *Workspace, state: *const WrappedRunState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const open = indexOfBytes(input, search, state.open) orelse return null;
            var pos = open + state.open.len;
            const body_start = pos;
            while (pos < input.len and state.body[input[pos]]) pos += 1;
            if (pos > body_start and pos + state.close.len <= input.len and
                std.mem.eql(u8, input[pos..][0..state.close.len], state.close))
            {
                self.slots[0] = open;
                self.slots[1] = pos + state.close.len;
                return .{ .start = open, .end = pos + state.close.len, .slots = self.slots };
            }
            search = open + 1;
        }
        return null;
    }

    /// `open1 body1+ close1 open2 body2+ close2`: both bodies exclude their
    /// closer, so each candidate needs one local check.
    fn findPaired(self: *Workspace, state: *const PairedState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const open = prefilter.indexOfByte(input, search, state.open1) orelse return null;
            var pos = open + 1;
            const body1_start = pos;
            while (pos < input.len and state.body1[input[pos]]) pos += 1;
            if (pos > body1_start and pos + 2 <= input.len and input[pos] == state.close1 and
                input[pos + 1] == state.open2)
            {
                var tail = pos + 2;
                const body2_start = tail;
                while (tail < input.len and state.body2[input[tail]]) tail += 1;
                if (tail > body2_start and tail < input.len and input[tail] == state.close2) {
                    self.slots[0] = open;
                    self.slots[1] = tail + 1;
                    return .{ .start = open, .end = tail + 1, .slots = self.slots };
                }
            }
            search = open + 1;
        }
        return null;
    }

    /// `(?m)^space* run+ literal`: each line start skips the space run, then
    /// the key run must be followed directly by the literal.
    fn findLineKey(self: *Workspace, state: *const LineKeyState, input: []const u8, search_start: usize) ?Match {
        if (search_start > input.len) return null;
        var line = search_start;
        if (line > 0 and input[line - 1] != '\n') line = nextLineStart(input, line) orelse return null;
        while (line < input.len) {
            var pos = line;
            while (pos < input.len and state.space[input[pos]]) pos += 1;
            const run_start = pos;
            while (pos < input.len and state.run[input[pos]]) pos += 1;
            if (pos > run_start and pos < input.len and input[pos] == state.literal) {
                self.slots[0] = line;
                self.slots[1] = pos + 1;
                return .{ .start = line, .end = pos + 1, .slots = self.slots };
            }
            if (pos >= input.len) return null;
            line = nextLineStart(input, pos) orelse return null;
        }
        return null;
    }

    /// `(?m)^\[ run+ \]$`: each line start checks the bracket, the run and the
    /// line end.
    fn findLineBracket(self: *Workspace, state: *const LineBracketState, input: []const u8, search_start: usize) ?Match {
        if (search_start > input.len) return null;
        var line = search_start;
        if (line > 0 and input[line - 1] != '\n') line = nextLineStart(input, line) orelse return null;
        while (line < input.len) {
            var pos = line;
            if (input[pos] == '[') {
                pos += 1;
                const run_start = pos;
                while (pos < input.len and state.run[input[pos]]) pos += 1;
                if (pos > run_start and pos < input.len and input[pos] == ']' and
                    (pos + 1 == input.len or input[pos + 1] == '\n'))
                {
                    self.slots[0] = line;
                    self.slots[1] = pos + 1;
                    return .{ .start = line, .end = pos + 1, .slots = self.slots };
                }
            }
            if (pos >= input.len) return null;
            line = nextLineStart(input, pos) orelse return null;
        }
        return null;
    }

    /// `letters : \ run+`: each colon checks the drive letter before it and
    /// the separator after it, then consumes the path run.
    fn findWindowsPath(self: *Workspace, state: *const WindowsPathState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const colon = prefilter.indexOfByte(input, search, ':') orelse return null;
            if (colon > search and state.letters[input[colon - 1]] and colon + 1 < input.len and
                input[colon + 1] == '\\')
            {
                var pos = colon + 2;
                const run_start = pos;
                while (pos < input.len and state.run[input[pos]]) pos += 1;
                if (pos > run_start) {
                    self.slots[0] = colon - 1;
                    self.slots[1] = pos;
                    return .{ .start = colon - 1, .end = pos, .slots = self.slots };
                }
            }
            search = colon + 1;
        }
        return null;
    }

    /// First occurrence of `needle` at or after `start`. Two-byte needles
    /// use the SIMD pair scan; longer needles scan for their rarest byte and
    /// verify the full window, which is much faster than a two-byte prefix
    /// when the prefix is common.
    fn indexOfBytes(input: []const u8, start: usize, needle: []const u8) ?usize {
        if (needle.len == 1) return prefilter.indexOfByte(input, start, needle[0]);
        if (needle.len == 2) return prefilter.indexOfPair(input, start, needle[0], needle[1]);
        const anchor = prefilter.rarestByte(needle);
        var offset = start;
        while (prefilter.indexOfByte(input, offset + anchor, needle[anchor])) |found| {
            const at = found - anchor;
            if (at >= offset and at + needle.len <= input.len and
                std.mem.eql(u8, input[at..][0..needle.len], needle)) return at;
            offset = at + 1;
        }
        return null;
    }

    /// `(?m)^space* marker literal`: the whitespace run is maximal, so the
    /// marker must follow it directly. Line starts whose run reaches the same
    /// failure point are skipped together.
    /// `(?m)^space* marker trailing`: any match contains a marker byte, so
    /// scan for the next marker and walk back over the maximal space run.
    /// The run may cross line breaks, so the match starts at the first line
    /// start inside it that is not before `search_start`.
    fn findLineMarker(self: *Workspace, state: *const LineMarkerState, input: []const u8, search_start: usize) ?Match {
        var search = search_start;
        while (search < input.len) {
            const pos = state.marker_filter.indexOf(input, search) orelse return null;
            var run_start = pos;
            while (run_start > 0 and state.space[input[run_start - 1]]) run_start -= 1;
            var line = @max(run_start, search_start);
            while (line < pos and line != 0 and input[line - 1] != '\n') line += 1;
            if (line != 0 and input[line - 1] != '\n') {
                search = pos + 1;
                continue;
            }
            if (pos + 1 < input.len and state.trailing[input[pos + 1]]) {
                var end = pos + 2;
                if (state.trailing_run) {
                    while (end < input.len and state.trailing[input[end]]) end += 1;
                }
                self.slots[0] = line;
                self.slots[1] = end;
                return .{ .start = line, .end = end, .slots = self.slots };
            }
            search = pos + 1;
        }
        return null;
    }

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

    /// Folded-literal scan result. `absent` is definitive because every
    /// non-ASCII input byte is a filter hit and would have reached
    /// verification; `fallback` means a non-ASCII byte may hide a Unicode
    /// simple-fold peer (U+017F for `s`), so the general engine must decide.
    const CaselessScan = union(enum) {
        found: Match,
        absent,
        fallback,
    };

    /// A pure `(?i)` literal. The folded pair filter proposes the earliest
    /// possible start; ASCII windows are verified here instead of entering
    /// the DFA, and windows with a non-ASCII byte fall back to it for
    /// Unicode simple folding.
    fn findCaselessLiteral(self: *Workspace, input: []const u8, search_start: usize) CaselessScan {
        const literal = self.program.caseless_literal.?;
        for (literal) |byte| if (byte >= 0x80) return .fallback;
        const filter = self.fold_filter orelse return .fallback;
        var search = search_start;
        while (true) {
            const start = filter.indexOf(input, search) orelse return .absent;
            if (start + literal.len > input.len) return .absent;
            var matched = true;
            for (literal, 0..) |literal_byte, index| {
                const byte = input[start + index];
                if (byte >= 0x80) return .fallback;
                if (foldAsciiByte(byte) != foldAsciiByte(literal_byte)) {
                    matched = false;
                    break;
                }
            }
            if (matched) {
                self.slots[0] = start;
                self.slots[1] = start + literal.len;
                return .{ .found = .{ .start = start, .end = start + literal.len, .slots = self.slots } };
            }
            search = start + 1;
        }
    }

    /// A small pure literal alternation. The splat filter reports the matching
    /// branch, so the span is returned without a second verification pass.
    fn findLiteralMultiShared(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        // Shared-prefix candidates pin the first byte, so the few branches
        // verify cheaply at the candidate.
        const filter = &self.literal_set_multi.?;
        const literals = self.program.literal_set.?;
        var search = search_start;
        while (search < input.len) {
            const start = filter.indexOf(input, search) orelse return null;
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

    fn findLiteralMultiDistinct(self: *Workspace, input: []const u8, search_start: usize) bool {
        const filter = &self.literal_set_multi.?;
        var literal_index: usize = undefined;
        const start = filter.indexOfMatch(input, search_start, &literal_index) orelse return false;
        const literal = filter.literals[literal_index];
        self.slots[0] = start;
        self.slots[1] = start + literal.len;
        return true;
    }

    /// A wide pure literal alternation. The nibble filter reports the matching
    /// branch, so the span is returned without a second verification pass.
    fn findLiteralPair(self: *Workspace, input: []const u8, search_start: usize) bool {
        const filter = self.literal_set_pair.?;
        var literal_index: usize = undefined;
        const start = filter.indexOfAnyMatch(input, search_start, &literal_index) orelse return false;
        const literal = filter.literals[literal_index];
        self.slots[0] = start;
        self.slots[1] = start + literal.len;
        return true;
    }

    /// Every branch is one byte, so the first-byte scan is the match.
    fn findLiteralBytes(self: *Workspace, input: []const u8, search_start: usize) bool {
        const start = self.first_filter.indexOf(input, search_start) orelse return false;
        self.slots[0] = start;
        self.slots[1] = start + 1;
        return true;
    }

    /// A whole-pattern case-folded literal alternation. The folded filter
    /// reports the matching branch, so the span is returned directly.
    fn findCaselessLiteralSet(self: *Workspace, input: []const u8, search_start: usize) bool {
        const filter = &self.caseless_literal_set.?;
        var literal_index: usize = undefined;
        const start = filter.indexOfCaseless(input, search_start, &literal_index) orelse return false;
        const literal = filter.literals[literal_index];
        self.slots[0] = start;
        self.slots[1] = start + literal.len;
        return true;
    }

    /// `(?:literal)+`: find the literal, then consume greedy repetitions.
    fn findRepeatedLiteral(self: *Workspace, state: *const RepeatedLiteralState, input: []const u8, search_start: usize) ?Match {
        const literal = state.literal[0..state.literal_len];
        const first = literal[0];
        var start = search_start;
        while (start < input.len) {
            while (start < input.len and input[start] != first) start += 1;
            if (start + literal.len > input.len) return null;
            if (!std.mem.eql(u8, input[start..][0..literal.len], literal)) {
                start += 1;
                continue;
            }
            var end = start + literal.len;
            while (end + literal.len <= input.len and std.mem.eql(u8, input[end..][0..literal.len], literal)) {
                end += literal.len;
            }
            self.slots[0] = start;
            self.slots[1] = end;
            return .{ .start = start, .end = end, .slots = self.slots };
        }
        return null;
    }

    /// The first-byte filter proposes candidates; the branches are checked in
    /// source order at that position, which is exactly leftmost-first.
    fn findLiteralFirst(self: *Workspace, input: []const u8, search_start: usize) ?Match {
        const literals = self.program.literal_set.?;
        var search = search_start;
        while (search < input.len) {
            const start = self.first_filter.indexOf(input, search) orelse return null;
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
            if (element.kind == .optional_group) {
                // Trailing group: present when the separator and its bounded
                // run match, otherwise absent.
                if (pos < input.len and input[pos] == element.separator) {
                    const table = &state.tables[element.set];
                    var count: usize = 0;
                    const limit = @min(@as(usize, element.max), input.len - pos - 1);
                    while (count < limit and table[input[pos + 1 + count]]) count += 1;
                    if (count >= element.min) pos += 1 + count;
                }
                continue;
            }
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
        if (element.kind == .optional_group) {
            if (pos < input.len and input[pos] == element.separator) {
                const table = &state.tables[element.set];
                var count: usize = 0;
                const limit = @min(@as(usize, element.max), input.len - pos - 1);
                while (count < limit and table[input[pos + 1 + count]]) count += 1;
                if (count >= element.min) return pos + 1 + count;
            }
            return pos;
        }
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

    /// `[a-z]+[A-Z][a-z]+`: one lower run, one upper byte, one lower run.
    /// The runs are maximal and the sets are disjoint, so a failed start
    /// skips the whole first run exactly like the generic walk.
    fn walkCamel(self: *Workspace, state: *const UnboundedSequenceState, input: []const u8, search_start: usize) ?Match {
        const lo = state.camel_lo;
        const span = state.camel_span;
        const upper_lo = state.camel_upper_lo;
        const upper_span = state.camel_upper_span;
        var start = search_start;
        while (start < input.len) {
            if (input[start] -% lo > span) {
                start += 1;
                continue;
            }
            var pos = start;
            while (pos < input.len and input[pos] -% lo <= span) pos += 1;
            if (pos < input.len and input[pos] -% upper_lo <= upper_span) {
                const after_upper = pos + 1;
                if (after_upper < input.len and input[after_upper] -% lo <= span) {
                    var end = after_upper;
                    while (end < input.len and input[end] -% lo <= span) end += 1;
                    self.slots[0] = start;
                    self.slots[1] = end;
                    return .{ .start = start, .end = end, .slots = self.slots };
                }
            }
            // Every start inside the first run shares its end.
            start = pos;
        }
        return null;
    }

    /// Unbounded run chain: each run is maximal and the following literal's
    /// first byte is outside the run set, so the flat walk needs no
    /// backtracking.
    fn findUnboundedSequence(
        self: *Workspace,
        comptime fuse: bool,
        state: *UnboundedSequenceState,
        input: []const u8,
        search_start: usize,
    ) ?Match {
        if (!fuse and state.camel) return self.walkCamel(state, input, search_start);
        if (search_start >= input.len) return null;
        var start = search_start;
        while (start < input.len) : (start += 1) {
            if (!state.first_table[input[start]]) continue;
            var pos = start;
            var index: usize = 0;
            var first_end: usize = 0;
            // Peel a run first element: it is the common chain shape, and it
            // keeps the element loop free of first-element bookkeeping.
            const first = state.elements[0];
            if (first.kind == .run_range or first.kind == .run) {
                const begin = pos;
                if (first.kind == .run_range) {
                    const set_index = if (fuse) first.value & 0x7F else first.value;
                    const lo = state.range_lo[set_index];
                    const span = state.range_hi[set_index] -% lo;
                    while (pos < input.len and input[pos] -% lo <= span) pos += 1;
                } else {
                    const set_index = if (fuse) first.value & 0x7F else first.value;
                    if (state.set_ascii[set_index]) {
                        const table = &state.tables[set_index];
                        while (pos < input.len and table[input[pos]]) pos += 1;
                    } else {
                        const runner = &state.runs[set_index].?;
                        pos = runner.runEnd(self.allocator, input, pos);
                    }
                }
                first_end = pos;
                if (pos - begin < first.len) {
                    // Every start inside the run shares its end.
                    if (first.len != 0) start = first_end;
                    continue;
                }
                if (fuse and first.value & 0x80 != 0) {
                    const following = state.elements[1];
                    const bytes = state.literal_bytes[following.value..][0..following.len];
                    if (pos >= input.len or input[pos] != bytes[0]) {
                        if (first.len != 0) start = first_end;
                        continue;
                    }
                    pos += 1;
                    index = 2;
                } else {
                    index = 1;
                }
            }
            while (index < state.len) : (index += 1) {
                const element = state.elements[index];
                if (element.kind == .literal) {
                    const bytes = state.literal_bytes[element.value..][0..element.len];
                    if (bytes.len == 1) {
                        if (pos >= input.len or input[pos] != bytes[0]) break;
                        pos += 1;
                    } else {
                        if (pos + bytes.len > input.len or !std.mem.eql(u8, input[pos..][0..bytes.len], bytes)) break;
                        pos += bytes.len;
                    }
                } else if (element.kind == .run_range) {
                    const set_index = if (fuse) element.value & 0x7F else element.value;
                    const begin = pos;
                    const lo = state.range_lo[set_index];
                    const span = state.range_hi[set_index] -% lo;
                    while (pos < input.len and input[pos] -% lo <= span) pos += 1;
                    if (pos - begin < element.len) break;
                    // Fuse a following single-byte literal to halve the loop
                    // overhead on run/literal chains.
                    if (fuse and element.value & 0x80 != 0) {
                        const following = state.elements[index + 1];
                        const bytes = state.literal_bytes[following.value..][0..following.len];
                        if (pos >= input.len or input[pos] != bytes[0]) break;
                        pos += 1;
                        index += 1;
                    }
                } else if (element.kind == .run) {
                    const set_index = if (fuse) element.value & 0x7F else element.value;
                    const begin = pos;
                    if (state.set_ascii[set_index]) {
                        const table = &state.tables[set_index];
                        while (pos < input.len and table[input[pos]]) pos += 1;
                    } else {
                        const runner = &state.runs[set_index].?;
                        pos = runner.runEnd(self.allocator, input, pos);
                    }
                    if (pos - begin < element.len) break;
                    if (fuse and element.value & 0x80 != 0) {
                        const following = state.elements[index + 1];
                        const bytes = state.literal_bytes[following.value..][0..following.len];
                        if (pos >= input.len or input[pos] != bytes[0]) break;
                        pos += 1;
                        index += 1;
                    }
                } else switch (element.kind) {
                    .optional => {
                        if (pos < input.len and input[pos] == element.value) pos += 1;
                    },
                    .single_set => {
                        if (pos < input.len and state.tables[element.value][input[pos]]) {
                            pos += 1;
                        } else break;
                    },
                    .alternation => {
                        var matched = false;
                        for (state.alternatives[element.value..][0..element.len]) |alternative| {
                            const bytes = state.literal_bytes[alternative.offset..][0..alternative.len];
                            if (pos + bytes.len <= input.len and std.mem.eql(u8, input[pos..][0..bytes.len], bytes)) {
                                pos += bytes.len;
                                matched = true;
                                break;
                            }
                        }
                        if (!matched) break;
                    },
                    else => unreachable,
                }
            }
            if (index == state.len) {
                self.slots[0] = start;
                self.slots[1] = pos;
                return .{ .start = start, .end = pos, .slots = self.slots };
            }
            // A failed start inside the first run shares the same run end and
            // the same remaining input, so the whole run can be skipped. The
            // walk already knows that end.
            if ((first.kind == .run or first.kind == .run_range) and first.len != 0) {
                start = first_end;
            }
        }
        return null;
    }

    /// `set* literal`: the greedy star consumes the maximal member run and
    /// backtracks to the last literal occurrence inside it, so a failed start
    /// skips the whole run.
    fn findStarLiteral(self: *Workspace, state: *StarLiteralState, input: []const u8, search_start: usize) ?Match {
        const literal = state.literal[0..state.literal_len];
        const dot = state.dot;
        var start = search_start;
        while (start < input.len) {
            const run_end = if (dot)
                self.dotRunEnd(state, input, start)
            else
                state.run.runEnd(self.allocator, input, start);
            if (lastLiteralInRange(input, start, run_end, literal)) |occurrence| {
                self.slots[0] = start;
                self.slots[1] = occurrence + literal.len;
                return .{ .start = start, .end = occurrence + literal.len, .slots = self.slots };
            }
            start = run_end + 1;
        }
        return null;
    }

    /// Dot-set run end: ASCII bytes are members except `\n`, so a SIMD scan
    /// finds the first line break or non-ASCII byte. Non-ASCII input defers
    /// to the general run scan, which validates UTF-8.
    fn dotRunEnd(self: *Workspace, state: *StarLiteralState, input: []const u8, start: usize) usize {
        const Vec = @Vector(16, u8);
        const line_break: Vec = @splat('\n');
        const nonascii: Vec = @splat(0x80);
        var end = start;
        while (end + 16 <= input.len) {
            const chunk: Vec = input[end..][0..16].*;
            const stop = (chunk == line_break) | (chunk >= nonascii);
            const bits: u16 = @bitCast(stop);
            if (bits != 0) {
                end += @ctz(bits);
                if (input[end] == '\n') return end;
                return state.run.runEnd(self.allocator, input, end);
            }
            end += 16;
        }
        while (end < input.len and input[end] < 0x80 and input[end] != '\n') end += 1;
        if (end >= input.len or input[end] == '\n') return end;
        return state.run.runEnd(self.allocator, input, end);
    }

    /// Last occurrence of `literal` starting in `[start, run_end]`. The
    /// literal may extend past `run_end`; only its start is bounded. A
    /// first-byte scalar scan beats a reverse memmem for short literals.
    fn lastLiteralInRange(input: []const u8, start: usize, run_end: usize, literal: []const u8) ?usize {
        const limit = @min(run_end + 1, input.len);
        if (start >= limit) return null;
        var best: ?usize = null;
        var cursor = start;
        while (cursor < limit) {
            const hit = std.mem.indexOfScalarPos(u8, input[0..limit], cursor, literal[0]) orelse break;
            if (hit + literal.len <= input.len and std.mem.eql(u8, input[hit..][0..literal.len], literal)) best = hit;
            cursor = hit + 1;
        }
        return best;
    }

    /// One set byte followed by a greedy run: the first set byte anchors the
    /// match and the run is maximal, so no backtracking is needed.
    fn findPrefixRun(self: *Workspace, state: *const PrefixRunState, input: []const u8, search_start: usize) ?Match {
        const rest = &state.table_b;
        var start = search_start;
        while (start < input.len) {
            if (state.dense) {
                // Dense first sets hit on most bytes; the scalar check beats
                // the 16-byte filter setup.
                while (start < input.len and !byte_table.has(&state.table_a, input[start])) start += 1;
                if (start >= input.len) return null;
            } else {
                start = state.first_filter.indexOf(input, start) orelse return null;
            }
            var end = start + 1;
            while (end < input.len and byte_table.has(rest, input[end])) end += 1;
            if (state.min_b == 1 and end == start + 1) {
                start += 1;
                continue;
            }
            self.slots[0] = start;
            self.slots[1] = end;
            return .{ .start = start, .end = end, .slots = self.slots };
        }
        return null;
    }

    /// A run followed by a greedy repetition of `separator run`. The
    /// separator is disjoint from both run sets, so the run ends exactly at
    /// the separator and the walk needs no backtracking.
    fn findChainLoop(self: *Workspace, state: *const ChainLoopState, input: []const u8, search_start: usize) ?Match {
        const first = &state.table_a;
        const rest = &state.table_b;
        var start = search_start;
        while (start < input.len) {
            if (!first[input[start]]) {
                start += 1;
                continue;
            }
            var end = start + 1;
            while (end < input.len and first[input[end]]) end += 1;
            var cursor = end;
            var groups: usize = 0;
            while (cursor < input.len and input[cursor] == state.separator) {
                const run_start = cursor + 1;
                if (run_start >= input.len or !rest[input[run_start]]) break;
                var run_end = run_start + 1;
                while (run_end < input.len and rest[input[run_end]]) run_end += 1;
                cursor = run_end;
                groups += 1;
            }
            if (groups >= state.min_groups) {
                self.slots[0] = start;
                self.slots[1] = cursor;
                return .{ .start = start, .end = cursor, .slots = self.slots };
            }
            start = end + 1;
        }
        return null;
    }

    /// A run, an optional `separator run` group, then a literal byte. The
    /// optional group is tried first (greedy); when its literal fails, the
    /// group is skipped and the literal is retried at the first run's end.
    fn findOptionalTail(self: *Workspace, state: *const OptionalTailState, input: []const u8, search_start: usize) ?Match {
        const first = &state.table_a;
        const rest = &state.table_b;
        var start = search_start;
        while (start < input.len) {
            if (!first[input[start]]) {
                start += 1;
                continue;
            }
            var end = start + 1;
            while (end < input.len and first[input[end]]) end += 1;
            if (end + 1 < input.len and input[end] == state.separator and rest[input[end + 1]]) {
                var group_end = end + 2;
                while (group_end < input.len and rest[input[group_end]]) group_end += 1;
                if (group_end < input.len and input[group_end] == state.literal) {
                    self.slots[0] = start;
                    self.slots[1] = group_end + 1;
                    return .{ .start = start, .end = group_end + 1, .slots = self.slots };
                }
            }
            if (end < input.len and input[end] == state.literal) {
                self.slots[0] = start;
                self.slots[1] = end + 1;
                return .{ .start = start, .end = end + 1, .slots = self.slots };
            }
            start = end + 1;
        }
        return null;
    }

    /// A bounded run then a greedy repetition of a bounded `separator run`
    /// group. The first run's width is tried greedily and shortened when the
    /// group repetition cannot start.
    fn findBoundedLoop(self: *Workspace, state: *const BoundedLoopState, input: []const u8, search_start: usize) ?Match {
        const first = &state.table_a;
        const rest = &state.table_b;
        var start = search_start;
        while (start < input.len) {
            if (!first[input[start]]) {
                start += 1;
                continue;
            }
            var count_a: usize = 0;
            while (count_a < state.max_a and start + count_a < input.len and first[input[start + count_a]]) count_a += 1;
            if (count_a < state.min_a) {
                start += 1;
                continue;
            }
            var a = count_a;
            while (a >= state.min_a) : (a -= 1) {
                var cursor = start + a;
                var groups: usize = 0;
                while (cursor < input.len and input[cursor] == state.separator) {
                    const run_start = cursor + 1;
                    var count_b: usize = 0;
                    while (count_b < state.max_b and run_start + count_b < input.len and rest[input[run_start + count_b]]) count_b += 1;
                    if (count_b < state.min_b) break;
                    cursor = run_start + count_b;
                    groups += 1;
                }
                if (groups >= state.min_groups) {
                    self.slots[0] = start;
                    self.slots[1] = cursor;
                    return .{ .start = start, .end = cursor, .slots = self.slots };
                }
            }
            start += 1;
        }
        return null;
    }

    /// A sign set followed by a greedy digit run and an optional `.digits`
    /// fraction. The sign is consumed greedily; it cannot be a digit, so a
    /// failed digit run never needs the sign-skipped retry.
    fn findSignedNumber(self: *Workspace, state: *const SignedNumberState, input: []const u8, search_start: usize) ?Match {
        const sign = &state.table_sign;
        const digits = &state.table_digits;
        var start = search_start;
        while (start < input.len) {
            var pos = start;
            if (state.optional_sign and sign[input[pos]]) pos += 1;
            const digit_start = pos;
            while (pos < input.len and digits[input[pos]]) pos += 1;
            if (pos == digit_start) {
                start += 1;
                continue;
            }
            if (state.fraction and pos + 1 < input.len and input[pos] == '.' and digits[input[pos + 1]]) {
                pos += 1;
                while (pos < input.len and digits[input[pos]]) pos += 1;
            }
            if (state.exponent and pos < input.len and state.table_exponent_marker[input[pos]]) {
                var tail = pos + 1;
                if (state.exponent_has_sign and tail < input.len and state.table_exponent_sign[input[tail]]) {
                    tail += 1;
                }
                const exponent_start = tail;
                while (tail < input.len and state.table_exponent_digits[input[tail]]) tail += 1;
                if (tail > exponent_start) pos = tail;
            }
            self.slots[0] = start;
            self.slots[1] = pos;
            return .{ .start = start, .end = pos, .slots = self.slots };
        }
        return null;
    }

    /// `(?m)^X{min,max} Y.*$`: each line start is tried, the heading run is
    /// shortened until the space matches, and the body run must reach the
    /// line end.
    fn findLineHeading(self: *Workspace, state: *LineHeadingState, input: []const u8, search_start: usize) ?Match {
        var line = search_start;
        if (line < input.len and input[line] == '\n' and (line == 0 or input[line - 1] != '\n')) {
            // The previous match ended exactly at this line break.
            line += 1;
        } else if (line > 0 and input[line - 1] != '\n') {
            line = std.mem.indexOfScalarPos(u8, input, line, '\n') orelse return null;
            line += 1;
        }
        while (line < input.len) {
            var count: usize = 0;
            while (count < state.max and line + count < input.len and input[line + count] == state.byte) count += 1;
            var body_start: ?usize = null;
            var heading = count;
            while (heading >= state.min) : (heading -= 1) {
                const pos = line + heading;
                if (pos < input.len and state.space[input[pos]]) {
                    body_start = pos + 1;
                    break;
                }
            }
            if (body_start) |start_body| {
                const run_end = state.run.runEnd(self.allocator, input, start_body);
                if (run_end == input.len or input[run_end] == '\n') {
                    self.slots[0] = line;
                    self.slots[1] = run_end;
                    return .{ .start = line, .end = run_end, .slots = self.slots };
                }
            }
            line = std.mem.indexOfScalarPos(u8, input, line, '\n') orelse return null;
            line += 1;
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
                    const end = if (branch.cjk)
                        branch.run.runEndCjk(self.allocator, input, next)
                    else
                        branch.run.runEndAsciiFirst(self.allocator, input, next);
                    if (end > next) {
                        self.slots[0] = search_start;
                        self.slots[1] = end;
                        return .{ .start = search_start, .end = end, .slots = self.slots };
                    }
                }
            }
        }
        if (input[search_start] >= 0x80 or branch.run.runeAt(self.allocator, input, search_start) != null) {
            const end = if (branch.cjk)
                branch.run.runEndCjk(self.allocator, input, search_start)
            else
                branch.run.runEndAsciiFirst(self.allocator, input, search_start);
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
                        // Try the collapsed whitespace branches in source
                        // order: `\s*[\r\n]+` through the last newline,
                        // `\s+(?!\S)` with one space of backtracking, then
                        // the bare `\s+`. A branch that cannot match falls
                        // through to the next one, and the plan ends in the
                        // general engine when none can.
                        const end = later.run.runEnd(self.allocator, input, search_start);
                        if (end == search_start) continue;
                        var match_end: usize = 0;
                        var matched = false;
                        if (later.newline_branch) {
                            var last_newline: ?usize = null;
                            var scan = search_start;
                            while (scan < end) : (scan += 1) {
                                if (input[scan] == '\n' or input[scan] == '\r') last_newline = scan;
                            }
                            if (last_newline) |at| {
                                match_end = at + 1;
                                matched = true;
                            }
                        }
                        if (!matched and later.lookahead_branch) {
                            // At the text end the lookahead succeeds; before
                            // text it needs a spare space to backtrack over.
                            if (end == input.len) {
                                match_end = end;
                                matched = true;
                            } else if (end - search_start >= 2) {
                                match_end = end - 1;
                                matched = true;
                            }
                        }
                        if (!matched and later.bare_branch) {
                            match_end = end;
                            matched = true;
                        }
                        if (!matched) continue;
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
    fn findAnchoredRun(self: *Workspace, comptime ascii: bool, anchored: AnchoredRun, input: []const u8, search_start: usize) ?Match {
        const set = anchored.set;
        const kind = anchored.kind;
        const table = &self.anchored_table;
        var offset = search_start;
        while (offset < input.len) {
            const member = if (ascii) table[input[offset]] else set.matches(input[offset]);
            if (!member) {
                offset = self.first_filter.indexOf(input, offset) orelse return null;
                if (offset >= input.len) return null;
                const candidate = if (ascii) table[input[offset]] else set.matches(input[offset]);
                if (!candidate) {
                    offset += 1;
                    continue;
                }
            }
            const start = offset;
            if (ascii) {
                while (offset < input.len and table[input[offset]]) offset += 1;
            } else {
                while (offset < input.len and set.matches(input[offset])) offset += 1;
            }
            // Every anchor kind accepted here is a line/text-end check, so a
            // run ending at an ordinary byte cannot satisfy it.
            if (offset == input.len or input[offset] == '\n' or input[offset] == '\r') {
                if (position(input, offset, self.program.newline).allows(kind)) {
                    self.slots[0] = start;
                    self.slots[1] = offset;
                    return .{ .start = start, .end = offset, .slots = self.slots };
                }
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

/// Whether two literal lists hold the same bytes in the same order.
fn sameLiterals(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
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
    bare_branch: bool = false,

    fn deinit(self: *LaterRun, allocator: std.mem.Allocator) void {
        if (self.prefix) |*prefix| prefix.deinit(allocator);
        self.run.deinit(allocator);
        if (self.tail) |*tail| tail.deinit(allocator);
    }
};

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
    const Kind = enum(u8) { run, optional_group };
    const Element = struct { kind: Kind = .run, set: u8, min: u8, max: u8, separator: u8 = 0 };

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
            self.elements[self.len] = .{
                .kind = if (element.kind == .optional_group) .optional_group else .run,
                .set = set_index,
                .min = element.min,
                .max = element.max,
                .separator = element.separator,
            };
            self.len += 1;
        }
        return true;
    }
};

const UnboundedSequenceState = struct {
    const max_elements = 32;
    const max_sets = 8;
    const max_literal_bytes = 64;
    const Kind = enum(u8) { run, run_range, literal, optional, alternation, single_set };
    /// Run `value` bytes keep the set index in the low seven bits; bit 7
    /// marks a following single-byte literal that the walk fuses into the
    /// same loop iteration.
    const Element = struct { kind: Kind, value: u8, len: u8 };
    const Alternative = struct { offset: u8, len: u8 };

    elements: [max_elements]Element = undefined,
    len: u8 = 0,
    tables: [max_sets][256]bool = undefined,
    /// Contiguous ASCII run bounds for `run_range` elements.
    range_lo: [max_sets]u8 = undefined,
    range_hi: [max_sets]u8 = undefined,
    runs: [max_sets]?deferred_utf8.Run = .{null} ** max_sets,
    set_ascii: [max_sets]bool = .{false} ** max_sets,
    set_count: u8 = 0,
    literal_bytes: [max_literal_bytes]u8 = undefined,
    literal_len: u8 = 0,
    alternatives: [16]Alternative = undefined,
    alternative_count: u8 = 0,
    first_table: [256]bool = .{false} ** 256,
    /// At least two runs are followed by a single-byte literal that the walk
    /// fuses; one fused pair does not repay the per-run marker test.
    has_fuse: bool = false,
    /// `[a-z]+[A-Z][a-z]+`: one lower run, one upper byte, one lower run.
    /// The dedicated walk skips the generic element dispatch.
    camel: bool = false,
    camel_lo: u8 = 0,
    camel_span: u8 = 0,
    camel_upper_lo: u8 = 0,
    camel_upper_span: u8 = 0,

    fn deinit(self: *UnboundedSequenceState, allocator: std.mem.Allocator) void {
        for (&self.runs) |*run| {
            if (run.*) |*value| value.deinit(allocator);
            run.* = null;
        }
    }

    fn build(self: *UnboundedSequenceState, source: []const UnboundedElement) bool {
        if (source.len > self.elements.len) return false;
        var fuse_count: usize = 0;
        for (source, 0..) |element, index| {
            if (element != .run or index + 1 >= source.len) continue;
            switch (source[index + 1]) {
                .literal => |bytes| if (bytes.len == 1) {
                    fuse_count += 1;
                },
                else => {},
            }
        }
        const fuse_enabled = fuse_count >= 2;
        self.has_fuse = fuse_enabled;
        var sets: [max_sets]model.Set = undefined;
        for (source, 0..) |element, source_index| {
            switch (element) {
                .run => |run| {
                    var set_index: u8 = 0;
                    while (set_index < self.set_count) : (set_index += 1) {
                        if (shapes.sameSet(sets[set_index], run.set)) break;
                    }
                    if (set_index == self.set_count) {
                        if (self.set_count == sets.len) return false;
                        sets[self.set_count] = run.set;
                        if (run.set.ascii_only) {
                            self.tables[self.set_count] = byte_table.init(256, run.set);
                            self.set_ascii[self.set_count] = true;
                        } else {
                            self.runs[self.set_count] = deferred_utf8.Run.init(run.set);
                            self.runs[self.set_count].?.prepare_after = std.math.maxInt(u16);
                        }
                        self.set_count += 1;
                    }
                    if (run.set.ascii_only) self.set_ascii[set_index] = true;
                    const single_range = run.set.ascii_only and run.set.ranges.len == 1 and
                        run.set.ranges[0].last < 0x80;
                    if (single_range) {
                        self.range_lo[set_index] = @intCast(run.set.ranges[0].first);
                        self.range_hi[set_index] = @intCast(run.set.ranges[0].last);
                    }
                    const fuse = fuse_enabled and source_index + 1 < source.len and switch (source[source_index + 1]) {
                        .literal => |bytes| bytes.len == 1,
                        else => false,
                    };
                    self.elements[self.len] = .{
                        .kind = if (single_range) .run_range else .run,
                        .value = set_index | (if (fuse) @as(u8, 0x80) else 0),
                        .len = run.min,
                    };
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
                .single_set => |set| {
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
                    self.elements[self.len] = .{ .kind = .single_set, .value = set_index, .len = 0 };
                },
                .alternation => |branches| {
                    if (branches.len == 0 or branches.len > std.math.maxInt(u8)) return false;
                    if (self.alternative_count + branches.len > self.alternatives.len) return false;
                    const first = self.alternative_count;
                    for (branches) |branch| {
                        if (branch.len == 0 or branch.len > std.math.maxInt(u8)) return false;
                        if (self.literal_len + branch.len > self.literal_bytes.len) return false;
                        @memcpy(self.literal_bytes[self.literal_len..][0..branch.len], branch);
                        self.alternatives[self.alternative_count] = .{
                            .offset = self.literal_len,
                            .len = @intCast(branch.len),
                        };
                        self.alternative_count += 1;
                        self.literal_len += @intCast(branch.len);
                    }
                    self.elements[self.len] = .{
                        .kind = .alternation,
                        .value = first,
                        .len = @intCast(branches.len),
                    };
                },
            }
            self.len += 1;
        }
        if (self.len == 0) return false;
        if (self.len == 3 and
            self.elements[0].kind == .run_range and self.elements[0].len == 1 and
            self.elements[1].kind == .single_set and
            self.elements[2].kind == .run_range and self.elements[2].len == 1 and
            self.elements[0].value == self.elements[2].value)
        {
            const upper = source[1].single_set;
            if (upper.ranges.len == 1 and upper.ranges[0].last < 0x80) {
                const set_index = self.elements[0].value;
                const lo = self.range_lo[set_index];
                self.camel_lo = lo;
                self.camel_span = self.range_hi[set_index] -% lo;
                self.camel_upper_lo = @intCast(upper.ranges[0].first);
                self.camel_upper_span = @intCast(upper.ranges[0].last - upper.ranges[0].first);
                self.camel = true;
            }
        }
        // Leading min-0 runs and optional literals may consume nothing, so
        // the match can start at the next element's first bytes too.
        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const element = self.elements[index];
            switch (element.kind) {
                .run, .run_range => {
                    const set_index = element.value & 0x7F;
                    if (!self.set_ascii[set_index]) return false;
                    self.first_table = mergeTables(self.first_table, self.tables[set_index]);
                    if (element.len != 0) return true;
                },
                .literal => {
                    self.first_table[self.literal_bytes[element.value]] = true;
                    return true;
                },
                .alternation => {
                    for (self.alternatives[element.value..][0..element.len]) |alternative| {
                        self.first_table[self.literal_bytes[alternative.offset]] = true;
                    }
                    return true;
                },
                .optional => self.first_table[element.value] = true,
                .single_set => {
                    self.first_table = mergeTables(self.first_table, self.tables[element.value]);
                    return true;
                },
            }
        }
        return true;
    }

    fn mergeTables(a: [256]bool, b: [256]bool) [256]bool {
        var result = a;
        for (&result, b) |*slot, byte| slot.* = slot.* or byte;
        return result;
    }
};

const EscapedDelimitedState = struct { quote: u8, escape: u8 };

const WordAlternationState = struct {
    filter: prefilter.MultiFilter,
    literals: []const []const u8,
    caseless: bool,
};

const EmailState = struct {
    local: [256]bool,
    domain: [256]bool,
    tld: [256]bool,
    tld_min: usize,
};

const BlankLinesState = struct { space: [256]bool };

const RunLiteralsState = struct {
    run: [256]bool,
    filter: prefilter.FirstFilter,
    literals: []const []const u8,
    /// First bytes of the suffix alternatives, gating the literal compare.
    first_bytes: [256]bool = .{false} ** 256,
};

const PrefixRunLiteralState = struct {
    prefix_filter: prefilter.FirstFilter,
    run: [256]bool,
    literal: u8,
};

const DelimitedAnyState = struct { open: []const u8, close: []const u8 };

const DelimitedTailState = struct {
    quote: u8,
    body: [256]bool,
    space: [256]bool,
    literal: u8,
};

const WrappedRunState = struct {
    open: []const u8,
    close: []const u8,
    body: [256]bool,
};

const PairedState = struct {
    open1: u8,
    close1: u8,
    open2: u8,
    close2: u8,
    body1: [256]bool,
    body2: [256]bool,
};

const LineKeyState = struct {
    space: [256]bool,
    run: [256]bool,
    literal: u8,
};

const LineBracketState = struct { run: [256]bool };

const WindowsPathState = struct {
    letters: [256]bool,
    run: [256]bool,
};

const LineMarkerState = struct {
    space: [256]bool,
    marker: [256]bool,
    trailing: [256]bool,
    trailing_run: bool,
    marker_filter: prefilter.FirstFilter,
};

const LineHeadingState = struct {
    byte: u8 = 0,
    min: u8 = 1,
    max: u8 = 1,
    space: [256]bool = .{false} ** 256,
    run: deferred_utf8.Run,
};

const SignedNumberState = struct {
    table_sign: [256]bool = undefined,
    table_digits: [256]bool = undefined,
    table_exponent_marker: [256]bool = undefined,
    table_exponent_sign: [256]bool = undefined,
    table_exponent_digits: [256]bool = undefined,
    fraction: bool = false,
    exponent: bool = false,
    optional_sign: bool = false,
    exponent_has_sign: bool = false,
};

const BoundedLoopState = struct {
    table_a: [256]bool = undefined,
    table_b: [256]bool = undefined,
    min_a: u8 = 1,
    max_a: u8 = 1,
    min_b: u8 = 1,
    max_b: u8 = 1,
    separator: u8 = 0,
    min_groups: u8 = 1,
};

const OptionalTailState = struct {
    table_a: [256]bool = undefined,
    table_b: [256]bool = undefined,
    separator: u8 = 0,
    literal: u8 = 0,
};

const ChainLoopState = struct {
    table_a: [256]bool = undefined,
    table_b: [256]bool = undefined,
    separator: u8 = 0,
    min_groups: u8 = 0,
};

const RepeatedLiteralState = struct {
    literal: [64]u8 = undefined,
    literal_len: u8 = 0,
};

const PrefixRunState = struct {
    table_a: [4]u64 = undefined,
    table_b: [4]u64 = undefined,
    min_b: u8 = 0,
    first_filter: prefilter.FirstFilter,
    dense: bool = false,
};

const StarLiteralShape = struct { set: model.Set, literal: [64]u8, literal_len: u8 };

const StarLiteralState = struct {
    run: deferred_utf8.Run,
    literal: [64]u8 = undefined,
    literal_len: u8 = 0,
    /// The star set is the dot set, so the run ends at the next line break.
    dot: bool = false,
};

fn detectStarLiteral(program: Program) ?StarLiteralShape {
    if (program.capture_count != 0 or program.extended) return null;
    const ins = program.instructions;
    if (ins.len < 7 or program.accept != 0) return null;
    if (std.meta.activeTag(ins[0]) != .accept or std.meta.activeTag(ins[1]) != .sub_accept or
        std.meta.activeTag(ins[2]) != .ret) return null;
    if (program.start >= ins.len) return null;
    const whole = ins[program.start];
    if (std.meta.activeTag(whole) != .save or whole.save.slot != 0 or whole.save.next != program.body) return null;
    if (program.body >= ins.len) return null;
    const star = ins[program.body];
    if (std.meta.activeTag(star) != .star or star.star.set.ranges.len == 0) return null;
    var shape = StarLiteralShape{ .set = star.star.set, .literal = undefined, .literal_len = 0 };
    var pc = star.star.next;
    while (pc < ins.len and std.meta.activeTag(ins[pc]) == .literal_byte) {
        if (shape.literal_len == shape.literal.len) return null;
        shape.literal[shape.literal_len] = ins[pc].literal_byte.value;
        shape.literal_len += 1;
        pc = ins[pc].literal_byte.next;
    }
    if (shape.literal_len == 0 or pc >= ins.len) return null;
    const save1 = ins[pc];
    if (std.meta.activeTag(save1) != .save or save1.save.slot != 1 or save1.save.next != program.accept) return null;
    return shape;
}

const FastBranch = struct {
    prior: prefilter.FirstFilter,
    prefix: ?deferred_utf8.Run,
    run: deferred_utf8.Run,
    /// The run set covers U+4E00-U+9FFF, so three-byte CJK groups can be
    /// checked in vectors before the scalar scan.
    cjk: bool = false,
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
