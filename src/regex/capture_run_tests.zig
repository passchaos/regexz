const std = @import("std");
const regex = @import("../root.zig");
const Plan = @import("capture_run.zig").Plan;
const gpa = std.testing.allocator;

test "capture run detector accepts fixed saves and rejects competing paths" {
    for ([_][]const u8{ "(a+)", "(\\w+)", "((\\d+))", "()(\\w+)()", "(?<word>[a-z]+)", "(?i)(a+)", "([\\x00-\\x7f]+)", "(猫+)", "(\\p{L}+)" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        try std.testing.expect(Plan.init(value.program) != null);
    }
    for ([_][]const u8{ "a+", "(a*)", "(a+?)", "(a)+", "(a+)(b+)", "(a+b*)", "(a|b)+", "^(a+)", "(a+)(?=b)", "(a+)\\1" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        try std.testing.expect(Plan.init(value.program) == null);
    }
}

fn compare(input: []const u8, from: usize, direct: *regex.ReplaceWorkspace, reference: *regex.ReplaceWorkspace) !void {
    const actual = direct.find(input, from) catch |err| {
        try std.testing.expectError(err, reference.find(input, from));
        return;
    };
    const expected = try reference.find(input, from);
    try std.testing.expectEqual(expected != null, actual != null);
    if (actual) |match| {
        try std.testing.expectEqual(expected.?.start, match.start);
        try std.testing.expectEqual(expected.?.end, match.end);
        try std.testing.expectEqualSlices(usize, expected.?.slots, match.slots);
    }
}

test "capture run search agrees with general capture search at every offset" {
    const patterns = [_][]const u8{ "(a+)", "(\\w+)", "((\\d+))", "()(\\w+)()", "(?<word>[a-z]+)", "(?i)(a+)" };
    const inputs = [_][]const u8{ "", "a", "aab 123 AA_xyz", "猫 abc 猫 123", "\xffab\x80c", "#" ** 40 ++ "abc 123 aaa" };
    for (patterns) |pattern| {
        for ([_]bool{ false, true }) |reset| {
            const limits = regex.Limits{ .capture_reset = reset };
            var value = try regex.Regex.init(gpa, pattern, limits);
            defer value.deinit();
            var direct = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
            defer direct.deinit();
            var reference = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
            defer reference.deinit();
            reference.fast_kind = .none;
            for (inputs) |input| {
                for (0..input.len + 2) |from| try compare(input, from, &direct, &reference);
            }
        }
    }
}

test "capture run preserves strict budgets and linear fallback captures" {
    for ([_][]const u8{ "(a+)", "((a+))", "()(a+)()" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        for ([_]bool{ false, true }) |fallback| {
            for ([_]usize{ 0, 1, 6, 8, 25, 27, 100 }) |budget| {
                const limits = regex.Limits{ .max_execution_steps = budget, .linear_fallback = fallback };
                var direct = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
                defer direct.deinit();
                var reference = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
                defer reference.deinit();
                reference.fast_kind = .none;
                for ([_][]const u8{ "", "b", "a", "a" ** 20, "#" ** 40 ++ "aaa" }) |input| {
                    try compare(input, 0, &direct, &reference);
                    if (!fallback) try std.testing.expect(direct.steps <= budget + 1);
                }
            }
        }
    }
}

test "capture run needs no allocations after workspace setup" {
    var value = try regex.Regex.init(gpa, "()(\\w+)()", .{});
    defer value.deinit();
    var counter = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    var workspace = try regex.ReplaceWorkspace.init(counter.allocator(), value.program, .{ .max_execution_steps = 1 });
    defer workspace.deinit();
    const input = "#" ** 40 ++ "abc 123";
    const match = (try workspace.find(input, 0)).?;
    try std.testing.expectEqualStrings("", match.group(input, 1).?);
    try std.testing.expectEqualStrings("abc", match.group(input, 2).?);
    try std.testing.expectEqualStrings("", match.group(input, 3).?);
    const next = (try workspace.find(input, match.end)).?;
    try std.testing.expectEqualStrings("123", next.group(input, 2).?);
    try std.testing.expect(!counter.has_induced_failure);
}

test "capture run respects the Pike capture-slot bound" {
    var supported = try regex.Regex.init(gpa, "()" ** 126 ++ "(a+)", .{});
    defer supported.deinit();
    var direct = try regex.ReplaceWorkspace.init(gpa, supported.program, .{ .max_execution_steps = 1 });
    defer direct.deinit();
    try std.testing.expect(Plan.init(supported.program) != null);
    const match = (try direct.find("aaa", 0)).?;
    try std.testing.expectEqualStrings("", match.group("aaa", 126).?);
    try std.testing.expectEqualStrings("aaa", match.group("aaa", 127).?);

    var unsupported = try regex.Regex.init(gpa, "()" ** 127 ++ "(a+)", .{});
    defer unsupported.deinit();
    try std.testing.expect(Plan.init(unsupported.program) == null);
    var bounded = try regex.ReplaceWorkspace.init(gpa, unsupported.program, .{ .max_execution_steps = 1 });
    defer bounded.deinit();
    try std.testing.expectError(error.RegexLimitExceeded, bounded.find("aaa", 0));
}

test "capture run reconstructs captures from serialized programs" {
    var run = try regex.Regex.init(gpa, "()([abc]+)()", .{});
    defer run.deinit();
    const bytes = try run.program.serialize(gpa);
    defer gpa.free(bytes);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const program = try regex.Program.deserialize(arena.allocator(), bytes);
    var workspace = try regex.ReplaceWorkspace.init(gpa, program, .{});
    defer workspace.deinit();
    const input = "#" ** 40 ++ "abc";
    const match = (try workspace.find(input, 0)).?;
    try std.testing.expectEqualStrings("", match.group(input, 1).?);
    try std.testing.expectEqualStrings("abc", match.group(input, 2).?);
    try std.testing.expectEqualStrings("", match.group(input, 3).?);
}

test "Unicode capture runs agree with general search at every byte offset" {
    const patterns = [_][]const u8{ "(猫+)", "(\\p{L}+)", "((\\p{Greek}+))", "()(\\p{Han}+)()", "(?i)(k+)", "([^0-9]+)" };
    const inputs = [_][]const u8{ "", "abc 你好 Ελληνικά", "猫猫 x 猫", "123 ΔσΩ 123", "kKK kk", "\xffa\x80猫", "\xe4a", "猫\xe4\xb8", "x\xed\xa0\x80a" };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var direct = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer direct.deinit();
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.fast_kind = .none;
        for (inputs) |input| for (0..input.len + 2) |from| try compare(input, from, &direct, &reference);
    }
}

test "Unicode capture run budgets count runes rather than bytes" {
    var value = try regex.Regex.init(gpa, "()(\\p{L}+)()", .{});
    defer value.deinit();
    for ([_]bool{ false, true }) |fallback| {
        for ([_]usize{ 0, 1, 8, 9, 10, 100 }) |budget| {
            const limits = regex.Limits{ .max_execution_steps = budget, .linear_fallback = fallback };
            var direct = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
            defer direct.deinit();
            var reference = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
            defer reference.deinit();
            reference.fast_kind = .none;
            for ([_][]const u8{ "猫", "猫猫", "ΔσΩ", "abc", "123", "x\xff猫" }) |input| try compare(input, 0, &direct, &reference);
        }
    }
}
