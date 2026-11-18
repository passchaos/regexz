//! Reproducible microbenchmarks for regexz.
//!
//! Run with `zig build bench -Doptimize=ReleaseFast`. Numbers are wall-clock
//! medians from one process and are meant for relative comparisons between
//! changes, not as cross-machine claims.
const std = @import("std");
const regexz = @import("regexz");

const gpa = std.heap.page_allocator;

fn elapsed(io: std.Io, start: std.Io.Timestamp) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start.nanoseconds;
}

fn report(out: *std.Io.Writer, name: []const u8, iterations: usize, bytes: usize, ns: i96) !void {
    const ns_per_iter = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(iterations));
    const mib_per_s = if (ns == 0) 0 else (@as(f64, @floatFromInt(bytes * iterations)) / (1024.0 * 1024.0)) / (@as(f64, @floatFromInt(ns)) / 1e9);
    try out.print("{s:<42} {d:>10.1} ns/iter  {d:>9.1} MiB/s\n", .{ name, ns_per_iter, mib_per_s });
}

fn benchMatches(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, iterations: usize, reuse: bool) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    if (reuse) {
        var workspace = try regexz.Workspace.init(gpa, value.program);
        defer workspace.deinit();
        for (0..1000) |_| std.mem.doNotOptimizeAway(workspace.matches(value.program, input));
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(workspace.matches(value.program, input));
        try report(out, name, iterations, input.len, elapsed(io, .{ .nanoseconds = start }));
    } else {
        for (0..1000) |_| std.mem.doNotOptimizeAway(try value.matches(gpa, input));
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| std.mem.doNotOptimizeAway(try value.matches(gpa, input));
        try report(out, name, iterations, input.len, elapsed(io, .{ .nanoseconds = start }));
    }
}

fn benchFind(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, iterations: usize, limits: regexz.Limits) !void {
    var value = try regexz.Regex.init(gpa, pattern, limits);
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, limits);
    defer workspace.deinit();
    for (0..100) |_| {
        var offset: usize = 0;
        while (offset < input.len) {
            const match = (try workspace.find(input, offset)) orelse break;
            if (match.end <= match.start) break;
            offset = match.end;
        }
    }
    const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    var pieces: usize = 0;
    for (0..iterations) |_| {
        var offset: usize = 0;
        while (offset < input.len) {
            const match = (try workspace.find(input, offset)) orelse break;
            if (match.end <= match.start) break;
            offset = match.end;
            pieces += 1;
        }
    }
    std.mem.doNotOptimizeAway(pieces);
    try report(out, name, iterations, input.len, elapsed(io, .{ .nanoseconds = start }));
}

fn benchFindFirst(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, iterations: usize, limits: regexz.Limits) !void {
    var value = try regexz.Regex.init(gpa, pattern, limits);
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, limits);
    defer workspace.deinit();
    for (0..100) |_| std.mem.doNotOptimizeAway((try workspace.find(input, 0)) != null);
    const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    for (0..iterations) |_| std.mem.doNotOptimizeAway((try workspace.find(input, 0)) != null);
    try report(out, name, iterations, input.len, elapsed(io, .{ .nanoseconds = start }));
}

fn benchReplace(io: std.Io, out: *std.Io.Writer, name: []const u8, pattern: []const u8, input: []const u8, substitution: []const u8, iterations: usize) !void {
    var value = try regexz.Regex.init(gpa, pattern, .{});
    defer value.deinit();
    var workspace = try regexz.ReplaceWorkspace.init(gpa, value.program, .{});
    defer workspace.deinit();
    for (0..100) |_| {
        const output = try workspace.replaceAll(input, substitution);
        gpa.free(output);
    }
    const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
    for (0..iterations) |_| {
        const output = try workspace.replaceAll(input, substitution);
        std.mem.doNotOptimizeAway(output.len);
        gpa.free(output);
    }
    try report(out, name, iterations, input.len, elapsed(io, .{ .nanoseconds = start }));
}

