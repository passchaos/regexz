//! Recognition of a dominant alternation branch that admits a dedicated run
//! scan.
//!
//! Tokenizer patterns often start with a small set of special prefixes and
//! then a branch shaped like `set? setB+`. When the current byte cannot start
//! any earlier branch, that branch alone decides the match: a maximal run of
//! `setB` (optionally preceded by one `set` rune). A dedicated UTF-8
//! automaton scan then replaces the general DFA for the common case.
//!
//! The analysis is deliberately conservative: an earlier branch whose first
//! byte summary cannot be computed, or one that can match empty, disables the
//! plan. The optional prefix may overlap the run set; the scan then tries the
//! greedy prefix form before the bare run, matching the engine's order.
const std = @import("std");
const model = @import("model.zig");

pub const LaterKind = enum { single, run, prefix_run_tail, whitespace };

/// A branch after the dominant one whose match can be scanned directly once
/// the dominant branch has failed at the position.
pub const Later = struct {
    kind: LaterKind,
    /// Optional single-rune prefix (`set?`); disjoint from `run`.
    prefix: ?model.Set = null,
    run: model.Set,
    /// Optional trailing run (`set*`), for example `[\r\n]*`.
    tail: ?model.Set = null,
    /// The trailing whitespace branches also include `\s*[\r\n]+` and/or
    /// `\s+(?!\S)` before the bare `\s+` run.
    newline_branch: bool = false,
    lookahead_branch: bool = false,
    /// A bare `\s+` branch follows the newline/lookahead branches, so a
    /// failed earlier branch may still match the whole run.
    bare_branch: bool = false,
};

pub const Plan = struct {
    /// Union of the first-byte summaries of every earlier branch. A byte
    /// outside it cannot start an earlier branch.
    prior_first: model.FirstSet,
    /// Optional single-rune prefix (`set?`).
    prefix: ?model.Set,
    /// The run set (`set+`).
    run: model.Set,
    /// Branches after the dominant one, in order, up to the first branch
    /// that cannot be scanned directly.
    later: []const Later = &.{},
};

pub fn analyze(allocator: std.mem.Allocator, root: *const model.Node) model.Error!?Plan {
    var branches: std.ArrayList(*const model.Node) = .empty;
    defer branches.deinit(allocator);
    try collect(allocator, root, &branches);
    if (branches.items.len < 2) return null;
    var prior_first = model.FirstSet{};
    for (branches.items, 0..) |branch, index| {
        if (branchPlan(branch)) |plan| {
            var later: std.ArrayList(Later) = .empty;
            defer later.deinit(allocator);
            for (branches.items[index + 1 ..], 0..) |next, offset| {
                if (laterPlan(next)) |next_plan| {
                    try later.append(allocator, next_plan);
                    continue;
                }
                // The trailing branches may be the whitespace tail
                // (`\s*[\r\n]+`, `\s+(?!\S)`, `\s+`), which one scan
                // decides exactly.
                if (whitespacePlan(branches.items[index + 1 + offset ..])) |plan_ws| {
                    try later.append(allocator, plan_ws);
                }
                break;
            }
            return .{
                .prior_first = prior_first,
                .prefix = plan.prefix,
                .run = plan.run,
                .later = try later.toOwnedSlice(allocator),
            };
        }
        // An earlier branch must be provably unable to match here, so its
        // first-byte summary must exist and must consume input.
        const first = firstOf(branch) orelse return null;
        if (first.empty) return null;
        prior_first = model.FirstSet.merge(prior_first, first);
    }
    return null;
}

fn collect(
    allocator: std.mem.Allocator,
    node: *const model.Node,
    list: *std.ArrayList(*const model.Node),
) model.Error!void {
    switch (node.*) {
        .alternate => |pair| {
            try collect(allocator, pair.left, list);
            try collect(allocator, pair.right, list);
        },
        else => try list.append(allocator, node),
    }
}

