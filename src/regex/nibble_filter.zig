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
        var tables = [_][16]u8{[_]u8{0} ** 16} ** 4;
        for (literals, 0..) |literal, index| {
            if (literal.len < 2) return null;
            const bit = @as(u8, 1) << @as(u3, @intCast(index & 7));
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
