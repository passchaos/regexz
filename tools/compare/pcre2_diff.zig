//! Feature differential: regexz vs PCRE2 10.45.
//!
//! Every case is compiled by both engines and, unless the case is
//! compile-only, matched against the same subject. The harness compares the
//! first-match span, every capture slot, the last MARK, and (for `findAll`
//! cases) the whole span sequence. It is deliberately an audit tool, not a
//! gate: mismatches are printed and the process exits non-zero.
//!
//! Build against a local PCRE2 10.45 install (the system library is older):
//!   zig build-exe -O ReleaseFast -lc \
//!       -I/tmp/pcre2-10.45-install/include \
//!       -L/tmp/pcre2-10.45-install/lib -lpcre2-8 \
//!       --dep regexz -Mroot=tools/compare/pcre2_diff.zig -Mregexz=src/root.zig \
//!       -femit-bin=/tmp/regexz-pcre2-diff
//!   /tmp/regexz-pcre2-diff
const std = @import("std");
const regex = @import("regexz");
const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cInclude("pcre2.h");
});

const gpa = std.heap.smp_allocator;

const Mode = enum { find, full, findAll, compile_only };

const base_limits = regex.Limits{ .pcre_vertical_whitespace = true };

const Case = struct {
    name: []const u8,
    pattern: []const u8,
    subject: []const u8 = "",
    mode: Mode = .find,
    /// Byte offset passed to `findFrom` / `pcre2_match`.
    start: usize = 0,
    /// PCRE2 deliberately lacks this construct; regexz accepting it while
    /// PCRE2 rejects it is a documented extension, not a mismatch.
    extension: bool = false,
    limits: regex.Limits = base_limits,
    pcre_options: c_uint = c.PCRE2_UTF,
};

const Span = struct { start: usize, end: usize };

const Pcre = struct {
    code: *c.pcre2_code_8,
    md: *c.pcre2_match_data_8,
    captures: u32,

    fn init(pattern: []const u8, options: c_uint) !Pcre {
        var error_code: c_int = 0;
        var error_offset: usize = 0;
        const code = c.pcre2_compile_8(pattern.ptr, pattern.len, options, &error_code, &error_offset, null) orelse {
            std.debug.print("  pcre2 compile error {d} at {d}\n", .{ error_code, error_offset });
            return error.PcreCompile;
        };
        errdefer c.pcre2_code_free_8(code);
        const md = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return error.OutOfMemory;
        var captures: u32 = 0;
        _ = c.pcre2_pattern_info_8(code, c.PCRE2_INFO_CAPTURECOUNT, &captures);
        return .{ .code = code, .md = md, .captures = captures };
    }

    fn deinit(self: *Pcre) void {
        c.pcre2_match_data_free_8(self.md);
        c.pcre2_code_free_8(self.code);
    }

    fn find(self: *Pcre, subject: []const u8, start: usize, options: c_uint) ?Span {
        const rc = c.pcre2_match_8(self.code, subject.ptr, subject.len, start, c.PCRE2_NO_UTF_CHECK | options, self.md, null);
        if (rc < 0) return null;
        const ov = c.pcre2_get_ovector_pointer_8(self.md);
        return .{ .start = ov[0], .end = ov[1] };
    }

    fn slots(self: *Pcre) [*]const usize {
        return c.pcre2_get_ovector_pointer_8(self.md);
    }

    fn mark(self: *Pcre) ?[]const u8 {
        const ptr = c.pcre2_get_mark_8(self.md);
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }
};

fn runeLenAt(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return 1;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return 1;
    if (len > input.len - offset) return 1;
    return len;
}

fn pcreFindAll(p: *Pcre, subject: []const u8, out: *std.ArrayList(Span)) !void {
    var start: usize = 0;
    var options: c_uint = 0;
    while (start <= subject.len) {
        const span = p.find(subject, start, options) orelse {
            if (options == 0) break;
            if (start >= subject.len) break;
            start += runeLenAt(subject, start);
            options = 0;
            continue;
        };
        try out.append(gpa, span);
        if (span.end > span.start) {
            start = span.end;
            options = 0;
        } else {
            if (span.end == subject.len) break;
            start = span.end;
            options = c.PCRE2_NOTEMPTY_ATSTART | c.PCRE2_ANCHORED;
        }
        if (out.items.len >= 256) break;
    }
}

fn zigFindAll(value: *regex.Regex, subject: []const u8, out: *std.ArrayList(Span)) !void {
    var matches = try value.findAll(gpa, subject);
    defer matches.deinit();
    while (try matches.next()) |m| {
        try out.append(gpa, .{ .start = m.start, .end = m.end });
        if (out.items.len >= 256) break;
    }
}

fn eqlSpans(a: []const Span, b: []const Span) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.start != y.start or x.end != y.end) return false;
    }
    return true;
}

fn printSpans(label: []const u8, spans: []const Span) void {
    std.debug.print("  {s}:", .{label});
    for (spans, 0..) |s, i| {
        if (i >= 8) {
            std.debug.print(" ...({d})", .{spans.len});
            break;
        }
        std.debug.print(" {d}:{d}", .{ s.start, s.end });
    }
    if (spans.len == 0) std.debug.print(" (none)", .{});
    std.debug.print("\n", .{});
}

fn printZigSlots(slots: []const usize, count: usize) void {
    std.debug.print("  zig caps:", .{});
    for (0..count) |i| {
        if (i >= 8) {
            std.debug.print(" ...", .{});
            break;
        }
        const s = slots[2 * i];
        const e = slots[2 * i + 1];
        if (s == std.math.maxInt(usize) or e == std.math.maxInt(usize)) {
            std.debug.print(" -", .{});
        } else {
            std.debug.print(" {d}:{d}", .{ s, e });
        }
    }
    std.debug.print("\n", .{});
}

fn printPcreSlots(slots: [*]const usize, count: u32) void {
    std.debug.print("  pcre caps:", .{});
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (i >= 8) {
            std.debug.print(" ...", .{});
            break;
        }
        const s = slots[2 * i];
        const e = slots[2 * i + 1];
        if (s == std.math.maxInt(usize) or e == std.math.maxInt(usize)) {
            std.debug.print(" -", .{});
        } else {
            std.debug.print(" {d}:{d}", .{ s, e });
        }
    }
    std.debug.print("\n", .{});
}

const Stats = struct {
    total: usize = 0,
    ok: usize = 0,
    extensions: usize = 0,
    limits: usize = 0,
    compile: usize = 0,
    span: usize = 0,
    caps: usize = 0,
    mark: usize = 0,
    findAll: usize = 0,
    error_zig: usize = 0,
    error_pcre: usize = 0,
};