pub fn main() !void {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const literal_input = "hello, world!";
    const token_input = "User.Name_42";
    const path_input = "/demo.Service/Get";
    const unicode_input = "Δσ2";
    const ci_input = "HeLLo";

    {
        const pattern = "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)";
        const iterations = 20000;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var value = try regexz.Regex.init(gpa, pattern, .{});
            value.deinit();
        }
        try report(out, "compile xDS-like", iterations, pattern.len, elapsed(io, .{ .nanoseconds = start }));
    }
    {
        const smp = std.heap.smp_allocator;
        const pattern = "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)";
        const iterations = 20000;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var value = try regexz.Regex.init(smp, pattern, .{});
            value.deinit();
        }
        try report(out, "compile xDS-like (smp allocator)", iterations, pattern.len, elapsed(io, .{ .nanoseconds = start }));
    }

    try benchMatches(io, out, "fullmatch literal (alloc)", "hello, world!", literal_input, 200000, false);
    try benchMatches(io, out, "fullmatch literal (reuse)", "hello, world!", literal_input, 200000, true);
    try benchMatches(io, out, "fullmatch class (alloc)", "[A-Za-z0-9._-]+", token_input, 200000, false);
    try benchMatches(io, out, "fullmatch class (reuse)", "[A-Za-z0-9._-]+", token_input, 200000, true);
    try benchMatches(io, out, "fullmatch xDS-like (alloc)", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", path_input, 200000, false);
    try benchMatches(io, out, "fullmatch xDS-like (reuse)", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", path_input, 200000, true);
    try benchMatches(io, out, "fullmatch unicode (reuse)", "\\p{Greek}+\\p{Nd}", unicode_input, 200000, true);
    try benchMatches(io, out, "fullmatch (?i) literal (reuse)", "(?i)hello", ci_input, 200000, true);
    try benchMatches(io, out, "fullmatch backref (Regex)", "(a)\\1", "aa", 200000, false);
    try benchMatches(io, out, "fullmatch atomic (Regex)", "(?>a+)a", "aa", 200000, false);

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const sample = "Hello, world!  This is a test of the Qwen pre-tokenizer. Numbers 12345 and symbols !@#$%^&*() and Unicode 你好世界 café.\n";
    for (0..200) |_| try text.appendSlice(gpa, sample);
    const qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+";
    // Same pattern without the lookahead branch: the exact shape Rust `regex`
    // can compile, so the CJK comparison isolates the engine, not the feature.
    const qwen_no_lookahead = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";
    const ucp = regexz.Limits{ .unicode_perl_space = true, .max_execution_steps = 16_000_000 };
    try benchFind(io, out, "find Qwen tokenizer", qwen, text.items, 50, ucp);

    var email_text: std.ArrayList(u8) = .empty;
    defer email_text.deinit(gpa);
    for (0..800) |_| try email_text.appendSlice(gpa, "user.name@example.com ");
    try benchFind(io, out, "find capture email tokens", "(\\w+)@(\\w+)\\.com", email_text.items, 100, .{});
    try benchFind(io, out, "find capture no-match", "(\\p{L}+)@(\\p{L}+)", text.items, 20, .{});
    try benchFindFirst(io, out, "find loop-exit no-match", "[a-z]*(?:foo|bar)", text.items, 200, .{});
    try benchFindFirst(io, out, "find extended no-match", "(?=foo)bar", text.items, 2000, .{});
    try benchFindFirst(io, out, "find suffix no-match", "[a-z]+(?:ing|ed)\\b", text.items, 200, .{});
    try benchFind(io, out, "find byte escape scan", "\\C+", text.items, 50, .{});
    try benchFindFirst(io, out, "find shared-prefix no-match", "(?:sunday|saturday|september)", text.items, 500, .{});

    var cjk_text: std.ArrayList(u8) = .empty;
    defer cjk_text.deinit(gpa);
    for (0..4000) |_| try cjk_text.appendSlice(gpa, "\u{4f60}\u{597d}\u{4e16}\u{754c}\u{ff0c}\u{8fd9}\u{662f}\u{4e00}\u{4e2a}\u{4e2d}\u{6587}\u{5206}\u{8bcd}\u{6d4b}\u{8bd5}\u{3002}\n");
    try benchFind(io, out, "find CJK tokenizer", qwen, cjk_text.items, 50, ucp);
    try benchFind(io, out, "find CJK tokenizer (no lookahead)", qwen_no_lookahead, cjk_text.items, 50, ucp);
    try benchFind(io, out, "find Han class scan", "\\p{Han}+", cjk_text.items, 50, .{});

    var han_text: std.ArrayList(u8) = .empty;
    defer han_text.deinit(gpa);
    for (0..4000) |_| try han_text.appendSlice(gpa, "\u{4f60}\u{597d}\u{4e16}\u{754c}\u{8fd9}\u{662f}\u{4e00}\u{4e2a}\u{4e2d}\u{6587}\u{5206}\u{8bcd}\u{6d4b}\u{8bd5}\n");
    try benchMatches(io, out, "fullmatch Han class (191 KiB)", "(?:\\p{Han}+\n)+", han_text.items, 50, true);

    var ascii_text: std.ArrayList(u8) = .empty;
    defer ascii_text.deinit(gpa);
    for (0..4000) |_| try ascii_text.appendSlice(gpa, "the quick brown fox jumps over the lazy dog 1234567890\n");
    try benchMatches(io, out, "fullmatch ASCII class (216 KiB)", "[a-z0-9 \n]+", ascii_text.items, 50, true);
    try benchMatches(io, out, "fullmatch ASCII loop (216 KiB)", "(?:[a-z0-9]+[ \n])+", ascii_text.items, 50, true);

    {
        const set_patterns = [_][]const u8{
            "[a-z]+@", "[a-z]+#", "[a-z]+%", "[a-z]+&", "[a-z]+!",
            "[a-z]+~", "[a-z]+`", "[a-z]+;", "[a-z]+:",
        };
        var set = try regexz.RegexSet.init(gpa, &set_patterns, .{});
        defer set.deinit();
        var matched: [set_patterns.len]bool = undefined;
        for (0..100) |_| try set.matches(text.items, &matched);
        const iterations = 200;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            try set.matches(text.items, &matched);
            std.mem.doNotOptimizeAway(matched[0]);
        }
        try report(out, "RegexSet 9 no-match patterns", iterations, text.items.len, elapsed(io, .{ .nanoseconds = start }));
    }

    var haystack: std.ArrayList(u8) = .empty;
    defer haystack.deinit(gpa);
    for (0..4096) |_| try haystack.append(gpa, 'x');
    try haystack.appendSlice(gpa, "/demo.Service/Get");
    try benchFindFirst(io, out, "find xDS-like after 4KB prefix", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", haystack.items, 20000, .{});

    var literal_haystack: std.ArrayList(u8) = .empty;
    defer literal_haystack.deinit(gpa);
    for (0..4096) |_| try literal_haystack.append(gpa, 'x');
    try literal_haystack.appendSlice(gpa, "needle");
    try benchFindFirst(io, out, "find literal after 4KB prefix", "needle", literal_haystack.items, 20000, .{});

    var token_haystack: std.ArrayList(u8) = .empty;
    defer token_haystack.deinit(gpa);
    for (0..4096) |_| try token_haystack.append(gpa, 'x');
    try token_haystack.appendSlice(gpa, "POST");
    try benchFindFirst(io, out, "find multi-literal after 4KB prefix", "(?:GET|POST|PUT|DELETE)", token_haystack.items, 20000, .{});

    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(gpa);
    for (0..2000) |_| try long.appendSlice(gpa, "aaa bbb aaa bbb ");
    try benchReplace(io, out, "replaceAll a+ -> x", "a+", long.items, "x", 200);

    {
        var value = try regexz.Regex.init(gpa, qwen, ucp);
        defer value.deinit();
        const iterations = 200000;
        // The page allocator would benchmark mmap/munmap under host memory
        // pressure; a general-purpose allocator measures workspace setup.
        const smp = std.heap.smp_allocator;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var workspace = try regexz.Workspace.init(smp, value.program);
            workspace.deinit();
        }
        try report(out, "Workspace.init Qwen program", iterations, 0, elapsed(io, .{ .nanoseconds = start }));
        try out.print("instructions={d} workspace_bytes={d}\n", .{ value.program.instructions.len, value.program.instructions.len * 11 * @sizeOf(u32) });
    }
    try out.flush();
}
