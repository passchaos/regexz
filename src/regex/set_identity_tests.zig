const std = @import("std");
const regex = @import("../root.zig");
const model = @import("model.zig");
const shapes = @import("shapes.zig");
const gpa = std.testing.allocator;

test "set identity keeps content equality for independently stored ranges" {
    const ranges = [_]model.Range{
        .{ .first = 'a', .last = 'c' },
        .{ .first = 0x0391, .last = 0x03a9 },
        .{ .first = 0x4e00, .last = 0x9fff },
    };
    const original = model.Set{ .ranges = &ranges };
    const copied = try gpa.dupe(model.Range, &ranges);
    defer gpa.free(copied);
    const distinct = model.Set{ .ranges = copied };
    try std.testing.expect(original.ranges.ptr != distinct.ranges.ptr);
    try std.testing.expect(shapes.sameSet(original, original));
    try std.testing.expect(shapes.sameSet(original, distinct));
    try std.testing.expect(!shapes.sameSet(original, .{ .ranges = ranges[0..2] }));
    try std.testing.expect(shapes.sameSet(.{ .ranges = &.{} }, .{ .ranges = ranges[0..0] }));
    copied[1].last -= 1;
    try std.testing.expect(!shapes.sameSet(original, distinct));
}

test "set identity recognition retains copied equal sets and rejects differing members" {
    var value = try regex.Regex.init(gpa, "\\p{L}+", .{});
    defer value.deinit();
    const instructions = try gpa.dupe(model.Instruction, value.program.instructions);
    defer gpa.free(instructions);
    var program = value.program;
    program.instructions = instructions;
    const star = instructions[4].star.set;
    try std.testing.expect(star.ranges.ptr == instructions[5].consume.set.ranges.ptr);
    try std.testing.expect(shapes.setRun(program) != null);
    const copied = try gpa.dupe(model.Range, star.ranges);
    defer gpa.free(copied);
    instructions[5].consume.set.ranges = copied;
    try std.testing.expect(shapes.setRun(program) != null);
    copied[0].first += 1;
    try std.testing.expect(shapes.setRun(program) == null);
    instructions[5].consume.set.ranges = star.ranges[0 .. star.ranges.len - 1];
    try std.testing.expect(shapes.setRun(program) == null);
}
