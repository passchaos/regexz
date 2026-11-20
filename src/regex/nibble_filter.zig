//! Two-byte candidate filter using eight buckets and four nibble tables.
//! Bucket collisions are conservative; callers still verify exact prefixes.
const std = @import("std");
const builtin = @import("builtin");
const Vec = @Vector(16, u8);

pub const supported = builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon);

pub const Filter = struct {
    first_low: Vec,
    first_high: Vec,
    second_low: Vec,
    second_high: Vec,

    pub fn init(literals: []const []const u8) ?Filter {
        if (literals.len < 9 or literals.len > 32) return null;
        for (literals) |literal| {
            if (literal.len < 2) return null;
        }
        const buckets = assignBuckets(literals);
        var tables = [_][16]u8{[_]u8{0} ** 16} ** 4;
        for (literals, 0..) |literal, index| {
            const bit = @as(u8, 1) << buckets[index];
            tables[0][literal[0] & 15] |= bit;
            tables[1][literal[0] >> 4] |= bit;
            tables[2][literal[1] & 15] |= bit;
            tables[3][literal[1] >> 4] |= bit;
        }
        return .{ .first_low = tables[0], .first_high = tables[1], .second_low = tables[2], .second_high = tables[3] };
    }

    pub fn candidates(self: *const Filter, first: Vec, second: Vec) @Vector(16, bool) {
        const low: Vec = @splat(15);
        const shift: @Vector(16, u3) = @splat(4);
        const values = lookup(self.first_low, first & low) & lookup(self.first_high, first >> shift) &
            lookup(self.second_low, second & low) & lookup(self.second_high, second >> shift);
        return values != @as(Vec, @splat(0));
    }
};

/// Relative English text byte frequencies (per mille), used only to rank
/// bucket assignments. Uppercase folds to lowercase; bytes outside the table
/// keep a small default so digit and punctuation literals still participate.
const byte_weights: [256]u16 = blk: {
    var table = [_]u16{6} ** 256;
    const order = " etaoinshrdlucmfwypvbgkqjxz";
    const values = [_]u16{ 180, 127, 91, 82, 75, 70, 67, 63, 61, 60, 43, 40, 28, 28, 24, 24, 22, 20, 20, 19, 15, 10, 8, 2, 2, 1, 1 };
    for (order, values) |byte, value| table[byte] = value;
    for ('A'..'Z' + 1) |byte| table[byte] = table[byte + 32];
    break :blk table;
};

