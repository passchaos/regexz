const std = @import("std");
const regex = @import("../root.zig");
const gpa = std.testing.allocator;

const Collector = struct {
    spans: std.ArrayList([2]usize) = .empty,
    fn deinit(self: *Collector) void {
        self.spans.deinit(gpa);
    }
};

fn emitMatch(context: ?*anyopaque, match: regex.StreamMatch) void {
    const collector: *Collector = @ptrCast(@alignCast(context.?));
    collector.spans.append(gpa, .{ match.start, match.end }) catch @panic("out of memory");
}

fn findSpan(value: *regex.Regex, input: []const u8) !?[2]usize {
    var workspace = try regex.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    const match = (try workspace.find(input, 0)) orelse return null;
    return .{ match.start, match.end };
}

test "notempty rejects empty full and search matches" {
    var value = try regex.Regex.init(gpa, "(*NOTEMPTY)a*", .{});
    defer value.deinit();
    try std.testing.expect(!try value.matches(gpa, ""));
    try std.testing.expect(try value.matches(gpa, "aaa"));
    try std.testing.expectEqual(@as(?[2]usize, null), try findSpan(&value, "bbb"));
    try std.testing.expectEqual(@as(?[2]usize, .{ 1, 3 }), try findSpan(&value, "baa"));
}

test "notempty_atstart rejects only the first empty match" {
    var value = try regex.Regex.init(gpa, "(*NOTEMPTY_ATSTART)a*", .{});
    defer value.deinit();
    try std.testing.expect(!try value.matches(gpa, ""));
    try std.testing.expect(try value.matches(gpa, "aaa"));
    try std.testing.expectEqual(@as(?[2]usize, .{ 1, 1 }), try findSpan(&value, "bbb"));
    try std.testing.expectEqual(@as(?[2]usize, null), try findSpan(&value, ""));
}

test "notempty affects replacement and regex sets" {
    var value = try regex.Regex.init(gpa, "(*NOTEMPTY)a*", .{});
    defer value.deinit();
    const replaced = try value.replaceAll(gpa, "bbb", "x");
    defer gpa.free(replaced);
    try std.testing.expectEqualStrings("bbb", replaced);

    const patterns = [_][]const u8{ "(*NOTEMPTY)a*", "z" };
    var set = try regex.RegexSet.init(gpa, &patterns, .{});
    defer set.deinit();
    var matched: [2]bool = undefined;
    try set.matches("", &matched);
    try std.testing.expectEqualSlices(bool, &.{ false, false }, &matched);
    try set.matches("aaa", &matched);
    try std.testing.expectEqualSlices(bool, &.{ true, false }, &matched);
}

test "notempty affects the streaming scanner" {
    var value = try regex.Regex.init(gpa, "(*NOTEMPTY)a*", .{});
    defer value.deinit();
    var scanner = try regex.StreamScanner.init(gpa, value.program, .{});
    defer scanner.deinit();
    var collector = Collector{};
    defer collector.deinit();
    try scanner.feed("bbb", &collector, emitMatch);
    try scanner.finish(&collector, emitMatch);
    try std.testing.expectEqual(@as(usize, 0), collector.spans.items.len);

    var atstart = try regex.Regex.init(gpa, "(*NOTEMPTY_ATSTART)a*", .{});
    defer atstart.deinit();
    var scanner2 = try regex.StreamScanner.init(gpa, atstart.program, .{});
    defer scanner2.deinit();
    var collector2 = Collector{};
    defer collector2.deinit();
    try scanner2.feed("bbb", &collector2, emitMatch);
    try scanner2.finish(&collector2, emitMatch);
    try std.testing.expect(collector2.spans.items.len > 0);
    try std.testing.expectEqual(@as(usize, 1), collector2.spans.items[0][0]);
}
