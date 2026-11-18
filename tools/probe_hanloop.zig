const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.page_allocator;
pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var cjk: std.ArrayList(u8) = .empty;
    defer cjk.deinit(gpa);
    for (0..4000) |_| try cjk.appendSlice(gpa, "\u{4f60}\u{597d}\u{4e16}\u{754c}\u{ff0c}\u{8fd9}\u{662f}\u{4e00}\u{4e2a}\u{4e2d}\u{6587}\u{5206}\u{8bcd}\u{6d4b}\u{8bd5}\u{3002}\n");
    const program = try regexz.compile(gpa, "\\p{Han}+", .{});
    var workspace = try regexz.ReplaceWorkspace.init(gpa, program, .{});
    defer workspace.deinit();
    var total: usize = 0;
    const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    while (std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start < 10_000_000_000) {
        var offset: usize = 0;
        while (offset < cjk.items.len) {
            const m = (try workspace.find(cjk.items, offset)) orelse break;
            if (m.end <= m.start) break;
            offset = m.end;
            total += 1;
        }
    }
    std.debug.print("total={d}\n", .{total});
}
