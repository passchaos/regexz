const std = @import("std");
const prefilter = @import("prefilter.zig");
const nibble = @import("nibble_filter.zig");

const words = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india", "juliet", "kilo", "lima", "mike", "november", "oscar", "papa", "quebec", "romeo", "sierra", "tango", "uniform", "victor", "whiskey", "xray" };

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
    const filter = prefilter.PairSet.init(literals).?;
    for (0..input.len + 2) |from| try std.testing.expectEqual(naive(input, from, literals), filter.indexOfAny(input, from));
}

test "nibble candidates retain every complete prefix at every lane" {
    const filter = nibble.Filter.init(&words).?;
    for (words) |word| {
        for (0..16) |lane| {
            var a = [_]u8{'x'} ** 16;
            var b = [_]u8{'x'} ** 16;
            a[lane] = word[0];
            b[lane] = word[1];
            const mask = filter.candidates(a, b);
            const flags: [16]bool = mask;
            try std.testing.expect(flags[lane]);
        }
    }
}

test "nibble PairSet agrees with exact scans across all byte offsets" {
    try compare("", &words);
    try compare("x" ** 64, &words);
    try compare("a alphq bravq hote whiskey xray", &words);
    for (words) |word| {
        for (0..34) |position| {
            var input = [_]u8{'x'} ** 64;
            @memcpy(input[position..][0..word.len], word);
            try compare(&input, &words);
        }
    }
    var random = std.Random.DefaultPrng.init(191);
    var input: [64]u8 = undefined;
    for (0..65) |length| {
        random.random().bytes(input[0..length]);
        try compare(input[0..length], &words);
    }
    const dense = [_][]const u8{ "aa0", "ba0", "ca0", "da0", "ea0", "fa0", "ga0", "ha0", "ia0" };
    try compare("a" ** 64, &dense);
    const unicode = [_][]const u8{ "é", "ê", "ë", "è", "í", "ì", "î", "ï", "ü" };
    try compare("\xffé ê ü\x80 ë ì ï", &unicode);
    const filter = prefilter.PairSet.init(&words).?;
    try std.testing.expect(filter.indexOfAny("abc", std.math.maxInt(usize)) == null);
}
