//! Separate compile, workspace construction, cold matching and warmed costs.
const std = @import("std");
const regexz = @import("regexz");
const gpa = std.heap.smp_allocator;
const Mode = enum { compile_first, init, cold, dfa_cold, warm };

fn bench(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, mode: Mode) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var warm = try regexz.Workspace.init(gpa, value.program);
    defer warm.deinit();
    const warmups: usize = if (input.len > 64) 8 else 1000;
    for (0..warmups) |_| std.mem.doNotOptimizeAway(warm.matchesBorrowed(&value.program, input));
    var subject = input;
    const iterations: usize = if (input.len > 64)
        (if (mode == .warm) @max(20, 1000000 / input.len) else @max(8, 8192 / input.len))
    else if (mode == .warm) 100000 else 2000;
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
                .init, .cold, .dfa_cold => {
                    var workspace = try regexz.Workspace.init(gpa, value.program);
                    defer workspace.deinit();
                    if (mode == .dfa_cold) {
                        for (0..3) |_| std.mem.doNotOptimizeAway(workspace.matchesBorrowed(&value.program, subject));
                    } else if (mode == .cold) {
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
    const init_allocations = counter.allocations;
    const init_bytes = counter.allocated_bytes;
    std.mem.doNotOptimizeAway(workspace.matchesBorrowed(&value.program, input));
    const first_allocations = counter.allocations - init_allocations;
    const first_bytes = counter.allocated_bytes - init_bytes;
    for (0..2) |_| std.mem.doNotOptimizeAway(workspace.matchesBorrowed(&value.program, input));
    const cache_bytes = if (workspace.dfa) |dfa| dfa.unicode_cache.len * @sizeOf(@TypeOf(dfa.unicode_cache[0])) else 0;
    try out.print("{s:<20} {s:<13} {d:>12.1} ns/iter init_allocations={d} scratch_bytes={d} post_init_allocations={d} post_init_requested_bytes={d} unicode_cache_bytes={d} init_bytes={d} workspace_bytes={d} first_allocations={d} first_requested_bytes={d}\n", .{
        name,                                 @tagName(mode),                                              @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations)),
        init_allocations,                     (workspace.storage.len + workspace.seen.len) * @sizeOf(u32), counter.allocations - init_allocations,
        counter.allocated_bytes - init_bytes, cache_bytes,                                                 init_bytes,
        @sizeOf(regexz.Workspace),            first_allocations,                                           first_bytes,
    });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buffer);
    var varied: std.ArrayList(u8) = .empty;
    defer varied.deinit(gpa);
    var collisions: std.ArrayList(u8) = .empty;
    defer collisions.deinit(gpa);
    for (0..4096) |index| {
        var encoded: [4]u8 = undefined;
        const length = try std.unicode.utf8Encode(@intCast(0x4e00 + index), &encoded);
        try varied.appendSlice(gpa, encoded[0..length]);
        try varied.append(gpa, '0');
    }
    for (0..512) |_| {
        // These Han runes share a slot in the original 4096-entry cache.
        try collisions.appendSlice(gpa, "一币0");
    }
    const cases = [_]struct { name: []const u8, pattern: []const u8, input: []const u8 }{
        .{ .name = "literal", .pattern = "hello, world!", .input = "hello, world!" },
        .{ .name = "ASCII class", .pattern = "[A-Za-z0-9._-]+", .input = "User.Name_42" },
        .{ .name = "fragmented class", .pattern = "[acegikmoqsuwy]+", .input = "acegikmo" },
        .{ .name = "ASCII loop", .pattern = "(?:[a-z0-9]+[ \n])+", .input = "word 123\n" },
        .{ .name = "alternation", .pattern = "(?:foo|bar)+", .input = "foobarfoo" },
        .{ .name = "xDS path", .pattern = "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", .input = "/demo.Service/Get" },
        .{ .name = "Unicode run", .pattern = "\\p{Han}+", .input = "你好世界" },
        .{ .name = "mixed Unicode", .pattern = "(?:\\p{Greek}|[0-9])+", .input = "Δ1σ2Δ" },
        .{ .name = "Unicode ASCII input", .pattern = "(?:\\p{Greek}|[0-9])+", .input = "123456789012" },
        .{ .name = "varied Unicode", .pattern = "(?:\\p{Han}|[0-9])+", .input = varied.items },
        .{ .name = "Unicode collisions", .pattern = "(?:\\p{Han}|[0-9])+", .input = collisions.items },
        .{ .name = "Unicode letters ASCII", .pattern = "\\p{L}+", .input = "abcdefghijklmnop" },
        .{ .name = "Unicode letters", .pattern = "\\p{L}+", .input = "猫Σé" },
        .{ .name = "Greek run", .pattern = "\\p{Greek}+", .input = "Ελληνικά" },
        .{ .name = "Han line loop", .pattern = "(?:\\p{Han}+\\n)+", .input = "你好\n世界\n" },
    };
    for (cases) |case| {
        for ([_]Mode{ .compile_first, .init, .cold, .dfa_cold, .warm }) |mode| {
            try bench(io, &stdout.interface, case.name, case.pattern, case.input, mode);
        }
    }
    try stdout.interface.flush();
}
