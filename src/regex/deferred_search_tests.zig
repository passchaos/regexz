const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

fn compare(workspace: *regex.ReplaceWorkspace, reference: *regex.ReplaceWorkspace, input: []const u8, from: usize) !void {
    const expected = try reference.find(input, from);
    const found = try workspace.find(input, from);
    try std.testing.expectEqual(expected != null, found != null);
    if (expected) |match| {
        try std.testing.expectEqual(match.start, found.?.start);
        try std.testing.expectEqual(match.end, found.?.end);
        try std.testing.expectEqualSlices(usize, match.slots, found.?.slots);
    }
}

test "deferred search retains two allocations across ASCII searches" {
    var value = try regex.Regex.init(gpa, "\\p{L}+", .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    var workspace = try regex.ReplaceWorkspace.init(failing.allocator(), value.program, .{});
    defer workspace.deinit();
    for (0..10) |_| {
        const first = (try workspace.find("hello world", 0)).?;
        try std.testing.expectEqual(@as(usize, 0), first.start);
        try std.testing.expectEqual(@as(usize, 5), first.end);
        const second = (try workspace.find("hello world", 5)).?;
        try std.testing.expectEqual(@as(usize, 6), second.start);
        try std.testing.expectEqual(@as(usize, 11), second.end);
        try std.testing.expect((try workspace.find("1234", 0)) == null);
    }
    try std.testing.expectEqual(@as(usize, 2), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expect(workspace.utf8_run.?.table == null);
    try std.testing.expectEqual(@as(u8, 0), workspace.utf8_run.?.unicode_probes);
}

test "deferred search matches interpreter at every byte offset before and after preparation" {
    for ([_][]const u8{ "\\p{L}+", "\\p{Han}+", "\\p{Greek}+", "[ΣσςaA]+", "[^a]+" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.fast_kind = .none;
        reference.search_dfa_ineligible = true;
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        try std.testing.expect(workspace.utf8_run != null);
        const inputs = [_][]const u8{
            "",              "abc 123",
            "AΣ",
            "A猫Σé",
            "abc𐐀𝔄",
            "A\xe7A",
            "A\xed\xa0\x80猫",
            "猫Σé café",
            "𐐀𝔄 𠀀",
            "ΣσςaA",
            "Σ" ** 40,
            "\xff猫1",
            "猫\xe7\x8c",
            "\xe7A",         "\xe7\x8cA",
            "\xe7猫A",
            "\xf0猫",
            "\xe0\x80\x80A",
            "\xed\xa0\x80猫",
            "\xf4\x90\x80\x80Σ",
            "\x80猫",
        };
        for (0..2) |_| {
            for (inputs) |input| {
                for (0..input.len + 2) |from| try compare(&workspace, &reference, input, from);
            }
            try std.testing.expect(workspace.utf8_run.?.table != null);
            try std.testing.expect(workspace.fast_kind == .utf8_run_prepared);
        }
    }
}

test "deferred search miss warming enables prepared find and replacement" {
    var value = try regex.Regex.init(gpa, "\\p{Greek}+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (0..4) |_| try std.testing.expect((try workspace.find("猫", 0)) == null);
    try std.testing.expect(workspace.utf8_run.?.table != null);
    try std.testing.expect(workspace.fast_kind == .utf8_run_prepared);
    const found = (try workspace.find("猫Σ", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 5), found.end);
    const output = try workspace.replaceAll("猫Σ", "_");
    defer gpa.free(output);
    try std.testing.expectEqualStrings("猫_", output);
}

test "deferred search recovers the next candidate after malformed UTF-8 prefixes" {
    var value = try regex.Regex.init(gpa, "\\p{L}+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (0..2) |_| {
        for ([_][]const u8{ "\xe7A", "\xe7\x8cA", "\xf0A", "\xc3A", "\xe7猫" }) |input| {
            const found = try workspace.find(input, 0);
            try std.testing.expect(found != null);
            const length: usize = if (input[input.len - 1] == 'A') 1 else 3;
            try std.testing.expectEqual(input.len - length, found.?.start);
            try std.testing.expectEqual(input.len, found.?.end);
        }
        for (0..4) |_| _ = try workspace.find("猫", 0);
        try std.testing.expect(workspace.utf8_run.?.table != null);
    }
}

test "deferred search optional allocation failures retain scalar bounds and cleanup" {
    const Harness = struct {
        fn check(allocator: std.mem.Allocator, program: regex.Program, input: []const u8) !void {
            var workspace = try regex.ReplaceWorkspace.init(allocator, program, .{});
            defer workspace.deinit();
            for (0..6) |_| {
                const found = (try workspace.find(input, 0)).?;
                try std.testing.expectEqual(@as(usize, 0), found.start);
                try std.testing.expectEqual(input.len, found.end);
                try std.testing.expect((try workspace.find("123", 0)) == null);
            }
        }
    };
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "\\p{L}+", .input = "猫Σé" },
        .{ .pattern = "\\p{Han}+", .input = "猫" ** 32 },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var counted = std.testing.FailingAllocator.init(gpa, .{});
        try Harness.check(counted.allocator(), value.program, case.input);
        try std.testing.expect(counted.allocations > 2);
        for (0..counted.allocations) |fail_index| {
            var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            Harness.check(failing.allocator(), value.program, case.input) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                try std.testing.expect(fail_index < 2);
            };
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "deferred search rejects malformed probes and warms valid misses" {
    var value = try regex.Regex.init(gpa, "\\p{L}+", .{});
    defer value.deinit();
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    var workspace = try regex.ReplaceWorkspace.init(failing.allocator(), value.program, .{});
    defer workspace.deinit();
    for ([_][]const u8{ "\xff", "\xe0\x80\x80", "\xe7\x8c", "\x80", "\xed\xa0\x80", "\xf4\x90\x80\x80" }) |input| {
        for (0..4) |_| try std.testing.expect((try workspace.find(input, 0)) == null);
    }
    try std.testing.expectEqual(@as(u8, 0), workspace.utf8_run.?.unicode_probes);
    try std.testing.expect(!failing.has_induced_failure);
    for (0..4) |_| try std.testing.expect((try workspace.find("。", 0)) == null);
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(workspace.utf8_run.?.failed);
    try std.testing.expect(workspace.utf8_run.?.table == null);
    const found = (try workspace.find("。猫", 0)).?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 6), found.end);
}

test "deferred search replacement and iterator reuse preserve run boundaries" {
    var value = try regex.Regex.init(gpa, "\\p{L}+", .{});
    defer value.deinit();
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (0..3) |_| {
        const output = try workspace.replaceAll("猫 A Δ!", "_");
        defer gpa.free(output);
        try std.testing.expectEqualStrings("_ _ _!", output);
    }
    try std.testing.expect(workspace.utf8_run.?.table != null);
    var iterator = try value.findAll(gpa, "猫 A Δ!");
    defer iterator.deinit();
    for ([_]usize{ 0, 4, 6 }, [_]usize{ 3, 5, 8 }) |start, end| {
        const found = (try iterator.next()).?;
        try std.testing.expectEqual(start, found.start);
        try std.testing.expectEqual(end, found.end);
    }
    try std.testing.expect((try iterator.next()) == null);
}
