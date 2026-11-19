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

pub const Plan = struct {
    /// Union of the first-byte summaries of every earlier branch. A byte
    /// outside it cannot start an earlier branch.
    prior_first: model.FirstSet,
    /// Optional single-rune prefix (`set?`).
    prefix: ?model.Set,
    /// The run set (`set+`).
    run: model.Set,
};

pub fn analyze(allocator: std.mem.Allocator, root: *const model.Node) model.Error!?Plan {
    var branches: std.ArrayList(*const model.Node) = .empty;
    defer branches.deinit(allocator);
    try collect(allocator, root, &branches);
    if (branches.items.len < 2) return null;
    var prior_first = model.FirstSet{};
    for (branches.items) |branch| {
        if (branchPlan(branch)) |plan| {
            return .{ .prior_first = prior_first, .prefix = plan.prefix, .run = plan.run };
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
