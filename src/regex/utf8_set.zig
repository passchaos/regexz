//! Deterministic byte-level UTF-8 automaton for a codepoint set.
//!
//! A set is decomposed into UTF-8 byte-range sequences (the same shape as the
//! `utf8-ranges` crate), then stored as a trie of disjoint byte ranges. Disjoint
//! codepoint ranges produce disjoint byte prefixes, so the trie is already
//! deterministic: no subset construction is needed. Leaves are not states; a
//! transition into a leaf reports `accept`, meaning a complete rune was read.
//!
//! `advance` is only used while building the byte-level search DFA, never in a
//! scanning hot loop, so a compact edge list beats a 256-entry table here.
const std = @import("std");
const model = @import("model.zig");

/// Transition result for a byte that no edge covers.
pub const dead: u16 = 0xFFFF;
/// Transition result for a byte that completes a rune in the set.
pub const accept: u16 = 0xFFFE;

const max_codepoint: u21 = 0x10FFFF;

/// Codepoint ranges where the UTF-8 encoding is "linear": the lead byte range
/// never spans the special E0/ED/F0/F4 continuation constraints. Splitting at
/// these boundaries keeps the recursive range split from emitting overlong or
/// surrogate encodings.
const segments = [_][2]u21{
    .{ 0x0000, 0x007F },
    .{ 0x0080, 0x07FF },
    .{ 0x0800, 0xD7FF },
    .{ 0xE000, 0xFFFF },
    .{ 0x10000, 0x3FFFF },
    .{ 0x40000, 0xFFFFF },
    .{ 0x100000, 0x10FFFF },
};

pub const Edge = struct { lo: u8, hi: u8, next: u16 };
pub const Node = struct { start: u32, count: u16 };

pub const Automaton = struct {
    nodes: []Node,
    edges: []Edge,

    pub fn deinit(self: *Automaton, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.edges);
        self.* = undefined;
    }

    pub fn stateCount(self: Automaton) usize {
        return self.nodes.len;
    }

    /// Follow `byte` from `state`: `dead`, `accept`, or the next state id.
    pub fn advance(self: Automaton, state: u16, byte: u8) u16 {
        const node = self.nodes[state];
        const edges = self.edges[node.start..][0..node.count];
        if (edges.len == 1) {
            const edge = edges[0];
            return if (byte >= edge.lo and byte <= edge.hi) edge.next else dead;
        }
        var first: usize = 0;
        var last: usize = edges.len;
        while (first < last) {
            const middle = first + (last - first) / 2;
            const edge = edges[middle];
            if (byte < edge.lo) {
                last = middle;
            } else if (byte > edge.hi) {
                first = middle + 1;
            } else {
                return edge.next;
            }
        }
        return dead;
    }
};

const ByteRange = struct { lo: u8, hi: u8 };

const BuildNode = struct {
    edges: std.ArrayListUnmanaged(ByteRange) = .empty,
    children: std.ArrayListUnmanaged(u32) = .empty,
    leaf: bool = false,
};

