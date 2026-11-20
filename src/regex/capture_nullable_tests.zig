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

test "nullable capture replay preserves maximal greedy capture order without records" {
    const cases = [_]struct { pattern: []const u8, input: []const u8, groups: []const []const u8 }{
        .{ .pattern = "(a*)(b*)", .input = "aaabbb", .groups = &.{ "aaa", "bbb" } },
        .{ .pattern = "(a*)(a*)", .input = "aaaa", .groups = &.{ "aaaa", "" } },
        .{ .pattern = "(a*){3}", .input = "aaaa", .groups = &.{""} },
        .{ .pattern = "(a*)(b*)", .input = "", .groups = &.{ "", "" } },
        .{ .pattern = "([a-z]+)([0-9]*)([A-Z]+)", .input = "helloXYZ", .groups = &.{ "hello", "", "XYZ" } },
        .{ .pattern = "([a-z]+)([0-9]*)([A-Z]+)", .input = "hello123XYZ", .groups = &.{ "hello", "123", "XYZ" } },
        .{ .pattern = "([a-z]+)([a-z0-9]*)([A-Z]+)", .input = "hello123XYZ", .groups = &.{ "hello", "123", "XYZ" } },
        .{ .pattern = "([a-z]+)([a-z]*)([A-Z]+)", .input = "helloXYZ", .groups = &.{ "hello", "", "XYZ" } },
        .{ .pattern = "(\\p{Greek}*)(\\p{Nd}*)(\\p{Han}+)", .input = "猫狗", .groups = &.{ "", "", "猫狗" } },
        .{ .pattern = "()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", .input = "Σσ猫狗", .groups = &.{ "", "Σσ", "", "猫狗", "" } },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        const match = (try workspace.find(case.input, 0)).?;
        try std.testing.expectEqual(@as(usize, 0), match.start);
        try std.testing.expectEqual(case.input.len, match.end);
        for (case.groups, 1..) |group, index| try std.testing.expectEqualStrings(group, match.group(case.input, index).?);
        // Disjoint adjacent runs take the deterministic run-chain path;
        // nullable-only shapes still use the search DFA plus forced replay.
        if (workspace.fast_kind != .run_chain) {
            try std.testing.expect(workspace.search_dfa_workspace != null);
            try std.testing.expect(workspace.capture_replay_plan == .forced);
        }
        try std.testing.expectEqual(@as(usize, 0), workspace.trail.capacity);
        try std.testing.expectEqual(@as(usize, 0), workspace.choices.capacity);
    }
}

test "nullable capture replay agrees with interpreter across offsets and empty restrictions" {
    const patterns = [_][]const u8{
        "(a*){3}",
        "(a*)(b*)",
        "(a*)(a*)",
        "(a*)([ab]*)(b*)(C+)",
        "([a-z]+)([0-9]*)([A-Z]+)",
        "([a-z]+)([a-z0-9]*)([A-Z]+)",
        "(\\p{Greek}*)(\\p{Nd}*)(\\p{Han}+)",
        "()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()",
        "([a-z]+)([a-z]*)([a-z]+)",
        "(a*)(b*?)(C+)",
        "(a*)(b*)(?=C)(C+)",
        "(a*)a",
    };
    const inputs = [_][]const u8{
        "",                             "aaabbb aaaa aaabbC aaabbbCCC hello123XYZ helloXYZ abc",
        "Σσ١٢猫狗 Σ猫 猫狗 Ω١𠀀",
        "\xffaaabbb\xe0\x80\x80aaabbC",
        "😀Σσ猫狗\xed\xa0\x80Ω١𠀀",
    };
    for ([_][]const u8{ "", "(*NOTEMPTY)", "(*NOTEMPTY_ATSTART)" }) |prefix| {
        for (patterns) |pattern| {
            const expression = try std.mem.concat(gpa, u8, &.{ prefix, pattern });
            defer gpa.free(expression);
            var value = try regex.Regex.init(gpa, expression, .{});
            defer value.deinit();
            var direct = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
            defer direct.deinit();
            var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
            defer reference.deinit();
            reference.fast_kind = .none;
            reference.search_dfa_ineligible = true;
            for (inputs) |input| for (0..input.len + 2) |from| try compare(&direct, &reference, input, from);
        }
    }
}

test "nullable capture replay retains strict budget boundaries and fallback captures" {
    // Both workspaces are pinned to the interpreter so the step budget and
    // its linear fallback are exercised directly.
    const cases = [_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "(a*)(b*)", .input = "aaabbb" },
        .{ .pattern = "(a*)(a*)", .input = "aaaa" },
        .{ .pattern = "(a*){3}", .input = "aaaa" },
        .{ .pattern = "(a*)(b*)", .input = "" },
        .{ .pattern = "([a-z]+)([0-9]*)([A-Z]+)", .input = "helloXYZ" },
        .{ .pattern = "()(\\p{Greek}+)(\\p{Nd}*)(\\p{Han}+)()", .input = "Σσ猫狗" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        for ([_]bool{ false, true }) |fallback| {
            for ([_]usize{ 0, 1, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 20, 32, 100 }) |budget| {
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
