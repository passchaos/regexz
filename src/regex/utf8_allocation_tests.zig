const std = @import("std");
const regex = @import("../root.zig");
const utf8_set = @import("utf8_set.zig");
const utf8_run = @import("utf8_run.zig");
const model = @import("model.zig");
const gpa = std.testing.allocator;

test "utf8 automaton construction rolls back allocation failures" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var automaton = try utf8_set.build(allocator, &.{
                .{ .first = 0x3400, .last = 0x4DBF },
                .{ .first = 0x4E00, .last = 0x9FFF },
                .{ .first = 0x20000, .last = 0x2A6DF },
            });
            defer automaton.deinit(allocator);
        }
    };
    try std.testing.checkAllAllocationFailures(gpa, Harness.run, .{});
}

test "Unicode workspace construction rolls back allocation failures" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, program: regex.Program, input: []const u8) !void {
            var workspace = try regex.Workspace.init(allocator, program);
            defer workspace.deinit();
            try std.testing.expect(workspace.matchesBorrowed(&program, input));
        }
    };
    for ([_]struct { pattern: []const u8, input: []const u8 }{
        .{ .pattern = "\\p{Han}+", .input = "你好" },
        .{ .pattern = "(?:\\p{Han}+\n)+", .input = "你好\n世界\n" },
    }) |case| {
        var value = try regex.Regex.init(gpa, case.pattern, .{});
        defer value.deinit();
        try std.testing.checkAllAllocationFailures(gpa, Harness.run, .{ value.program, case.input });
    }
}

fn checkExpanded(set: model.Set) !void {
    var compact = try utf8_set.build(gpa, set.ranges);
    defer compact.deinit(gpa);
    var expanded = try utf8_run.Utf8Run.init(gpa, set);
    defer expanded.deinit(gpa);
    try std.testing.expectEqual(compact.stateCount() * 256, expanded.table.len);
    for (0..compact.stateCount()) |state| {
        for (0..256) |byte| {
            try std.testing.expectEqual(compact.advance(@intCast(state), @intCast(byte)), expanded.table[state * 256 + byte]);
        }
    }
}

test "expanded UTF8 rows agree with compact transitions for every byte" {
    for ([_][]const u8{
        "[\\p{Han}\\p{Greek}]",                                               "\\p{L}", "[\\x{80}-\\x{10ffff}]",
        "[A-Za-zΣσ猫]",
        "[\\x{7ff}\\x{800}\\x{d7ff}\\x{e000}\\x{ffff}\\x{10000}\\x{10ffff}]",
    }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        const set = for (value.program.instructions) |instruction| {
            if (instruction == .consume) break instruction.consume.set;
        } else unreachable;
        try checkExpanded(set);
    }
    try checkExpanded(.{ .ranges = &.{} });
    try checkExpanded(.{ .ranges = &.{.{ .first = 0, .last = 0x10ffff }} });
}

test "expanded UTF8 direct construction rolls back allocation failures" {
    const Harness = struct {
        fn run(allocator: std.mem.Allocator, set: model.Set) !void {
            var expanded = try utf8_run.Utf8Run.init(allocator, set);
            defer expanded.deinit(allocator);
            try std.testing.expect(expanded.table.len >= 256);
        }
    };
    for ([_][]const u8{ "[\\p{Han}\\p{Greek}]", "\\p{L}", "[\\x{80}-\\x{10ffff}]" }) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        const set = for (value.program.instructions) |instruction| {
            if (instruction == .consume) break instruction.consume.set;
        } else unreachable;
        try std.testing.checkAllAllocationFailures(gpa, Harness.run, .{set});
    }
}
