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

fn benchFindAll(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
    limits: regexz.Limits,
    borrowed: bool,
) !void {
    var value = try regexz.Regex.init(gpa, pattern, limits);
    defer value.deinit();
    var workspace: regexz.ReplaceWorkspace = undefined;
    if (borrowed) workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, limits);
    defer if (borrowed) workspace.deinit();
    for (0..3) |_| {
        var iterator = if (borrowed) value.findAllWith(&workspace, input) else try value.findAll(gpa, input);
        defer iterator.deinit();
        while (try iterator.next()) |_| {}
    }
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        var pieces: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var iterator = if (borrowed) value.findAllWith(&workspace, input) else try value.findAll(gpa, input);
            defer iterator.deinit();
            while (try iterator.next()) |_| pieces += 1;
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
        std.mem.doNotOptimizeAway(pieces);
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn benchSplit(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    for (0..20) |_| {
        const parts = try value.split(gpa, input);
        gpa.free(parts);
    }
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            const parts = try value.split(gpa, input);
            std.mem.doNotOptimizeAway(parts.len);
            gpa.free(parts);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn benchMatches(
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
    for (0..1000) |_| std.mem.doNotOptimizeAway(try value.matches(gpa, input));
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        var hits: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            hits += @intFromBool(try value.matches(gpa, input));
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
        std.mem.doNotOptimizeAway(hits);
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn benchReplace(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    substitution: []const u8,
    iterations: usize,
) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    for (0..100) |_| {
        const output = try value.replaceAll(gpa, input, substitution);
        gpa.free(output);
    }
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            const output = try value.replaceAll(gpa, input, substitution);
            std.mem.doNotOptimizeAway(output);
            gpa.free(output);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn benchSet(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    patterns: []const []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    var set = try regexz.RegexSet.init(gpa, patterns, .{});
    defer set.deinit();
    var matched: [16]bool = undefined;
    for (0..10) |_| try set.matches(input, matched[0..patterns.len]);
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        var hits: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            try set.matches(input, matched[0..patterns.len]);
            for (matched[0..patterns.len]) |value| hits += @intFromBool(value);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
        std.mem.doNotOptimizeAway(hits);
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

    var csv_text: std.ArrayList(u8) = .empty;
    defer csv_text.deinit(gpa);
    for (0..1000) |_| try csv_text.appendSlice(gpa, "alpha,beta,gamma,delta,epsilon,");

    var word_text: std.ArrayList(u8) = .empty;
    defer word_text.deinit(gpa);
    for (0..3000) |_| try word_text.appendSlice(gpa, "alpha beta gamma delta epsilon ");

    var replace_text: std.ArrayList(u8) = .empty;
    defer replace_text.deinit(gpa);
    for (0..2000) |_| try replace_text.appendSlice(gpa, "aaa bbb aaa bbb ");

    var greek_text: std.ArrayList(u8) = .empty;
    defer greek_text.deinit(gpa);
    for (0..2000) |_| try greek_text.appendSlice(gpa, "αβγδε ζηθικ λμνξο ");

    var email_text: std.ArrayList(u8) = .empty;
    defer email_text.deinit(gpa);
    for (0..800) |_| try email_text.appendSlice(gpa, "user.name@example.com ");

    var ip_text: std.ArrayList(u8) = .empty;
    defer ip_text.deinit(gpa);
    for (0..2000) |_| try ip_text.appendSlice(gpa, "192.168.1.1 10.0.0.255 172.16.0.1 ");

    var date_text: std.ArrayList(u8) = .empty;
    defer date_text.deinit(gpa);
    for (0..2000) |_| try date_text.appendSlice(gpa, "2026-11-21 2025-01-05 1999-12-31 ");

    var cafe_text: std.ArrayList(u8) = .empty;
    defer cafe_text.deinit(gpa);
    for (0..2000) |_| try cafe_text.appendSlice(gpa, "café CAFÉ Café ");

    var day_text: std.ArrayList(u8) = .empty;
    defer day_text.deinit(gpa);
    for (0..2000) |_| try day_text.appendSlice(gpa, "sunday monday tuesday wednesday ");

    var color_text: std.ArrayList(u8) = .empty;
    defer color_text.deinit(gpa);
    for (0..2000) |_| try color_text.appendSlice(gpa, "#ff00aa #00FF00 #123456 ");

    var version_text: std.ArrayList(u8) = .empty;
    defer version_text.deinit(gpa);
    for (0..2000) |_| try version_text.appendSlice(gpa, "v1.2.3 10.0.0 v2.11.5 ");

    const qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";
    const ucp = regexz.Limits{ .unicode_perl_space = true, .max_execution_steps = 16_000_000 };

    try benchCompile(io, out, "compile Qwen tokenizer", qwen, 500, ucp);
    try benchCompile(io, out, "compile xDS-like", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", 20000, .{});
    try benchFind(io, out, "find Qwen tokenizer", qwen, ascii_text.items, 50, ucp);
    try benchFindAll(io, out, "findAll Qwen (borrowed)", qwen, ascii_text.items, 50, ucp, true);
    try benchFindAll(io, out, "findAll Qwen (owning)", qwen, ascii_text.items, 50, ucp, false);
    try benchFind(io, out, "find CJK tokenizer", qwen, cjk_text.items, 50, ucp);
    try benchFind(io, out, "find HTML tag", "<[^>]+>", html_text.items, 200, .{});
    try benchFind(io, out, "find URL", "https?://[^\\s]+", url_text.items, 200, .{});
    try benchFind(io, out, "find JSON string literal", "\"[^\"]*\"", json_text.items, 200, .{});
    try benchFind(io, out, "find JSON number", "-?\\d+(?:\\.\\d+)?", number_text.items, 200, .{});
    try benchFind(io, out, "find word boundary", "\\b\\w+\\b", word_text.items, 200, .{});
    try benchFind(io, out, "find (?i) literal", "(?i)alpha", word_text.items, 200, .{});
    try benchFind(io, out, "find alternation (5 words)", "alpha|gamma|epsilon|zeta|theta", word_text.items, 200, .{});
    try benchFind(io, out, "find (?i) alternation", "(?i)alpha|gamma", word_text.items, 200, .{});
    try benchFind(io, out, "find 10-word alternation", "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa", word_text.items, 200, .{});
    try benchFind(io, out, "find Greek class", "\\p{Script=Greek}+", greek_text.items, 200, .{});
    try benchFind(io, out, "find prefix+suffix", "\\w+@example\\.com", email_text.items, 200, .{});
    try benchReplace(io, out, "replaceAll email captures", "(\\w+)@(\\w+)\\.com", email_text.items, "$2@$1", 200);
    try benchFind(io, out, "find IPv4", "\\d{1,3}(?:\\.\\d{1,3}){3}", ip_text.items, 200, .{});
    try benchFind(io, out, "find date", "\\d{4}-\\d{2}-\\d{2}", date_text.items, 200, .{});
    try benchFind(io, out, "find 20-word alternation", "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon", word_text.items, 200, .{});
    try benchFind(io, out, "find anchored line", "(?m)^\\w+", ascii_text.items, 200, .{});
    try benchFind(io, out, "find (?i) Unicode literal", "(?i)café", cafe_text.items, 200, .{});
    try benchFind(io, out, "find shared-prefix alternation", "sunday|saturday|someday", day_text.items, 200, .{});
    try benchFind(io, out, "find one-char alternation", "a|b|c", ascii_text.items, 200, .{});
    try benchFind(io, out, "find hex color", "#[0-9a-fA-F]{6}", color_text.items, 200, .{});
    try benchFind(io, out, "find version", "v?\\d+\\.\\d+\\.\\d+", version_text.items, 200, .{});
    try benchSplit(io, out, "split whitespace (22 KiB)", "\\s+", ascii_text.items, 200);
    try benchSplit(io, out, "split commas (29 KiB)", ",", csv_text.items, 200);
    try benchMatches(io, out, "fullmatch literal", "hello, world!", "hello, world!", 200000, .{});
    try benchMatches(io, out, "fullmatch class", "[A-Za-z0-9._-]+", "User.Name_42", 200000, .{});
    try benchMatches(io, out, "fullmatch xDS-like", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", "/demo.Service/Get", 200000, .{});
    try benchReplace(io, out, "replaceAll a+ -> x", "a+", replace_text.items, "x", 200);
    try benchReplace(io, out, "replaceAll \\A|\\z -> X", "\\A|\\z", ascii_text.items, "X", 200);

    const set_patterns = [_][]const u8{
        "[a-z]+@", "[a-z]+#", "[a-z]+%", "[a-z]+&", "[a-z]+!",
        "[a-z]+~", "[a-z]+`", "[a-z]+;", "[a-z]+:",
    };
    try benchSet(io, out, "RegexSet 9 no-match patterns", &set_patterns, ascii_text.items, 200);
    try out.flush();
}
