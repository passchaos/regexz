//! Thompson construction. Linear programs execute on the NFA/DFA/Pike paths;
//! patterns using general lookaround, backreferences, atomic groups,
//! possessive quantifiers, conditionals, or recursion are marked `extended`
//! and run on the bounded backtracking VM in `backtrack.zig`.
const std = @import("std");
const model = @import("model.zig");
const classes = @import("classes.zig");
const serialize_mod = @import("serialize.zig");
const required_literals = @import("required_literals.zig");
const start_literals_mod = @import("start_literals.zig");
const fast_branch_mod = @import("fast_branch.zig");
const zero_width_mod = @import("zero_width.zig");

pub const BoundedElement = struct {
    kind: enum { run, optional_group } = .run,
    set: model.Set,
    min: u8,
    max: u8,
    separator: u8 = 0,
};

pub const UnboundedElement = union(enum) {
    run: struct { set: model.Set, min: u8 },
    literal: []const u8,
    /// One member of a multi-member ASCII set.
    single_set: model.Set,
    optional: u8,
    alternation: []const []const u8,
};

pub const PrefixRunShape = struct { set_a: model.Set, set_b: model.Set, min_b: u8 };

pub const OptionalTailShape = struct {
    set_a: model.Set,
    set_b: model.Set,
    separator: u8,
    literal: u8,
};

pub const NumberShape = struct {
    sign: model.Set,
    digits: model.Set,
    fraction: bool,
};

pub const LineHeadingShape = struct {
    byte: u8,
    min: u8,
    max: u8,
    space: u8,
    set: model.Set,
};

pub const BoundedLoopShape = struct {
    set_a: model.Set,
    min_a: u8,
    max_a: u8,
    set_b: model.Set,
    min_b: u8,
    max_b: u8,
    separator: u8,
    min_groups: u8,
};

pub const ChainLoopShape = struct {
    set_a: model.Set,
    set_b: model.Set,
    separator: [8]u8 = undefined,
    separator_len: u8 = 0,
    min_groups: u8 = 0,
};

pub const Program = struct {
    instructions: []const model.Instruction,
    start: usize,
    /// Entry point after the initial `save` slot-0 instruction. Search
    /// engines that pre-set slot 0 can start here and skip one dispatch.
    body: usize = 0,
    /// Index of the whole-program accept instruction.
    accept: usize = 0,
    capture_count: u16 = 0,
    /// Hidden slots used by non-atomic lookaround position saves.
    extra_slots: u16 = 0,
    /// Exact UTF-8 bytes when the whole pattern is a plain literal. Full
    /// matching can then bypass the NFA entirely.
    literal: ?[]const u8 = null,
    /// Fixed literal prefix that every match must start with. Used to skip
    /// impossible search positions.
    literal_prefix: ?[]const u8 = null,
    /// Lowercase ASCII form of a whole-pattern literal under simple case
    /// folding (`(?i)STRASSE` -> `strasse`). Not serialized; deserialized
    /// programs simply skip the optimization.
    caseless_literal: ?[]const u8 = null,
    /// Whole-pattern alternation of exact literals (`alpha|gamma`), in source
    /// order. The match is the first alternative that matches at the
    /// leftmost candidate. Not serialized.
    literal_set: ?[]const []const u8 = null,
    /// Whole-pattern concatenation of bounded ASCII set runs
    /// (`\d{1,3}(?:\.\d{1,3}){3}`), at least one of which is variable
    /// width. Not serialized.
    bounded_sequence: ?[]const BoundedElement = null,
    /// Whole-pattern alternation of unbounded ASCII runs and literal
    /// separators (`v?\d+\.\d+\.\d+`). Not serialized.
    unbounded_sequence: ?[]const UnboundedElement = null,
    /// One ASCII set byte followed by a greedy unbounded run
    /// (`[A-Za-z_]\w*`). Not serialized.
    prefix_run: ?PrefixRunShape = null,
    /// A run followed by a greedy repetition of `separator run`
    /// (`[a-z0-9-]+(?:\.[a-z0-9-]+)+`). Not serialized.
    chain_loop: ?ChainLoopShape = null,
    /// A run followed by an optional `separator run` group and a literal
    /// (`\d+(?:\.\d+)?%`). Not serialized.
    optional_tail: ?OptionalTailShape = null,
    /// A bounded run followed by a greedy repetition of a bounded
    /// `separator run` group (`\d{1,3}(?:,\d{3})+`). Not serialized.
    bounded_loop: ?BoundedLoopShape = null,
    /// A sign set followed by digits and an optional fraction
    /// (`[+-]?\d+(?:\.\d+)?`). Not serialized.
    signed_number: ?NumberShape = null,
    /// `(?m)^X{min,max} Y.*$` with a literal heading byte and space. Not
    /// serialized.
    line_heading: ?LineHeadingShape = null,
    /// `x? set+` where `x` is a member of the set, which matches exactly the
    /// same spans as `set+`. Not serialized.
    optional_run: ?model.Set = null,
    /// A dominant alternation branch (`set? setB+`) that decides the match
    /// when no earlier branch can start at the current byte. Not serialized.
    fast_branch: ?fast_branch_mod.Plan = null,
    /// A zero-width edge-assertion alternation (`^|$`, `(?m)^$`, ...). Not
    /// serialized; deserialized programs skip the optimization.
    zero_width: ?zero_width_mod.Plan = null,
    /// True when a context-free lazy DFA can evaluate boolean full matches.
    dfa_eligible: bool = false,
    /// True when the program needs the extended backtracking VM.
    extended: bool = false,
    /// Newline convention for `^`, `$`, `\Z`, dot, and `\N`.
    newline: model.Newline = .lf,
    /// `(*NOTEMPTY)`: empty matches are not allowed anywhere.
    notempty: bool = false,
    /// `(*NOTEMPTY_ATSTART)`: empty matches are not allowed at the start.
    notempty_atstart: bool = false,
    /// Pattern-level resource caps.
    limit_match: usize = std.math.maxInt(usize),
    limit_depth: usize = std.math.maxInt(usize),
    limit_heap_choices: usize = std.math.maxInt(usize),
    group_names: []const model.GroupName = &.{},
    /// UCP word set, present when the pattern uses Unicode `\b`/`\B`.
    ucp_word: ?model.Set = null,
    /// Names from `(*MARK:name)` in source order.
    marks: []const []const u8 = &.{},
    /// Callout sites in source order.
    callouts: []const model.CalloutSpec = &.{},
    /// Multi-way alternation dispatch tables.
    dispatches: []const model.Dispatch = &.{},
    /// Literal-alternation start set for the multi-byte prefilter. Not
    /// serialized; deserialized programs simply skip the optimization.
    start_literals: ?[]const []const u8 = null,
    /// Conservative first-rune summary of the whole program. Search uses it
    /// to skip start positions that cannot begin a match. The default is
    /// conservative (empty matches possible, any byte allowed).
    first: model.FirstSet = .{ .nonascii = true, .empty = true },
    /// True when `first` can rule out start positions; search then runs a
    /// byte-scanning prefilter before entering the VM.
    skip_start: bool = false,
    /// Literals that every match must contain. Search scans for one of them
    /// before entering the VM; when none occurs, no match is possible.
    required_literals: ?[]const []const u8 = null,
    pub fn trackedCaptures(self: Program) u16 {
        return self.capture_count;
    }
    pub fn groupIndex(self: Program, name: []const u8) ?u16 {
        for (self.group_names) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.index;
        }
        return null;
    }
    pub fn groupName(self: Program, index: u16) ?[]const u8 {
        for (self.group_names) |entry| {
            if (entry.index == index) return entry.name;
        }
        return null;
    }
    pub fn markName(self: Program, index: u16) ?[]const u8 {
        if (index >= self.marks.len) return null;
        return self.marks[index];
    }
    /// Serialize this compiled program into a versioned binary blob.
    pub fn serialize(self: Program, allocator: std.mem.Allocator) model.Error![]u8 {
        return serialize_mod.serialize(self, allocator);
    }
    /// Load a program produced by `serialize`. The returned program borrows
    /// slices allocated in `allocator`; use an arena and keep it alive for
    /// the program's lifetime. Corrupt blobs fail with `error.InvalidRegex`.
    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) model.Error!Program {
        return serialize_mod.deserialize(allocator, bytes);
    }
};

const PendingCall = struct { instruction: usize, group: u16 };

/// Enable the experimental multi-way alternation dispatch table. It is off
/// because the split + first-byte-skip chain benchmarks faster on the
/// tokenizer and xDS workloads.
const alternation_dispatch = false;