/// Bucket state for the assignment search. Distinct-byte counts decide when
/// a bucket's weighted byte sums change.
const Buckets = struct {
    first_group: [32]u8 = undefined,
    second_group: [32]u8 = undefined,
    first_counts: [8][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 8,
    second_counts: [8][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 8,
    first_sum: [8]u64 = [_]u64{0} ** 8,
    second_sum: [8]u64 = [_]u64{0} ** 8,

    fn add(self: *Buckets, index: usize, bucket: u3, first_weight: []const u32, second_weight: []const u32) void {
        const first = self.first_group[index];
        if (self.first_counts[bucket][first] == 0) self.first_sum[bucket] += first_weight[first];
        self.first_counts[bucket][first] += 1;
        const second = self.second_group[index];
        if (self.second_counts[bucket][second] == 0) self.second_sum[bucket] += second_weight[second];
        self.second_counts[bucket][second] += 1;
    }

    fn remove(self: *Buckets, index: usize, bucket: u3, first_weight: []const u32, second_weight: []const u32) void {
        const first = self.first_group[index];
        self.first_counts[bucket][first] -= 1;
        if (self.first_counts[bucket][first] == 0) self.first_sum[bucket] -= first_weight[first];
        const second = self.second_group[index];
        self.second_counts[bucket][second] -= 1;
        if (self.second_counts[bucket][second] == 0) self.second_sum[bucket] -= second_weight[second];
    }

    /// Cost change from moving `index` out of `from` and into `to`. The
    /// total expected false-positive weight is the sum over buckets of
    /// distinct first-byte weight times distinct second-byte weight.
    fn moveDelta(self: *const Buckets, index: usize, from: u3, to: u3, first_weight: []const u32, second_weight: []const u32) i64 {
        const first = self.first_group[index];
        const second = self.second_group[index];
        const first_out: u64 = if (self.first_counts[from][first] == 1) first_weight[first] else 0;
        const second_out: u64 = if (self.second_counts[from][second] == 1) second_weight[second] else 0;
        const first_in: u64 = if (self.first_counts[to][first] == 0) first_weight[first] else 0;
        const second_in: u64 = if (self.second_counts[to][second] == 0) second_weight[second] else 0;
        const before: i64 = @intCast(self.first_sum[from] * self.second_sum[from] + self.first_sum[to] * self.second_sum[to]);
        const after: i64 = @intCast((self.first_sum[from] - first_out) * (self.second_sum[from] - second_out) +
            (self.first_sum[to] + first_in) * (self.second_sum[to] + second_in));
        return after - before;
    }
};

fn groupOf(bytes: *[32]u8, weights: *[32]u32, count: *usize, byte: u8) u8 {
    for (bytes[0..count.*], 0..) |existing, index| {
        if (existing == byte) return @intCast(index);
    }
    const index = count.*;
    bytes[index] = byte;
    weights[index] = byte_weights[byte];
    count.* += 1;
    return @intCast(index);
}

/// Choose bucket bits that reduce nibble-filter false positives.
///
/// A lane is a candidate when some literal's first byte and some literal's
/// second byte share a bucket. Under independent byte frequencies the
/// expected false-positive weight is
/// `sum_bucket (distinct first-byte weight) * (distinct second-byte weight)`
/// minus the true literal pairs, which do not depend on the assignment.
/// Place literals greedily by weight and then hill-climb single moves until
/// the cost stops improving. The search is deterministic and runs once per
/// filter construction.
fn assignBuckets(literals: []const []const u8) [32]u3 {
    var first_bytes: [32]u8 = undefined;
    var second_bytes: [32]u8 = undefined;
    var first_weight: [32]u32 = undefined;
    var second_weight: [32]u32 = undefined;
    var first_groups: usize = 0;
    var second_groups: usize = 0;
    var state = Buckets{};
    for (literals, 0..) |literal, index| {
        state.first_group[index] = groupOf(&first_bytes, &first_weight, &first_groups, literal[0]);
        state.second_group[index] = groupOf(&second_bytes, &second_weight, &second_groups, literal[1]);
    }

    var order: [32]u8 = undefined;
    for (0..literals.len) |index| order[index] = @intCast(index);
    // Heaviest first; insertion sort keeps the index order on ties, so the
    // assignment is deterministic.
    var sorted: usize = 1;
    while (sorted < literals.len) : (sorted += 1) {
        const value = order[sorted];
        const weight = first_weight[state.first_group[value]] + second_weight[state.second_group[value]];
        var position = sorted;
        while (position > 0) : (position -= 1) {
            const previous = order[position - 1];
            const previous_weight = first_weight[state.first_group[previous]] + second_weight[state.second_group[previous]];
            if (previous_weight >= weight) break;
            order[position] = previous;
        }
        order[position] = value;
    }

    var buckets: [32]u3 = [_]u3{0} ** 32;
    for (order[0..literals.len]) |index| {
        const first = state.first_group[index];
        const second = state.second_group[index];
        var best_bucket: u3 = 0;
        var best_delta: u64 = std.math.maxInt(u64);
        for (0..8) |bucket| {
            const first_in: u64 = if (state.first_counts[bucket][first] == 0) first_weight[first] else 0;
            const second_in: u64 = if (state.second_counts[bucket][second] == 0) second_weight[second] else 0;
            const delta = (state.first_sum[bucket] + first_in) * (state.second_sum[bucket] + second_in) -
                state.first_sum[bucket] * state.second_sum[bucket];
            if (delta < best_delta) {
                best_delta = delta;
                best_bucket = @intCast(bucket);
            }
        }
        buckets[index] = best_bucket;
        state.add(index, best_bucket, &first_weight, &second_weight);
    }

    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        var improved = false;
        for (0..literals.len) |index| {
            const current = buckets[index];
            var best_bucket = current;
            var best_delta: i64 = 0;
            for (0..8) |bucket| {
                const candidate: u3 = @intCast(bucket);
                if (candidate == current) continue;
                const delta = state.moveDelta(index, current, candidate, &first_weight, &second_weight);
                if (delta < best_delta) {
                    best_delta = delta;
                    best_bucket = candidate;
                }
            }
            if (best_bucket != current) {
                state.remove(index, current, &first_weight, &second_weight);
                state.add(index, best_bucket, &first_weight, &second_weight);
                buckets[index] = best_bucket;
                improved = true;
            }
        }
        if (!improved) break;
    }
    return buckets;
}

fn lookup(table: Vec, indices: Vec) Vec {
    if (supported) {
        return asm ("tbl %[result].16b, {%[table].16b}, %[indices].16b"
            : [result] "=x" (-> Vec),
            : [table] "x" (table),
              [indices] "x" (indices),
        );
    }
    const bytes: [16]u8 = table;
    const offsets: [16]u8 = indices;
    var result: [16]u8 = undefined;
    for (0..16) |index| result[index] = bytes[offsets[index]];
    return result;
}
