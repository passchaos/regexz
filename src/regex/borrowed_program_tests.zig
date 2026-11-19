const std = @import("std");
const regex = @import("../root.zig");

test "borrowed program matching agrees with the value entry" {
    const gpa = std.testing.allocator;
    const patterns = [_][]const u8{
        "",      "hello",     "[a-z]+",  "(?i)hello", "(?:foo|bar)+",  "(?:a|aa)*b",
        "(ab)+", "\\p{Han}+", "a(?=b)b", "\\C+",      "(*NOTEMPTY)a*",
    };
    const inputs = [_][]const u8{ "", "hello", "HELLO", "abc", "foobarfoo", "aaaab", "ab", "abab", "你好", "\xffa" };
    for (patterns) |pattern| {
        var value = try regex.Regex.init(gpa, pattern, .{});
        defer value.deinit();
        var legacy = try regex.Workspace.init(gpa, value.program);
        defer legacy.deinit();
        var borrowed = try regex.Workspace.init(gpa, value.program);
        defer borrowed.deinit();
        for (0..3) |_| {
            for (inputs) |input| {
                try std.testing.expectEqual(legacy.matches(value.program, input), borrowed.matchesBorrowed(&value.program, input));
                try std.testing.expectEqual(input.len, borrowed.stats.input_bytes);
            }
        }
    }
}

test "value and borrowed matching entries remain callable as function pointers" {
    var value = try regex.Regex.init(std.testing.allocator, "[a-z]+", .{});
    defer value.deinit();
    var workspace = try regex.Workspace.init(std.testing.allocator, value.program);
    defer workspace.deinit();
    const legacy: *const fn (*regex.Workspace, regex.Program, []const u8) bool = regex.Workspace.matches;
    const borrowed: *const fn (*regex.Workspace, *const regex.Program, []const u8) bool = regex.Workspace.matchesBorrowed;
    try std.testing.expect(legacy(&workspace, value.program, "abc"));
    try std.testing.expect(borrowed(&workspace, &value.program, "abc"));
}