const Builder = struct {
    allocator: std.mem.Allocator,
    limits: model.Limits,
    instructions: std.ArrayList(model.Instruction) = .empty,
    sub_accept: usize = 0,
    ret: usize = 0,
    group_nodes: []const *const model.Node = &.{},
    group_starts: []usize = &.{},
    group_compiled: []bool = &.{},
    pending_calls: std.ArrayList(PendingCall) = .empty,
    /// Emit `.star` for greedy unbounded single-set loops. Disabled for
    /// extended programs, whose backtracking VM handles the split form.
    specialize_loops: bool = true,
    /// Insert `.reset_captures` at the start of each repetition iteration.
    capture_reset: bool = false,
    /// Insert callout 255 before consuming atoms.
    auto_callout: bool = false,
    capture_count: u16 = 0,
    extra_slots: u16 = 0,
    pending_dispatches: std.ArrayList(PendingDispatch) = .empty,
    const PendingDispatch = struct { instruction: usize, branches: []const usize };
    fn emit(self: *Builder, value: model.Instruction) model.Error!usize {
        if (self.instructions.items.len >= self.limits.max_instructions) return error.RegexLimitExceeded;
        const index = self.instructions.items.len;
        try self.instructions.append(self.allocator, value);
        return index;
    }
    const SlotRange = struct { first: u16, last: u16 };

    fn collectCaptureSlots(value: *const model.Node, range: *?SlotRange) void {
        switch (value.*) {
            .capture => |capture| {
                const first = capture.index * 2;
                if (range.*) |*existing| {
                    existing.first = @min(existing.first, first);
                    existing.last = @max(existing.last, first + 2);
                } else range.* = .{ .first = first, .last = first + 2 };
                collectCaptureSlots(capture.child, range);
            },
            .group => |child| collectCaptureSlots(child, range),
            .pair => |pair| {
                collectCaptureSlots(pair.left, range);
                collectCaptureSlots(pair.right, range);
            },
            .alternate => |pair| {
                collectCaptureSlots(pair.left, range);
                collectCaptureSlots(pair.right, range);
            },
            .repeat => |repeat| collectCaptureSlots(repeat.child, range),
            .atomic => |child| collectCaptureSlots(child, range),
            .lookaround => |look| collectCaptureSlots(look.child, range),
            .script_run => |run| collectCaptureSlots(run.child, range),
            .scan_substring => |scan| collectCaptureSlots(scan.child, range),
            .conditional => |cond| {
                collectCaptureSlots(cond.yes, range);
                if (cond.no) |no| collectCaptureSlots(no, range);
            },
            else => {},
        }
    }

    fn collectAlternatives(self: *Builder, value: *const model.Node, list: *std.ArrayList(*const model.Node)) model.Error!void {
        switch (value.*) {
            .alternate => |pair| {
                try self.collectAlternatives(pair.left, list);
                try self.collectAlternatives(pair.right, list);
            },
            else => try list.append(self.allocator, value),
        }
    }

    fn repeatChild(self: *Builder, child: *const model.Node, continuation: usize) model.Error!usize {
        if (self.capture_reset) {
            var range: ?SlotRange = null;
            collectCaptureSlots(child, &range);
            if (range) |slots| {
                const body = try self.node(child, continuation);
                return self.emit(.{ .reset_captures = .{ .first = slots.first, .last = slots.last, .next = body } });
            }
        }
        return self.node(child, continuation);
    }

    fn repeatNode(self: *Builder, repeat: anytype, continuation: usize) model.Error!usize {
        if (repeat.maximum == null and !repeat.lazy and self.specialize_loops and repeat.child.* == .set) {
            // `x{min,}` over a single set: emit `min` mandatory copies and
            // one greedy star. The star backtracks by re-entering the loop
            // one rune earlier, so a run costs O(1) choice memory.
            var next = try self.emit(.{ .star = .{ .set = repeat.child.set, .next = continuation } });
            var remaining = repeat.minimum;
            while (remaining != 0) : (remaining -= 1) next = try self.repeatChild(repeat.child, next);
            return next;
        }
        var next = continuation;
        if (repeat.maximum) |maximum| {
            for (repeat.minimum..maximum) |_| {
                const child = try self.repeatChild(repeat.child, next);
                next = try self.emit(if (repeat.lazy)
                    .{ .split = .{ .left = next, .right = child } }
                else
                    .{ .split = .{ .left = child, .right = next } });
            }
            for (0..repeat.minimum) |_| next = try self.repeatChild(repeat.child, next);
            return next;
        }
        if (repeat.minimum == 0) {
            const split = try self.emit(.{ .split = .{ .left = 0, .right = 0 } });
            const child = try self.repeatChild(repeat.child, split);
            self.instructions.items[split].split = if (repeat.lazy)
                .{ .left = next, .right = child }
            else
                .{ .left = child, .right = next };
            return split;
        }
        // `x{min,}` with min >= 1: enter the loop body directly and reuse it
        // for the first iteration instead of compiling a second copy. The
        // smaller program also keeps behaviorally equal DFA states merged.
        const split = try self.emit(.{ .split = .{ .left = 0, .right = 0 } });
        next = try self.repeatChild(repeat.child, split);
        self.instructions.items[split].split = if (repeat.lazy)
            .{ .left = continuation, .right = next }
        else
            .{ .left = next, .right = continuation };
        var remaining = repeat.minimum - 1;
        while (remaining != 0) : (remaining -= 1) next = try self.repeatChild(repeat.child, next);
        return next;
    }
    fn node(self: *Builder, value: *const model.Node, continuation: usize) model.Error!usize {
        if (self.auto_callout) {
            const needs_callout = switch (value.*) {
                .set, .byte, .grapheme, .backref, .assertion, .lookahead_set => true,
                else => false,
            };
            if (needs_callout) {
                const entry = try self.nodeInner(value, continuation);
                return self.emit(.{ .auto_callout = entry });
            }
        }
        return self.nodeInner(value, continuation);
    }
    fn nodeInner(self: *Builder, value: *const model.Node, continuation: usize) model.Error!usize {
        return switch (value.*) {
            .empty, .flag_change => continuation,
            .group => |child| self.node(child, continuation),
            .capture => |capture| blk: {
                const end = try self.emit(.{ .save = .{
                    .slot = capture.index * 2 + 1,
                    .next = continuation,
                } });
                const child = try self.node(capture.child, end);
                break :blk try self.emit(.{ .save = .{
                    .slot = capture.index * 2,
                    .next = child,
                } });
            },
            .byte => self.emit(.{ .byte = continuation }),
            .string_property => |property| self.emit(.{ .string_property = .{ .property = property, .next = continuation } }),
            .set => |set| blk: {
                if (set.ranges.len == 1 and set.ranges[0].first == set.ranges[0].last) {
                    const rune = set.ranges[0].first;
                    break :blk if (rune < 0x80)
                        self.emit(.{ .literal_byte = .{ .value = @intCast(rune), .next = continuation } })
                    else
                        self.emit(.{ .literal_rune = .{ .value = rune, .next = continuation } });
                }
                break :blk self.emit(.{ .consume = .{ .set = set, .next = continuation } });
            },
            .assertion => |kind| self.emit(.{ .assertion = .{ .kind = kind, .next = continuation } }),
            .lookahead_set => |look| self.emit(.{ .lookahead = .{ .set = look.set, .negative = look.negative, .next = continuation } }),
            .pair => |pair| self.node(pair.left, try self.node(pair.right, continuation)),
            .alternate => |pair| blk: {
                // Multi-way dispatch tables were measured slower than the
                // split + first-byte-skip chain for typical tokenizer
                // alternations, so they are kept behind a compile-time flag.
                if (!alternation_dispatch) {
                    break :blk self.emit(.{ .split = .{
                        .left = try self.node(pair.left, continuation),
                        .right = try self.node(pair.right, continuation),
                        .alternation = true,
                    } });
                }
                var leaves: std.ArrayList(*const model.Node) = .empty;
                defer leaves.deinit(self.allocator);
                try self.collectAlternatives(value, &leaves);
                if (leaves.items.len >= 2 and leaves.items.len <= 16) {
                    const branches = try self.allocator.alloc(usize, leaves.items.len);
                    for (leaves.items, 0..) |leaf, index| branches[index] = try self.node(leaf, continuation);
                    const instruction = try self.emit(.{ .dispatch = .{ .table = 0 } });
                    try self.pending_dispatches.append(self.allocator, .{ .instruction = instruction, .branches = branches });
                    break :blk instruction;
                }
                break :blk self.emit(.{ .split = .{
                    .left = try self.node(pair.left, continuation),
                    .right = try self.node(pair.right, continuation),
                    .alternation = true,
                } });
            },
            .repeat => |repeat| blk: {
                if (repeat.possessive) {
                    const child = try self.repeatNode(repeat, self.sub_accept);
                    break :blk self.emit(.{ .atomic = .{ .child = child, .next = continuation } });
                }
                break :blk self.repeatNode(repeat, continuation);
            },
            .lookaround => |look| blk: {
                if (look.non_atomic) {
                    if (look.negative) return error.UnsupportedRegexFeature;
                    const base = 2 * (@as(usize, self.capture_count) + 1);
                    if (look.behind) {
                        // Non-atomic lookbehind: try every start position at or
                        // before the current one. Each start leaves a choice so
                        // a failing continuation can resume the scan, while the
                        // child's own choices are tried first (LIFO).
                        const target_slot = base + self.extra_slots;
                        const start_slot = target_slot + 1;
                        if (start_slot > 65535) return error.RegexLimitExceeded;
                        self.extra_slots += 2;
                        const accept = try self.emit(.{ .lookbehind_accept = .{
                            .target_slot = @intCast(target_slot),
                            .next = continuation,
                        } });
                        const child = try self.node(look.child, accept);
                        const scan_pc = try self.emit(.{ .lookbehind_next = .{
                            .child = child,
                            .target_slot = @intCast(target_slot),
                            .start_slot = @intCast(start_slot),
                        } });
                        break :blk try self.emit(.{ .lookbehind_non_atomic = .{
                            .child = child,
                            .next = continuation,
                            .scan_pc = scan_pc,
                            .target_slot = @intCast(target_slot),
                            .start_slot = @intCast(start_slot),
                        } });
                    }
                    const slot = base + self.extra_slots;
                    if (slot > 65535) return error.RegexLimitExceeded;
                    self.extra_slots += 1;
                    const restore = try self.emit(.{ .restore_pos = .{ .slot = @intCast(slot), .next = continuation } });
                    const child = try self.node(look.child, restore);
                    break :blk try self.emit(.{ .save = .{ .slot = @intCast(slot), .next = child } });
                }
                const child = try self.node(look.child, self.sub_accept);
                break :blk self.emit(.{ .lookaround = .{
                    .child = child,
                    .negative = look.negative,
                    .behind = look.behind,
                    .next = continuation,
                } });
            },
            .backref => |ref| blk: {
                if (ref.index > self.capture_count) return error.InvalidRegex;
                break :blk self.emit(.{ .backref = .{ .group = ref.index, .groups = ref.groups, .fold = ref.fold, .next = continuation } });
            },
            .script_run => |run| blk: {
                const base = 2 * (@as(usize, self.capture_count) + 1);
                const slot = base + self.extra_slots;
                if (slot > 65535) return error.RegexLimitExceeded;
                self.extra_slots += 1;
                const check = try self.emit(.{ .script_run_check = .{ .slot = @intCast(slot), .next = continuation } });
                const inner = if (run.atomic)
                    try self.emit(.{ .atomic = .{
                        .child = try self.node(run.child, self.sub_accept),
                        .next = check,
                    } })
                else
                    try self.node(run.child, check);
                break :blk try self.emit(.{ .save = .{ .slot = @intCast(slot), .next = inner } });
            },
            .scan_substring => |scan| blk: {
                for (scan.groups) |group| if (group > self.capture_count) return error.InvalidRegex;
                const child = try self.node(scan.child, self.sub_accept);
                break :blk self.emit(.{ .scan_substring = .{
                    .child = child,
                    .groups = scan.groups,
                    .next = continuation,
                } });
            },
            .atomic => |child| blk: {
                const start = try self.node(child, self.sub_accept);
                break :blk self.emit(.{ .atomic = .{ .child = start, .next = continuation } });
            },
            .conditional => |cond| blk: {
                const yes = try self.node(cond.yes, continuation);
                const no = if (cond.no) |no_node| try self.node(no_node, continuation) else continuation;
                switch (cond.condition) {
                    .group => |group| {
                        if (group > self.capture_count) return error.InvalidRegex;
                        break :blk self.emit(.{ .conditional = .{ .group = group, .yes = yes, .no = no } });
                    },
                    .recursion => |group| break :blk self.emit(.{ .conditional_recursion = .{ .group = group, .yes = yes, .no = no } }),
                    .version => |satisfied| break :blk if (satisfied) yes else no,
                    .groups => |list| {
                        for (list) |group| if (group > self.capture_count) return error.InvalidRegex;
                        var inner = no;
                        var index = list.len;
                        while (index > 0) {
                            index -= 1;
                            inner = try self.emit(.{ .conditional = .{ .group = list[index], .yes = yes, .no = inner } });
                        }
                        break :blk inner;
                    },
                    .assertion => |assertion_node| {
                        const look = switch (assertion_node.*) {
                            .lookaround => |look_value| look_value,
                            else => return error.InvalidRegex,
                        };
                        const child = try self.node(look.child, self.sub_accept);
                        break :blk self.emit(.{ .conditional_assert = .{
                            .child = child,
                            .negative = look.negative,
                            .behind = look.behind,
                            .yes = yes,
                            .no = no,
                        } });
                    },
                }
            },
            .reset_start => self.emit(.{ .reset_start = continuation }),
            .grapheme => self.emit(.{ .grapheme = continuation }),
            .fail => self.emit(.fail),
            .accept_verb => self.emit(.accept_verb),
            .prune => self.emit(.{ .prune = continuation }),
            .skip => self.emit(.{ .skip = .{ .next = continuation } }),
            .skip_named => |name| self.emit(.{ .skip = .{ .next = continuation, .name = name } }),
            .commit => self.emit(.{ .commit = continuation }),
            .then_verb => self.emit(.{ .then = continuation }),
            .mark => |index| self.emit(.{ .mark = .{ .index = index, .next = continuation } }),
            .callout => |id| self.emit(.{ .callout = .{ .id = id, .next = continuation } }),
            .subroutine => |sub| blk: {
                const call = try self.emit(.{ .call = .{ .group = sub.group, .child = 0, .next = continuation } });
                try self.pending_calls.append(self.allocator, .{ .instruction = call, .group = sub.group });
                break :blk call;
            },
        };
    }
};

