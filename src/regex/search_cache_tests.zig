const std = @import("std");
const regex = @import("../root.zig");
const search = @import("search_dfa.zig");
const cache = @import("search_cache.zig");
const gpa = std.testing.allocator;

test "search DFA defers both Unicode caches until non-ASCII input" {
    var value = try regex.Regex.init(gpa, "\\p{L}+(?!\\p{L})", .{});
    defer value.deinit();
    var workspace = (try search.Workspace.init(gpa, value.program)).?;
    defer workspace.deinit();
    try std.testing.expectEqual(@as(usize, 0), workspace.unicode_cache.len);
    try std.testing.expect(workspace.state_cache.items.ptr == cache.emptyFront().items.ptr);
    const ascii = (try workspace.find("hello1", 0)).?;
    try std.testing.expectEqual(@as(usize, 5), ascii.end);
    try std.testing.expect(workspace.states.items.len > 1);
    try std.testing.expectEqual(@as(usize, 0), workspace.unicode_cache.len);
    try std.testing.expect(workspace.state_cache.items.ptr == cache.emptyFront().items.ptr);
    const unicode = (try workspace.find("Ελληνικά1", 0)).?;
    try std.testing.expectEqual("Ελληνικά".len, unicode.end);
    try std.testing.expectEqual(cache.global_slots, workspace.unicode_cache.len);
    try std.testing.expectEqual(workspace.states.items.len * cache.front_slots, workspace.state_cache.items.len);
    const again = (try workspace.find("hello1", 0)).?;
    try std.testing.expectEqual(ascii.start, again.start);
    try std.testing.expectEqual(ascii.end, again.end);
}

test "search DFA lazy caches retain Unicode lookahead bounds at every offset" {
    for ([_][]const u8{
        "[a-z]+(?=\\p{Han})", "[a-z]+(?!\\p{Han})", "\\p{L}+(?!\\p{L})", "(?!\\p{Han})",
    }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var workspace = (try search.Workspace.init(gpa, value.program)).?;
        defer workspace.deinit();
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.search_dfa_ineligible = true;
        for ([_][]const u8{ "hello猫 x", "猫hello", "hello1", "é猫1", "", "hello\xff", "hello\xe7\x8c", "hello\xe0\x80\x80" }) |input| {
            for (0..input.len + 1) |from| {
                const expected = try reference.find(input, from);
                const actual = try workspace.find(input, from);
                try std.testing.expectEqual(expected != null, actual != null);
                if (expected) |match| {
                    try std.testing.expectEqual(match.start, actual.?.start);
                    try std.testing.expectEqual(match.end, actual.?.end);
                }
            }
        }
    }
}

test "search cache allocation failure releases the global buffer" {
    for (0..2) |fail_index| {
        var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        {
            var front = cache.emptyFront();
            var global: []cache.Entry = &.{};
            defer cache.deinit(failing.allocator(), global, &front);
            try std.testing.expectError(error.OutOfMemory, cache.init(failing.allocator(), &global, &front, 3));
            try std.testing.expect(front.items.ptr == cache.emptyFront().items.ptr);
            try std.testing.expectEqual(@as(usize, 0), global.len);
        }
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "search DFA lazy cache failures preserve API fallback and cleanup" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, program: regex.Program) !void {
            var workspace = try regex.ReplaceWorkspace.init(allocator, program, .{});
            defer workspace.deinit();
            for ([_][]const u8{ "hello1", "hello猫", "Ελληνικά1", "hello1" }) |input| {
                const match = (try workspace.find(input, 0)).?;
                try std.testing.expectEqual(@as(usize, 0), match.start);
                const expected: usize = if (std.mem.eql(u8, input, "hello猫")) input.len else input.len - 1;
                try std.testing.expectEqual(expected, match.end);
            }
        }
    };
    var value = try regex.Regex.init(gpa, "\\p{L}+(?!\\p{L})", .{});
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

test "search DFA late Unicode caches cover tokenizer state growth" {
    const pattern = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
    var value = try regex.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = (try search.Workspace.init(gpa, value.program)).?;
    defer workspace.deinit();
    var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer reference.deinit();
    reference.search_dfa_ineligible = true;
    for ([_][]const u8{ "hello world! 123", "hello 猫Σé!", "'s 'ſ hello 猫 \n" }, 0..) |input, case| {
        var offset: usize = 0;
        while (offset <= input.len) {
            const expected = try reference.find(input, offset);
            const actual = try workspace.find(input, offset);
            try std.testing.expectEqual(expected != null, actual != null);
            const match = expected orelse break;
            try std.testing.expectEqual(match.start, actual.?.start);
            try std.testing.expectEqual(match.end, actual.?.end);
            try std.testing.expect(match.end > offset);
            offset = match.end;
        }
        if (case == 0) {
            try std.testing.expectEqual(@as(usize, 0), workspace.unicode_cache.len);
            try std.testing.expect(workspace.state_cache.items.ptr == cache.emptyFront().items.ptr);
        } else {
            try std.testing.expectEqual(workspace.states.items.len * cache.front_slots, workspace.state_cache.items.len);
        }
    }
}

test "search DFA replaces borrowed front rows independently per workspace" {
    var value = try regex.Regex.init(gpa, "\\p{L}+(?!\\p{L})", .{});
    defer value.deinit();
    var first = (try search.Workspace.init(gpa, value.program)).?;
    defer first.deinit();
    var second = (try search.Workspace.init(gpa, value.program)).?;
    defer second.deinit();
    try std.testing.expect(first.state_cache.items.ptr == second.state_cache.items.ptr);
    const greek = (try first.find("Σ1", 0)).?;
    try std.testing.expectEqual("Σ".len, greek.end);
    try std.testing.expect(first.state_cache.items.ptr != second.state_cache.items.ptr);
    try std.testing.expectEqual(@as(usize, 0), second.unicode_cache.len);
    const han = (try second.find("猫1", 0)).?;
    try std.testing.expectEqual("猫".len, han.end);
    try std.testing.expect(first.state_cache.items.ptr != second.state_cache.items.ptr);
    try std.testing.expect((try first.find("Σ1", 0)).?.end == greek.end);
}
