const std = @import("std");
const regex = @import("../root.zig");
const model = @import("model.zig");
const capture = @import("capture_run.zig");
const prefilter = @import("prefilter.zig");
const prefix = @import("utf8_prefix.zig");
const gpa = std.testing.allocator;

fn firstSet(set: model.Set) model.FirstSet {
    return .{ .ascii = set.ascii, .nonascii = !set.ascii_only, .empty = false };
}

fn memberLeads(set: model.Set) [256]bool {
    var result = [_]bool{false} ** 256;
    for (set.ranges) |range| {
        var value: usize = range.first;
        while (value <= range.last and value <= 0x10ffff) : (value += 1) {
            const rune: u21 = @intCast(value);
            if (!set.matches(rune)) continue;
            var bytes: [4]u8 = undefined;
            _ = std.unicode.utf8Encode(rune, &bytes) catch continue;
            result[bytes[0]] = true;
        }
    }
    return result;
}

test "UTF8 prefix ranges retain all valid materialized set members" {
    const patterns = [_][]const u8{
        "([\\x{7ff}\\x{800}\\x{d7ff}\\x{e000}\\x{ffff}\\x{10000}\\x{10ffff}]+)",
        "(\\p{Greek}+)",
        "(\\p{Han}+)",
        "(\\p{Cyrillic}+)",
        "(\\p{Hiragana}+)",
        "(?i)(k+)",
        "([A-Za-zΣσ猫]+)",
    };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        const plan = capture.Plan.init(value.program).?;
        const ranges = prefix.fromSet(plan.set).?;
        const expected = memberLeads(plan.set);
        for (0..256) |byte| try std.testing.expectEqual(expected[byte], ranges.contains(@intCast(byte)));
        for ([_]u8{ 0x80, 0xbf, 0xc0, 0xc1, 0xf5, 0xff }) |byte| try std.testing.expect(!ranges.contains(byte));
    }
}

test "UTF8 prefix FirstFilter selects the earliest byte across vectors and tails" {
    for ([_][]const u8{ "(\\p{Greek}+)", "(\\p{Han}+)", "(\\p{Cyrillic}+)", "([A-Za-zΣσ猫]+)", "([\\x{7ff}\\x{800}\\x{d7ff}\\x{e000}\\x{ffff}\\x{10000}\\x{10ffff}]+)" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        const plan = capture.Plan.init(value.program).?;
        const expected = memberLeads(plan.set);
        const symbolic = firstSet(plan.set);
        var filter = prefilter.FirstFilter.init(symbolic);
        filter.prepareRunePrefixes(plan.set);
        try std.testing.expect(filter.prefix_state == .ready);
        try std.testing.expectEqualDeep(symbolic, filter.first);
        for ([_]u8{ 0xcd, 0xce, 0xcf, 0xe1, 0xe2, 0xe7, 0xea, 0xef, 0xf0, 0xf4, 'a', 'k', 'Z', 0xff }) |byte| {
            for (0..80) |hit| {
                var input = [_]u8{0x80} ** 80;
                input[hit] = byte;
                for (0..input.len + 2) |from| {
                    const offset: ?usize = if (from <= hit and expected[byte]) hit else null;
                    try std.testing.expectEqual(offset, filter.indexOfRuneCandidates(&input, from));
                }
            }
        }
    }
}

test "UTF8 prefix capture preparation borrows existing storage and recovers invalid starts" {
    var value = try regex.Regex.init(gpa, "()(\\p{Han}+)()", .{});
    defer value.deinit();
    var counter = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 1 });
    var direct = try regex.ReplaceWorkspace.init(counter.allocator(), value.program, .{});
    defer direct.deinit();
    const symbolic = direct.first_filter.first;
    try std.testing.expect(direct.first_filter.prefix_state == .unprepared);
    const input = "Ελληνικά😀𐐀 " ** 8 ++ "\xe0\x80\x80\xed\xa0\x80\xf4\x90\x80\x80\xf0𠀀猫";
    const match = (try direct.find(input, 0)).?;
    try std.testing.expectEqual(input.len - "𠀀猫".len, match.start);
    try std.testing.expectEqualStrings("𠀀猫", match.group(input, 2).?);
    try std.testing.expect(direct.first_filter.prefix_state == .ready);
    try std.testing.expectEqualDeep(symbolic, direct.first_filter.first);
    var reference = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer reference.deinit();
    reference.fast_kind = .none;
    reference.search_dfa_ineligible = true;
    for (0..input.len + 2) |from| {
        const actual = try direct.find(input, from);
        const expected = try reference.find(input, from);
        try std.testing.expectEqual(expected != null, actual != null);
        if (expected) |found| {
            try std.testing.expectEqual(found.start, actual.?.start);
            try std.testing.expectEqual(found.end, actual.?.end);
            try std.testing.expectEqualSlices(usize, found.slots, actual.?.slots);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), counter.allocations);
    try std.testing.expect(!counter.has_induced_failure);
    try std.testing.expect(direct.search_dfa_workspace == null);
    try std.testing.expectEqual(@as(usize, 0), direct.trail.capacity);
    try std.testing.expectEqual(@as(usize, 0), direct.choices.capacity);
}

test "UTF8 prefix wide and fragmented sets retain the original filter" {
    const cases = [_]struct { pattern: []const u8, input: []const u8, group: []const u8 }{
        .{ .pattern = "(\\p{L}+)", .input = "😀" ** 16 ++ "abc", .group = "abc" },
        .{ .pattern = "([\\x{100}\\x{400}\\x{1000}\\x{2000}\\x{3000}\\x{5000}\\x{9000}\\x{10000}\\x{40000}]+)", .input = "Σσ" ** 16 ++ "\u{100}", .group = "\u{100}" },
    };
    for (cases) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
        defer workspace.deinit();
        const symbolic = workspace.first_filter.first;
        const original_count = workspace.first_filter.range_count;
        try std.testing.expect(prefix.fromSet(workspace.capture_run.?.set) == null);
        const match = (try workspace.find(case.input, 0)).?;
        try std.testing.expectEqualStrings(case.group, match.group(case.input, 1).?);
        try std.testing.expect(workspace.first_filter.prefix_state == .disabled);
        try std.testing.expectEqualDeep(symbolic, workspace.first_filter.first);
        try std.testing.expectEqual(original_count, workspace.first_filter.range_count);
    }
}

test "UTF8 prefix prepared and unprepared capture scans retain rune budgets" {
    var value = try regex.Regex.init(gpa, "()(\\p{Han}+)()", .{});
    defer value.deinit();
    const input = "Σσ😀 " ** 8 ++ "𠀀猫";
    for ([_]bool{ false, true }) |fallback| {
        for ([_]usize{ 0, 1, 7, 8, 9, 10, 11, 12, 32 }) |budget| {
            const limits = regex.Limits{ .max_execution_steps = budget, .linear_fallback = fallback };
            var direct = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
            defer direct.deinit();
            direct.first_filter.prepareRunePrefixes(direct.capture_run.?.set);
            var reference = try regex.ReplaceWorkspace.init(gpa, value.program, limits);
            defer reference.deinit();
            reference.first_filter.prefix_state = .disabled;
            for ([_]usize{ 0, 1, input.len - 7, input.len - 6, input.len - 3 }) |from| {
                const actual = direct.find(input, from) catch |err| {
                    try std.testing.expectError(err, reference.find(input, from));
                    continue;
                };
                const expected = try reference.find(input, from);
                try std.testing.expectEqual(expected != null, actual != null);
                if (expected) |found| try std.testing.expectEqualSlices(usize, found.slots, actual.?.slots);
            }
        }
    }
}
