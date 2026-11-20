//! Recognition of zero-width assertion programs (`^`, `$`, `(?m)^$`, ...).
//!
//! A pattern made only of text/line edge assertions can match only at the
//! text edges or next to a line break, so a search can enumerate those
//! positions and check each assertion conjunction instead of restarting the
//! interpreter at every offset.
const std = @import("std");
const model = @import("model.zig");

pub const Plan = struct {
    pub const max_paths = 8;
    pub const max_assertions = 4;
    pub const max_slots = 8;
    paths: [max_paths]Path = undefined,
    count: u8 = 0,
};

/// One alternation path: a conjunction of edge assertions plus the capture
/// slots saved along the way. A zero-width match sets every saved slot to the
/// match offset.
pub const Path = struct {
    assertions: [Plan.max_assertions]model.Assertion = undefined,
    assertion_count: u8 = 0,
    slots: [Plan.max_slots]u16 = undefined,
    slot_count: u8 = 0,
};

fn allowed(assertion: model.Assertion) bool {
    return switch (assertion) {
        .start_text, .start_line, .end_text, .end_text_or_newline, .end_line => true,
        else => false,
    };
}

/// Analyze a parsed pattern. Returns null for anything that is not a pure
/// edge-assertion alternation, including the `(*ANY)` convention whose
/// multi-byte Unicode breaks the byte-oriented boundary scan does not cover.
pub fn analyze(root: *const model.Node, newline: model.Newline) ?Plan {
    if (newline == .any) return null;
    var plan = Plan{};
    var count: usize = 0;
    if (!expand(root, .{}, &plan.paths, &count, 0)) return null;
    if (count == 0) return null;
    plan.count = @intCast(count);
    return plan;
}

fn expand(node: *const model.Node, base: Path, out: *[Plan.max_paths]Path, count: *usize, depth: usize) bool {
    if (depth > 64) return false;
    switch (node.*) {
        .empty, .flag_change => {
            if (count.* == Plan.max_paths) return false;
            out[count.*] = base;
            count.* += 1;
            return true;
        },
        .assertion => |assertion| {
            if (!allowed(assertion)) return false;
            var path = base;
            if (path.assertion_count == Plan.max_assertions) return false;
            path.assertions[path.assertion_count] = assertion;
            path.assertion_count += 1;
            if (count.* == Plan.max_paths) return false;
            out[count.*] = path;
            count.* += 1;
            return true;
        },
        .group => |child| return expand(child, base, out, count, depth + 1),
        .atomic => |child| return expand(child, base, out, count, depth + 1),
        .capture => |capture| {
            var path = base;
            if (path.slot_count + 2 > Plan.max_slots) return false;
            path.slots[path.slot_count] = capture.index * 2;
            path.slots[path.slot_count + 1] = capture.index * 2 + 1;
            path.slot_count += 2;
            return expand(capture.child, path, out, count, depth + 1);
        },
        .alternate => |pair| {
            return expand(pair.left, base, out, count, depth + 1) and
                expand(pair.right, base, out, count, depth + 1);
        },
        .pair => |pair| {
            var left: [Plan.max_paths]Path = undefined;
            var left_count: usize = 0;
            if (!expand(pair.left, base, &left, &left_count, depth + 1)) return false;
            for (left[0..left_count]) |path| {
                if (!expand(pair.right, path, out, count, depth + 1)) return false;
            }
            return true;
        },
        else => return false,
    }
}
