//! PCRE2 side of the competitor comparison. Mirrors
//! tools/compare/zig_regex.zig, but drives the system PCRE2 library through
//! its C API with JIT and `PCRE2_NO_UTF_CHECK` (subjects are already valid
//! UTF-8). Build from the repository root:
//!   zig build-exe -O ReleaseFast -lc -lpcre2-8 \
//!       tools/compare/pcre2_regex.zig -femit-bin=/tmp/regexz-pcre2
const std = @import("std");
const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const gpa = std.heap.smp_allocator;

/// Optional single-case filter from argv, used by the isolated runner.
var case_filter: ?[]const u8 = null;

fn selected(name: []const u8) bool {
    if (case_filter) |only| return std.mem.eql(u8, only, name);
    return true;
}

const Match = struct { start: usize, end: usize };

/// Advance past one UTF-8 code unit so empty matches do not split a rune.
fn nextRune(input: []const u8, pos: usize) usize {
    if (pos >= input.len) return pos + 1;
    const length = std.unicode.utf8ByteSequenceLength(input[pos]) catch 1;
    return pos + length;
}

const Pattern = struct {
    code: *c.pcre2_code_8,
    match_data: *c.pcre2_match_data_8,
    last_rc: c_int = 0,

    fn init(pattern: []const u8) !Pattern {
        var error_code: c_int = 0;
        var error_offset: usize = 0;
        const code = c.pcre2_compile_8(pattern.ptr, pattern.len, c.PCRE2_UTF, &error_code, &error_offset, null) orelse
            return error.Compile;
        _ = c.pcre2_jit_compile_8(code, c.PCRE2_JIT_COMPLETE);
        const match_data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse
            return error.OutOfMemory;
        return .{ .code = code, .match_data = match_data };
    }

    fn deinit(self: *Pattern) void {
        c.pcre2_match_data_free_8(self.match_data);
        c.pcre2_code_free_8(self.code);
    }

    fn find(self: *Pattern, input: []const u8, start: usize) ?Match {
        const rc = c.pcre2_match_8(self.code, input.ptr, input.len, start, c.PCRE2_NO_UTF_CHECK, self.match_data, null);
        self.last_rc = rc;
        if (rc < 0) return null;
        const ovector = c.pcre2_get_ovector_pointer_8(self.match_data);
        return .{ .start = ovector[0], .end = ovector[1] };
    }
};

fn countMatches(pattern: *Pattern, input: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (pos < input.len) {
        const match = pattern.find(input, pos) orelse break;
        if (match.end <= match.start) break;
        count += 1;
        pos = match.end;
    }
    return count;
}

fn benchFind(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    if (!selected(name)) return;
    var value = try Pattern.init(pattern);
    defer value.deinit();
    for (0..10) |_| std.mem.doNotOptimizeAway(countMatches(&value, input));
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        var pieces: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| pieces += countMatches(&value, input);
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
    borrowed: bool,
) !void {
    if (!selected(name)) return;
    _ = borrowed;
    return benchFind(io, out, name, pattern, input, iterations);
}

fn splitAll(allocator: std.mem.Allocator, pattern: *Pattern, input: []const u8) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    var last: usize = 0;
    var pos: usize = 0;
    while (pos < input.len) {
        const match = pattern.find(input, pos) orelse break;
        try parts.append(allocator, input[last..match.start]);
        last = match.end;
        pos = if (match.end > match.start) match.end else nextRune(input, match.end);
    }
    try parts.append(allocator, input[last..]);
    return parts.toOwnedSlice(allocator);
}

fn benchSplit(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    if (!selected(name)) return;
    var value = try Pattern.init(pattern);
    defer value.deinit();
    for (0..20) |_| {
        const parts = try splitAll(gpa, &value, input);
        gpa.free(parts);
    }
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            const parts = try splitAll(gpa, &value, input);
            std.mem.doNotOptimizeAway(parts.len);
            gpa.free(parts);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn fullMatch(pattern: *Pattern, input: []const u8) bool {
    const match = pattern.find(input, 0) orelse return false;
    return match.start == 0 and match.end == input.len;
}

fn benchMatches(
    io: std.Io,
    out: *std.Io.Writer,
    name: []const u8,
    pattern: []const u8,
    input: []const u8,
    iterations: usize,
) !void {
    if (!selected(name)) return;
    var value = try Pattern.init(pattern);
    defer value.deinit();
    for (0..1000) |_| std.mem.doNotOptimizeAway(fullMatch(&value, input));
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        var hits: usize = 0;
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| hits += @intFromBool(fullMatch(&value, input));
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
        std.mem.doNotOptimizeAway(hits);
    }
    std.mem.sort(i96, &samples, {}, std.sort.asc(i96));
    const ns = @as(f64, @floatFromInt(samples[2])) / @as(f64, @floatFromInt(iterations));
    try out.print("{s:<40} {d:>10.1} ns/iter\n", .{ name, ns });
}