fn runCase(case: Case, stats: *Stats) void {
    stats.total += 1;
    std.debug.print("[{s}] /{s}/ subject={s}\n", .{ case.name, case.pattern, case.subject });

    var value = regex.Regex.init(gpa, case.pattern, case.limits) catch |err| {
        if (err == error.OutOfMemory) @panic("out of memory");
        if (Pcre.init(case.pattern, case.pcre_options)) |p| {
            var pcre = p;
            pcre.deinit();
            if (err == error.RegexLimitExceeded) {
                std.debug.print("  LIMIT compile: regexz={s}, pcre2=ok\n", .{@errorName(err)});
                stats.limits += 1;
            } else {
                std.debug.print("  MISMATCH compile: regexz={s}, pcre2=ok\n", .{@errorName(err)});
                stats.compile += 1;
            }
        } else |_| {
            stats.ok += 1;
        }
        return;
    };
    defer value.deinit();

    var pcre = Pcre.init(case.pattern, case.pcre_options) catch {
        if (case.extension) {
            std.debug.print("  EXTENSION: regexz accepts, pcre2 rejects\n", .{});
            stats.extensions += 1;
        } else {
            std.debug.print("  MISMATCH compile: regexz=ok, pcre2=error\n", .{});
            stats.compile += 1;
        }
        return;
    };
    defer pcre.deinit();

    if (case.extension) {
        std.debug.print("  EXTENSION: both compile, semantics intentionally differ\n", .{});
        stats.extensions += 1;
        return;
    }

    if (value.program.capture_count != pcre.captures) {
        std.debug.print("  MISMATCH capture count: regexz={d}, pcre2={d}\n", .{ value.program.capture_count, pcre.captures });
        stats.compile += 1;
    }

    if (case.mode == .compile_only) {
        stats.ok += 1;
        return;
    }

    if (case.mode == .full) {
        const zig_full = value.matches(gpa, case.subject) catch |err| {
            std.debug.print("  MISMATCH full: regexz error {s}, pcre2 ok\n", .{@errorName(err)});
            stats.error_zig += 1;
            return;
        };
        // Anchoring the original pattern only proves that its preferred
        // branch consumes the input; wrapping it in \A(?:...)\z also finds a
        // longer alternative, which is what "the input fully matches" means.
        const wrapped = std.fmt.allocPrint(gpa, "\\A(?:{s})\\z", .{case.pattern}) catch @panic("out of memory");
        defer gpa.free(wrapped);
        var full_pcre = Pcre.init(wrapped, case.pcre_options) catch {
            std.debug.print("  (full oracle compile failed)\n", .{});
            stats.ok += 1;
            return;
        };
        defer full_pcre.deinit();
        const pcre_full = full_pcre.find(case.subject, 0, 0) != null;
        if (zig_full != pcre_full) {
            std.debug.print("  MISMATCH full: regexz={}, pcre2={}\n", .{ zig_full, pcre_full });
            stats.span += 1;
        } else {
            stats.ok += 1;
        }
        return;
    }

    if (case.mode == .findAll) {
        var zig_spans: std.ArrayList(Span) = .empty;
        defer zig_spans.deinit(gpa);
        zigFindAll(&value, case.subject, &zig_spans) catch |err| {
            std.debug.print("  MISMATCH findAll: regexz error {s}\n", .{@errorName(err)});
            stats.error_zig += 1;
            return;
        };
        var pcre_spans: std.ArrayList(Span) = .empty;
        defer pcre_spans.deinit(gpa);
        pcreFindAll(&pcre, case.subject, &pcre_spans) catch |err| {
            std.debug.print("  MISMATCH findAll: pcre2 error {s}\n", .{@errorName(err)});
            stats.error_pcre += 1;
            return;
        };
        if (!eqlSpans(zig_spans.items, pcre_spans.items)) {
            std.debug.print("  MISMATCH findAll\n", .{});
            printSpans("zig", zig_spans.items);
            printSpans("pcre", pcre_spans.items);
            stats.findAll += 1;
        } else {
            stats.ok += 1;
        }
        return;
    }

    var captures = regex.Captures.init(gpa, value.program) catch @panic("out of memory");
    defer captures.deinit(gpa);
    const zm = value.findFrom(gpa, case.subject, case.start, &captures) catch |err| {
        const pspan = pcre.find(case.subject, case.start, 0);
        if (pspan != null) {
            std.debug.print("  MISMATCH find: regexz error {s}, pcre2 matched {d}:{d}\n", .{ @errorName(err), pspan.?.start, pspan.?.end });
            stats.error_zig += 1;
        } else {
            stats.ok += 1;
        }
        return;
    };
    const pspan = pcre.find(case.subject, case.start, 0);
    if (zm == null and pspan == null) {
        stats.ok += 1;
        return;
    }
    if (zm == null or pspan == null) {
        std.debug.print("  MISMATCH find: regexz={s}, pcre2={s}\n", .{
            if (zm) |m| if (m.start == m.end) "empty" else "match" else "none",
            if (pspan) |s| if (s.start == s.end) "empty" else "match" else "none",
        });
        if (zm) |m| std.debug.print("  zig span: {d}:{d}\n", .{ m.start, m.end });
        if (pspan) |s| std.debug.print("  pcre span: {d}:{d}\n", .{ s.start, s.end });
        stats.span += 1;
        return;
    }
    const z = zm.?;
    const p = pspan.?;
    var bad = false;
    if (z.start != p.start or z.end != p.end) {
        std.debug.print("  MISMATCH span: regexz {d}:{d}, pcre2 {d}:{d}\n", .{ z.start, z.end, p.start, p.end });
        stats.span += 1;
        bad = true;
    }

    const zcount: usize = @as(usize, value.program.capture_count) + 1;
    const pcount: usize = @as(usize, pcre.captures) + 1;
    const common = @min(zcount, pcount);
    const ov = pcre.slots();
    var cap_bad = false;
    for (0..common) |i| {
        const zs = z.slots[2 * i];
        const ze = z.slots[2 * i + 1];
        const ps = ov[2 * i];
        const pe = ov[2 * i + 1];
        const z_unset = zs == std.math.maxInt(usize) or ze == std.math.maxInt(usize);
        const p_unset = ps == std.math.maxInt(usize) or pe == std.math.maxInt(usize);
        if (z_unset != p_unset or (!z_unset and (zs != ps or ze != pe))) {
            cap_bad = true;
        }
    }
    if (cap_bad) {
        std.debug.print("  MISMATCH captures\n", .{});
        printZigSlots(z.slots, common);
        printPcreSlots(ov, @intCast(common));
        stats.caps += 1;
        bad = true;
    }

    const zmark = z.mark;
    const pmark = pcre.mark();
    const mark_equal = if (zmark == null and pmark == null)
        true
    else if (zmark != null and pmark != null)
        std.mem.eql(u8, zmark.?, pmark.?)
    else
        false;
    if (!mark_equal) {
        std.debug.print("  MISMATCH mark: regexz={s}, pcre2={s}\n", .{
            if (zmark) |m| m else "(none)",
            if (pmark) |m| m else "(none)",
        });
        stats.mark += 1;
        bad = true;
    }

    if (!bad) stats.ok += 1;
}

