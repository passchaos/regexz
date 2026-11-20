const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

fn compare(direct: *regex.ReplaceWorkspace, reference: *regex.ReplaceWorkspace, input: []const u8, from: usize) !void {
    const actual = direct.find(input, from) catch |err| {
        try std.testing.expectError(err, reference.find(input, from));
        return;
    };
    const expected = try reference.find(input, from);
    try std.testing.expectEqual(expected != null, actual != null);
    if (expected) |match| {
        try std.testing.expectEqual(match.start, actual.?.start);
        try std.testing.expectEqual(match.end, actual.?.end);
        try std.testing.expectEqualSlices(usize, match.slots, actual.?.slots);
    }
}

test "capture replay disjoint adjacent runs report captures without choices or trails" {
    const cases = [_]struct { pattern: []const u8, input: []const u8, groups: []const []const u8 }{
        .{ .pattern = "([a-z]+)([0-9]+)([A-Z]+)", .input = "hello123XYZ", .groups = &.{ "hello", "123", "XYZ" } },
        .{ .pattern = "(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)", .input = "Σσ١٢猫狗", .groups = &.{ "Σσ", "١٢", "猫狗" } },
        .{ .pattern = "()(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)()", .input = "Σσ١٢猫狗", .groups = &.{ "", "Σσ", "١٢", "猫狗", "" } },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var direct = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer direct.deinit();
        const found = (try direct.find(case.input, 0)).?;
        try std.testing.expectEqual(@as(usize, 0), found.start);
        try std.testing.expectEqual(case.input.len, found.end);
        for (case.groups, 1..) |group, index| try std.testing.expectEqualStrings(group, found.group(case.input, index).?);
        // Disjoint adjacent runs are a deterministic run chain, so neither
        // the search DFA nor the interpreter records choices or trails.
        try std.testing.expect(direct.fast_kind == .run_chain);
        try std.testing.expectEqual(@as(usize, 0), direct.trail.capacity);
        try std.testing.expectEqual(@as(usize, 0), direct.choices.capacity);
    }
}

test "capture replay adjacent and overlapping sets agree at every byte offset" {
    const patterns = [_][]const u8{
        "([a-z]+)([0-9]+)([A-Z]+)",
        "(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)",
        "()(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)()",
        "([a-z0-9]+)([0-9]+)([A-Z]+)",
        "([a-z]+?)([0-9]+)([A-Z]+)",
        "([a-z]*)([0-9]+)([A-Z]+)",
    };
    const inputs = [_][]const u8{ "", "a1A hello123XYZ", "Σσ١٢猫狗 Ω1𠀀", "123ABC", "aaa111ZZ", "\xffa1A", "Σ١𠀀\xe7", "hello123XYZ\xe0\x80\x80" };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var direct = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer direct.deinit();
        var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer reference.deinit();
        reference.fast_kind = .none;
        reference.search_dfa_ineligible = true;
        for (inputs) |input| {
            for (0..input.len + 2) |from| try compare(&direct, &reference, input, from);
        }
    }
}

test "capture replay adjacent runs retain strict execution limits and fallback captures" {
    // Both workspaces are pinned to the interpreter so the step budget and
    // its linear fallback are exercised directly.
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "([a-z]+)([0-9]+)([A-Z]+)", .input = "hello123XYZ" },
        .{ .pattern = "(\\p{Greek}+)(\\p{Nd}+)(\\p{Han}+)", .input = "Σσ١٢猫狗" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        for ([_]bool{ false, true }) |fallback| {
            for ([_]usize{ 0, 1, 13, 14, 15, 19, 20, 32, 100 }) |budget| {
                const limits = regex.Limits{ .max_execution_steps = budget, .linear_fallback = fallback };
                var direct = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
                defer direct.deinit();
                direct.fast_kind = .none;
                direct.search_dfa_ineligible = true;
                var reference = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
                defer reference.deinit();
                reference.fast_kind = .none;
                reference.search_dfa_ineligible = true;
                try compare(&direct, &reference, case.input, 0);
            }
        }
    }
}