const Builder = struct {
    gpa: std.mem.Allocator,
    nodes: std.ArrayList(BuildNode) = .empty,

    fn init(gpa: std.mem.Allocator) !Builder {
        var self: Builder = .{ .gpa = gpa };
        try self.nodes.append(gpa, .{});
        return self;
    }

    fn deinit(self: *Builder) void {
        for (self.nodes.items) |*node| {
            node.edges.deinit(self.gpa);
            node.children.deinit(self.gpa);
        }
        self.nodes.deinit(self.gpa);
    }

    /// Return the child reached by an edge covering exactly `[lo, hi]`,
    /// creating it when absent. Identical prefixes share one subtree.
    fn child(self: *Builder, node: u32, lo: u8, hi: u8) !u32 {
        const target = &self.nodes.items[node];
        for (target.edges.items, target.children.items) |edge, existing| {
            if (edge.lo == lo and edge.hi == hi) return existing;
        }
        // Sequences are emitted in increasing byte order, so appending keeps
        // each node's edges sorted by `lo`.
        std.debug.assert(target.edges.items.len == 0 or target.edges.items[target.edges.items.len - 1].lo < lo);
        const created: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(self.gpa, .{});
        // `append` may reallocate; re-read the node instead of holding a
        // pointer across it.
        const owner = &self.nodes.items[node];
        try owner.edges.append(self.gpa, .{ .lo = lo, .hi = hi });
        try owner.children.append(self.gpa, created);
        return created;
    }

    fn insert(self: *Builder, sequence: []const ByteRange) !void {
        var node: u32 = 0;
        for (sequence) |range| node = try self.child(node, range.lo, range.hi);
        self.nodes.items[node].leaf = true;
    }

    fn finish(self: *Builder) !Automaton {
        var total: usize = 0;
        for (self.nodes.items) |node| total += node.edges.items.len;
        const nodes = try self.gpa.alloc(Node, self.nodes.items.len);
        errdefer self.gpa.free(nodes);
        const edges = try self.gpa.alloc(Edge, total);
        errdefer self.gpa.free(edges);
        var offset: usize = 0;
        for (self.nodes.items, 0..) |node, index| {
            nodes[index] = .{ .start = @intCast(offset), .count = @intCast(node.edges.items.len) };
            for (node.edges.items, node.children.items) |edge, target| {
                edges[offset] = .{
                    .lo = edge.lo,
                    .hi = edge.hi,
                    .next = if (self.nodes.items[target].leaf) accept else @intCast(target),
                };
                offset += 1;
            }
        }
        return .{ .nodes = nodes, .edges = edges };
    }
};

