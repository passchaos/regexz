//! Compile-time extraction of literals that every match must contain.
//!
//! Search can scan for one of these literals before entering the VM; when
//! none occurs, no match is possible. This turns no-match scans of patterns
//! like `[a-z]*(?:foo|bar)` from repeated backtracking into one literal scan.
//!
//! The analysis is deliberately conservative: it only reports a set when the
//! AST proves that every match contains at least one of the literals. Pure
//! literals are exact byte strings; alternations contribute the union of both
//! branches only when both branches have a required set.
const std = @import("std");
const model = @import("model.zig");

pub const max_literals: usize = 8;
pub const max_literal_len: usize = 32;

const Set = struct {
    items: [max_literals][]const u8 = undefined,
    count: usize = 0,
};

/// Returns an arena-owned list of required literal alternatives, or null when
/// the pattern provides no useful guarantee.
pub fn analyze(allocator: std.mem.Allocator, root: *const model.Node) std.mem.Allocator.Error!?[]const []const u8 {
    const set = try required(allocator, root, 0) orelse return null;
    if (set.count == 0) return null;
    const result = try allocator.alloc([]const u8, set.count);
    @memcpy(result, set.items[0..set.count]);
    return result;
}

/// Whether any required literal occurs at or after `start`.
pub fn containsAny(input: []const u8, start: usize, literals: []const []const u8) bool {
    for (literals) |literal| {
        if (literal.len == 0) return true;
        if (indexOfLiteral(input, start, literal) != null) return true;
    }
    return false;
}

fn indexOfLiteral(input: []const u8, start: usize, needle: []const u8) ?usize {
    if (start > input.len) return null;
    var offset = start;
    while (std.mem.indexOfScalarPos(u8, input, offset, needle[0])) |found| {
        if (needle.len <= input.len - found and std.mem.eql(u8, input[found..][0..needle.len], needle)) return found;
        offset = found + 1;
    }
    return null;
}

fn pureLiteral(allocator: std.mem.Allocator, node: *const model.Node, depth: usize) std.mem.Allocator.Error!?[]const u8 {
    if (depth > 64) return null;
    switch (node.*) {
        .empty => return try allocator.dupe(u8, ""),
        .set => |set| {
            if (set.ranges.len != 1) return null;
            const range = set.ranges[0];
            if (range.first != range.last) return null;
            var buffer: [4]u8 = undefined;
            const length = std.unicode.utf8Encode(range.first, &buffer) catch return null;
            return try allocator.dupe(u8, buffer[0..length]);
        },
        .pair => |pair| {
            const left = try pureLiteral(allocator, pair.left, depth + 1) orelse return null;
            const right = try pureLiteral(allocator, pair.right, depth + 1) orelse return null;
            if (left.len + right.len > max_literal_len) return null;
            const result = try allocator.alloc(u8, left.len + right.len);
            @memcpy(result[0..left.len], left);
            @memcpy(result[left.len..], right);
            return result;
        },
        .capture => |capture| return pureLiteral(allocator, capture.child, depth + 1),
        .group => |child| return pureLiteral(allocator, child, depth + 1),
        .atomic => |child| return pureLiteral(allocator, child, depth + 1),
        .repeat => |repeat| {
            if (repeat.maximum == null or repeat.maximum.? != repeat.minimum) return null;
            const child = try pureLiteral(allocator, repeat.child, depth + 1) orelse return null;
            if (child.len * repeat.minimum > max_literal_len) return null;
            const result = try allocator.alloc(u8, child.len * repeat.minimum);
            for (0..repeat.minimum) |index| {
                @memcpy(result[index * child.len ..][0..child.len], child);
            }
            return result;
        },
        else => return null,
    }
}

fn required(allocator: std.mem.Allocator, node: *const model.Node, depth: usize) std.mem.Allocator.Error!?Set {
    if (depth > 64) return null;
    if (try pureLiteral(allocator, node, depth)) |literal| {
        if (literal.len == 0) return null;
        var set = Set{};
        set.items[0] = literal;
        set.count = 1;
        return set;
    }
    switch (node.*) {
        .pair => |pair| {
            const left = try required(allocator, pair.left, depth + 1);
            const right = try required(allocator, pair.right, depth + 1);
            return better(left, right);
        },
        .alternate => |pair| {
            const left = try required(allocator, pair.left, depth + 1) orelse return null;
            const right = try required(allocator, pair.right, depth + 1) orelse return null;
            return unionSets(left, right);
        },
        .repeat => |repeat| {
            if (repeat.minimum == 0) return null;
            return required(allocator, repeat.child, depth + 1);
        },
        .capture => |capture| return required(allocator, capture.child, depth + 1),
        .group => |child| return required(allocator, child, depth + 1),
        .atomic => |child| return required(allocator, child, depth + 1),
        .lookaround => |look| {
            // A positive lookahead is evaluated ahead of the match, so its
            // literal is still inside the scanned region. Lookbehind may look
            // before the search start, and negative assertions prove nothing.
            if (look.negative or look.behind) return null;
            return required(allocator, look.child, depth + 1);
        },
        .conditional => |conditional| {
            const no = conditional.no orelse return null;
            const yes_set = try required(allocator, conditional.yes, depth + 1) orelse return null;
            const no_set = try required(allocator, no, depth + 1) orelse return null;
            return unionSets(yes_set, no_set);
        },
        else => return null,
    }
}

fn score(set: Set) usize {
    var shortest = max_literal_len;
    for (set.items[0..set.count]) |literal| shortest = @min(shortest, literal.len);
    // Prefer fewer alternatives and longer literals.
    return shortest * 16 -| set.count;
}

fn better(a: ?Set, b: ?Set) ?Set {
    if (a == null) return b;
    if (b == null) return a;
    return if (score(a.?) >= score(b.?)) a else b;
}

fn unionSets(a: Set, b: Set) ?Set {
    var result = Set{};
    for (a.items[0..a.count]) |literal| {
        if (!addLiteral(&result, literal)) return null;
    }
    for (b.items[0..b.count]) |literal| {
        if (!addLiteral(&result, literal)) return null;
    }
    return result;
}

fn addLiteral(set: *Set, literal: []const u8) bool {
    for (set.items[0..set.count]) |existing| {
        if (std.mem.eql(u8, existing, literal)) return true;
        // A shorter prefix makes the longer literal redundant for an OR scan.
        if (std.mem.startsWith(u8, literal, existing)) return true;
    }
    var write: usize = 0;
    for (set.items[0..set.count]) |existing| {
        if (std.mem.startsWith(u8, existing, literal)) continue;
        set.items[write] = existing;
        write += 1;
    }
    set.count = write;
    if (set.count == max_literals) return false;
    set.items[set.count] = literal;
    set.count += 1;
    return true;
}