fn strip(node: *const model.Node) *const model.Node {
    var current = node;
    while (true) {
        current = switch (current.*) {
            .group => |child| child,
            else => return current,
        };
    }
}

fn branchPlan(branch: *const model.Node) ?Plan {
    const node = strip(branch);
    return switch (node.*) {
        .repeat => |repeat| blk: {
            if (repeat.minimum < 1 or repeat.maximum != null or repeat.lazy) break :blk null;
            const child = strip(repeat.child);
            if (child.* != .set) break :blk null;
            break :blk .{ .prior_first = .{}, .prefix = null, .run = child.set };
        },
        .pair => |pair| blk: {
            const left = strip(pair.left);
            const right = strip(pair.right);
            const prefix = switch (left.*) {
                .repeat => |repeat| blk2: {
                    if (repeat.minimum != 0 or repeat.maximum == null or repeat.maximum.? > 1 or repeat.lazy) break :blk2 null;
                    const child = strip(repeat.child);
                    if (child.* != .set) break :blk2 null;
                    break :blk2 child.set;
                },
                else => null,
            } orelse break :blk null;
            const run = switch (right.*) {
                .repeat => |repeat| blk2: {
                    if (repeat.minimum < 1 or repeat.maximum != null or repeat.lazy) break :blk2 null;
                    const child = strip(repeat.child);
                    if (child.* != .set) break :blk2 null;
                    break :blk2 child.set;
                },
                else => null,
            } orelse break :blk null;
            break :blk .{ .prior_first = .{}, .prefix = prefix, .run = run };
        },
        else => null,
    };
}

/// A branch after the dominant one, or null when it is not one of the shapes
/// that can be scanned directly (`set`, `set+`, or `prefix? set+ set*`).
/// Whether the subtree contains a lookaround. The direct later-branch scans
/// cannot model lookaround side conditions, so such branches must stay on
/// the general engine. Pure whitespace branches are handled separately by
/// `whitespacePlan`, which does model `\s+(?!\S)`.
fn hasLookaround(node: *const model.Node) bool {
    return switch (node.*) {
        .lookahead_set, .lookaround => true,
        .group => |child| hasLookaround(child),
        .capture => |capture| hasLookaround(capture.child),
        .atomic => |child| hasLookaround(child),
        .pair => |pair| hasLookaround(pair.left) or hasLookaround(pair.right),
        .alternate => |pair| hasLookaround(pair.left) or hasLookaround(pair.right),
        .repeat => |repeat| hasLookaround(repeat.child),
        else => false,
    };
}

fn laterPlan(branch: *const model.Node) ?Later {
    if (hasLookaround(branch)) return null;
    const node = strip(branch);
    return switch (node.*) {
        .set => |set| .{ .kind = .single, .run = set },
        .repeat => blk: {
            const run = requiredRun(node) orelse break :blk null;
            break :blk .{ .kind = .run, .run = run };
        },
        .pair => |pair| blk: {
            const left = strip(pair.left);
            const right = strip(pair.right);
            // prefix? (run tail?)  [right-nested sequence]
            if (optionalPrefix(left)) |prefix| {
                if (right.* == .pair) {
                    const inner = right.pair;
                    const run = requiredRun(inner.left);
                    const tail = optionalTail(inner.right);
                    if (run != null and !setsOverlap(prefix, run.?)) {
                        break :blk .{ .kind = .prefix_run_tail, .prefix = prefix, .run = run.?, .tail = tail };
                    }
                    break :blk null;
                }
                if (requiredRun(right)) |run| {
                    if (!setsOverlap(prefix, run)) {
                        break :blk .{ .kind = .prefix_run_tail, .prefix = prefix, .run = run };
                    }
                }
                break :blk null;
            }
            // run tail  [right-nested sequence]
            if (requiredRun(left)) |run| {
                const tail = optionalTail(right);
                if (tail != null) {
                    break :blk .{ .kind = .prefix_run_tail, .run = run, .tail = tail };
                }
                break :blk null;
            }
            // (prefix? run) tail?  [left-nested sequence]
            if (left.* == .pair) {
                const inner = left.pair;
                const prefix = optionalPrefix(inner.left);
                const run = requiredRun(inner.right);
                const tail = optionalTail(right);
                if (prefix != null and run != null and !setsOverlap(prefix.?, run.?)) {
                    break :blk .{ .kind = .prefix_run_tail, .prefix = prefix, .run = run.?, .tail = tail };
                }
            }
            break :blk null;
        },
        else => null,
    };
}