fn encode(codepoint: u21, out: *[4]u8) usize {
    if (codepoint < 0x80) {
        out[0] = @intCast(codepoint);
        return 1;
    }
    if (codepoint < 0x800) {
        out[0] = @intCast(0xC0 | (codepoint >> 6));
        out[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    }
    if (codepoint < 0x10000) {
        out[0] = @intCast(0xE0 | (codepoint >> 12));
        out[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    }
    out[0] = @intCast(0xF0 | (codepoint >> 18));
    out[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
    out[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
    out[3] = @intCast(0x80 | (codepoint & 0x3F));
    return 4;
}

/// Maximum (0xBF) and minimum (0x80) continuation bytes for every suffix
/// position of a UTF-8 sequence.
const max_suffix = [_]u8{0xBF} ** 3;
const min_suffix = [_]u8{0x80} ** 3;

fn emitBytes(
    builder: *Builder,
    sequence: *[4]ByteRange,
    depth: usize,
    lo: []const u8,
    hi: []const u8,
) !void {
    if (lo.len == 0) return builder.insert(sequence[0..depth]);
    if (lo[0] == hi[0]) {
        sequence[depth] = .{ .lo = lo[0], .hi = lo[0] };
        return emitBytes(builder, sequence, depth + 1, lo[1..], hi[1..]);
    }
    // The first differing byte: `lo[0]` with every suffix up to the maximum,
    // the middle byte values with full continuation ranges, then `hi[0]` with
    // every suffix from the minimum.
    const suffix_len = lo.len - 1;
    sequence[depth] = .{ .lo = lo[0], .hi = lo[0] };
    try emitBytes(builder, sequence, depth + 1, lo[1..], max_suffix[0..suffix_len]);
    if (@as(u16, lo[0]) + 1 <= @as(u16, hi[0]) - 1) {
        sequence[depth] = .{ .lo = lo[0] + 1, .hi = hi[0] - 1 };
        for (0..suffix_len) |index| sequence[depth + 1 + index] = .{ .lo = 0x80, .hi = 0xBF };
        try builder.insert(sequence[0 .. depth + lo.len]);
    }
    sequence[depth] = .{ .lo = hi[0], .hi = hi[0] };
    try emitBytes(builder, sequence, depth + 1, min_suffix[0..suffix_len], hi[1..]);
}

fn emitRange(builder: *Builder, first: u21, last: u21) !void {
    var lo_buffer: [4]u8 = undefined;
    const lo_len = encode(first, &lo_buffer);
    var hi_buffer: [4]u8 = undefined;
    const hi_len = encode(last, &hi_buffer);
    std.debug.assert(lo_len == hi_len);
    var sequence: [4]ByteRange = undefined;
    try emitBytes(builder, &sequence, 0, lo_buffer[0..lo_len], hi_buffer[0..hi_len]);
}

/// Build the automaton for a positive, sorted, disjoint range list.
pub fn build(gpa: std.mem.Allocator, ranges: []const model.Range) !Automaton {
    var builder = try Builder.init(gpa);
    errdefer builder.deinit();
    for (ranges) |range| {
        const first: u21 = range.first;
        const last: u21 = @min(range.last, max_codepoint);
        if (first > last) continue;
        for (segments) |segment| {
            const lo = @max(first, segment[0]);
            const hi = @min(last, segment[1]);
            if (lo <= hi) try emitRange(&builder, lo, hi);
            if (segment[1] >= last) break;
        }
    }
    const automaton = try builder.finish();
    builder.deinit();
    return automaton;
}

/// Whether `ranges` contains `codepoint` (linear scan for tests).
fn contains(ranges: []const model.Range, codepoint: u21) bool {
    for (ranges) |range| {
        if (codepoint >= range.first and codepoint <= range.last) return true;
    }
    return false;
}

fn expectMatches(ranges: []const model.Range) !void {
    var automaton = try build(std.testing.allocator, ranges);
    defer automaton.deinit(std.testing.allocator);
    var buffer: [4]u8 = undefined;
    var codepoint: u22 = 0;
    while (codepoint <= max_codepoint) : (codepoint += 1) {
        const value: u21 = @intCast(codepoint);
        const length = encode(value, &buffer);
        var state: u16 = 0;
        var accepted = false;
        for (buffer[0..length], 0..) |byte, index| {
            state = automaton.advance(state, byte);
            if (state == dead) break;
            if (state == accept) {
                accepted = index + 1 == length;
                break;
            }
        }
        if (accepted != contains(ranges, value)) {
            std.debug.print("mismatch at U+{X:0>4}: automaton={} set={}\n", .{ value, accepted, contains(ranges, value) });
            return error.TestUnexpectedResult;
        }
    }
}

test "utf8 automaton matches ASCII ranges" {
    try expectMatches(&[_]model.Range{
        .{ .first = '0', .last = '9' },
        .{ .first = 'A', .last = 'F' },
        .{ .first = 'a', .last = 'f' },
    });
}

test "utf8 automaton matches Han ranges" {
    try expectMatches(&[_]model.Range{
        .{ .first = 0x2E80, .last = 0x2E99 },
        .{ .first = 0x3005, .last = 0x3005 },
        .{ .first = 0x3400, .last = 0x4DBF },
        .{ .first = 0x4E00, .last = 0x9FFF },
        .{ .first = 0xF900, .last = 0xFA6D },
        .{ .first = 0x20000, .last = 0x2A6DF },
        .{ .first = 0x30000, .last = 0x3134A },
    });
}

test "utf8 automaton matches every segment boundary" {
    try expectMatches(&[_]model.Range{
        .{ .first = 0x0000, .last = 0x007F },
        .{ .first = 0x0080, .last = 0x07FF },
        .{ .first = 0x0800, .last = 0xD7FF },
        .{ .first = 0xE000, .last = 0xFFFF },
        .{ .first = 0x10000, .last = 0x3FFFF },
        .{ .first = 0x40000, .last = 0xFFFFF },
        .{ .first = 0x100000, .last = 0x10FFFF },
    });
}

test "utf8 automaton rejects invalid encodings" {
    var automaton = try build(std.testing.allocator, &[_]model.Range{.{ .first = 0x4E00, .last = 0x9FFF }});
    defer automaton.deinit(std.testing.allocator);
    const invalid = [_][]const u8{
        "\x80", // bare continuation
        "\xC0\xAF", // overlong
        "\xE0\x80\xAF", // overlong three-byte
        "\xED\xA0\x80", // surrogate
        "\xF4\x90\x80\x80", // above U+10FFFF
        "\xE4\xB8", // truncated
        "\xE4\x41", // bad continuation
    };
    for (invalid) |bytes| {
        var state: u16 = 0;
        for (bytes) |byte| {
            state = automaton.advance(state, byte);
            if (state == dead) break;
        }
        try std.testing.expect(state != accept);
    }
}
