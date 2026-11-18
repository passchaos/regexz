//! Extract a literal-alternation start set from a parsed pattern.
//!
//! When every match must begin with one of a small set of literal strings, the
//! search DFA can use a multi-byte prefilter instead of a single-byte scan.
//! The analysis is deliberately conservative: anything that could start with a
//! class, an empty alternative, or a non-literal bails out.
const std = @import("std");
const model = @import("model.zig");

const max_literals: usize = 16;
const max_literal_len: usize = 32;
const max_total_bytes: usize = 256;

/// Start literals for `node`, or null when the pattern does not qualify.
/// Returned slices are allocated from `allocator` (normally the compile arena).
pub fn analyze(allocator: std.mem.Allocator, node: *const model.Node) model.Error!?[]const []const u8 {
    const list = (try literalsOf(allocator, node, 0)) orelse return null;
    if (list.len == 0 or list.len > max_literals) return null;
    var total: usize = 0;
    for (list) |literal| {
        if (literal.len == 0 or literal.len > max_literal_len) return null;
        total += literal.len;
    }
    if (total > max_total_bytes) return null;
    return list;
}

fn literalsOf(
    allocator: std.mem.Allocator,
    node: *const model.Node,
    depth: usize,
) model.Error!?[]const []const u8 {
    if (depth > 64) return null;
    return switch (node.*) {
        .empty, .flag_change, .assertion, .lookahead_set, .lookaround => null,
        .group => |child| literalsOf(allocator, child, depth + 1),
        .capture => |capture| literalsOf(allocator, capture.child, depth + 1),
        .atomic => |child| literalsOf(allocator, child, depth + 1),
        .set => |set| singleRuneLiteral(allocator, set),
        .pair => |pair| concat(allocator, pair.left, pair.right, depth),
        .alternate => |pair| unionLists(allocator, pair.left, pair.right, depth),
        .repeat => |repeat| if (repeat.minimum >= 1)
            literalsOf(allocator, repeat.child, depth + 1)
        else
            null,
        else => null,
    };
}

fn singleRuneLiteral(allocator: std.mem.Allocator, set: model.Set) model.Error!?[]const []const u8 {
    if (set.ranges.len != 1 or set.ranges[0].first != set.ranges[0].last) return null;
    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(set.ranges[0].first, &encoded) catch return null;
    const bytes = try allocator.dupe(u8, encoded[0..len]);
    const list = try allocator.alloc([]const u8, 1);
    list[0] = bytes;
    return list;
}

fn concat(
    allocator: std.mem.Allocator,
    left: *const model.Node,
    right: *const model.Node,
    depth: usize,
) model.Error!?[]const []const u8 {
    const left_list = (try literalsOf(allocator, left, depth + 1)) orelse return null;
    const right_list = (try literalsOf(allocator, right, depth + 1)) orelse {
        // The left side alone is still a safe prefix for every match.
        return left_list;
    };
    if (left_list.len * right_list.len > max_literals) return null;
    var result: std.ArrayList([]const u8) = .empty;
    defer result.deinit(allocator);
    for (left_list) |prefix| {
        for (right_list) |suffix| {
            if (prefix.len + suffix.len > max_literal_len) return null;
            const bytes = try allocator.alloc(u8, prefix.len + suffix.len);
            @memcpy(bytes[0..prefix.len], prefix);
            @memcpy(bytes[prefix.len..], suffix);
            try result.append(allocator, bytes);
        }
    }
    const owned: []const []const u8 = try result.toOwnedSlice(allocator);
    return owned;
}

fn unionLists(
    allocator: std.mem.Allocator,
    left: *const model.Node,
    right: *const model.Node,
    depth: usize,
) model.Error!?[]const []const u8 {
    const left_list = (try literalsOf(allocator, left, depth + 1)) orelse return null;
    const right_list = (try literalsOf(allocator, right, depth + 1)) orelse return null;
    if (left_list.len + right_list.len > max_literals) return null;
    const result = try allocator.alloc([]const u8, left_list.len + right_list.len);
    @memcpy(result[0..left_list.len], left_list);
    @memcpy(result[left_list.len..], right_list);
    return @as([]const []const u8, result);
}
