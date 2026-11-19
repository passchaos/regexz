const std = @import("std");
const cache = @import("rune_cache.zig");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

test "rune cache promotes after collisions and preserves valid entries" {
    var entries = try gpa.alloc(cache.Entry, cache.initial_size);
    defer gpa.free(entries);
    @memset(entries, .{});
    var collisions: u8 = 0;
    for (0..cache.initial_size) |key| cache.put(gpa, &entries, &collisions, key, @intCast(key + 1));
    try std.testing.expectEqual(cache.initial_size, entries.len);
    // Each insertion overwrites an occupied small-cache slot. The final one
    // promotes and rehashes the surviving entries into the full cache.
    for (0..64) |index| cache.put(gpa, &entries, &collisions, index + 256, @intCast(index + 1000));
    try std.testing.expectEqual(cache.maximum_size, entries.len);
    const preserved = entries[cache.slot(200, entries.len)];
    try std.testing.expectEqual(@as(u64, 200), preserved.key);
    try std.testing.expectEqual(@as(u32, 201), preserved.next);
    const last = entries[cache.slot(319, entries.len)];
    try std.testing.expectEqual(@as(u64, 319), last.key);
    try std.testing.expectEqual(@as(u32, 1063), last.next);
    // A dead-transition sentinel must be cached unchanged as well.
    cache.put(gpa, &entries, &collisions, 1234, std.math.maxInt(u32));
    try std.testing.expectEqual(std.math.maxInt(u32), entries[cache.slot(1234, entries.len)].next);
}

test "rune cache failed promotion retains small storage and usable entries" {
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    {
        const allocator = failing.allocator();
        var entries = try allocator.alloc(cache.Entry, cache.initial_size);
        defer allocator.free(entries);
        @memset(entries, .{});
        var collisions: u8 = 0;
        for (0..128) |index| cache.put(allocator, &entries, &collisions, (index & 1) << 8, @intCast(index));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(cache.initial_size, entries.len);
        const last = entries[cache.slot(256, entries.len)];
        try std.testing.expectEqual(@as(u64, 256), last.key);
        try std.testing.expectEqual(@as(u32, 127), last.next);
    }
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "Unicode DFA small cache grows without changing matches" {
    var value = try regex.Regex.init(gpa, "(?:\\p{Han}|[0-9])+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(gpa, value.program);
    defer workspace.deinit();
    for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&value.program, "一0"));
    try std.testing.expectEqual(cache.initial_size, workspace.dfa.?.unicode_cache.len);
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "一伀" ** 128));
    try std.testing.expectEqual(cache.maximum_size, workspace.dfa.?.unicode_cache.len);
    try std.testing.expect(!workspace.dfa_failed);
    try std.testing.expect(workspace.matchesBorrowed(&value.program, "一伀0"));
    try std.testing.expect(!workspace.matchesBorrowed(&value.program, "一A"));
    try std.testing.expect(!workspace.matchesBorrowed(&value.program, "一\xff"));
    try std.testing.expect(!workspace.matchesBorrowed(&value.program, "一\xe4\xb8"));
}

test "Unicode DFA allocation failures during promotion retain matching fallback" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, program: regex.Program) !void {
            var workspace = try regex.Workspace.init(allocator, program);
            defer workspace.deinit();
            for (0..3) |_| try std.testing.expect(workspace.matchesBorrowed(&program, "一0"));
            try std.testing.expect(workspace.matchesBorrowed(&program, "一伀" ** 128));
            try std.testing.expect(!workspace.matchesBorrowed(&program, "一A"));
            try std.testing.expect(workspace.matchesBorrowed(&program, "伀0一"));
        }
    };
    var value = try regex.Regex.init(gpa, "(?:\\p{Han}|[0-9])+", .{});
    defer value.deinit();
    var counted = std.testing.FailingAllocator.init(gpa, .{});
    try Harness.run(counted.allocator(), value.program);
    for (0..counted.allocations) |fail_index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        Harness.run(failing.allocator(), value.program) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(failing.has_induced_failure);
        };
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "Unicode DFA cache agrees with NFA across varied runes and state keys" {
    var random = std.Random.DefaultPrng.init(191);
    for ([_][]const u8{
        "(?:\\p{Han}|\\p{Greek}|[0-9])+",
        "(?:\\p{Han}|[0-9])+\\p{Greek}?",
        "(?:\\p{Han}[0-9]?|\\p{Greek})+",
    }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var cached = try regex.Workspace.init(gpa, value.program);
        defer cached.deinit();
        var reference = try regex.Workspace.init(gpa, value.program);
        defer reference.deinit();
        // Trigger the lazy construction before the randomized subjects.
        for (0..3) |_| _ = cached.matchesBorrowed(&value.program, "一1Δ");
        var input: std.ArrayList(u8) = .empty;
        defer input.deinit(gpa);
        for (0..32) |round| {
            input.clearRetainingCapacity();
            for (0..128) |_| {
                const rune: u21 = switch (random.random().uintLessThan(u8, 3)) {
                    0 => @intCast(0x4e00 + random.random().uintLessThan(u32, 4096)),
                    1 => @intCast('0' + random.random().uintLessThan(u8, 10)),
                    else => 0x394,
                };
                var bytes: [4]u8 = undefined;
                const length = try std.unicode.utf8Encode(rune, &bytes);
                try input.appendSlice(gpa, bytes[0..length]);
            }
            if (round & 1 != 0) try input.append(gpa, 'A');
            try std.testing.expectEqual(reference.matchesNfa(value.program, input.items), cached.matchesBorrowed(&value.program, input.items));
        }
        try std.testing.expect(!cached.dfa_failed);
    }
}