const LiteralBuilder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Returns false as soon as the subtree is not a fixed literal. Bytes
    /// appended before that point are discarded by the caller.
    fn append(self: *LiteralBuilder, value: *const model.Node) model.Error!bool {
        return switch (value.*) {
            .empty, .flag_change => true,
            .group => |child| self.append(child),
            .capture => |capture| self.append(capture.child),
            .set => |set| blk: {
                if (set.ranges.len != 1 or set.ranges[0].first != set.ranges[0].last) break :blk false;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(set.ranges[0].first, &encoded) catch break :blk false;
                try self.bytes.appendSlice(self.allocator, encoded[0..len]);
                break :blk true;
            },
            .pair => |pair| (try self.append(pair.left)) and (try self.append(pair.right)),
            else => false,
        };
    }
};

/// Lowercase ASCII canonical byte for every rune in `rune`'s simple case-fold
/// class, or null when the class has no ASCII canonical form (for example a
/// non-ASCII letter without an ASCII peer, or a class mixing letters).
fn foldCanonical(rune: u21) ?u8 {
    var canonical: ?u8 = null;
    var peer = rune;
    while (true) {
        if (peer < 0x80) {
            const byte: u8 = @intCast(peer);
            const lower: ?u8 = if (byte >= 'A' and byte <= 'Z')
                byte + 32
            else if (byte >= 'a' and byte <= 'z')
                byte
            else
                null;
            if (lower) |value| {
                if (canonical) |existing| {
                    if (existing != value) return null;
                } else canonical = value;
            }
        }
        peer = model.unicode.foldNext(peer);
        if (peer == rune) break;
    }
    if (canonical) |value| return value;
    // No ASCII letter: only a single ASCII non-letter qualifies.
    if (rune < 0x80 and model.unicode.foldNext(rune) == rune) return @intCast(rune);
    return null;
}

/// The canonical byte for a set that is exactly one case-fold class, or null.
fn caselessCanonical(set: model.Set) ?u8 {
    var canonical: ?u8 = null;
    for (set.ranges) |range| {
        var rune: u32 = range.first;
        while (rune <= range.last) : (rune += 1) {
            const folded = foldCanonical(@intCast(rune)) orelse return null;
            if (canonical) |existing| {
                if (existing != folded) return null;
            } else canonical = folded;
        }
    }
    return canonical;
}

/// Extract the lowercase ASCII form of a whole-pattern literal whose sets are
/// simple case-fold classes. A byte-wise folded scan can then look for the
/// literal; non-ASCII input bytes stay conservative at verification time.
const CaselessLiteralBuilder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Returns false as soon as the subtree is not a caseless literal.
    fn append(self: *CaselessLiteralBuilder, value: *const model.Node) model.Error!bool {
        return switch (value.*) {
            .empty, .flag_change => true,
            .group => |child| self.append(child),
            .capture => |capture| self.append(capture.child),
            .set => |set| blk: {
                const canonical = caselessCanonical(set) orelse break :blk false;
                try self.bytes.append(self.allocator, canonical);
                break :blk true;
            },
            .pair => |pair| (try self.append(pair.left)) and (try self.append(pair.right)),
            else => false,
        };
    }
};

/// Whole-pattern alternation of exact literals. Each alternative must be a
/// non-empty sequence of singleton sets; groups are transparent, while
/// captures, assertions, repeats and nested non-literal nodes reject the
/// shape so the general engine keeps its semantics.
/// Expands a whole-pattern literal alternation, distributing literal
/// prefixes and suffixes over the branches: `(?:pre|post)fix` becomes
/// `prefix|postfix`. Every leaf must be a singleton set (a literal byte) and
/// the branch count and bytes are bounded.
const LiteralExpander = struct {
    const max_branches = 32;
    const max_total_bytes = 1024;

    allocator: std.mem.Allocator,
    total_bytes: usize = 0,

    fn single(self: *LiteralExpander, bytes: []const u8) model.Error![]const []const u8 {
        if (self.total_bytes + bytes.len > max_total_bytes) return error.RegexLimitExceeded;
        self.total_bytes += bytes.len;
        const list = try self.allocator.alloc([]const u8, 1);
        list[0] = try self.allocator.dupe(u8, bytes);
        return list;
    }

    fn expand(self: *LiteralExpander, value: *const model.Node) model.Error!?[]const []const u8 {
        return switch (value.*) {
            .empty, .flag_change => try self.single(""),
            .group => |child| self.expand(child),
            .set => |set| blk: {
                if (set.ranges.len != 1 or set.ranges[0].first != set.ranges[0].last) break :blk null;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(set.ranges[0].first, &encoded) catch break :blk null;
                break :blk try self.single(encoded[0..len]);
            },
            .alternate => |pair| blk: {
                const left = try self.expand(pair.left) orelse break :blk null;
                const right = try self.expand(pair.right) orelse break :blk null;
                if (left.len + right.len > max_branches) break :blk null;
                const list = try self.allocator.alloc([]const u8, left.len + right.len);
                @memcpy(list[0..left.len], left);
                @memcpy(list[left.len..], right);
                break :blk list;
            },
            .pair => |pair| blk: {
                const left = try self.expand(pair.left) orelse break :blk null;
                const right = try self.expand(pair.right) orelse break :blk null;
                if (left.len * right.len > max_branches) break :blk null;
                const list = try self.allocator.alloc([]const u8, left.len * right.len);
                var index: usize = 0;
                for (left) |prefix| {
                    for (right) |suffix| {
                        const bytes = try self.allocator.alloc(u8, prefix.len + suffix.len);
                        if (self.total_bytes + bytes.len > max_total_bytes) return error.RegexLimitExceeded;
                        self.total_bytes += bytes.len;
                        @memcpy(bytes[0..prefix.len], prefix);
                        @memcpy(bytes[prefix.len..], suffix);
                        list[index] = bytes;
                        index += 1;
                    }
                }
                break :blk list;
            },
            else => null,
        };
    }
};

