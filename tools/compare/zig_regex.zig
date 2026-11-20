//! Zig side of the competitor comparison. Mirrors tools/compare/rust_regex.
//!
//! Build from the repository root:
//!   zig build-exe -O ReleaseFast --dep regexz \
//!       -Mroot=tools/compare/zig_regex.zig -Mregexz=src/root.zig \
//!       -femit-bin=/tmp/regexz-compare
const std = @import("std");
const regexz = @import("regexz");

const gpa = std.heap.page_allocator;

fn benchFind(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
    limits: regexz.Limits,
) !void {
    var value = try regexz.Regex.init(gpa, pattern, limits);
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, limits);
    defer workspace.deinit();
    for (0..10) |_| {
        var offset: usize = 0;
        while (offset < input.len) {
            const match = (try workspace.find(input, offset)) orelse break;
            if (match.end <= match.start) break;
            offset = match.end;
        }
    }
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        var pieces: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var offset: usize = 0;
            while (offset < input.len) {
                const match = (try workspace.find(input, offset)) orelse break;
                if (match.end <= match.start) break;
                offset = match.end;
                pieces += 1;
            }
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
        std.mem.doNotOptimizeAway(pieces);
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn benchCompile(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    iterations: usize,
    limits: regexz.Limits,
) !void {
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var value = try regexz.Regex.init(gpa, pattern, limits);
            std.mem.doNotOptimizeAway(&value);
            value.deinit();
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;

    var ascii_text: std.ArrayList(u8) = .empty;
    defer ascii_text.deinit(gpa);
    const sample = "Hello, world!  This is a test of the Qwen pre-tokenizer. Numbers 12345 and symbols !@#$%^&*() and Unicode 你好世界 café.\n";
    for (0..200) |_| try ascii_text.appendSlice(gpa, sample);

    var cjk_text: std.ArrayList(u8) = .empty;
    defer cjk_text.deinit(gpa);
    for (0..4000) |_| try cjk_text.appendSlice(gpa, "你好世界，这是一个中文分词测试。\n");

    var html_text: std.ArrayList(u8) = .empty;
    defer html_text.deinit(gpa);
    for (0..2000) |_| try html_text.appendSlice(gpa, "<div class=\"x\"><span>text</span></div> ");

    var url_text: std.ArrayList(u8) = .empty;
    defer url_text.deinit(gpa);
    for (0..1500) |_| try url_text.appendSlice(gpa, "see https://example.com/a/b?c=1 and http://x.y ");

    var json_text: std.ArrayList(u8) = .empty;
    defer json_text.deinit(gpa);
    for (0..400) |_| try json_text.appendSlice(gpa, "{\"name\": \"value\", \"id\": 12345} ");

    var number_text: std.ArrayList(u8) = .empty;
    defer number_text.deinit(gpa);
    for (0..2000) |_| try number_text.appendSlice(gpa, "x=-12.5 y=3 z=0.25 ");

    const qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";
    const ucp = regexz.Limits{ .unicode_perl_space = true, .max_execution_steps = 16_000_000 };

    try benchCompile(io, out, "compile Qwen tokenizer", qwen, 500, ucp);
    try benchFind(io, out, "find Qwen tokenizer", qwen, ascii_text.items, 50, ucp);
    try benchFind(io, out, "find CJK tokenizer", qwen, cjk_text.items, 50, ucp);
    try benchFind(io, out, "find HTML tag", "<[^>]+>", html_text.items, 200, .{});
    try benchFind(io, out, "find URL", "https?://[^\\s]+", url_text.items, 200, .{});
    try benchFind(io, out, "find JSON string literal", "\"[^\"]*\"", json_text.items, 200, .{});
    try benchFind(io, out, "find JSON number", "-?\\d+(?:\\.\\d+)?", number_text.items, 200, .{});
    try out.flush();
}