const WhitespaceShape = struct { set: model.Set, newline: bool = false, lookahead: bool = false };

/// Recognizes `\s*[\r\n]+`, `\s+(?!\S)` and `\s+` branches.
fn whitespaceShape(node: *const model.Node) ?WhitespaceShape {
    const value = strip(node);
    return switch (value.*) {
        .repeat => |repeat| blk: {
            if (repeat.minimum < 1 or repeat.maximum != null or repeat.lazy) break :blk null;
            const child = strip(repeat.child);
            if (child.* != .set) break :blk null;
            break :blk .{ .set = child.set };
        },
        .pair => |pair| blk: {
            const left = strip(pair.left);
            const right = strip(pair.right);
            if (left.* == .repeat and right.* == .repeat) {
                const star = left.repeat;
                const plus = right.repeat;
                if (star.minimum != 0 or star.lazy) break :blk null;
                if (star.maximum != null and star.maximum.? > 1) break :blk null;
                if (plus.minimum < 1 or plus.maximum != null or plus.lazy) break :blk null;
                const run = strip(star.child);
                const newline = strip(plus.child);
                if (run.* != .set or newline.* != .set) break :blk null;
                if (!isNewlineSet(newline.set)) break :blk null;
                break :blk .{ .set = run.set, .newline = true };
            }
            if (left.* == .repeat and right.* == .lookahead_set) {
                const plus = left.repeat;
                if (plus.minimum < 1 or plus.maximum != null or plus.lazy) break :blk null;
                const run = strip(plus.child);
                if (run.* != .set) break :blk null;
                const look = right.lookahead_set;
                if (!look.negative or !isComplement(run.set, look.set)) break :blk null;
                break :blk .{ .set = run.set, .lookahead = true };
            }
            break :blk null;
        },
        else => null,
    };
}

fn sameSet(a: model.Set, b: model.Set) bool {
    if (a.ranges.len != b.ranges.len) return false;
    for (a.ranges, b.ranges) |left, right| {
        if (left.first != right.first or left.last != right.last) return false;
    }
    return true;
}

fn isNewlineSet(set: model.Set) bool {
    if (set.ranges.len != 2) return false;
    return set.ranges[0].first == '\n' and set.ranges[0].last == '\n' and
        set.ranges[1].first == '\r' and set.ranges[1].last == '\r';
}

/// Whether `b` is exactly the complement of the normalized set `a`.
fn isComplement(a: model.Set, b: model.Set) bool {
    var next: u32 = 0;
    var index: usize = 0;
    for (a.ranges) |range| {
        if (range.first > next) {
            if (index >= b.ranges.len) return false;
            if (b.ranges[index].first != next or b.ranges[index].last != range.first - 1) return false;
            index += 1;
        }
        next = @as(u32, range.last) + 1;
    }
    if (next <= 0x10FFFF) {
        if (index >= b.ranges.len) return false;
        if (b.ranges[index].first != next or b.ranges[index].last != 0x10FFFF) return false;
        index += 1;
    }
    return index == b.ranges.len;
}

