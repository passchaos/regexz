//! Separate compile, workspace construction, cold matching and warmed costs.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;
const Mode = enum { compile_first, init, cold, warm };

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, mode: Mode) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var warm = try regexz.Workspace.init(gpa, value.program);
    defer warm.deinit();
    for (0..1000) |_| std.mem.doNotOptimizeAway(warm.matchesBorrowed(&value.program, input));
    var subject = input;
    const iterations: usize = if (mode == .warm) 100000 else 2000;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            std.mem.doNotOptimizeAway(&subject);
            switch (mode) {
                .compile_first => {
                    var fresh = try regexz.Regex.init(gpa, pattern, .{});
                    defer fresh.deinit();
                    std.mem.doNotOptimizeAway(try fresh.matches(gpa, subject));
                },
                .init, .cold => {
                    var workspace = try regexz.Workspace.init(gpa, value.program);
                    defer workspace.deinit();
                    if (mode == .cold) {
                        std.mem.doNotOptimizeAway(workspace.matchesBorrowed(&value.program, subject));
                    } else {
                        std.mem.doNotOptimizeAway(&workspace);
                    }
                },
                .warm => std.mem.doNotOptimizeAway(warm.matchesBorrowed(&value.program, subject)),
            }
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    var counter = std.testing.FailingAllocator.init(gpa, .{});
    var workspace = try regexz.Workspace.init(counter.allocator(), value.program);
    defer workspace.deinit();
    try out.print("{s:<20} {s:<13} {d:>12.1} ns/iter init_allocations={d} scratch_bytes={d}\n", .{
        name,                @tagName(mode),                                              @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations)),
        counter.allocations, (workspace.storage.len + workspace.seen.len) * @sizeOf(u32),
    });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    const cases = [_]struct { name: []const u8, pattern: []const u8, input: []const u8 }{
        .{ .name = "literal", .pattern = "hello, world!", .input = "hello, world!" },
        .{ .name = "ASCII class", .pattern = "[A-Za-z0-9._-]+", .input = "User.Name_42" },
        .{ .name = "alternation", .pattern = "(?:foo|bar)+", .input = "foobarfoo" },
        .{ .name = "xDS path", .pattern = "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", .input = "/demo.Service/Get" },
        .{ .name = "Unicode run", .pattern = "\\p{Han}+", .input = "你好世界" },
    };
    for (cases) |case| {
        for ([_]Mode{ .compile_first, .init, .cold, .warm }) |mode| {
            try bench(io, &stdout.interface, case.name, case.pattern, case.input, mode);
        }
    }
    try stdout.interface.flush();
}