fn expandLiteralSet(allocator: std.mem.Allocator, root: *const model.Node) model.Error!?[]const []const u8 {
    var expander = LiteralExpander{ .allocator = allocator };
    const branches = try expander.expand(root) orelse return null;
    if (branches.len < 2) return null;
    for (branches) |branch| {
        if (branch.len == 0) return null;
    }
    return branches;
}

/// Whole-pattern concatenation of bounded set runs. Fixed repeats of a
/// sequence expand; variable repeats are only accepted when the child is a
/// single set. At least one element must be variable width, otherwise the
/// instruction-based fixed-sequence path handles the program.
/// `(?: separator set{min,max} )?` as a bounded element.
fn optionalGroup(node: *const model.Node) ?BoundedElement {
    var child = node;
    while (child.* == .group) child = child.group;
    if (child.* != .pair) return null;
    var separator = child.pair.left;
    while (separator.* == .group) separator = separator.group;
    if (separator.* != .set or separator.set.ranges.len != 1 or
        separator.set.ranges[0].first != separator.set.ranges[0].last or separator.set.ranges[0].first >= 0x80)
    {
        return null;
    }
    var run_node = child.pair.right;
    while (run_node.* == .group) run_node = run_node.group;
    if (run_node.* != .repeat) return null;
    const run = run_node.repeat;
    if (run.lazy or run.possessive or run.maximum == null or run.minimum == 0 or
        run.minimum > run.maximum.? or run.maximum.? > 8)
    {
        return null;
    }
    var set_node = run.child;
    while (set_node.* == .group) set_node = set_node.group;
    if (set_node.* != .set) return null;
    const set = set_node.set;
    if (!set.ascii_only or set.ranges.len == 0) return null;
    const byte: u8 = @intCast(separator.set.ranges[0].first);
    if (set.matches(byte)) return null;
    return .{
        .kind = .optional_group,
        .set = set,
        .min = @intCast(run.minimum),
        .max = @intCast(run.maximum.?),
        .separator = byte,
    };
}