/// Recognizes the trailing whitespace branches as one exact scan. The slice
/// must contain exactly the remaining branches.
fn whitespacePlan(rest: []const *const model.Node) ?Later {
    if (rest.len == 0) return null;
    const first = whitespaceShape(rest[0]) orelse return null;
    var plan = Later{ .kind = .whitespace, .run = first.set };
    if (first.newline) {
        plan.newline_branch = true;
        if (rest.len == 1) return plan;
        const second = whitespaceShape(rest[1]) orelse return null;
        if (second.newline or !sameSet(first.set, second.set)) return null;
        if (second.lookahead) {
            plan.lookahead_branch = true;
            if (rest.len == 2) return plan;
            if (rest.len != 3) return null;
            const third = whitespaceShape(rest[2]) orelse return null;
            if (third.newline or third.lookahead or !sameSet(first.set, third.set)) return null;
            plan.bare_branch = true;
            return plan;
        }
        if (rest.len != 2) return null;
        plan.bare_branch = true;
        return plan;
    }
    if (first.lookahead) {
        plan.lookahead_branch = true;
        if (rest.len == 1) return plan;
        if (rest.len != 2) return null;
        const second = whitespaceShape(rest[1]) orelse return null;
        if (second.newline or second.lookahead or !sameSet(first.set, second.set)) return null;
        plan.bare_branch = true;
        return plan;
    }
    if (rest.len != 1) return null;
    plan.bare_branch = true;
    return plan;
}

fn optionalPrefix(node: *const model.Node) ?model.Set {
    const value = strip(node);
    if (value.* != .repeat) return null;
    const repeat = value.repeat;
    if (repeat.lazy or repeat.possessive or repeat.minimum != 0 or repeat.maximum == null or repeat.maximum.? != 1) return null;
    const child = strip(repeat.child);
    if (child.* != .set) return null;
    return child.set;
}

fn requiredRun(node: *const model.Node) ?model.Set {
    const value = strip(node);
    if (value.* != .repeat) return null;
    const repeat = value.repeat;
    if (repeat.lazy or repeat.possessive or repeat.minimum < 1 or repeat.maximum != null) return null;
    const child = strip(repeat.child);
    if (child.* != .set) return null;
    return child.set;
}

fn optionalTail(node: *const model.Node) ?model.Set {
    const value = strip(node);
    if (value.* != .repeat) return null;
    const repeat = value.repeat;
    if (repeat.lazy or repeat.possessive or repeat.minimum != 0 or repeat.maximum != null) return null;
    const child = strip(repeat.child);
    if (child.* != .set) return null;
    return child.set;
}

/// Whether two normalized range lists share any rune.
fn setsOverlap(a: model.Set, b: model.Set) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.ranges.len and bi < b.ranges.len) {
        const ar = a.ranges[ai];
        const br = b.ranges[bi];
        if (ar.last < br.first) {
            ai += 1;
        } else if (br.last < ar.first) {
            bi += 1;
        } else {
            return true;
        }
    }
    return false;
}

/// First-byte summary of `node`, or null when it cannot be computed exactly.
fn firstOf(node: *const model.Node) ?model.FirstSet {
    return switch (node.*) {
        .empty, .flag_change => model.FirstSet{ .empty = true },
        .set => |set| .{ .ascii = set.ascii, .nonascii = !set.ascii_only },
        .pair => |pair| blk: {
            const left = firstOf(pair.left) orelse break :blk null;
            if (!left.empty) break :blk left;
            const right = firstOf(pair.right) orelse break :blk null;
            break :blk model.FirstSet.merge(left, right);
        },
        .alternate => |pair| blk: {
            const left = firstOf(pair.left) orelse break :blk null;
            const right = firstOf(pair.right) orelse break :blk null;
            break :blk model.FirstSet.merge(left, right);
        },
        .group => |child| firstOf(child),
        .capture => |capture| firstOf(capture.child),
        .atomic => |child| firstOf(child),
        .repeat => |repeat| blk: {
            const child = firstOf(repeat.child) orelse break :blk null;
            if (repeat.minimum >= 1) break :blk child;
            break :blk .{ .ascii = child.ascii, .nonascii = child.nonascii, .empty = true };
        },
        else => null,
    };
}