const cases = [_]Case{
    // --- backslash escapes -------------------------------------------------
    .{ .name = "esc-a", .pattern = "\\a", .subject = "\x07" },
    .{ .name = "esc-e", .pattern = "\\e", .subject = "\x1b" },
    .{ .name = "esc-f", .pattern = "\\f", .subject = "\x0c" },
    .{ .name = "esc-n", .pattern = "\\n", .subject = "\n" },
    .{ .name = "esc-r", .pattern = "\\r", .subject = "\r" },
    .{ .name = "esc-t", .pattern = "\\t", .subject = "\t" },
    .{ .name = "esc-v-vt", .pattern = "\\v", .subject = "\x0b" },
    .{ .name = "esc-v-nbsp", .pattern = "\\v", .subject = "\u{00a0}" },
    .{ .name = "esc-xhh", .pattern = "\\x41", .subject = "A" },
    .{ .name = "esc-xbrace", .pattern = "\\x{1F600}", .subject = "\u{1F600}" },
    .{ .name = "esc-obrace", .pattern = "\\o{101}", .subject = "A" },
    .{ .name = "esc-cA", .pattern = "\\cA", .subject = "\x01" },
    .{ .name = "esc-octal", .pattern = "\\101", .subject = "A" },
    .{ .name = "esc-octal-0", .pattern = "\\0", .subject = "\x00" },
    .{ .name = "esc-Q", .pattern = "\\Qa.b\\E", .subject = "a.b" },
    .{ .name = "esc-Q-nomatch", .pattern = "\\Qa.b\\E", .subject = "axb" },
    .{ .name = "esc-Q-class", .pattern = "[\\Qa.b\\E]+", .subject = "a.b" },
    .{ .name = "esc-N-notnewline", .pattern = "\\N", .subject = "a" },
    .{ .name = "esc-N-newline", .pattern = "\\N", .subject = "\n" },
    .{ .name = "esc-h", .pattern = "\\h+", .subject = " \t" },
    .{ .name = "esc-H", .pattern = "\\H+", .subject = "abc" },
    .{ .name = "esc-R-crlf", .pattern = "\\R", .subject = "\r\n" },
    .{ .name = "esc-R-ls", .pattern = "\\R", .subject = "\u{2028}" },
    .{ .name = "esc-X-combining", .pattern = "\\X", .subject = "e\u{0301}" },
    .{ .name = "esc-X-zwj", .pattern = "\\X", .subject = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}" },
    .{ .name = "esc-C", .pattern = "\\C", .subject = "\u{00e9}" },
    .{ .name = "esc-K", .pattern = "a\\Kb", .subject = "ab" },
    .{ .name = "esc-K-multi", .pattern = "a\\Kb\\Kc", .subject = "abc" },
    .{ .name = "esc-G-start", .pattern = "\\Gab", .subject = "ab" },
    .{ .name = "esc-G-offset", .pattern = "\\Gab", .subject = "xab", .start = 1 },
    .{ .name = "esc-A", .pattern = "\\Aab", .subject = "ab" },
    .{ .name = "esc-Z-final-lf", .pattern = "ab\\Z", .subject = "ab\n" },
    .{ .name = "esc-z", .pattern = "ab\\z", .subject = "ab\n" },
    .{ .name = "esc-b", .pattern = "\\bab\\b", .subject = "ab" },
    .{ .name = "esc-B", .pattern = "a\\Bb", .subject = "ab" },
    .{ .name = "esc-b-ucp", .pattern = "(*UCP)\\b\u{00e9}\\b", .subject = "\u{00e9}" },
    .{ .name = "esc-b-no-ucp", .pattern = "\\b\u{00e9}", .subject = "\u{00e9}" },
    .{ .name = "esc-N-U", .pattern = "\\N{U+1F600}", .subject = "\u{1F600}" },

    // --- Perl classes / properties ----------------------------------------
    .{ .name = "cls-d-ascii", .pattern = "\\d+", .subject = "\u{0661}\u{0662}" },
    .{ .name = "cls-d-ucp", .pattern = "(*UCP)\\d+", .subject = "\u{0661}\u{0662}" },
    .{ .name = "cls-w-ascii", .pattern = "\\w+", .subject = "caf\u{00e9}" },
    .{ .name = "cls-w-ucp", .pattern = "(*UCP)\\w+", .subject = "caf\u{00e9}" },
    .{ .name = "cls-s-ascii", .pattern = "\\s+", .subject = "\u{00a0}" },
    .{ .name = "cls-s-ucp", .pattern = "(*UCP)\\s+", .subject = "\u{00a0}" },
    .{ .name = "cls-posix-alpha", .pattern = "[[:alpha:]]+", .subject = "\u{00e9}" },
    .{ .name = "cls-posix-alpha-ucp", .pattern = "(*UCP)[[:alpha:]]+", .subject = "\u{00e9}" },
    .{ .name = "cls-posix-digit-ucp", .pattern = "(*UCP)[[:digit:]]+", .subject = "\u{0661}" },
    .{ .name = "cls-posix-upper-ucp", .pattern = "(*UCP)[[:upper:]]+", .subject = "\u{00c9}" },
    .{ .name = "cls-posix-xdigit", .pattern = "[[:xdigit:]]+", .subject = "aF09" },
    .{ .name = "cls-posix-word", .pattern = "[[:word:]]+", .subject = "a_1" },
    .{ .name = "cls-posix-graph", .pattern = "[[:graph:]]+", .subject = "!~a" },
    .{ .name = "cls-posix-print", .pattern = "[[:print:]]+", .subject = " a" },
    .{ .name = "cls-posix-punct", .pattern = "[[:punct:]]+", .subject = ".,;" },
    .{ .name = "cls-posix-cntrl", .pattern = "[[:cntrl:]]+", .subject = "\x01\x02" },
    .{ .name = "cls-posix-space", .pattern = "[[:space:]]+", .subject = " \t\n" },
    .{ .name = "cls-posix-blank", .pattern = "[[:blank:]]+", .subject = " \t" },
    .{ .name = "cls-posix-ascii", .pattern = "[[:ascii:]]+", .subject = "abc" },
    .{ .name = "cls-posix-neg", .pattern = "[[:^alpha:]]+", .subject = "123" },
    .{ .name = "cls-p-L", .pattern = "\\p{L}+", .subject = "abc\u{00e9}" },
    .{ .name = "cls-p-neg", .pattern = "\\P{L}+", .subject = "123" },
    .{ .name = "cls-p-caret", .pattern = "\\p{^L}+", .subject = "123" },
    .{ .name = "cls-p-gc-long", .pattern = "\\p{General_Category=Letter}+", .subject = "ab", .extension = true },
    .{ .name = "cls-p-Lu", .pattern = "\\p{Lu}+", .subject = "AB" },
    .{ .name = "cls-p-upper-long", .pattern = "\\p{Uppercase_Letter}+", .subject = "AB", .extension = true },
    .{ .name = "cls-p-Lamp", .pattern = "\\p{L&}+", .subject = "aB" },
    .{ .name = "cls-p-sc", .pattern = "\\p{Script=Greek}+", .subject = "\u{03b1}\u{03b2}" },
    .{ .name = "cls-p-sc-short", .pattern = "\\p{sc=Grek}+", .subject = "\u{03b1}\u{03b2}" },
    .{ .name = "cls-p-scx", .pattern = "\\p{Script_Extensions=Greek}+", .subject = "\u{03b1}" },
    .{ .name = "cls-p-Xan", .pattern = "\\p{Xan}+", .subject = "a1" },
    .{ .name = "cls-p-Xwd", .pattern = "\\p{Xwd}+", .subject = "a_1" },
    .{ .name = "cls-p-Xsp", .pattern = "\\p{Xsp}+", .subject = " \t\n" },
    .{ .name = "cls-p-Xps", .pattern = "\\p{Xps}+", .subject = "\x0b" },
    .{ .name = "cls-p-Xuc", .pattern = "\\p{Xuc}+", .subject = "\u{00e9}" },
    .{ .name = "cls-p-Any", .pattern = "\\p{Any}", .subject = "\u{1F600}" },
    .{ .name = "cls-p-Cn", .pattern = "\\p{Cn}", .subject = "\u{0378}" },
    .{ .name = "cls-p-Assigned", .pattern = "\\p{Assigned}", .subject = "a", .extension = true },
    .{ .name = "cls-p-Alphabetic", .pattern = "\\p{Alphabetic}+", .subject = "ab" },
    .{ .name = "cls-p-Emoji", .pattern = "\\p{Emoji}+", .subject = "\u{1F600}" },
    .{ .name = "cls-p-WhiteSpace", .pattern = "\\p{White_Space}+", .subject = " \t" },
    .{ .name = "cls-p-bc", .pattern = "\\p{Bidi_Class=AL}+", .subject = "\u{0627}" },
    .{ .name = "cls-p-bc-short", .pattern = "\\p{bc=AL}+", .subject = "\u{0627}" },

    // --- character classes -------------------------------------------------
    .{ .name = "class-basic", .pattern = "[abc]+", .subject = "cabx" },
    .{ .name = "class-range", .pattern = "[a-z]+", .subject = "abcX" },
    .{ .name = "class-neg", .pattern = "[^a-z]+", .subject = "ABc" },
    .{ .name = "class-rbrace", .pattern = "[]]+", .subject = "]]" },
    .{ .name = "class-neg-rbrace", .pattern = "[^]]+", .subject = "ab]" },
    .{ .name = "class-dash-first", .pattern = "[-a]+", .subject = "-a" },
    .{ .name = "class-dash-last", .pattern = "[a-]+", .subject = "a-" },
    .{ .name = "class-caret", .pattern = "[\\^]+", .subject = "^^" },
    .{ .name = "class-b-backspace", .pattern = "[\\b]", .subject = "\x08" },
    .{ .name = "class-Q", .pattern = "[\\Qa-z\\E]+", .subject = "a-z" },
    .{ .name = "class-utf-range", .pattern = "[\u{00e9}-\u{00ea}]+", .subject = "\u{00e9}\u{00ea}" },
    .{ .name = "class-d-inside", .pattern = "[\\d]+", .subject = "12" },
    .{ .name = "class-D-inside", .pattern = "[\\D]+", .subject = "ab" },
    .{ .name = "class-h-inside", .pattern = "[\\h]+", .subject = " \t" },
    .{ .name = "class-v-inside", .pattern = "[\\v]+", .subject = "\n\r" },
    .{ .name = "class-nested-posix", .pattern = "[[:alpha:][:digit:]]+", .subject = "a1" },

    // --- quantifiers --------------------------------------------------------
    .{ .name = "quant-star", .pattern = "a*", .subject = "aaa" },
    .{ .name = "quant-lazy", .pattern = "a*?b", .subject = "aaab" },
    .{ .name = "quant-possessive", .pattern = "a*+b", .subject = "aaab" },
    .{ .name = "quant-possessive-fail", .pattern = "a*+a", .subject = "aaa" },
    .{ .name = "quant-plus", .pattern = "a+", .subject = "aaa" },
    .{ .name = "quant-opt", .pattern = "ab?c", .subject = "ac" },
    .{ .name = "quant-count", .pattern = "a{2,3}", .subject = "aaaa" },
    .{ .name = "quant-open", .pattern = "a{2,}", .subject = "aaaa" },
    .{ .name = "quant-upto", .pattern = "a{,3}", .subject = "aaaa" },
    .{ .name = "quant-zero", .pattern = "a{0}b", .subject = "b" },
    .{ .name = "quant-group-possessive", .pattern = "(?:ab)*+", .subject = "abab" },
    .{ .name = "quant-nested", .pattern = "(a+)+b", .subject = "aaab" },
    .{ .name = "quant-lazy-opt", .pattern = "a??b", .subject = "ab" },

    // --- groups and captures ------------------------------------------------
    .{ .name = "group-captures", .pattern = "(a)(b)", .subject = "ab" },
    .{ .name = "group-noncapture", .pattern = "(?:ab)+", .subject = "abab" },
    .{ .name = "group-named-angle", .pattern = "(?<x>a)b", .subject = "ab" },
    .{ .name = "group-named-P", .pattern = "(?P<x>a)b", .subject = "ab" },
    .{ .name = "group-named-quote", .pattern = "(?'x'a)b", .subject = "ab" },
    .{ .name = "group-dup-J", .pattern = "(?J)(?<x>a)(?<x>b)", .subject = "ab" },
    .{ .name = "group-dup-J-backref", .pattern = "(?J)(?<x>a)|(?<x>b)\\k<x>", .subject = "bb" },
    .{ .name = "group-branch-reset", .pattern = "(?|(a)|(b))", .subject = "b" },
    .{ .name = "group-branch-reset-named", .pattern = "(?|(?<x>a)|(?<x>b))", .subject = "b" },
    .{ .name = "group-atomic", .pattern = "(?>a+)a", .subject = "aaa" },
    .{ .name = "group-atomic-alt", .pattern = "(?>a|ab)c", .subject = "abc" },
    .{ .name = "group-define", .pattern = "(?(DEFINE)(?<d>\\d+))(?&d)", .subject = "123" },
    .{ .name = "group-no-auto-capture", .pattern = "(?n)(a)(?<x>b)", .subject = "ab" },
    .{ .name = "group-option-scope", .pattern = "(?i:a)b", .subject = "Ab" },
    .{ .name = "group-option-scope-fail", .pattern = "(?i:a)b", .subject = "AB" },
    .{ .name = "group-option-reset", .pattern = "(?i)(?^)a", .subject = "A" },
    .{ .name = "group-option-negate", .pattern = "(?i)(?-i:a)", .subject = "A" },
    .{ .name = "group-empty", .pattern = "()", .subject = "" },
    .{ .name = "group-capture-reset", .pattern = "(a|(b))+", .subject = "ab" },

    // --- assertions ---------------------------------------------------------
    .{ .name = "look-pos", .pattern = "a(?=b)b", .subject = "ab" },
    .{ .name = "look-neg", .pattern = "a(?!b)c", .subject = "ac" },
    .{ .name = "lookbehind-pos", .pattern = "(?<=a)b", .subject = "ab" },
    .{ .name = "lookbehind-neg", .pattern = "(?<!a)b", .subject = "cb" },
    .{ .name = "lookbehind-alt", .pattern = "(?<=a|bc)d", .subject = "bcd" },
    .{ .name = "lookbehind-quant", .pattern = "(?<=a{1,3})b", .subject = "aaab" },
    .{ .name = "lookbehind-star", .pattern = "(?<=a*)b", .subject = "aaab", .extension = true },
    .{ .name = "lookbehind-plus", .pattern = "(?<=a+)b", .subject = "aaab", .extension = true },
    .{ .name = "lookbehind-nested-alt", .pattern = "(?<=(?:ab|a)c)d", .subject = "acd" },
    .{ .name = "lookbehind-neg-alt", .pattern = "(?<!a|bc)d", .subject = "bd" },
    .{ .name = "lookbehind-K", .pattern = "(?<=a\\K)b", .subject = "ab", .extension = true },
    .{ .name = "non-atomic-la", .pattern = "(?*ab)abc", .subject = "xabc" },
    .{ .name = "non-atomic-la-verb", .pattern = "(*napla:ab)abc", .subject = "xabc" },
    .{ .name = "non-atomic-lb", .pattern = "(?<*a{1,3})b", .subject = "aaab" },
    .{ .name = "non-atomic-lb-verb", .pattern = "(*naplb:a{1,3})b", .subject = "aaab" },
    .{ .name = "script-run", .pattern = "(*sr:\\w+)", .subject = "abc" },
    .{ .name = "script-run-mixed", .pattern = "(*sr:\\w+)", .subject = "a\u{0431}" },
    .{ .name = "script-run-asr", .pattern = "(*asr:\\w+)", .subject = "abc" },
    .{ .name = "scan-substring", .pattern = "\\b(\\w++)(*scs:(1).+rh)", .subject = "arithmetic" },
    .{ .name = "scan-substring-name", .pattern = "(?<x>\\w+)(*scs:('x')end)", .subject = "weekend" },
    .{ .name = "scan-substring-rel", .pattern = "(\\w+)(*scs:(-1)end)", .subject = "weekend" },

    // --- backreferences -----------------------------------------------------
    .{ .name = "backref-num", .pattern = "(a)\\1", .subject = "aa" },
    .{ .name = "backref-num-fail", .pattern = "(a)\\1", .subject = "ab" },
    .{ .name = "backref-multi", .pattern = "(a)(b)\\2\\1", .subject = "abba" },
    .{ .name = "backref-g-brace", .pattern = "(a)\\g{1}", .subject = "aa" },
    .{ .name = "backref-g-rel", .pattern = "(a)\\g{-1}", .subject = "aa" },
    .{ .name = "backref-k-angle", .pattern = "(?<x>a)\\k<x>", .subject = "aa" },
    .{ .name = "backref-k-quote", .pattern = "(?<x>a)\\k'x'", .subject = "aa" },
    .{ .name = "backref-k-brace", .pattern = "(?<x>a)\\k{x}", .subject = "aa" },
    .{ .name = "backref-P-eq", .pattern = "(?P<x>a)(?P=x)", .subject = "aa" },
    .{ .name = "backref-unset", .pattern = "(a)|b\\1", .subject = "b" },
    .{ .name = "backref-forward", .pattern = "(\\2two|(one))+", .subject = "onetwo" },
    .{ .name = "backref-case", .pattern = "(?i)(a)\\1", .subject = "aA" },

    // --- conditionals -------------------------------------------------------
    .{ .name = "cond-group-yes", .pattern = "(a)?(?(1)b|c)", .subject = "ab" },
    .{ .name = "cond-group-no", .pattern = "(a)?(?(1)b|c)", .subject = "c" },
    .{ .name = "cond-name", .pattern = "(?<x>a)?(?(<x>)b|c)", .subject = "ab" },
    .{ .name = "cond-name-quote", .pattern = "(?<x>a)?(?('x')b|c)", .subject = "ab" },
    .{ .name = "cond-assert", .pattern = "(?(?=a)ab|cd)", .subject = "ab" },
    .{ .name = "cond-assert-neg", .pattern = "(?(?!a)cd|ab)", .subject = "cd" },
    .{ .name = "cond-version", .pattern = "(?(VERSION>=10.0)yes|no)", .subject = "yes" },
    .{ .name = "cond-version-eq", .pattern = "(?(VERSION=10.45)yes|no)", .subject = "yes" },
    .{ .name = "cond-recursion", .pattern = "(a)(?(R)b|c)", .subject = "ab" },

    // --- recursion and subroutines -----------------------------------------
    .{ .name = "recurse-parens", .pattern = "\\((?:[^()]|(?R))*\\)", .subject = "(a(b)c)" },
    .{ .name = "recurse-zero", .pattern = "\\((?:[^()]|(?0))*\\)", .subject = "(ab)" },
    .{ .name = "subroutine-num", .pattern = "(ab)(?1)", .subject = "abab" },
    .{ .name = "subroutine-minus", .pattern = "(a)(b)(?-1)", .subject = "abb" },
    .{ .name = "subroutine-name", .pattern = "(?<x>ab)(?&x)", .subject = "abab" },
    .{ .name = "subroutine-P", .pattern = "(?P<x>ab)(?P>x)", .subject = "abab" },
    .{ .name = "subroutine-g-angle", .pattern = "(?<x>ab)\\g<x>", .subject = "abab" },
    .{ .name = "subroutine-g-quote", .pattern = "(?<x>ab)\\g'x'", .subject = "abab" },
    .{ .name = "recurse-named", .pattern = "(?<x>a(?&x)?b)", .subject = "aabb" },

    // --- backtracking verbs -------------------------------------------------
    .{ .name = "verb-fail", .pattern = "a(*FAIL)|b", .subject = "b" },
    .{ .name = "verb-accept", .pattern = "a(*ACCEPT)b", .subject = "ab" },
    .{ .name = "verb-accept-group", .pattern = "(a(*ACCEPT)b)c", .subject = "abc" },
    .{ .name = "verb-prune", .pattern = "a(*PRUNE)b|a", .subject = "ab" },
    .{ .name = "verb-skip", .pattern = "a(*SKIP)b|a", .subject = "ab" },
    .{ .name = "verb-commit", .pattern = "a(*COMMIT)b|a", .subject = "ab" },
    .{ .name = "verb-then", .pattern = "(a(*THEN)b|c)", .subject = "ac" },
    .{ .name = "verb-mark", .pattern = "(*MARK:m)a", .subject = "a" },
    .{ .name = "verb-mark-alt", .pattern = "(*MARK:a)x|(*MARK:b)y", .subject = "y" },
    .{ .name = "verb-mark-prune", .pattern = "(*MARK:a)a(*PRUNE)b|a", .subject = "ab" },
    .{ .name = "verb-notempty", .pattern = "(*NOTEMPTY)a*", .subject = "" },
    .{ .name = "verb-notempty-atstart", .pattern = "(*NOTEMPTY_ATSTART)a*", .subject = "" },

    // --- newline conventions ------------------------------------------------
    .{ .name = "nl-cr", .pattern = "(*CR)(?m)^b", .subject = "a\rb" },
    .{ .name = "nl-lf", .pattern = "(*LF)(?m)^b", .subject = "a\nb" },
    .{ .name = "nl-crlf", .pattern = "(*CRLF)(?m)^b", .subject = "a\r\nb" },
    .{ .name = "nl-anycrlf", .pattern = "(*ANYCRLF)(?m)^b", .subject = "a\rb" },
    .{ .name = "nl-any", .pattern = "(*ANY)(?m)^b", .subject = "a\u{2028}b" },
    .{ .name = "nl-nul", .pattern = "(*NUL)(?m)^b", .subject = "a\x00b" },
    .{ .name = "nl-dot-cr", .pattern = "(*CR).", .subject = "a\rb" },
    .{ .name = "nl-dollar-crlf", .pattern = "(*CRLF)a$", .subject = "a\r\nb" },
    .{ .name = "nl-Z-anycrlf", .pattern = "(*ANYCRLF)a\\Z", .subject = "a\r\n" },
    .{ .name = "nl-R-bsr-anycrlf", .pattern = "(*BSR_ANYCRLF)\\R", .subject = "\u{2028}" },
    .{ .name = "nl-R-bsr-unicode", .pattern = "(*BSR_UNICODE)\\R", .subject = "\u{2028}" },
    .{ .name = "nl-dot-s", .pattern = "(*ANY)(?s).", .subject = "\u{2028}" },
    .{ .name = "nl-N-cr", .pattern = "(*CR)\\N", .subject = "\r" },

    // --- options and caseless matching -------------------------------------
    .{ .name = "opt-i", .pattern = "(?i)abc", .subject = "ABC" },
    .{ .name = "opt-i-sigma", .pattern = "(?i)\u{03c3}", .subject = "\u{03a3}" },
    .{ .name = "opt-i-kelvin", .pattern = "(?i)k", .subject = "\u{212a}" },
    .{ .name = "opt-i-long-s", .pattern = "(?i)s", .subject = "\u{017f}" },
    .{ .name = "opt-i-sharp-s", .pattern = "(?i)\u{00df}", .subject = "\u{1e9e}" },
    .{ .name = "opt-i-class", .pattern = "(?i)[a-z]+", .subject = "ABC" },
    .{ .name = "opt-i-greek-class", .pattern = "(?i)[\u{03b1}-\u{03c9}]+", .subject = "\u{0391}\u{0392}" },
    .{ .name = "opt-turkish", .pattern = "(*TURKISH_CASING)(?i)i", .subject = "\u{0130}" },
    .{ .name = "opt-caseless-restrict", .pattern = "(?ri)abc", .subject = "ABC" },
    .{ .name = "opt-caseless-restrict-unicode", .pattern = "(?ri)\u{00e9}", .subject = "\u{00c9}" },
    .{ .name = "opt-U", .pattern = "(?U)a+", .subject = "aaa" },
    .{ .name = "opt-x", .pattern = "(?x) a b", .subject = "ab" },
    .{ .name = "opt-xx", .pattern = "(?xx)[ a ]", .subject = "a" },
    .{ .name = "opt-s", .pattern = "(?s).", .subject = "\n" },
    .{ .name = "opt-m", .pattern = "(?m)^b", .subject = "a\nb" },
    .{ .name = "opt-aD", .pattern = "(*UCP)(?aD)\\d", .subject = "\u{0661}" },
    .{ .name = "opt-aS", .pattern = "(*UCP)(?aS)\\s", .subject = "\u{00a0}" },
    .{ .name = "opt-aW", .pattern = "(*UCP)(?aW)\\w", .subject = "\u{00e9}" },
    .{ .name = "opt-aP", .pattern = "(*UCP)(?aP)[[:alpha:]]", .subject = "\u{00e9}" },
    .{ .name = "opt-aT", .pattern = "(*UCP)(?aT)[[:digit:]]", .subject = "\u{0661}" },
    .{ .name = "opt-comment", .pattern = "(?#comment)abc", .subject = "abc" },

    // --- anchors ------------------------------------------------------------
    .{ .name = "anchor-A", .pattern = "\\Aabc", .subject = "abc" },
    .{ .name = "anchor-dollar-final", .pattern = "abc$", .subject = "abc\n" },
    .{ .name = "anchor-dollar-crlf", .pattern = "abc$", .subject = "abc\r\n" },
    .{ .name = "anchor-dollar-endonly", .pattern = "abc$", .subject = "abc\n", .limits = .{ .pcre_vertical_whitespace = true, .dollar_endonly = true }, .pcre_options = c.PCRE2_UTF | c.PCRE2_DOLLAR_ENDONLY },
    .{ .name = "anchor-multiline-dollar", .pattern = "(?m)abc$", .subject = "abc\nx" },
    .{ .name = "anchor-Z-crlf", .pattern = "(*CRLF)a\\Z", .subject = "a\r\n" },

    // --- dot / \N -----------------------------------------------------------
    .{ .name = "dot-s-crlf", .pattern = "(?s).", .subject = "\r\n" },
    .{ .name = "dot-s-ls", .pattern = "(?s).", .subject = "\u{2028}" },
    .{ .name = "dot-N-cr", .pattern = "\\N", .subject = "\r" },

    // --- start-of-pattern directives ---------------------------------------
    .{ .name = "start-UTF", .pattern = "(*UTF)abc", .subject = "abc" },
    .{ .name = "start-UCP", .pattern = "(*UCP)\\w+", .subject = "caf\u{00e9}" },
    .{ .name = "start-no-auto-possess", .pattern = "(*NO_AUTO_POSSESS)a+", .subject = "aaa" },
    .{ .name = "start-no-start-opt", .pattern = "(*NO_START_OPT)a+", .subject = "aaa" },
    .{ .name = "start-no-dotstar", .pattern = "(*NO_DOTSTAR_ANCHOR)a+", .subject = "aaa" },
    .{ .name = "start-no-jit", .pattern = "(*NO_JIT)a+", .subject = "aaa" },
    .{ .name = "start-caseless-restrict", .pattern = "(*CASELESS_RESTRICT)(?i)abc", .subject = "ABC" },
    .{ .name = "start-turkish", .pattern = "(*TURKISH_CASING)(?i)i", .subject = "\u{0130}" },

    // --- findAll sequences (non-nullable patterns) --------------------------
    .{ .name = "all-words", .pattern = "\\w+", .subject = " a bb ccc ", .mode = .findAll },
    .{ .name = "all-digits", .pattern = "\\d+", .subject = "1 22 333", .mode = .findAll },
    .{ .name = "all-alt", .pattern = "ab|cd", .subject = "ab cd ab", .mode = .findAll },
    .{ .name = "all-lookahead", .pattern = "a(?=b)", .subject = "ab ab", .mode = .findAll },
    .{ .name = "all-backref", .pattern = "(a)\\1", .subject = "aa a aa", .mode = .findAll },
    .{ .name = "all-K", .pattern = "a\\Kb", .subject = "abab", .mode = .findAll },
    .{ .name = "all-notempty", .pattern = "(*NOTEMPTY)\\w*", .subject = "ab cd", .mode = .findAll },

    // --- full match ---------------------------------------------------------
    .{ .name = "full-lit", .pattern = "abc", .subject = "abc", .mode = .full },
    .{ .name = "full-prefix", .pattern = "abc", .subject = "abcd", .mode = .full },
    .{ .name = "full-alt", .pattern = "a|ab", .subject = "ab", .mode = .full },
    .{ .name = "full-look", .pattern = "a(?=b)b", .subject = "ab", .mode = .full },
    .{ .name = "full-backref", .pattern = "(a)\\1", .subject = "aa", .mode = .full },
    .{ .name = "full-atomic", .pattern = "(?>a+)a", .subject = "aaa", .mode = .full },
    .{ .name = "full-K", .pattern = "a\\Kb", .subject = "ab", .mode = .full },

    // --- limits and invalid syntax (compile agreement) ----------------------
    .{ .name = "limit-repeat-default", .pattern = "a{1001}", .subject = "", .mode = .compile_only },
    .{ .name = "limit-repeat-raised", .pattern = "a{1001}", .subject = "", .mode = .compile_only, .limits = .{ .pcre_vertical_whitespace = true, .max_repeat = 65535 } },
    .{ .name = "limit-repeat-max", .pattern = "a{65535}", .subject = "", .mode = .compile_only, .limits = .{ .pcre_vertical_whitespace = true, .max_repeat = 65535 } },
    .{ .name = "invalid-p", .pattern = "\\p{NoSuchProperty}", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-x-empty", .pattern = "\\x", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-c-empty", .pattern = "\\c", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-g-zero", .pattern = "\\g{0}", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-unclosed-class", .pattern = "[a", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-unclosed-group", .pattern = "(a", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-quant", .pattern = "*a", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-backref-missing", .pattern = "\\9", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-dup-name-no-J", .pattern = "(?<x>a)(?<x>b)", .subject = "", .mode = .compile_only },
    .{ .name = "invalid-lookbehind-K", .pattern = "(?<=\\Ka)b", .subject = "", .mode = .compile_only, .extension = true },

    // --- PCRE2 10.43-10.45 syntax and semantics ----------------------------
    .{ .name = "quant-upto-lazy", .pattern = "a{,2}?b", .subject = "aaab" },
    .{ .name = "quant-space-open", .pattern = "a{ 2, 3 }", .subject = "aaa" },
    .{ .name = "quant-space-before-comma", .pattern = "a{2 ,3}", .subject = "aaa" },
    .{ .name = "quant-space-after-comma", .pattern = "a{2, 3}", .subject = "aaa" },
    .{ .name = "esc-x-space", .pattern = "\\x{ 41 }", .subject = "A" },
    .{ .name = "esc-o-space", .pattern = "\\o{ 101 }", .subject = "A" },
    .{ .name = "esc-E-alone", .pattern = "\\Eabc", .subject = "abc" },
    .{ .name = "esc-c-question", .pattern = "\\c?", .subject = "\x7f" },
    .{ .name = "esc-c-at", .pattern = "\\c@", .subject = "\x00" },
    .{ .name = "esc-p-Greek", .pattern = "\\p{Greek}+", .subject = "\u{03b1}\u{03b2}" },
    .{ .name = "esc-p-script-colon", .pattern = "\\p{Script:Greek}+", .subject = "\u{03b1}\u{03b2}" },
    .{ .name = "esc-p-sc-colon", .pattern = "\\p{sc:Grek}+", .subject = "\u{03b1}\u{03b2}" },
    .{ .name = "esc-p-scx-colon", .pattern = "\\p{scx:Grek}+", .subject = "\u{03b1}" },
    .{ .name = "caseless-Lu", .pattern = "(?i)\\p{Lu}+", .subject = "abc" },
    .{ .name = "caseless-Ll", .pattern = "(?i)\\p{Ll}+", .subject = "ABC" },
    .{ .name = "caseless-Lt", .pattern = "(?i)\\p{Lt}+", .subject = "abc" },
    .{ .name = "verb-accept-name", .pattern = "(*ACCEPT:m)a", .subject = "a" },
    .{ .name = "verb-prune-name", .pattern = "(*MARK:m)a(*PRUNE:m)b|a", .subject = "ab" },
    .{ .name = "verb-skip-name", .pattern = "(*MARK:m)a(*SKIP:m)b|a", .subject = "ab" },
    .{ .name = "verb-then-name", .pattern = "(*MARK:m)(a(*THEN:m)b|c)", .subject = "ac" },
    .{ .name = "verb-commit-name", .pattern = "(*MARK:m)a(*COMMIT:m)b|a", .subject = "ab" },
    .{ .name = "callout-number", .pattern = "(?C1)abc", .subject = "abc" },
    .{ .name = "callout-zero", .pattern = "(?C)abc", .subject = "abc" },
    .{ .name = "callout-string", .pattern = "(?C'str')abc", .subject = "abc" },
    .{ .name = "callout-255", .pattern = "(?C255)abc", .subject = "abc" },
    .{ .name = "class-R-invalid", .pattern = "[\\R]", .subject = "", .mode = .compile_only },
    .{ .name = "class-X-invalid", .pattern = "[\\X]", .subject = "", .mode = .compile_only },
    .{ .name = "lookbehind-C", .pattern = "(?<=\\C)b", .subject = "ab", .extension = true },
    .{ .name = "backref-g-name-forward", .pattern = "\\g{x}(?<x>a)", .subject = "aa" },
    .{ .name = "cond-R-name", .pattern = "(?<x>a(?:(?&x))?(?(R&x)b|c))", .subject = "aab" },
    .{ .name = "cond-R1", .pattern = "(a|(b)(?(R1)c))", .subject = "bc" },
    .{ .name = "dup-name-branch-reset", .pattern = "(?J)(?|(?<x>a)|(?<x>b))\\k<x>", .subject = "bb" },
    .{ .name = "class-set-and", .pattern = "[a-z&&[^aeiou]]+", .subject = "hello", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "class-set-sub", .pattern = "[a-z--[aeiou]]+", .subject = "hello", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "class-set-xor", .pattern = "[a-z~~[aeiou]]+", .subject = "hello", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "uts-and-props", .pattern = "[\\p{L}--[QW]]+", .subject = "hello", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "uts-juxtaposition", .pattern = "[A-Z0-9&&[^E8]]+", .subject = "HELLO8", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "uts-nested-union", .pattern = "[\\p{L}&&[\\p{Thai}||\\p{Greek}]]+", .subject = "\u{03b1}\u{03b2}", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "uts-nested-class", .pattern = "[[a-z]--[aeiou]]+", .subject = "hello", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "perlx-class-and", .pattern = "(?[[a-z]&[^aeiou]])+", .subject = "hello" },
    .{ .name = "perlx-class-sub", .pattern = "(?[[a-z]-[aeiou]])+", .subject = "hello" },
    .{ .name = "perlx-class-xor", .pattern = "(?[[a-z]^[aeiou]])+", .subject = "hello" },
    .{ .name = "perlx-class-union", .pattern = "(?[[a-z]|[0-9]])+", .subject = "a1" },
    .{ .name = "perlx-class-not", .pattern = "(?[![a-z]])+", .subject = "12" },
    .{ .name = "perlx-class-prec", .pattern = "(?[[a-z]|[0-9]&[^5]])+", .subject = "a5" },
    .{ .name = "perlx-class-group", .pattern = "(?[([a-z]|[0-9])&[^aeiou]])+", .subject = "a1b" },
    .{ .name = "esc-N-name", .pattern = "\\N{LATIN CAPITAL LETTER A}", .subject = "A", .extension = true },
    .{ .name = "boundary-gcb", .pattern = "\\b{gcb}", .subject = "a", .extension = true },
    .{ .name = "boundary-wb", .pattern = "\\b{wb}", .subject = "a", .extension = true },
    .{ .name = "boundary-sb", .pattern = "\\b{sb}", .subject = "a", .extension = true },

    // --- second wave: whitespace, caseless properties, extended classes ----
    .{ .name = "esc-p-space-caret", .pattern = "\\p{ ^L }+", .subject = "123" },
    .{ .name = "esc-p-space", .pattern = "\\p{ L }+", .subject = "abc" },
    .{ .name = "esc-g-brace-space", .pattern = "(a)\\g{ 1 }", .subject = "aa" },
    .{ .name = "esc-k-brace-space", .pattern = "(?<x>a)\\k{ x }", .subject = "aa" },
    .{ .name = "esc-N-space", .pattern = "\\N{ U+41 }", .subject = "A" },
    .{ .name = "esc-x-trailing-space", .pattern = "\\x{41 }", .subject = "A" },
    .{ .name = "esc-o-trailing-space", .pattern = "\\o{101 }", .subject = "A" },
    .{ .name = "quant-space-open-only", .pattern = "a{ 2 }", .subject = "aa" },
    .{ .name = "caseless-P-Lu", .pattern = "(?i)\\P{Lu}+", .subject = "a" },
    .{ .name = "caseless-P-Lu-other", .pattern = "(?i)\\P{Lu}+", .subject = "1" },
    .{ .name = "caseless-Lu-neg", .pattern = "(?i)\\P{Lu}+", .subject = "A" },
    .{ .name = "perlx-digit", .pattern = "(?[\\d])", .subject = "5" },
    .{ .name = "perlx-posix", .pattern = "(?[[:alpha:]])", .subject = "a" },
    .{ .name = "perlx-prop-caseless", .pattern = "(?i)(?[\\p{Lu}])+", .subject = "abc" },
    .{ .name = "perlx-prop-P-caseless", .pattern = "(?i)(?[\\P{Lu}])+", .subject = "1" },
    .{ .name = "perlx-caseless-sub", .pattern = "(?i)(?[[a-z]-[A-Z]])+", .subject = "a" },
    .{ .name = "perlx-caseless-not", .pattern = "(?i)(?[![a-z]])+", .subject = "A" },
    .{ .name = "perlx-nested-class", .pattern = "(?[[a-z0-9]])+", .subject = "a1" },
    .{ .name = "perlx-nested-neg", .pattern = "(?[[^a-z]])+", .subject = "1" },
    .{ .name = "perlx-mixed-precedence", .pattern = "(?[[a-z]|[0-9]&[^5]])+", .subject = "a5" },
    .{ .name = "perlx-plus-union", .pattern = "(?[[a-z]+[0-9]])+", .subject = "a1" },
    .{ .name = "perlx-two-unions", .pattern = "(?[[a-z]|[0-9]|[A-Z]])+", .subject = "a1B" },
    .{ .name = "perlx-empty-invalid", .pattern = "(?[ ])", .subject = "", .mode = .compile_only },
    .{ .name = "perlx-literal-invalid", .pattern = "(?[a])", .subject = "", .mode = .compile_only },
    .{ .name = "uts-union-op", .pattern = "[a-z||[0-9]]+", .subject = "a|1", .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS },
    .{ .name = "uts-mixed-ops-invalid", .pattern = "[A-Z&&B--C]", .subject = "", .mode = .compile_only, .pcre_options = c.PCRE2_UTF | c.PCRE2_ALT_EXTENDED_CLASS, .extension = true },
    .{ .name = "accept-subroutine", .pattern = "(?(DEFINE)(?<x>a(*ACCEPT)b))(?&x)cd", .subject = "acd" },
    .{ .name = "accept-subroutine-caps", .pattern = "(?(DEFINE)(?<x>a(*ACCEPT)b))(?&x)cd", .subject = "acd" },
    .{ .name = "accept-inline-group", .pattern = "A((?:A|B(*ACCEPT)|C)D)", .subject = "AB" },
    .{ .name = "accept-quantified", .pattern = "(A(*ACCEPT)??B)C", .subject = "ABC" },
    .{ .name = "accept-positive-assert", .pattern = "(?=(a(*ACCEPT)b))acd", .subject = "acd" },
    .{ .name = "accept-negative-assert", .pattern = "(?!(a(*ACCEPT)b))abx", .subject = "abx" },
    .{ .name = "subroutine-restore-nested", .pattern = "(a(b)(?1))(?2)", .subject = "abb" },
    .{ .name = "backref-restrict-kelvin", .pattern = "(?ri)(k)\\1", .subject = "k\u{212a}" },
    .{ .name = "backref-restrict-eacute", .pattern = "(?ri)(\u{00e9})\\1", .subject = "\u{00e9}\u{00c9}" },

    // --- third wave: assertion aliases, POSIX UCP edge cases ----------------
    .{ .name = "assert-pla", .pattern = "(*pla:a)ab", .subject = "ab" },
    .{ .name = "assert-nla", .pattern = "(*nla:a)ab", .subject = "ab" },
    .{ .name = "assert-plb", .pattern = "(*plb:a)b", .subject = "ab" },
    .{ .name = "assert-nlb", .pattern = "(*nlb:a)cb", .subject = "cb" },
    .{ .name = "assert-napla-long", .pattern = "(*non_atomic_positive_lookahead:ab)abc", .subject = "xabc" },
    .{ .name = "assert-naplb-long", .pattern = "(*non_atomic_positive_lookbehind:a)b", .subject = "ab" },
    .{ .name = "prop-LC", .pattern = "\\p{LC}+", .subject = "aB" },
    .{ .name = "prop-RGI-emoji", .pattern = "\\p{RGI_Emoji}", .subject = "\u{1F600}", .extension = true },
    .{ .name = "prop-Basic-emoji", .pattern = "\\p{Basic_Emoji}", .subject = "\u{1F600}", .extension = true },
    .{ .name = "posix-punct-ucp-bang", .pattern = "(*UCP)[[:punct:]]", .subject = "!" },
    .{ .name = "posix-punct-ucp-pound", .pattern = "(*UCP)[[:punct:]]", .subject = "\u{00a3}" },
    .{ .name = "posix-graph-ucp-cf", .pattern = "(*UCP)[[:graph:]]", .subject = "\u{200e}" },
    .{ .name = "posix-graph-ucp-excluded", .pattern = "(*UCP)[[:graph:]]", .subject = "\u{061c}" },
    .{ .name = "posix-xdigit-ucp-fullwidth", .pattern = "(*UCP)[[:xdigit:]]", .subject = "\u{ff21}" },
    .{ .name = "posix-print-ucp-fullwidth", .pattern = "(*UCP)[[:print:]]", .subject = "\u{ff21}" },
    .{ .name = "posix-alpha-ucp-ascii", .pattern = "(*UCP)[[:alpha:]]", .subject = "\u{00e9}" },
    .{ .name = "posix-word-start", .pattern = "[[:<:]]abc", .subject = "abc" },
    .{ .name = "posix-word-end", .pattern = "abc[[:>:]]", .subject = "abc" },
    .{ .name = "posix-word-start-ucp", .pattern = "(*UCP)[[:<:]]\u{00e9}", .subject = "\u{00e9}" },
    .{ .name = "posix-word-end-ucp", .pattern = "(*UCP)\u{00e9}[[:>:]]", .subject = "\u{00e9}" },
    .{ .name = "posix-word-start-invalid", .pattern = "[a[:<:]b]", .subject = "", .mode = .compile_only },

    // --- fourth wave: class escape restrictions, newline details -----------
    .{ .name = "class-C-invalid", .pattern = "[\\C]", .subject = "", .mode = .compile_only },
    .{ .name = "class-N-invalid", .pattern = "[\\N]", .subject = "", .mode = .compile_only },
    .{ .name = "class-B-invalid", .pattern = "[\\B]", .subject = "", .mode = .compile_only },
    .{ .name = "class-A-invalid", .pattern = "[\\A]", .subject = "", .mode = .compile_only },
    .{ .name = "perlx-R-invalid", .pattern = "(?[\\R])", .subject = "", .mode = .compile_only },
    .{ .name = "perlx-X-invalid", .pattern = "(?[\\X])", .subject = "", .mode = .compile_only },
    .{ .name = "perlx-C-invalid", .pattern = "(?[\\C])", .subject = "", .mode = .compile_only },
    .{ .name = "k-angle-number", .pattern = "(a)\\k<1>", .subject = "aa", .extension = true },
    .{ .name = "k-brace-number", .pattern = "(a)\\k{1}", .subject = "aa", .extension = true },
    .{ .name = "subroutine-relative-plus", .pattern = "(?+1)(a)", .subject = "aa" },
    .{ .name = "nl-multiline-dollar-crlf", .pattern = "(*CRLF)(?m)a$", .subject = "a\r\nb" },
    .{ .name = "nl-multiline-dollar-cr", .pattern = "(*CR)(?m)a$", .subject = "a\rb" },
    .{ .name = "nl-dot-crlf", .pattern = "(*CRLF).", .subject = "\r\n" },
    .{ .name = "nl-N-crlf", .pattern = "(*CRLF)\\N", .subject = "\r\n" },
    .{ .name = "nl-Z-any", .pattern = "(*ANY)a\\Z", .subject = "a\u{2028}" },
    .{ .name = "nl-nul-caret", .pattern = "(*NUL)(?m)^b", .subject = "a\x00b" },
    .{ .name = "start-UTF8-alias", .pattern = "(*UTF8)abc", .subject = "abc" },
    .{ .name = "commit-start-opt", .pattern = "(*COMMIT)abc", .subject = "xyzabc" },
    .{ .name = "commit-no-start-opt", .pattern = "(*NO_START_OPT)(*COMMIT)abc", .subject = "xyzabc" },
    .{ .name = "skip-start-opt", .pattern = "(*SKIP)abc", .subject = "xyzabc" },
    .{ .name = "no-dotstar-anchor", .pattern = "(*NO_DOTSTAR_ANCHOR).*abc", .subject = "xyzabc" },
    .{ .name = "no-auto-possess", .pattern = "(*NO_AUTO_POSSESS)a+abc", .subject = "aaaabc" },
};

pub fn main() !void {
    var stats = Stats{};
    for (cases) |case| runCase(case, &stats);
    std.debug.print(
        "\n=== {d} cases: {d} ok, {d} extensions, {d} limits, compile {d}, span {d}, captures {d}, mark {d}, findAll {d}, zig-error {d}, pcre-error {d}\n",
        .{ stats.total, stats.ok, stats.extensions, stats.limits, stats.compile, stats.span, stats.caps, stats.mark, stats.findAll, stats.error_zig, stats.error_pcre },
    );
    if (stats.ok + stats.extensions + stats.limits != stats.total) std.process.exit(1);
}
