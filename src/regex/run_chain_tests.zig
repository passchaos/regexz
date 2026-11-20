//! Captured run-chain shape: `(setA*)(setB*)...(setZ*)` with disjoint sets.
const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

const RunMatch = struct {
    start: usize,
    end: usize,
    slots: []const usize,
};

fn nextRune(input: []const u8, offset: usize) usize {
    const length = std.unicode.utf8ByteSequenceLength(input[offset]) catch return offset + 1;
    if (length > input.len - offset) return offset + 1;
    _ = std.unicode.utf8Decode(input[offset..][0..length]) catch return offset + 1;
    return offset + length;
}

fn collect(allocator: std.mem.Allocator, workspace: *regex.ReplaceWorkspace, input: []const u8) ![]RunMatch {
    var matches: std.ArrayList(RunMatch) = .empty;
    errdefer {
        for (matches.items) |match| allocator.free(match.slots);
        matches.deinit(allocator);
    }
    var offset: usize = 0;
    while (offset <= input.len) {
        const match = (try workspace.find(input, offset)) orelse break;
        const slots = try allocator.dupe(usize, match.slots);
        try matches.append(allocator, .{ .start = match.start, .end = match.end, .slots = slots });
        if (match.end <= match.start) {
            if (match.start == input.len) break;
            offset = nextRune(input, match.start);
        } else {
            offset = match.end;
        }
    }
    return matches.toOwnedSlice(allocator);
}

fn freeMatches(allocator: std.mem.Allocator, matches: []RunMatch) void {
    for (matches) |match| allocator.free(match.slots);
    allocator.free(matches);
}

/// Compares the run-chain fast path with the same program pinned to the
/// interpreter. Pinning the reference keeps the oracle independent of future
/// shape detection.
fn compare(pattern: []const u8, input: []const u8) !void {
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .run_chain);
    var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer reference.deinit();
    reference.fast_kind = .none;
    reference.search_dfa_ineligible = true;
    const fast = try collect(gpa, &workspace, input);
    defer freeMatches(gpa, fast);
    const slow = try collect(gpa, &reference, input);
    defer freeMatches(gpa, slow);
    try std.testing.expectEqual(slow.len, fast.len);
    for (fast, slow) |left, right| {
        try std.testing.expectEqual(right.start, left.start);
        try std.testing.expectEqual(right.end, left.end);
        try std.testing.expectEqualSlices(usize, right.slots, left.slots);
    }
}

test "run chain is detected and reports run boundaries" {
    var value = try regex.Regex.init(gpa, "(\\p{Greek}*)(\\p{Nd}*)(\\p{Han}+)", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .run_chain);
    const match = (try workspace.find("Σσ١٢猫狗 x", 0)).?;
    try std.testing.expectEqual(@as(usize, 0), match.start);
    try std.testing.expectEqual(@as(usize, 14), match.end);
    // Greek 4 bytes, Nd 4 bytes, Han 6 bytes.
    try std.testing.expectEqual(@as(usize, 0), match.slots[2]);
    try std.testing.expectEqual(@as(usize, 4), match.slots[3]);
    try std.testing.expectEqual(@as(usize, 4), match.slots[4]);
    try std.testing.expectEqual(@as(usize, 8), match.slots[5]);
    try std.testing.expectEqual(@as(usize, 8), match.slots[6]);
    try std.testing.expectEqual(@as(usize, 14), match.slots[7]);
    try std.testing.expect((try workspace.find("Σσ١٢猫狗 x", 14)) == null);
}