fn expandSubstitution(allocator: std.mem.Allocator, out: *std.ArrayList(u8), template: []const u8, pattern: *Pattern, input: []const u8) !void {
    const ovector = c.pcre2_get_ovector_pointer_8(pattern.match_data);
    const rc: usize = @intCast(pattern.last_rc);
    var index: usize = 0;
    while (index < template.len) {
        if (template[index] == '$' and index + 1 < template.len and template[index + 1] >= '0' and template[index + 1] <= '9') {
            const group: usize = template[index + 1] - '0';
            if (group < rc) {
                const start = ovector[2 * group];
                const end = ovector[2 * group + 1];
                if (start != std.math.maxInt(usize) and end != std.math.maxInt(usize)) {
                    try out.appendSlice(allocator, input[start..end]);
                }
            }
            index += 2;
        } else {
            try out.append(allocator, template[index]);
            index += 1;
        }
    }
}

fn replaceAll(allocator: std.mem.Allocator, pattern: *Pattern, input: []const u8, substitution: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, input.len);
    var last: usize = 0;
    var pos: usize = 0;
    while (pos <= input.len) {
        const match = pattern.find(input, pos) orelse break;
        try out.appendSlice(allocator, input[last..match.start]);
        try expandSubstitution(allocator, &out, substitution, pattern, input);
        last = match.end;
        pos = if (match.end > match.start) match.end else nextRune(input, match.end);
    }
    try out.appendSlice(allocator, input[last..]);
    return out.toOwnedSlice(allocator);
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
    if (!selected(name)) return;
    var value = try Pattern.init(pattern);
    defer value.deinit();
    for (0..100) |_| {
        const output = try replaceAll(gpa, &value, input, substitution);
        gpa.free(output);
    }
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            const output = try replaceAll(gpa, &value, input, substitution);
            std.mem.doNotOptimizeAway(output);
            gpa.free(output);
        }
        sample.* = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds - start;
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
) !void {
    if (!selected(name)) return;
    var samples: [5]i96 = undefined;
    for (&samples) |*sample| {
        const start = std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
        for (0..iterations) |_| {
            var value = try Pattern.init(pattern);
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
    if (std.Io.Dir.openFileAbsolute(io, "/proc/self/cmdline", .{}) catch null) |file| {
        var cmdline_buf: [4096]u8 = undefined;
        var cmdline_reader = file.readerStreaming(io, &cmdline_buf);
        if (cmdline_reader.interface.allocRemaining(gpa, .limited(1 << 16))) |data| {
            var args = std.mem.splitScalar(u8, data, 0);
            _ = args.next();
            if (args.next()) |arg| {
                if (arg.len != 0) case_filter = arg;
            }
        } else |_| {}
    }
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

    var code_text: std.ArrayList(u8) = .empty;
    defer code_text.deinit(gpa);
    for (0..2000) |_| try code_text.appendSlice(gpa, "int foo_1 = bar2; x = y_3; ");

    var thousands_text: std.ArrayList(u8) = .empty;
    defer thousands_text.deinit(gpa);
    for (0..2000) |_| try thousands_text.appendSlice(gpa, "1,234 12,345,678 999,000 ");

    var domain_text: std.ArrayList(u8) = .empty;
    defer domain_text.deinit(gpa);
    for (0..1500) |_| try domain_text.appendSlice(gpa, "www.example.com api.test.org sub.domain.net ");

    var percent_text: std.ArrayList(u8) = .empty;
    defer percent_text.deinit(gpa);
    for (0..2000) |_| try percent_text.appendSlice(gpa, "12.5% 100% 0.25% ");

    var time_text: std.ArrayList(u8) = .empty;
    defer time_text.deinit(gpa);
    for (0..2000) |_| try time_text.appendSlice(gpa, "12:34 23:59:59 07:08 ");

    var uuid_text: std.ArrayList(u8) = .empty;
    defer uuid_text.deinit(gpa);
    for (0..1000) |_| try uuid_text.appendSlice(gpa, "550e8400-e29b-41d4-a716-446655440000 123e4567-e89b-12d3-a456-426614174000 ");

    var semver_text: std.ArrayList(u8) = .empty;
    defer semver_text.deinit(gpa);
    for (0..2000) |_| try semver_text.appendSlice(gpa, "1.2.3-beta.1 10.0.0-rc.2 2.11.5 ");

    var opt_text: std.ArrayList(u8) = .empty;
    defer opt_text.deinit(gpa);
    for (0..3000) |_| try opt_text.appendSlice(gpa, "v1.2 2.3 v4.5 6.7 ");

    var ab_text: std.ArrayList(u8) = .empty;
    defer ab_text.deinit(gpa);
    for (0..4000) |_| try ab_text.appendSlice(gpa, "ababab abab ");

    var camel_text: std.ArrayList(u8) = .empty;
    defer camel_text.deinit(gpa);
    for (0..3000) |_| try camel_text.appendSlice(gpa, "fooBar bazQux helloWorld x ");

    var kv_text: std.ArrayList(u8) = .empty;
    defer kv_text.deinit(gpa);
    for (0..3000) |_| try kv_text.appendSlice(gpa, "name = value key=value a  =  b ");

    var ipport_text: std.ArrayList(u8) = .empty;
    defer ipport_text.deinit(gpa);
    for (0..3000) |_| try ipport_text.appendSlice(gpa, "192.168.1.1:8080 10.0.0.1:443 ");

    var sign_text: std.ArrayList(u8) = .empty;
    defer sign_text.deinit(gpa);
    for (0..2000) |_| try sign_text.appendSlice(gpa, "x=-12.5 y=+3 z=0.25 ");

    var attr_text: std.ArrayList(u8) = .empty;
    defer attr_text.deinit(gpa);
    for (0..2000) |_| try attr_text.appendSlice(gpa, "<div id=\"main\" class=\"box\">");

    var md_text: std.ArrayList(u8) = .empty;
    defer md_text.deinit(gpa);
    for (0..1500) |_| try md_text.appendSlice(gpa, "# Title\n## Section\ntext\n### Sub\n");

    var prefix_text: std.ArrayList(u8) = .empty;
    defer prefix_text.deinit(gpa);
    for (0..3000) |_| try prefix_text.appendSlice(gpa, "prefix postfix prefixx post ");

    var mixed_text: std.ArrayList(u8) = .empty;
    defer mixed_text.deinit(gpa);
    for (0..4000) |_| try mixed_text.appendSlice(gpa, "a bb ccc a bb ccc ");

    var stamp_text: std.ArrayList(u8) = .empty;
    defer stamp_text.deinit(gpa);
    for (0..2000) |_| try stamp_text.appendSlice(gpa, "2026-11-21T13:29:29 2025-01-05T00:00:00 ");

    var unit_text: std.ArrayList(u8) = .empty;
    defer unit_text.deinit(gpa);
    for (0..2000) |_| try unit_text.appendSlice(gpa, "12px 3.5em 100% 2rem ");

    var call_text: std.ArrayList(u8) = .empty;
    defer call_text.deinit(gpa);
    for (0..2000) |_| try call_text.appendSlice(gpa, "foo(1) bar_baz(x) qux () ");

    var mac_text: std.ArrayList(u8) = .empty;
    defer mac_text.deinit(gpa);
    for (0..2000) |_| try mac_text.appendSlice(gpa, "00:1A:2B:3C:4D:5E aa:bb:cc:dd:ee:ff ");

    var b64_text: std.ArrayList(u8) = .empty;
    defer b64_text.deinit(gpa);
    for (0..2000) |_| try b64_text.appendSlice(gpa, "SGVsbG8gV29ybGQhIFRoaXMgaXMgYSBiYXNlNjQgc3RyaW5nIQ== ");

    var config_text: std.ArrayList(u8) = .empty;
    defer config_text.deinit(gpa);
    for (0..2000) |_| try config_text.appendSlice(gpa, "name: value\n[section]\nkey = 1\n");

    var template_text: std.ArrayList(u8) = .empty;
    defer template_text.deinit(gpa);
    for (0..2000) |_| try template_text.appendSlice(gpa, "hello ${name} and ${user.id} ");

    var path_text: std.ArrayList(u8) = .empty;
    defer path_text.deinit(gpa);
    for (0..2000) |_| try path_text.appendSlice(gpa, "C:\\Users\\dev\\file.txt D:\\data\\x.csv ");

    var css_text: std.ArrayList(u8) = .empty;
    defer css_text.deinit(gpa);
    for (0..2000) |_| try css_text.appendSlice(gpa, ".button { color: red; } #main { margin: 0; } ");

    var slash_text: std.ArrayList(u8) = .empty;
    defer slash_text.deinit(gpa);
    for (0..2000) |_| try slash_text.appendSlice(gpa, "11/21/2026 01/05/2025 12/31/1999 ");

    var ipv6_text: std.ArrayList(u8) = .empty;
    defer ipv6_text.deinit(gpa);
    for (0..1000) |_| try ipv6_text.appendSlice(gpa, "2001:0db8:85a3:0000:0000:8a2e:0370:7334 fe80:0000:0000:0000:0202:b3ff:fe1e:8329 ");

    var c_text: std.ArrayList(u8) = .empty;
    defer c_text.deinit(gpa);
    for (0..2000) |_| try c_text.appendSlice(gpa, "/* comment */ int x; /* multi\nline */ ");

    var sh_text: std.ArrayList(u8) = .empty;
    defer sh_text.deinit(gpa);
    for (0..2000) |_| try sh_text.appendSlice(gpa, "echo $HOME ${PATH} $1 ${USER:-root} ");

    const qwen = "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+";

    try benchCompile(io, out, "compile Qwen tokenizer", qwen, 500);
    try benchCompile(io, out, "compile xDS-like", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", 20000);
    try benchFind(io, out, "find Qwen tokenizer", qwen, ascii_text.items, 50);
    try benchFindAll(io, out, "findAll Qwen (borrowed)", qwen, ascii_text.items, 50, true);
    try benchFindAll(io, out, "findAll Qwen (owning)", qwen, ascii_text.items, 50, false);
    try benchFind(io, out, "find CJK tokenizer", qwen, cjk_text.items, 50);
    try benchFind(io, out, "find HTML tag", "<[^>]+>", html_text.items, 200);
    try benchFind(io, out, "find URL", "https?://[^\\s]+", url_text.items, 200);
    try benchFind(io, out, "find JSON string literal", "\"[^\"]*\"", json_text.items, 200);
    try benchFind(io, out, "find JSON number", "-?\\d+(?:\\.\\d+)?", number_text.items, 200);
    try benchFind(io, out, "find word boundary", "\\b\\w+\\b", word_text.items, 200);
    try benchFind(io, out, "find (?i) literal", "(?i)alpha", word_text.items, 200);
    try benchFind(io, out, "find alternation (5 words)", "alpha|gamma|epsilon|zeta|theta", word_text.items, 200);
    try benchFind(io, out, "find (?i) alternation", "(?i)alpha|gamma", word_text.items, 200);
    try benchFind(io, out, "find 10-word alternation", "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa", word_text.items, 200);
    try benchFind(io, out, "find Greek class", "\\p{Script=Greek}+", greek_text.items, 200);
    try benchFind(io, out, "find prefix+suffix", "\\w+@example\\.com", email_text.items, 200);
    try benchReplace(io, out, "replaceAll email captures", "(\\w+)@(\\w+)\\.com", email_text.items, "$2@$1", 200);
    try benchFind(io, out, "find IPv4", "\\d{1,3}(?:\\.\\d{1,3}){3}", ip_text.items, 200);
    try benchFind(io, out, "find date", "\\d{4}-\\d{2}-\\d{2}", date_text.items, 200);
    try benchFind(io, out, "find 20-word alternation", "alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon", word_text.items, 200);
    try benchFind(io, out, "find anchored line", "(?m)^\\w+", ascii_text.items, 200);
    try benchFind(io, out, "find (?i) Unicode literal", "(?i)café", cafe_text.items, 200);
    try benchFind(io, out, "find shared-prefix alternation", "sunday|saturday|someday", day_text.items, 200);
    try benchFind(io, out, "find one-char alternation", "a|b|c", ascii_text.items, 200);
    try benchFind(io, out, "find hex color", "#[0-9a-fA-F]{6}", color_text.items, 200);
    try benchFind(io, out, "find version", "v?\\d+\\.\\d+\\.\\d+", version_text.items, 200);
    try benchFind(io, out, "find nullable prefix", ".*test", ascii_text.items, 200);
    try benchFind(io, out, "find identifier", "[A-Za-z_]\\w*", code_text.items, 200);
    try benchFind(io, out, "find thousands", "\\d{1,3}(?:,\\d{3})+", thousands_text.items, 200);
    try benchFind(io, out, "find domain", "[a-z0-9-]+(?:\\.[a-z0-9-]+)+", domain_text.items, 200);
    try benchFind(io, out, "find percent", "\\d+(?:\\.\\d+)?%", percent_text.items, 200);
    try benchFind(io, out, "find time", "\\d{1,2}:\\d{2}(?::\\d{2})?", time_text.items, 200);
    try benchFind(io, out, "find end-anchored word", "(?m)\\w+$", ascii_text.items, 200);
    try benchFind(io, out, "find UUID", "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", uuid_text.items, 200);
    try benchFind(io, out, "find semver", "\\d+\\.\\d+\\.\\d+-[0-9A-Za-z.-]+", semver_text.items, 200);
    try benchFind(io, out, "find email TLD", "\\w+@\\w+\\.(?:com|org|net)", email_text.items, 200);
    try benchFind(io, out, "find CIDR", "\\d{1,3}(?:\\.\\d{1,3}){3}(?:/\\d{1,2})?", ip_text.items, 200);
    try benchFind(io, out, "find line full", "(?m)^.*$", ascii_text.items, 200);
    try benchFind(io, out, "find optional prefix run", "v?\\w+", opt_text.items, 200);
    try benchFind(io, out, "find repeated literal group", "(?:ab)+", ab_text.items, 200);
    try benchFind(io, out, "find camelCase", "[a-z]+[A-Z][a-z]+", camel_text.items, 200);
    try benchFind(io, out, "find key-value", "\\w+\\s*=\\s*\\w+", kv_text.items, 200);
    try benchFind(io, out, "find IP port", "\\d+\\.\\d+\\.\\d+\\.\\d+:\\d+", ipport_text.items, 200);
    try benchFind(io, out, "find (?i) class", "(?i)[a-z]+", ascii_text.items, 200);
    try benchFind(io, out, "find prefix alternation", "(?:pre|post)fix", prefix_text.items, 200);
    try benchFind(io, out, "find signed number", "[+-]?\\d+(?:\\.\\d+)?", sign_text.items, 200);
    try benchFind(io, out, "find html attribute", "\\w+=\"[^\"]*\"", attr_text.items, 200);
    try benchFind(io, out, "find markdown heading", "(?m)^#{1,6} .*$", md_text.items, 200);
    try benchFind(io, out, "find mixed alternation", "a|bb|ccc", mixed_text.items, 200);
    try benchFind(io, out, "find capitalized words", "\\b[A-Z][a-z]+\\b", word_text.items, 200);
    try benchFind(io, out, "find markdown list", "(?m)^\\s*[-*+] ", md_text.items, 200);
    try benchFind(io, out, "find JSON escaped string", "\"(?:\\\\.|[^\"\\\\])*\"", json_text.items, 200);
    try benchFind(io, out, "find double spaces", "\\s{2,}", ascii_text.items, 200);
    try benchFind(io, out, "find log level", "(?i)error|warn|info", ascii_text.items, 200);
    try benchFind(io, out, "find markdown heading ws", "(?m)^#{1,6}\\s+.*$", md_text.items, 200);
    try benchFind(io, out, "find markdown list ws", "(?m)^\\s*[-*+]\\s+", md_text.items, 200);
    try benchFind(io, out, "find escaped string loop", "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"", json_text.items, 200);
    try benchFind(io, out, "find HTTP methods", "(?i)\\b(?:get|post|put|delete)\\b", ascii_text.items, 200);
    try benchFind(io, out, "find full email", "\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b", email_text.items, 200);
    try benchFind(io, out, "find blank lines", "(?m)^\\s*$", ascii_text.items, 200);
    try benchFind(io, out, "find floats", "\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?", number_text.items, 200);
    try benchFind(io, out, "find currency", "\\$\\d+(?:\\.\\d{2})?", number_text.items, 200);
    try benchFind(io, out, "find ISO timestamp", "\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}", stamp_text.items, 200);
    try benchFind(io, out, "find JSON key", "\"[^\"]+\"\\s*:", json_text.items, 200);
    try benchFind(io, out, "find HTML comment", "<!--[\\s\\S]*?-->", html_text.items, 200);
    try benchFind(io, out, "find hashtag", "#\\w+", ascii_text.items, 200);
    try benchFind(io, out, "find mention", "@\\w+", ascii_text.items, 200);
    try benchFind(io, out, "find CSS unit", "\\d+(?:px|em|rem|%)", unit_text.items, 200);
    try benchFind(io, out, "find function call", "[A-Za-z_]\\w*\\s*\\(", call_text.items, 200);
    try benchFind(io, out, "find SQL keyword", "(?i)\\b(?:select|from|where|join)\\b", ascii_text.items, 200);
    try benchFind(io, out, "find JSON literal", "\\b(?:true|false|null)\\b", json_text.items, 200);
    try benchFind(io, out, "find blockquote", "(?m)^>.*$", md_text.items, 200);
    try benchFind(io, out, "find ordered list", "(?m)^\\d+\\.\\s", md_text.items, 200);
    try benchFind(io, out, "find query param", "[?&]\\w+=", url_text.items, 200);
    try benchFind(io, out, "find MAC address", "(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", mac_text.items, 200);
    try benchFind(io, out, "find base64 run", "[A-Za-z0-9+/]{20,}", b64_text.items, 200);
    try benchFind(io, out, "find markdown link", "\\[[^\\]]+\\]\\([^)]+\\)", md_text.items, 200);
    try benchFind(io, out, "find YAML key", "(?m)^\\s*[\\w-]+:", config_text.items, 200);
    try benchFind(io, out, "find TOML table", "(?m)^\\[[\\w.]+\\]$", config_text.items, 200);
    try benchFind(io, out, "find template", "\\$\\{[^}]+\\}", template_text.items, 200);
    try benchFind(io, out, "find Windows path", "[A-Za-z]:\\\\[^:*?\"<>|]+", path_text.items, 200);
    try benchFind(io, out, "find CSS selector", "[.#][\\w-]+\\s*\\{", css_text.items, 200);
    try benchFind(io, out, "find slash date", "\\d{2}/\\d{2}/\\d{4}", slash_text.items, 200);
    try benchFind(io, out, "find HTTP request", "(?:GET|POST) /[^ ]+ HTTP/1\\.[01]", ascii_text.items, 200);
    try benchFind(io, out, "find IPv6", "(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}", ipv6_text.items, 200);
    try benchFind(io, out, "find C comment", "/\\*[\\s\\S]*?\\*/", c_text.items, 200);
    try benchFind(io, out, "find markdown image", "!\\[[^\\]]*\\]\\([^)]+\\)", md_text.items, 200);
    try benchFind(io, out, "find HTML tag name", "</?([a-z][a-z0-9]*)\\b", html_text.items, 200);
    try benchFind(io, out, "find shell var", "\\$\\{[^}]+\\}|\\$\\w+", sh_text.items, 200);
    try benchSplit(io, out, "split whitespace (22 KiB)", "\\s+", ascii_text.items, 200);
    try benchSplit(io, out, "split commas (29 KiB)", ",", csv_text.items, 200);
    try benchSplit(io, out, "split lines", "\\n", ascii_text.items, 200);
    try benchSplit(io, out, "split semicolons", ";", code_text.items, 200);
    try benchMatches(io, out, "fullmatch literal", "hello, world!", "hello, world!", 200000);
    try benchMatches(io, out, "fullmatch class", "[A-Za-z0-9._-]+", "User.Name_42", 200000);
    try benchMatches(io, out, "fullmatch xDS-like", "/(?:demo|test)\\.[A-Z][A-Za-z]+/(Get|List)", "/demo.Service/Get", 200000);
    try benchReplace(io, out, "replaceAll a+ -> x", "a+", replace_text.items, "x", 200);
    try benchReplace(io, out, "replaceAll \\A|\\z -> X", "\\A|\\z", ascii_text.items, "X", 200);
    try benchReplace(io, out, "replaceAll digits -> N", "\\d+", number_text.items, "N", 200);

    try out.flush();
}
