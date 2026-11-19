const std = @import("std");
const regex = @import("../root.zig");
const prefilter = @import("prefilter.zig");

fn naive(input: []const u8, from: usize, literals: []const []const u8) ?usize {
    if (from > input.len) return null;
    var best: ?usize = null;
    for (literals) |literal| {
        if (std.mem.indexOfPos(u8, input, from, literal)) |found| {
            if (best == null or found < best.?) best = found;
        }
    }
    return best;
}

fn compare(input: []const u8, literals: []const []const u8) !void {
    const filter = prefilter.MultiFilter.init(literals).?;
    for (0..input.len + 2) |from| {
        try std.testing.expectEqual(naive(input, from, literals), filter.indexOf(input, from));
    }
}

test "MultiFilter candidates agree with exact scans across block boundaries" {
    const sets = [_][]const []const u8{
        &.{ "sunday", "saturday", "september" },
        &.{ "sa", "saturday", "sample", "september" },
        &.{ "ss0", "ss1", "ss2", "ss3", "ss4", "ss5", "ss6", "ss7" },
        &.{ "é", "ê", "ü", "ÿ" },
    };
    for (sets) |literals| {
        try compare("seed suit sail see xx september saturday sunday", literals);
        try compare("s" ** 64, literals);
        try compare("\xffé ê ü\x80 ÿ", literals);
        for (literals) |literal| {
            for (0..34) |position| {
                var input = [_]u8{'x'} ** 64;
                @memcpy(input[position..][0..literal.len], literal);
                try compare(&input, literals);
            }
        }
        var random = std.Random.DefaultPrng.init(191);
        var input: [64]u8 = undefined;
        const alphabet = "sauep012x\xc3\xa9\xff";
        for (0..65) |length| {
            for (input[0..length]) |*byte| byte.* = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            try compare(input[0..length], literals);
        }
        const filter = prefilter.MultiFilter.init(literals).?;
        try std.testing.expect(filter.indexOf("abc", std.math.maxInt(usize)) == null);
    }
}

test "MultiFilter rejects empty and unsupported literal sets" {
    try std.testing.expect(prefilter.MultiFilter.init(&.{}) == null);
    try std.testing.expect(prefilter.MultiFilter.init(&.{""}) == null);
    try std.testing.expect(prefilter.MultiFilter.init(&.{ "", "sunday" }) == null);
    try std.testing.expect(prefilter.MultiFilter.init(&.{ "a", "ab" }) == null);
    try std.testing.expect(prefilter.MultiFilter.init(&.{ "sunday", "monday" }) == null);
    const many = [_][]const u8{"ss"} ** 17;
    try std.testing.expect(prefilter.MultiFilter.init(&many) == null);
}

test "folded literal search honors the requested start offset" {
    const gpa = std.testing.allocator;
    var value = try regex.Regex.init(gpa, "(?i)strasse", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (1..8) |from| try std.testing.expect((try workspace.find("STRASSE", from)) == null);
    const input = "STRASSE xx strasse";
    for (1..12) |from| try std.testing.expectEqual(@as(usize, 11), (try workspace.find(input, from)).?.start);
    for (12..input.len + 1) |from| try std.testing.expect((try workspace.find(input, from)) == null);
    const unicode = "xx ſTRASSE";
    const found = (try workspace.find(unicode, 0)).?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    for (4..unicode.len + 1) |from| try std.testing.expect((try workspace.find(unicode, from)) == null);
}

test "FoldFilter candidate bounds stay within the requested search range" {
    const filter = prefilter.FoldFilter.init("strasse").?;
    for ([_][]const u8{ "", "s", "STRASSE", "xx ſTRASSE", "xx STRASSE yy" }) |input| {
        for (0..input.len + 2) |from| {
            if (filter.indexOf(input, from)) |candidate| try std.testing.expect(candidate >= from);
        }
    }
    try std.testing.expect(filter.indexOf("abc", std.math.maxInt(usize)) == null);
}