const BoundedSequenceBuilder = struct {
    const max_elements = 32;
    const max_element_width = 8;
    const max_expand = 8;

    allocator: std.mem.Allocator,
    elements: std.ArrayList(BoundedElement) = .empty,
    saw_variable: bool = false,

    fn setOf(value: *const model.Node) ?model.Set {
        return switch (value.*) {
            .group => |child| setOf(child),
            .set => |set| set,
            else => null,
        };
    }

    fn optionalLast(self: *BoundedSequenceBuilder) bool {
        for (self.elements.items, 0..) |element, index| {
            if (element.kind != .optional_group) continue;
            if (index + 1 != self.elements.items.len) return false;
            if (index != 0) {
                const previous = self.elements.items[index - 1];
                if (previous.kind == .run and previous.set.matches(element.separator)) return false;
            }
        }
        return true;
    }

    fn addSet(self: *BoundedSequenceBuilder, set: model.Set, min: usize, max: usize) model.Error!bool {
        if (!set.ascii_only or set.ranges.len == 0) return false;
        if (self.elements.items.len == max_elements) return false;
        try self.elements.append(self.allocator, .{
            .set = set,
            .min = @intCast(min),
            .max = @intCast(max),
        });
        return true;
    }

    fn add(self: *BoundedSequenceBuilder, value: *const model.Node) model.Error!bool {
        return switch (value.*) {
            .empty, .flag_change => true,
            .group => |child| self.add(child),
            .pair => |pair| (try self.add(pair.left)) and (try self.add(pair.right)),
            .set => |set| self.addSet(set, 1, 1),
            .repeat => |repeat| blk: {
                if (repeat.lazy or repeat.possessive) break :blk false;
                if (setOf(repeat.child)) |set| {
                    const maximum = repeat.maximum orelse break :blk false;
                    if (repeat.minimum == 0 or repeat.minimum > maximum or maximum > max_element_width) break :blk false;
                    if (maximum > repeat.minimum) self.saw_variable = true;
                    break :blk self.addSet(set, repeat.minimum, maximum);
                }
                if (repeat.minimum == 0 and repeat.maximum != null and repeat.maximum.? == 1) {
                    const element = optionalGroup(repeat.child) orelse break :blk false;
                    if (self.elements.items.len == max_elements) break :blk false;
                    try self.elements.append(self.allocator, element);
                    self.saw_variable = true;
                    break :blk true;
                }
                if (repeat.maximum == null or repeat.minimum != repeat.maximum.? or repeat.minimum > max_expand) break :blk false;
                for (0..repeat.minimum) |_| {
                    if (!try self.add(repeat.child)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        };
    }
};

/// `x? set+` where the optional byte is a member of the run set: the optional
/// never changes the match span, so the program behaves as `set+`.
fn detectOptionalRun(root: *const model.Node) ?model.Set {
    var node = root;
    while (node.* == .group) node = node.group;
    if (node.* != .pair) return null;
    var left = node.pair.left;
    while (left.* == .group) left = left.group;
    if (left.* != .repeat) return null;
    const optional = left.repeat;
    if (optional.lazy or optional.possessive or optional.minimum != 0 or optional.maximum == null or optional.maximum.? != 1) return null;
    var byte_node = optional.child;
    while (byte_node.* == .group) byte_node = byte_node.group;
    if (byte_node.* != .set or byte_node.set.ranges.len != 1 or
        byte_node.set.ranges[0].first != byte_node.set.ranges[0].last)
    {
        return null;
    }
    const byte = byte_node.set.ranges[0].first;
    var right = node.pair.right;
    while (right.* == .group) right = right.group;
    if (right.* != .repeat) return null;
    const run = right.repeat;
    if (run.lazy or run.possessive or run.maximum != null or run.minimum < 1) return null;
    var run_node = run.child;
    while (run_node.* == .group) run_node = run_node.group;
    if (run_node.* != .set) return null;
    const set = run_node.set;
    if (!set.matches(byte)) return null;
    return set;
}

fn nodeSet(node: *const model.Node) ?model.Set {
    var current = node;
    while (current.* == .group) current = current.group;
    return switch (current.*) {
        .set => |set| set,
        else => null,
    };
}

fn repeatOf(node: *const model.Node) ?*const model.Node {
    var current = node;
    while (current.* == .group) current = current.group;
    return switch (current.*) {
        .repeat => current,
        else => null,
    };
}

fn sameRanges(a: model.Set, b: model.Set) bool {
    if (a.ranges.len != b.ranges.len) return false;
    for (a.ranges, b.ranges) |left, right| {
        if (left.first != right.first or left.last != right.last) return false;
    }
    return true;
}

fn flattenN(node: *const model.Node, out: *[3]*const model.Node, count: *usize) bool {
    var current = node;
    while (current.* == .group) current = current.group;
    switch (current.*) {
        .empty, .flag_change => return true,
        .pair => |pair| {
            return flattenN(pair.left, out, count) and flattenN(pair.right, out, count);
        },
        else => {},
    }
    if (count.* == out.len) return false;
    out[count.*] = current;
    count.* += 1;
    return true;
}

/// A sign set followed by digits and an optional fraction, for example
/// `[+-]?\d+(?:\.\d+)?`. The sign set must be disjoint from the digits.
fn detectSignedNumber(root: *const model.Node) ?NumberShape {
    var nodes: [3]*const model.Node = undefined;
    var count: usize = 0;
    if (!flattenN(root, &nodes, &count) or count < 2) return null;
    const sign_repeat = (repeatOf(nodes[0]) orelse return null).repeat;
    if (sign_repeat.lazy or sign_repeat.possessive or sign_repeat.minimum != 0 or
        sign_repeat.maximum == null or sign_repeat.maximum.? != 1)
    {
        return null;
    }
    const sign = nodeSet(sign_repeat.child) orelse return null;
    const digits_repeat = (repeatOf(nodes[1]) orelse return null).repeat;
    if (digits_repeat.lazy or digits_repeat.possessive or digits_repeat.maximum != null or digits_repeat.minimum == 0) return null;
    const digits = nodeSet(digits_repeat.child) orelse return null;
    var fraction = false;
    if (count == 3) {
        const group = (repeatOf(nodes[2]) orelse return null).repeat;
        if (group.lazy or group.possessive or group.minimum != 0 or group.maximum == null or group.maximum.? != 1) return null;
        var child = group.child;
        while (child.* == .group) child = child.group;
        if (child.* != .pair) return null;
        var dot = child.pair.left;
        while (dot.* == .group) dot = dot.group;
        if (dot.* != .set or dot.set.ranges.len != 1 or dot.set.ranges[0].first != dot.set.ranges[0].last or
            dot.set.ranges[0].first != '.')
        {
            return null;
        }
        const fraction_repeat = (repeatOf(child.pair.right) orelse return null).repeat;
        if (fraction_repeat.lazy or fraction_repeat.possessive or fraction_repeat.maximum != null or fraction_repeat.minimum == 0) return null;
        const fraction_digits = nodeSet(fraction_repeat.child) orelse return null;
        if (!sameRanges(digits, fraction_digits)) return null;
        fraction = true;
    } else if (count > 3) return null;
    if (!sign.ascii_only or sign.ranges.len == 0) return null;
    if (!digits.ascii_only or digits.ranges.len == 0) return null;
    if (setOverlaps(sign, digits)) return null;
    return .{ .sign = sign, .digits = digits, .fraction = fraction };
}

fn flattenUpTo(node: *const model.Node, out: []*const model.Node, count: *usize) bool {
    var current = node;
    while (current.* == .group) current = current.group;
    switch (current.*) {
        .empty, .flag_change => return true,
        .pair => |pair| {
            return flattenUpTo(pair.left, out, count) and flattenUpTo(pair.right, out, count);
        },
        else => {},
    }
    if (count.* == out.len) return false;
    out[count.*] = current;
    count.* += 1;
    return true;
}

/// `(?m)^X{1,max} Y.*$` with a literal heading byte and space, in LF mode.
fn detectLineHeading(root: *const model.Node) ?LineHeadingShape {
    var nodes: [5]*const model.Node = undefined;
    var count: usize = 0;
    if (!flattenUpTo(root, &nodes, &count) or count != 5) return null;
    var first = nodes[0];
    while (first.* == .group) first = first.group;
    if (first.* != .assertion or first.assertion != .start_line) return null;
    const heading_repeat = (repeatOf(nodes[1]) orelse return null).repeat;
    if (heading_repeat.lazy or heading_repeat.possessive or heading_repeat.maximum == null or
        heading_repeat.minimum == 0 or heading_repeat.minimum > heading_repeat.maximum.? or
        heading_repeat.maximum.? > 8)
    {
        return null;
    }
    const heading_set = nodeSet(heading_repeat.child) orelse return null;
    if (heading_set.ranges.len != 1 or heading_set.ranges[0].first != heading_set.ranges[0].last or
        heading_set.ranges[0].first >= 0x80)
    {
        return null;
    }
    const space_set = nodeSet(nodes[2]) orelse return null;
    if (space_set.ranges.len != 1 or space_set.ranges[0].first != space_set.ranges[0].last or
        space_set.ranges[0].first >= 0x80)
    {
        return null;
    }
    const body_repeat = (repeatOf(nodes[3]) orelse return null).repeat;
    if (body_repeat.lazy or body_repeat.possessive or body_repeat.maximum != null or body_repeat.minimum != 0) return null;
    const body_set = nodeSet(body_repeat.child) orelse return null;
    if (body_set.ranges.len == 0) return null;
    var last = nodes[4];
    while (last.* == .group) last = last.group;
    if (last.* != .assertion or last.assertion != .end_line) return null;
    return .{
        .byte = @intCast(heading_set.ranges[0].first),
        .min = @intCast(heading_repeat.minimum),
        .max = @intCast(heading_repeat.maximum.?),
        .space = @intCast(space_set.ranges[0].first),
        .set = body_set,
    };
}

/// A bounded run followed by a greedy repetition of a bounded
/// `separator run` group, for example `\d{1,3}(?:,\d{3})+`.
fn detectBoundedLoop(root: *const model.Node) ?BoundedLoopShape {
    var node = root;
    while (node.* == .group) node = node.group;
    if (node.* != .pair) return null;
    var left = node.pair.left;
    while (left.* == .group) left = left.group;
    if (left.* != .repeat) return null;
    const run_a = left.repeat;
    if (run_a.lazy or run_a.possessive or run_a.maximum == null or run_a.minimum == 0 or
        run_a.minimum > run_a.maximum.? or run_a.maximum.? > 8)
    {
        return null;
    }
    var run_a_node = run_a.child;
    while (run_a_node.* == .group) run_a_node = run_a_node.group;
    if (run_a_node.* != .set) return null;
    const set_a = run_a_node.set;
    var right = node.pair.right;
    while (right.* == .group) right = right.group;
    if (right.* != .repeat) return null;
    const group_repeat = right.repeat;
    if (group_repeat.lazy or group_repeat.possessive or group_repeat.maximum != null or group_repeat.minimum == 0) return null;
    var child = group_repeat.child;
    while (child.* == .group) child = child.group;
    if (child.* != .pair) return null;
    var separator_node = child.pair.left;
    while (separator_node.* == .group) separator_node = separator_node.group;
    if (separator_node.* != .set or separator_node.set.ranges.len != 1 or
        separator_node.set.ranges[0].first != separator_node.set.ranges[0].last or separator_node.set.ranges[0].first >= 0x80)
    {
        return null;
    }
    var run_b_node = child.pair.right;
    while (run_b_node.* == .group) run_b_node = run_b_node.group;
    if (run_b_node.* != .repeat) return null;
    const run_b = run_b_node.repeat;
    if (run_b.lazy or run_b.possessive or run_b.maximum == null or run_b.minimum == 0 or
        run_b.minimum > run_b.maximum.? or run_b.maximum.? > 8)
    {
        return null;
    }
    var run_b_set_node = run_b.child;
    while (run_b_set_node.* == .group) run_b_set_node = run_b_set_node.group;
    if (run_b_set_node.* != .set) return null;
    const set_b = run_b_set_node.set;
    if (!set_a.ascii_only or set_a.ranges.len == 0 or !set_b.ascii_only or set_b.ranges.len == 0) return null;
    const separator: u8 = @intCast(separator_node.set.ranges[0].first);
    if (set_a.matches(separator) or set_b.matches(separator)) return null;
    return .{
        .set_a = set_a,
        .min_a = @intCast(run_a.minimum),
        .max_a = @intCast(run_a.maximum.?),
        .set_b = set_b,
        .min_b = @intCast(run_b.minimum),
        .max_b = @intCast(run_b.maximum.?),
        .separator = separator,
        .min_groups = @intCast(group_repeat.minimum),
    };
}

/// A run, an optional `separator run` group, then a literal byte, for
/// example `\d+(?:\.\d+)?%`.
fn detectOptionalTail(root: *const model.Node) ?OptionalTailShape {
    var flat: [3]*const model.Node = undefined;
    var count: usize = 0;
    if (!flattenSequence(root, &flat, &count) or count != 3) return null;
    const run_a = repeatSet(flat[0], 1) orelse return null;
    var group = flat[1];
    while (group.* == .group) group = group.group;
    if (group.* != .repeat) return null;
    const optional = group.repeat;
    if (optional.lazy or optional.possessive or optional.minimum != 0 or optional.maximum == null or optional.maximum.? != 1) return null;
    var child = optional.child;
    while (child.* == .group) child = child.group;
    if (child.* != .pair) return null;
    var separator_node = child.pair.left;
    while (separator_node.* == .group) separator_node = separator_node.group;
    if (separator_node.* != .set or separator_node.set.ranges.len != 1 or
        separator_node.set.ranges[0].first != separator_node.set.ranges[0].last or separator_node.set.ranges[0].first >= 0x80)
    {
        return null;
    }
    const run_b = repeatSet(child.pair.right, 1) orelse return null;
    var literal_node = flat[2];
    while (literal_node.* == .group) literal_node = literal_node.group;
    if (literal_node.* != .set or literal_node.set.ranges.len != 1 or
        literal_node.set.ranges[0].first != literal_node.set.ranges[0].last or literal_node.set.ranges[0].first >= 0x80)
    {
        return null;
    }
    const set_a = run_a;
    const set_b = run_b;
    const separator: u8 = @intCast(separator_node.set.ranges[0].first);
    if (!set_a.ascii_only or set_a.ranges.len == 0 or !set_b.ascii_only or set_b.ranges.len == 0) return null;
    if (set_a.matches(separator) or set_b.matches(separator)) return null;
    return .{
        .set_a = set_a,
        .set_b = set_b,
        .separator = separator,
        .literal = @intCast(literal_node.set.ranges[0].first),
    };
}

/// Flattens a right- or left-nested pair chain into its leaves.
fn flattenSequence(node: *const model.Node, out: *[3]*const model.Node, count: *usize) bool {
    var current = node;
    while (current.* == .group) current = current.group;
    if (current.* == .pair) {
        return flattenSequence(current.pair.left, out, count) and
            flattenSequence(current.pair.right, out, count);
    }
    if (count.* == out.len) return false;
    out[count.*] = current;
    count.* += 1;
    return true;
}

/// The set of a greedy `set{minimum,}` repeat, with groups stripped.
fn repeatSet(node: *const model.Node, minimum: usize) ?model.Set {
    var current = node;
    while (current.* == .group) current = current.group;
    if (current.* != .repeat) return null;
    const repeat = current.repeat;
    if (repeat.lazy or repeat.possessive or repeat.maximum != null or repeat.minimum < minimum) return null;
    var child = repeat.child;
    while (child.* == .group) child = child.group;
    if (child.* != .set) return null;
    return child.set;
}

/// A run followed by a greedy repetition of `separator run`, for example
/// `[a-z0-9-]+(?:\.[a-z0-9-]+)+`. The separator must be disjoint from both
/// run sets so the flat walk needs no backtracking.
fn detectChainLoop(root: *const model.Node) ?ChainLoopShape {
    var node = root;
    while (node.* == .group) node = node.group;
    if (node.* != .pair) return null;
    var left = node.pair.left;
    while (left.* == .group) left = left.group;
    if (left.* != .repeat) return null;
    const run_a = left.repeat;
    if (run_a.lazy or run_a.possessive or run_a.maximum != null or run_a.minimum < 1) return null;
    var run_a_node = run_a.child;
    while (run_a_node.* == .group) run_a_node = run_a_node.group;
    if (run_a_node.* != .set) return null;
    const set_a = run_a_node.set;
    var right = node.pair.right;
    while (right.* == .group) right = right.group;
    if (right.* != .repeat) return null;
    const group_repeat = right.repeat;
    if (group_repeat.lazy or group_repeat.possessive or group_repeat.maximum != null) return null;
    var child = group_repeat.child;
    while (child.* == .group) child = child.group;
    if (child.* != .pair) return null;
    var separator_node = child.pair.left;
    while (separator_node.* == .group) separator_node = separator_node.group;
    var shape = ChainLoopShape{ .set_a = set_a, .set_b = undefined, .min_groups = @intCast(group_repeat.minimum) };
    if (separator_node.* != .set or separator_node.set.ranges.len != 1 or
        separator_node.set.ranges[0].first != separator_node.set.ranges[0].last or separator_node.set.ranges[0].first >= 0x80)
    {
        return null;
    }
    shape.separator[0] = @intCast(separator_node.set.ranges[0].first);
    shape.separator_len = 1;
    var run_b_node = child.pair.right;
    while (run_b_node.* == .group) run_b_node = run_b_node.group;
    if (run_b_node.* != .repeat) return null;
    const run_b = run_b_node.repeat;
    if (run_b.lazy or run_b.possessive or run_b.maximum != null or run_b.minimum < 1) return null;
    var run_b_set_node = run_b.child;
    while (run_b_set_node.* == .group) run_b_set_node = run_b_set_node.group;
    if (run_b_set_node.* != .set) return null;
    const set_b = run_b_set_node.set;
    if (!set_a.ascii_only or set_a.ranges.len == 0) return null;
    if (!set_b.ascii_only or set_b.ranges.len == 0) return null;
    if (set_a.matches(shape.separator[0]) or set_b.matches(shape.separator[0])) return null;
    shape.set_b = set_b;
    return shape;
}

/// One ASCII set byte followed by a greedy unbounded ASCII run.
fn detectPrefixRun(root: *const model.Node) ?PrefixRunShape {
    var node = root;
    while (node.* == .group) node = node.group;
    if (node.* != .pair) return null;
    var left = node.pair.left;
    while (left.* == .group) left = left.group;
    if (left.* != .set) return null;
    const set_a = left.set;
    var right = node.pair.right;
    while (right.* == .group) right = right.group;
    if (right.* != .repeat) return null;
    const repeat = right.repeat;
    if (repeat.lazy or repeat.possessive or repeat.maximum != null or repeat.minimum > 1) return null;
    const child = repeat.child;
    var run_node = child;
    while (run_node.* == .group) run_node = run_node.group;
    if (run_node.* != .set) return null;
    const set_b = run_node.set;
    if (!set_a.ascii_only or set_a.ranges.len == 0) return null;
    if (!set_b.ascii_only or set_b.ranges.len == 0) return null;
    return .{ .set_a = set_a, .set_b = set_b, .min_b = @intCast(repeat.minimum) };
}

/// Whole-pattern sequence of unbounded ASCII set runs separated by literal
/// bytes, with an optional leading literal. Adjacent runs and literal bytes
/// inside a following run set would need backtracking, so they reject the
/// shape.
/// Whether two materialized sets share a rune.
fn setOverlaps(a: model.Set, b: model.Set) bool {
    var left: usize = 0;
    var right: usize = 0;
    while (left < a.ranges.len and right < b.ranges.len) {
        const x = a.ranges[left];
        const y = b.ranges[right];
        if (x.last < y.first) {
            left += 1;
        } else if (y.last < x.first) {
            right += 1;
        } else {
            return true;
        }
    }
    return false;
}

const UnboundedSequenceBuilder = struct {
    const max_elements = 32;
    const max_literal_bytes = 64;
    const max_alternatives = 8;
    const max_run_min = 8;

    allocator: std.mem.Allocator,
    elements: std.ArrayList(UnboundedElement) = .empty,
    /// Arena-owned fixed buffer; element slices stay valid across appends.
    literal_bytes: []u8,
    literal_len: usize = 0,
    last_literal_offset: usize = 0,
    run_count: u8 = 0,

    fn setOf(value: *const model.Node) ?model.Set {
        return switch (value.*) {
            .group => |child| setOf(child),
            .set => |set| set,
            else => null,
        };
    }

    fn appendLiteral(self: *UnboundedSequenceBuilder, byte: u8) model.Error!bool {
        if (byte >= 0x80) return false;
        if (self.elements.items.len != 0) {
            const last = &self.elements.items[self.elements.items.len - 1];
            if (last.* == .literal) {
                if (self.literal_len == self.literal_bytes.len) return false;
                self.literal_bytes[self.literal_len] = byte;
                self.literal_len += 1;
                last.literal = self.literal_bytes[self.last_literal_offset..self.literal_len];
                return true;
            }
        }
        if (self.elements.items.len == max_elements or self.literal_len == self.literal_bytes.len) return false;
        self.last_literal_offset = self.literal_len;
        self.literal_bytes[self.literal_len] = byte;
        self.literal_len += 1;
        try self.elements.append(self.allocator, .{ .literal = self.literal_bytes[self.last_literal_offset..self.literal_len] });
        return true;
    }

    fn appendRun(self: *UnboundedSequenceBuilder, set: model.Set, min: u8) model.Error!bool {
        if (set.ranges.len == 0) return false;
        if (self.elements.items.len == max_elements) return false;
        if (self.elements.items.len != 0) {
            const last = self.elements.items[self.elements.items.len - 1];
            // Disjoint adjacent runs are exact: the first run ends at the
            // first byte the second can consume. Overlapping sets would need
            // backtracking.
            if (last == .run and setOverlaps(last.run.set, set)) return false;
        }
        try self.elements.append(self.allocator, .{ .run = .{ .set = set, .min = min } });
        self.run_count += 1;
        return true;
    }

    fn sequence(self: *UnboundedSequenceBuilder, value: *const model.Node, out: *std.ArrayList(u8)) model.Error!bool {
        return switch (value.*) {
            .empty, .flag_change => true,
            .group => |child| self.sequence(child, out),
            .pair => |pair| (try self.sequence(pair.left, out)) and (try self.sequence(pair.right, out)),
            .set => |set| blk: {
                if (set.ranges.len != 1 or set.ranges[0].first != set.ranges[0].last) break :blk false;
                if (set.ranges[0].first >= 0x80) break :blk false;
                try out.append(self.allocator, @intCast(set.ranges[0].first));
                break :blk true;
            },
            else => false,
        };
    }

    fn collectBranches(self: *UnboundedSequenceBuilder, value: *const model.Node, out: *std.ArrayList([]const u8)) model.Error!bool {
        var current = value;
        while (current.* == .group) current = current.group;
        if (current.* == .alternate) {
            return (try self.collectBranches(current.alternate.left, out)) and
                (try self.collectBranches(current.alternate.right, out));
        }
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.allocator);
        if (!try self.sequence(current, &bytes)) return false;
        if (bytes.items.len == 0) return false;
        try out.append(self.allocator, try bytes.toOwnedSlice(self.allocator));
        return true;
    }

    fn addAlternation(self: *UnboundedSequenceBuilder, value: *const model.Node) model.Error!bool {
        var branches: std.ArrayList([]const u8) = .empty;
        defer branches.deinit(self.allocator);
        if (!try self.collectBranches(value, &branches)) return false;
        if (branches.items.len < 2 or branches.items.len > max_alternatives) return false;
        if (self.elements.items.len == max_elements) return false;
        var stored: std.ArrayList([]const u8) = .empty;
        for (branches.items) |branch| {
            if (self.literal_len + branch.len > self.literal_bytes.len) return false;
            @memcpy(self.literal_bytes[self.literal_len..][0..branch.len], branch);
            try stored.append(self.allocator, self.literal_bytes[self.literal_len..][0..branch.len]);
            self.literal_len += branch.len;
        }
        try self.elements.append(self.allocator, .{ .alternation = try stored.toOwnedSlice(self.allocator) });
        return true;
    }

    fn add(self: *UnboundedSequenceBuilder, value: *const model.Node) model.Error!bool {
        return switch (value.*) {
            .empty, .flag_change => true,
            .group => |child| self.add(child),
            .pair => |pair| (try self.add(pair.left)) and (try self.add(pair.right)),
            .alternate => self.addAlternation(value),
            .set => |set| blk: {
                if (set.ranges.len == 1 and set.ranges[0].first == set.ranges[0].last) {
                    if (set.ranges[0].first >= 0x80) break :blk false;
                    break :blk self.appendLiteral(@intCast(set.ranges[0].first));
                }
                if (!set.ascii_only or set.ranges.len == 0) break :blk false;
                if (self.elements.items.len == max_elements) break :blk false;
                if (self.elements.items.len != 0) {
                    const last = self.elements.items[self.elements.items.len - 1];
                    if (last == .run and setOverlaps(last.run.set, set)) break :blk false;
                }
                try self.elements.append(self.allocator, .{ .single_set = set });
                break :blk true;
            },
            .repeat => |repeat| blk: {
                if (repeat.lazy or repeat.possessive) break :blk false;
                const set = setOf(repeat.child) orelse break :blk false;
                if (repeat.maximum == null and repeat.minimum <= max_run_min) {
                    break :blk self.appendRun(set, @intCast(repeat.minimum));
                }
                // A leading `x?` literal prefix, for example `v?`.
                if (repeat.minimum == 0 and repeat.maximum == 1 and self.elements.items.len == 0) {
                    if (set.ranges.len != 1 or set.ranges[0].first != set.ranges[0].last) break :blk false;
                    if (set.ranges[0].first >= 0x80) break :blk false;
                    if (self.elements.items.len == max_elements) break :blk false;
                    try self.elements.append(self.allocator, .{ .optional = @intCast(set.ranges[0].first) });
                    break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
    }

    fn validate(self: *UnboundedSequenceBuilder) bool {
        if (self.run_count < 2) return false;
        var mandatory = false;
        for (self.elements.items) |element| {
            switch (element) {
                .run => |run| mandatory = mandatory or run.min != 0,
                .literal => mandatory = true,
                .single_set => mandatory = true,
                .optional => {},
                .alternation => mandatory = true,
            }
        }
        if (!mandatory) return false;
        var index: usize = 0;
        while (index < self.elements.items.len) : (index += 1) {
            const element = self.elements.items[index];
            if (element == .run and index + 1 < self.elements.items.len) {
                const next = self.elements.items[index + 1];
                if (next == .run and setOverlaps(element.run.set, next.run.set)) return false;
                if (next == .literal and next.literal.len != 0 and element.run.set.matches(next.literal[0])) return false;
                if (next == .alternation) {
                    for (next.alternation) |branch| {
                        if (branch.len != 0 and element.run.set.matches(branch[0])) return false;
                    }
                }
                if (next == .single_set and setOverlaps(element.run.set, next.single_set)) return false;
            }
            if (element == .optional) {
                if (index + 1 >= self.elements.items.len) return false;
                const next = self.elements.items[index + 1];
                const next_set = switch (next) {
                    .run => |run| run.set,
                    .literal => |bytes| if (bytes.len == 0) return false else null,
                    .optional => return false,
                    .alternation => null,
                    .single_set => |set| set,
                };
                if (next_set) |set| {
                    if (set.matches(element.optional)) return false;
                } else if (next == .literal and next.literal.len != 0 and next.literal[0] == element.optional) {
                    // Skipping the optional would let the literal match; the
                    // flat matcher cannot backtrack into it.
                    return false;
                } else if (next == .alternation) {
                    for (next.alternation) |branch| {
                        if (branch.len != 0 and branch[0] == element.optional) return false;
                    }
                }
            }
        }
        return true;
    }
};

const PrefixBuilder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    /// Append the longest fixed literal prefix. Zero-width assertions and
    /// lookarounds are skipped; alternation, `\C`, backrefs, and other
    /// non-fixed nodes stop the scan. Bytes already appended remain a valid
    /// prefix when false is returned.
    fn append(self: *PrefixBuilder, value: *const model.Node) model.Error!bool {
        return switch (value.*) {
            .empty, .flag_change, .assertion, .lookahead_set, .lookaround => true,
            .group => |child| self.append(child),
            .capture => |capture| self.append(capture.child),
            .set => |set| blk: {
                if (set.ranges.len != 1 or set.ranges[0].first != set.ranges[0].last) break :blk false;
                var encoded: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(set.ranges[0].first, &encoded) catch break :blk false;
                try self.bytes.appendSlice(self.allocator, encoded[0..len]);
                break :blk true;
            },
            .pair => |pair| (try self.append(pair.left)) and (try self.append(pair.right)),
            .repeat => |repeat| blk: {
                if (repeat.minimum == 0) break :blk false;
                _ = try self.append(repeat.child);
                break :blk false;
            },
            else => false,
        };
    }
};

/// Conservative summary used when an instruction cannot be analyzed. It never
/// allows skipping because it claims both empty and arbitrary-byte matches.
const conservative_first = model.FirstSet{ .ascii = .{ ~@as(u64, 0), ~@as(u64, 0) }, .nonascii = true, .empty = true };

fn setFirst(set: model.Set) model.FirstSet {
    return .{ .ascii = set.ascii, .nonascii = !set.ascii_only };
}

fn terminalFirst(instruction: model.Instruction) model.FirstSet {
    return switch (instruction) {
        .consume => |consume| setFirst(consume.set),
        .star => |star| setFirst(star.set),
        .literal_byte => |literal| blk: {
            var first = model.FirstSet{};
            first.ascii[literal.value >> 6] |= @as(u64, 1) << @intCast(literal.value & 63);
            break :blk first;
        },
        .literal_rune => |literal| if (literal.value < 128) blk: {
            var first = model.FirstSet{};
            const value: u8 = @intCast(literal.value);
            first.ascii[value >> 6] |= @as(u64, 1) << @intCast(value & 63);
            break :blk first;
        } else .{ .nonascii = true },
        .byte, .grapheme, .string_property => .{ .ascii = .{ ~@as(u64, 0), ~@as(u64, 0) }, .nonascii = true },
        .accept, .sub_accept, .accept_verb => .{ .empty = true },
        .fail => .{},
        .split, .save, .restore_pos, .assertion, .lookahead, .reset_start, .prune, .skip, .commit, .then, .mark, .callout, .auto_callout, .reset_captures, .dispatch, .lookaround, .conditional, .conditional_assert, .conditional_recursion, .lookbehind_non_atomic, .lookbehind_next, .lookbehind_accept, .script_run_check, .scan_substring => .{},
        .backref, .atomic, .call, .ret => conservative_first,
    };
}

/// Compute the conservative first-rune summary of every instruction. The
/// summary is the union of the first runes reachable through zero-width
/// instructions. Callers must free the returned slice.
fn computeFirstSets(allocator: std.mem.Allocator, instructions: []const model.Instruction, pending_dispatches: []const Builder.PendingDispatch) model.Error![]model.FirstSet {
    const count = instructions.len;
    const first = try allocator.alloc(model.FirstSet, count);
    errdefer allocator.free(first);
    if (count == 0) return first;
    for (instructions, 0..) |instruction, index| first[index] = terminalFirst(instruction);

    const Edge = struct { from: u32, to: u32 };
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(allocator);
    for (instructions, 0..) |instruction, index| {
        const from: u32 = @intCast(index);
        switch (instruction) {
            .split => |split| {
                try edges.append(allocator, .{ .from = from, .to = @intCast(split.left) });
                try edges.append(allocator, .{ .from = from, .to = @intCast(split.right) });
            },
            .save => |save| try edges.append(allocator, .{ .from = from, .to = @intCast(save.next) }),
            .restore_pos => |restore| try edges.append(allocator, .{ .from = from, .to = @intCast(restore.next) }),
            .lookbehind_non_atomic => |look| try edges.append(allocator, .{ .from = from, .to = @intCast(look.next) }),
            .lookbehind_accept => |look| try edges.append(allocator, .{ .from = from, .to = @intCast(look.next) }),
            .script_run_check => |check| try edges.append(allocator, .{ .from = from, .to = @intCast(check.next) }),
            .scan_substring => |scan| try edges.append(allocator, .{ .from = from, .to = @intCast(scan.next) }),
            .assertion => |assertion| try edges.append(allocator, .{ .from = from, .to = @intCast(assertion.next) }),
            .lookahead => |look| try edges.append(allocator, .{ .from = from, .to = @intCast(look.next) }),
            .star => |star| try edges.append(allocator, .{ .from = from, .to = @intCast(star.next) }),
            .reset_start => |next| try edges.append(allocator, .{ .from = from, .to = @intCast(next) }),
            .prune => |next| try edges.append(allocator, .{ .from = from, .to = @intCast(next) }),
            .skip => |skip| try edges.append(allocator, .{ .from = from, .to = @intCast(skip.next) }),
            .commit => |next| try edges.append(allocator, .{ .from = from, .to = @intCast(next) }),
            .then => |next| try edges.append(allocator, .{ .from = from, .to = @intCast(next) }),
            .mark => |mark| try edges.append(allocator, .{ .from = from, .to = @intCast(mark.next) }),
            .callout => |callout| try edges.append(allocator, .{ .from = from, .to = @intCast(callout.next) }),
            .auto_callout => |next| try edges.append(allocator, .{ .from = from, .to = @intCast(next) }),
            .reset_captures => |reset| try edges.append(allocator, .{ .from = from, .to = @intCast(reset.next) }),
            .dispatch => {
                for (pending_dispatches) |record| {
                    if (record.instruction != index) continue;
                    for (record.branches) |branch| {
                        try edges.append(allocator, .{ .from = from, .to = @intCast(branch) });
                    }
                    break;
                }
            },
            .lookaround => |look| try edges.append(allocator, .{ .from = from, .to = @intCast(look.next) }),
            .conditional => |cond| {
                try edges.append(allocator, .{ .from = from, .to = @intCast(cond.yes) });
                try edges.append(allocator, .{ .from = from, .to = @intCast(cond.no) });
            },
            .conditional_assert => |cond| {
                try edges.append(allocator, .{ .from = from, .to = @intCast(cond.yes) });
                try edges.append(allocator, .{ .from = from, .to = @intCast(cond.no) });
            },
            .conditional_recursion => |cond| {
                try edges.append(allocator, .{ .from = from, .to = @intCast(cond.yes) });
                try edges.append(allocator, .{ .from = from, .to = @intCast(cond.no) });
            },
            else => {},
        }
    }

    // CSR predecessor lists: an edge `u -> v` means `first[u]` depends on
    // `first[v]`, so changes to `v` propagate to `u`.
    const offsets = try allocator.alloc(u32, count + 1);
    defer allocator.free(offsets);
    @memset(offsets, 0);
    for (edges.items) |edge| offsets[edge.to + 1] += 1;
    for (1..count + 1) |index| offsets[index] += offsets[index - 1];
    const predecessors = try allocator.alloc(u32, edges.items.len);
    defer allocator.free(predecessors);
    const cursor = try allocator.alloc(u32, count);
    defer allocator.free(cursor);
    @memcpy(cursor, offsets[0..count]);
    for (edges.items) |edge| {
        predecessors[cursor[edge.to]] = edge.from;
        cursor[edge.to] += 1;
    }

    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    const queued = try allocator.alloc(bool, count);
    defer allocator.free(queued);
    @memset(queued, false);
    for (first, 0..) |value, index| {
        if (value.eql(.{})) continue;
        queued[index] = true;
        try queue.append(allocator, @intCast(index));
    }
    while (queue.pop()) |node| {
        queued[node] = false;
        for (predecessors[offsets[node]..offsets[node + 1]]) |pred| {
            const updated = first[pred].merge(first[node]);
            if (updated.eql(first[pred])) continue;
            first[pred] = updated;
            if (queued[pred]) continue;
            queued[pred] = true;
            try queue.append(allocator, pred);
        }
    }

    return first;
}

/// Fill `split.first`/`split.skip` from the computed summaries. A left branch
/// that can reach `accept` without consuming is never skipped.
fn annotateSplits(instructions: []model.Instruction, first: []const model.FirstSet) void {
    for (instructions) |*instruction| switch (instruction.*) {
        .split => |*split| {
            const summary = first[split.left];
            if (summary.empty or !summary.selective()) continue;
            split.first = summary;
            split.skip = true;
        },
        else => {},
    };
}

pub fn compile(allocator: std.mem.Allocator, parsed: model.ParseResult, limits: model.Limits) model.Error!Program {
    const extended = parsed.extended or limits.auto_callout;
    const group_count = parsed.group_nodes.len;
    const group_starts = try allocator.alloc(usize, group_count);
    defer allocator.free(group_starts);
    const group_compiled = try allocator.alloc(bool, group_count);
    defer allocator.free(group_compiled);
    @memset(group_compiled, false);

    var builder = Builder{
        .allocator = allocator,
        .limits = limits,
        .group_nodes = parsed.group_nodes,
        .group_starts = group_starts,
        .group_compiled = group_compiled,
        .specialize_loops = !extended,
        .capture_reset = limits.capture_reset,
        .auto_callout = limits.auto_callout,
        .capture_count = parsed.capture_count,
    };
    defer builder.instructions.deinit(allocator);
    defer builder.pending_calls.deinit(allocator);
    defer builder.pending_dispatches.deinit(allocator);

    const accept = try builder.emit(.accept);
    builder.sub_accept = try builder.emit(.sub_accept);
    builder.ret = try builder.emit(.ret);
    const match_end = try builder.emit(.{ .save = .{ .slot = 1, .next = accept } });
    const body = try builder.node(parsed.root, match_end);
    const start = try builder.emit(.{ .save = .{ .slot = 0, .next = body } });

    // Compile referenced subroutine bodies. New calls discovered while
    // compiling a body are appended to `pending_calls` and processed here.
    var pending_index: usize = 0;
    while (pending_index < builder.pending_calls.items.len) : (pending_index += 1) {
        const pending = builder.pending_calls.items[pending_index];
        const group = @as(usize, pending.group);
        if (group >= group_count) return error.InvalidRegex;
        if (group_compiled[group]) continue;
        group_compiled[group] = true;
        const subroutine_body = if (group == 0) parsed.root else parsed.group_nodes[group];
        group_starts[group] = try builder.node(subroutine_body, builder.ret);
    }
    for (builder.pending_calls.items) |pending| {
        const group = @as(usize, pending.group);
        builder.instructions.items[pending.instruction].call.child = group_starts[group];
    }

    if (!limits.longest) {
        // A star whose continuation always succeeds never needs a backtrack
        // record: the greedy scan is the only viable length.
        for (builder.instructions.items) |*instruction| {
            if (instruction.* != .star) continue;
            var next = instruction.star.next;
            while (next < builder.instructions.items.len) {
                switch (builder.instructions.items[next]) {
                    .save => |save| next = save.next,
                    .reset_captures => |reset| next = reset.next,
                    else => break,
                }
            }
            if (next == accept) instruction.star.backtrack = false;
        }
    }
    const first_sets = try computeFirstSets(allocator, builder.instructions.items, builder.pending_dispatches.items);
    defer allocator.free(first_sets);
    annotateSplits(builder.instructions.items, first_sets);
    const dispatches = try allocator.alloc(model.Dispatch, builder.pending_dispatches.items.len);
    errdefer allocator.free(dispatches);
    for (builder.pending_dispatches.items, 0..) |record, dispatch_index| {
        var dispatch = model.Dispatch{ .branches = record.branches };
        for (record.branches, 0..) |branch, branch_index| {
            const first = first_sets[branch];
            const bit: u16 = @as(u16, 1) << @intCast(branch_index);
            if (first.empty) dispatch.eof |= bit;
            if (first.empty or first.nonascii) dispatch.nonascii |= bit;
            var byte: usize = 0;
            while (byte < 128) : (byte += 1) {
                if (first.empty or first.allowsByte(@intCast(byte))) dispatch.ascii[byte] |= bit;
            }
        }
        dispatches[dispatch_index] = dispatch;
        builder.instructions.items[record.instruction].dispatch.table = @intCast(dispatch_index);
    }
    const program_first = first_sets[start];
    const instructions = try builder.instructions.toOwnedSlice(allocator);
    errdefer allocator.free(instructions);
    var literal_builder = LiteralBuilder{ .allocator = allocator };
    defer literal_builder.bytes.deinit(allocator);
    const literal: ?[]const u8 = if (!limits.auto_callout and try literal_builder.append(parsed.root))
        try literal_builder.bytes.toOwnedSlice(allocator)
    else
        null;
    var prefix_builder = PrefixBuilder{ .allocator = allocator };
    defer prefix_builder.bytes.deinit(allocator);
    if (!limits.auto_callout) _ = try prefix_builder.append(parsed.root);
    const prefix_bytes: ?[]const u8 = if (prefix_builder.bytes.items.len != 0)
        try prefix_builder.bytes.toOwnedSlice(allocator)
    else
        null;
    const literal_prefix = literal orelse prefix_bytes;
    var caseless_builder = CaselessLiteralBuilder{ .allocator = allocator };
    defer caseless_builder.bytes.deinit(allocator);
    const caseless_literal: ?[]const u8 = if (literal == null and !limits.auto_callout and
        try caseless_builder.append(parsed.root) and caseless_builder.bytes.items.len >= 2)
        try caseless_builder.bytes.toOwnedSlice(allocator)
    else
        null;
    const literal_set: ?[]const []const u8 = if (literal == null and caseless_literal == null and
        !limits.auto_callout) try expandLiteralSet(allocator, parsed.root) else null;
    const unbounded_storage = try allocator.alloc(u8, UnboundedSequenceBuilder.max_literal_bytes);
    const prefix_run: ?PrefixRunShape = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout) detectPrefixRun(parsed.root) else null;
    const chain_loop: ?ChainLoopShape = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout) detectChainLoop(parsed.root) else null;
    const optional_tail: ?OptionalTailShape = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout) detectOptionalTail(parsed.root) else null;
    const bounded_loop: ?BoundedLoopShape = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout) detectBoundedLoop(parsed.root) else null;
    const signed_number: ?NumberShape = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout) detectSignedNumber(parsed.root) else null;
    const line_heading: ?LineHeadingShape = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout and parsed.newline == .lf)
        detectLineHeading(parsed.root)
    else
        null;
    const optional_run: ?model.Set = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout) detectOptionalRun(parsed.root) else null;
    var unbounded_builder = UnboundedSequenceBuilder{ .allocator = allocator, .literal_bytes = unbounded_storage };
    defer unbounded_builder.elements.deinit(allocator);
    const unbounded_sequence: ?[]const UnboundedElement = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout and try unbounded_builder.add(parsed.root) and
        unbounded_builder.validate())
        try unbounded_builder.elements.toOwnedSlice(allocator)
    else
        null;
    var bounded_builder = BoundedSequenceBuilder{ .allocator = allocator };
    defer bounded_builder.elements.deinit(allocator);
    const bounded_sequence: ?[]const BoundedElement = if (literal == null and caseless_literal == null and
        literal_set == null and !limits.auto_callout and try bounded_builder.add(parsed.root) and
        bounded_builder.saw_variable and bounded_builder.optionalLast() and
        bounded_builder.elements.items.len >= 2)
        try bounded_builder.elements.toOwnedSlice(allocator)
    else
        null;
    var dfa_eligible = true;
    var needs_ucp_word = false;
    for (instructions) |instruction| switch (instruction) {
        .assertion => |assertion| {
            dfa_eligible = false;
            switch (assertion.kind) {
                .word_boundary_unicode, .no_word_boundary_unicode, .word_start_unicode, .no_word_start_unicode, .word_end_unicode, .no_word_end_unicode => needs_ucp_word = true,
                else => {},
            }
        },
        .lookahead, .lookaround, .backref, .atomic, .conditional, .conditional_assert, .conditional_recursion, .byte, .reset_start, .grapheme, .string_property, .restore_pos, .lookbehind_non_atomic, .lookbehind_next, .lookbehind_accept, .script_run_check, .fail, .accept_verb, .prune, .skip, .commit, .then, .mark, .call => dfa_eligible = false,
        else => {},
    };
    const ucp_word: ?model.Set = if (needs_ucp_word) blk: {
        const raw = try classes.unicodeWordRanges(allocator, limits.max_ranges);
        break :blk try classes.normalize(allocator, raw, false, .none, limits.max_ranges);
    } else null;
    const required = try required_literals.analyze(allocator, parsed.root);
    const start_literals = try start_literals_mod.analyze(allocator, parsed.root);
    const fast_branch = if (parsed.capture_count == 0)
        try fast_branch_mod.analyze(allocator, parsed.root)
    else
        null;
    const zero_width = zero_width_mod.analyze(parsed.root, parsed.newline);
    return .{
        .instructions = instructions,
        .start = start,
        .body = body,
        .accept = accept,
        .capture_count = parsed.capture_count,
        .extra_slots = builder.extra_slots,
        .literal = literal,
        .literal_prefix = literal_prefix,
        .caseless_literal = caseless_literal,
        .literal_set = literal_set,
        .bounded_sequence = bounded_sequence,
        .unbounded_sequence = unbounded_sequence,
        .prefix_run = prefix_run,
        .chain_loop = chain_loop,
        .optional_tail = optional_tail,
        .bounded_loop = bounded_loop,
        .signed_number = signed_number,
        .line_heading = line_heading,
        .optional_run = optional_run,
        .dfa_eligible = dfa_eligible,
        .extended = extended,
        .newline = parsed.newline,
        .notempty = parsed.notempty,
        .notempty_atstart = parsed.notempty_atstart,
        .limit_match = parsed.limit_match,
        .limit_depth = parsed.limit_depth,
        .limit_heap_choices = if (parsed.limit_heap_kib == std.math.maxInt(usize))
            std.math.maxInt(usize)
        else
            @max((std.math.mul(usize, parsed.limit_heap_kib, 1024) catch std.math.maxInt(usize)) / 64, 1),
        .group_names = parsed.group_names,
        .ucp_word = ucp_word,
        .marks = parsed.marks,
        .callouts = parsed.callouts,
        .dispatches = dispatches,
        .first = program_first,
        .skip_start = !program_first.empty and program_first.selective(),
        .required_literals = required,
        .start_literals = start_literals,
        .fast_branch = fast_branch,
        .zero_width = zero_width,
    };
}