test "run chain fills empty captures at the boundaries" {
    var value = try regex.Regex.init(gpa, "()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    try std.testing.expect(workspace.fast_kind == .run_chain);
    const input = "Σσ١٢猫狗 Σσ猫狗 猫狗 ";
    const first = (try workspace.find(input, 0)).?;
    try std.testing.expectEqual(@as(usize, 0), first.start);
    try std.testing.expectEqual(@as(usize, 14), first.end);
    try std.testing.expectEqual(@as(usize, 0), first.slots[2]);
    try std.testing.expectEqual(@as(usize, 0), first.slots[3]);
    try std.testing.expectEqual(@as(usize, 0), first.slots[4]);
    try std.testing.expectEqual(@as(usize, 4), first.slots[5]);
    try std.testing.expectEqual(@as(usize, 8), first.slots[7]);
    try std.testing.expectEqual(@as(usize, 14), first.slots[9]);
    try std.testing.expectEqual(@as(usize, 14), first.slots[10]);
    try std.testing.expectEqual(@as(usize, 14), first.slots[11]);
    const second = (try workspace.find(input, first.end)).?;
    try std.testing.expectEqual(@as(usize, 15), second.start);
    try std.testing.expectEqual(@as(usize, 25), second.end);
    // The trailing Han run without a Greek prefix cannot match.
    try std.testing.expect((try workspace.find(input, second.end)) == null);
}

test "run chain agrees with the interpreter on mixed subjects" {
    const inputs = [_][]const u8{
        "",
        "x",
        "Σσ١٢猫狗",
        "Σσ١٢猫狗 Σσ猫狗 猫狗 ",
        "Σ١٢猫狗 Σ猫狗 ١٢猫狗 猫狗",
        "١٢Σσ猫狗",
        "Σσ١٢猫",
        "猫狗Σσ١٢猫狗",
        "Σσ١٢猫狗Σσ١٢猫狗",
        "Σσ\xff١٢猫狗",
        "Σσ١٢\xe7猫狗",
        "aΣσ١٢猫狗b",
        "Σσ١٢猫狗\nΣ猫狗",
        "Σσ١٢猫狗 " ** 4,
    };
    for (inputs) |input| {
        try compare("(\\p{Greek}*)(\\p{Nd}*)(\\p{Han}+)", input);
        try compare("()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", input);
        try compare("([a-z]+)([0-9]*)([A-Z]+)", input);
        try compare("([A-Z]+)([0-9]+)([a-z]+)", input);
    }
}

test "run chain agrees with the interpreter on random run sequences" {
    const alphabet = [_][]const u8{ "a", "b", "0", "1", "A", "B", "Σ", "σ", "١", "猫", "狗", " ", "\n" };
    var random = std.Random.DefaultPrng.init(191);
    var buffer: [96]u8 = undefined;
    for (0..200) |_| {
        var length: usize = 0;
        const runes = random.random().uintLessThan(usize, 24);
        for (0..runes) |_| {
            const value = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            if (length + value.len > buffer.len) break;
            @memcpy(buffer[length..][0..value.len], value);
            length += value.len;
        }
        const input = buffer[0..length];
        try compare("(\\p{Greek}*)(\\p{Nd}*)(\\p{Han}+)", input);
        try compare("()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", input);
        try compare("([a-z]+)([0-9]*)([A-Z]+)", input);
        try compare("([A-Z]+)([0-9]+)([a-z]+)", input);
    }
}

test "lazy nullable run chains use the maximal run boundaries" {
    const patterns = [_][]const u8{
        "([a-z]+)([0-9]*?)([A-Z]+)",
        "(\\p{Greek}+)(\\p{Nd}*?)(\\p{Han}+)",
        "()(\\p{Greek}+)(\\p{Nd}*?)(\\p{Han}+)()",
    };
    const inputs = [_][]const u8{
        "",
        "hello123XYZ",
        "helloXYZ",
        "hello1XYZ hello12XYZ hello123xYZ",
        "Σσ١٢猫狗 Σσ猫狗 猫狗 ",
        "Σσ١٢猫狗 Σ١٢猫狗",
        "Σσ\xff١٢猫狗",
        "xΣσ١٢猫狗",
        "Σσ١٢猫狗\nΣσ١٢猫狗",
    };
    for (patterns) |pattern| {
        for (inputs) |input| try compare(pattern, input);
    }
    var random = std.Random.DefaultPrng.init(191);
    const alphabet = [_][]const u8{ "a", "b", "0", "1", "A", "B", "Σ", "σ", "١", "猫", "狗", " ", "\n" };
    var buffer: [96]u8 = undefined;
    for (0..200) |_| {
        var length: usize = 0;
        const runes = random.random().uintLessThan(usize, 24);
        for (0..runes) |_| {
            const value = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            if (length + value.len > buffer.len) break;
            @memcpy(buffer[length..][0..value.len], value);
            length += value.len;
        }
        try compare("([a-z]+)([0-9]*?)([A-Z]+)", buffer[0..length]);
        try compare("(\\p{Greek}+)(\\p{Nd}*?)(\\p{Han}+)", buffer[0..length]);
    }
}

test "nullable and trailing-nullable run chains agree with the interpreter" {
    const patterns = [_][]const u8{
        "(a*)(b*)",
        "(a+)(b*)",
        "(a*)(b+)",
        "(a*)(b+)(c*)",
        "(\\p{Greek}*)(\\p{Nd}*)",
        "(\\p{Greek}+)(\\p{Nd}*)",
    };
    const inputs = [_][]const u8{
        "",
        "a",
        "b",
        "aaabbb",
        "aaaa",
        "bbbb",
        "ab",
        "ba",
        "aaabbb aaaa bbbb ab ba ",
        "Σσ١٢ Σσ ١٢ ",
        "Σσ\xff١٢",
        "\xffΣσ١٢",
        "Σσ١٢ Σσ١٢\nΣσ١٢",
    };
    for (patterns) |pattern| {
        for (inputs) |input| try compare(pattern, input);
    }
    var random = std.Random.DefaultPrng.init(191);
    const alphabet = [_][]const u8{ "a", "b", "c", "Σ", "σ", "١", " ", "\n" };
    var buffer: [96]u8 = undefined;
    for (0..200) |_| {
        var length: usize = 0;
        const runes = random.random().uintLessThan(usize, 24);
        for (0..runes) |_| {
            const value = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            if (length + value.len > buffer.len) break;
            @memcpy(buffer[length..][0..value.len], value);
            length += value.len;
        }
        try compare("(a*)(b*)", buffer[0..length]);
        try compare("(a+)(b*)", buffer[0..length]);
        try compare("(a*)(b+)(c*)", buffer[0..length]);
        try compare("(\\p{Greek}*)(\\p{Nd}*)", buffer[0..length]);
        try compare("(\\p{Greek}+)(\\p{Nd}*)", buffer[0..length]);
    }
}

test "overlapping run chains use the forward scan only when complete" {
    const accepted = [_][]const u8{
        "([a-z]+)([a-z0-9]*)([A-Z]+)",
        "(\\p{Greek}+)([\\p{Greek}\\p{Nd}]*)(\\p{Han}+)",
        "(a+)(a*)(b+)",
        "([a-z]+)([0-9]*)([A-Z]+)",
    };
    const rejected = [_][]const u8{
        "([a-z]+)([a-z]*)([a-z]+)",
        "([a-z]+)([a-z]+)([A-Z]+)",
        "(a*)(b*)",
    };
    for (accepted) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        try std.testing.expect(workspace.fast_kind == .run_chain);
    }
    for (rejected) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        // `(a*)(b*)` is a valid nullable chain, the other two need
        // backtracking and must stay on the general engine.
        if (std.mem.eql(u8, pattern, "(a*)(b*)")) {
            try std.testing.expect(workspace.fast_kind == .run_chain);
        } else {
            try std.testing.expect(workspace.fast_kind != .run_chain);
        }
    }
    const inputs = [_][]const u8{
        "",
        "hello123XYZ",
        "helloXYZ",
        "hello1XYZ hello12XYZ hello123xYZ",
        "123ABC",
        "aaa111ZZ",
        "a1A b2B",
        "Σσ١٢猫狗 Σσ猫狗 猫狗 ",
        "Σ١٢猫狗",
        "Σσ\xff١٢猫狗",
    };
    for (inputs) |input| {
        try compare("([a-z]+)([a-z0-9]*)([A-Z]+)", input);
        try compare("(\\p{Greek}+)([\\p{Greek}\\p{Nd}]*)(\\p{Han}+)", input);
        try compare("(a+)(a*)(b+)", input);
    }
    var random = std.Random.DefaultPrng.init(191);
    const alphabet = [_][]const u8{ "a", "b", "0", "1", "A", "B", "Σ", "σ", "١", "猫", "狗", " ", "\n" };
    var buffer: [96]u8 = undefined;
    for (0..200) |_| {
        var length: usize = 0;
        const runes = random.random().uintLessThan(usize, 24);
        for (0..runes) |_| {
            const value = alphabet[random.random().uintLessThan(usize, alphabet.len)];
            if (length + value.len > buffer.len) break;
            @memcpy(buffer[length..][0..value.len], value);
            length += value.len;
        }
        try compare("([a-z]+)([a-z0-9]*)([A-Z]+)", buffer[0..length]);
        try compare("(a+)(a*)(b+)", buffer[0..length]);
    }
}
