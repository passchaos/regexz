//! RE2/PCRE escapes. Backreferences are parsed for the extended engine;
//! captures and general lookaround are executed by `backtrack.zig`.
const std = @import("std");
const m = @import("model.zig");
const classes = @import("classes.zig");
pub const Backref = struct { index: u16, groups: []const u16 = &.{} };
pub const Atom = union(enum) { set: m.ParsedSet, assertion: m.Assertion, byte, dot, backref: Backref, subroutine: u16, reset_start, string_property: m.StringProperty };
const any_range = [_]m.Range{.{ .first = 0, .last = 0x10ffff }};
const ascii_range = [_]m.Range{.{ .first = 0, .last = 0x7f }};
/// PCRE2 `\p{Xuc}`: characters representable by a Universal Character Name.
const xuc_ranges = [_]m.Range{
    .{ .first = '$', .last = '$' },
    .{ .first = '@', .last = '@' },
    .{ .first = '`', .last = '`' },
    .{ .first = 0xa0, .last = 0xd7ff },
    .{ .first = 0xe000, .last = 0x10ffff },
};
fn nameEqual(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (true) {
        while (ai < a.len and (a[ai] == '_' or a[ai] == '-' or a[ai] == ' ')) ai += 1;
        while (bi < b.len and (b[bi] == '_' or b[bi] == '-' or b[bi] == ' ')) bi += 1;
        if (ai == a.len or bi == b.len) return ai == a.len and bi == b.len;
        if (std.ascii.toLower(a[ai]) != std.ascii.toLower(b[bi])) return false;
        ai += 1;
        bi += 1;
    }
}

fn propertyAlias(name: []const u8) []const u8 {
    if (std.ascii.eqlIgnoreCase(name, "Alpha")) return "Alphabetic";
    if (std.ascii.eqlIgnoreCase(name, "Lower")) return "Lowercase";
    if (std.ascii.eqlIgnoreCase(name, "Upper")) return "Uppercase";
    if (std.ascii.eqlIgnoreCase(name, "WSpace")) return "White_Space";
    if (std.ascii.eqlIgnoreCase(name, "ExtPict")) return "Extended_Pictographic";
    if (std.ascii.eqlIgnoreCase(name, "Hex")) return "Hex_Digit";
    return name;
}
fn scalar(value: u32) m.Error!u21 {
    if (value > 0x10ffff) return error.InvalidRegex;
    return @intCast(value);
}
pub fn literal(p: anytype, value: u21, fold: m.Fold) m.Error!m.ParsedSet {
    const ranges = try p.allocator.alloc(m.Range, 1);
    ranges[0] = .{ .first = value, .last = value };
    return .{ .ranges = ranges, .fold = fold };
}
fn hexadecimal(p: anytype) m.Error!u21 {
    var value: u32 = 0;
    if (p.take('{')) {
        const start = p.cursor;
        while (p.peek()) |byte| {
            const digit = std.fmt.charToDigit(byte, 16) catch break;
            value = std.math.mul(u32, value, 16) catch return error.InvalidRegex;
            value = std.math.add(u32, value, digit) catch return error.InvalidRegex;
            p.cursor += 1;
        }
        if (p.cursor == start or !p.take('}')) return error.InvalidRegex;
    } else {
        for (0..2) |_| {
            const byte = p.peek() orelse return error.InvalidRegex;
            p.cursor += 1;
            value = value * 16 + (std.fmt.charToDigit(byte, 16) catch return error.InvalidRegex);
        }
    }
    return scalar(value);
}
fn property(p: anytype, negative: bool, fold: m.Fold) m.Error!m.ParsedSet {
    var negate = negative;
    const start = p.cursor;
    var name: []const u8 = undefined;
    if (p.take('{')) {
        const offset = p.cursor;
        while (p.peek()) |byte| {
            if (byte == '}') break;
            p.cursor += 1;
        }
        name = p.pattern[offset..p.cursor];
        if (!p.take('}')) return error.InvalidRegex;
    } else {
        if (p.peek() == null) return error.InvalidRegex;
        p.cursor += 1;
        name = p.pattern[start..p.cursor];
    }
    if (name.len != 0 and name[0] == '^') {
        negate = !negate;
        name = name[1..];
    }
    name = std.mem.trim(u8, name, " \t\n\r\x0b\x0c");
    if (std.mem.eql(u8, name, "Any")) return .{ .ranges = &any_range, .negate = negate, .fold = fold };
    if (nameEqual(name, "ASCII")) return .{ .ranges = &ascii_range, .negate = negate, .fold = fold };
    if (nameEqual(name, "Assigned")) {
        const cn = try classes.unicodePropertyRanges(p.allocator, "Cn");
        if (cn.len > p.limits.max_ranges) return error.RegexLimitExceeded;
        return .{ .ranges = cn, .negate = !negate, .fold = fold };
    }
    if (std.mem.eql(u8, name, "Xan")) return .{ .ranges = try classes.unicodePropertyUnion(p.allocator, &.{ "L", "N" }, p.limits.max_ranges), .negate = negate, .fold = fold };
    if (std.mem.eql(u8, name, "Xwd")) return .{ .ranges = try classes.unicodeWordRanges(p.allocator, p.limits.max_ranges), .negate = negate, .fold = fold };
    if (std.mem.eql(u8, name, "Xps") or std.mem.eql(u8, name, "Xsp")) return .{ .ranges = &classes.unicode_space_ranges, .negate = negate, .fold = fold };
    if (std.mem.eql(u8, name, "Xuc")) return .{ .ranges = &xuc_ranges, .negate = negate, .fold = fold };
    if (std.mem.startsWith(u8, name, "In") and name.len > 2) {
        const block = m.unicode.lookupBlock(name[2..]) orelse return error.InvalidRegex;
        const ranges = try p.allocator.alloc(m.Range, block.count);
        for (ranges, 0..) |*range, index| range.* = block.range(index);
        return .{ .ranges = ranges, .negate = negate, .fold = fold };
    }
    var property_name = name;
    var scripts_only = false;
    const Kind = enum { any, gc, script };
    var kind: Kind = .any;
    if (std.mem.indexOfAny(u8, name, "=:")) |separator| {
        const prefix = std.mem.trim(u8, name[0..separator], " \t\n\r\x0b\x0c");
        const value = std.mem.trim(u8, name[separator + 1 ..], " \t\n\r\x0b\x0c");
        if (std.ascii.eqlIgnoreCase(prefix, "block")) {
            const block = m.unicode.lookupBlock(value) orelse return error.InvalidRegex;
            const ranges = try p.allocator.alloc(m.Range, block.count);
            for (ranges, 0..) |*range, index| range.* = block.range(index);
            return .{ .ranges = ranges, .negate = negate, .fold = fold };
        }
        if (nameEqual(prefix, "bidi_class") or std.ascii.eqlIgnoreCase(prefix, "bc")) {
            const group = m.unicode.lookupBidiClass(value) orelse return error.InvalidRegex;
            if (group.count > p.limits.max_ranges) return error.RegexLimitExceeded;
            const ranges = try p.allocator.alloc(m.Range, group.count);
            for (ranges, 0..) |*range, index| range.* = group.range(index);
            return .{ .ranges = ranges, .negate = negate, .fold = fold };
        }
        if (nameEqual(prefix, "script_extensions") or std.ascii.eqlIgnoreCase(prefix, "scx")) {
            if (m.unicode.lookupScriptExtension(value)) |group| {
                if (group.count > p.limits.max_ranges) return error.RegexLimitExceeded;
                const ranges = try p.allocator.alloc(m.Range, group.count);
                for (ranges, 0..) |*range, index| range.* = group.range(index);
                return .{ .ranges = ranges, .negate = negate, .fold = fold };
            }
            // Scripts without explicit extensions fall back to their own
            // Scripts.txt ranges (this also covers new Unicode 16 scripts
            // missing from RE2's pinned tables).
            const canonical = m.unicode.lookupScriptAlias(value) orelse value;
            const group = m.unicode.lookup(canonical) orelse return error.InvalidRegex;
            if (group.count > p.limits.max_ranges) return error.RegexLimitExceeded;
            const ranges = try p.allocator.alloc(m.Range, group.count);
            for (ranges, 0..) |*range, index| range.* = group.range(index);
            return .{ .ranges = ranges, .negate = negate, .fold = fold };
        }
        if (nameEqual(prefix, "script") or std.ascii.eqlIgnoreCase(prefix, "sc")) {
            property_name = value;
            scripts_only = true;
            kind = .script;
        } else if (nameEqual(prefix, "general_category") or
            std.ascii.eqlIgnoreCase(prefix, "gc") or
            nameEqual(prefix, "category"))
        {
            property_name = value;
            scripts_only = true;
            kind = .gc;
        } else return error.InvalidRegex;
    } else if (std.mem.startsWith(u8, name, "Is") and name.len > 2) {
        property_name = name[2..];
    }
    property_name = propertyAlias(property_name);
    var group: ?m.unicode.Group = m.unicode.lookup(property_name);
    var binary: ?m.unicode.Property = null;
    if (group == null and !scripts_only) binary = m.unicode.lookupProperty(property_name);
    if (group == null and binary == null) {
        const canonical: ?[]const u8 = switch (kind) {
            .gc => m.unicode.lookupGcAlias(property_name),
            .script => m.unicode.lookupScriptAlias(property_name),
            .any => m.unicode.lookupGcAlias(property_name) orelse m.unicode.lookupScriptAlias(property_name),
        };
        if (canonical) |mapped| {
            // RE2's group table does not carry the derived Cased_Letter set.
            if (std.mem.eql(u8, mapped, "LC")) {
                return .{
                    .ranges = try classes.unicodePropertyUnion(p.allocator, &.{ "Lu", "Ll", "Lt" }, p.limits.max_ranges),
                    .negate = negate,
                    .fold = fold,
                };
            }
            group = m.unicode.lookup(mapped);
            if (group == null and !scripts_only) binary = m.unicode.lookupProperty(mapped);
        }
    }
    if (group == null and binary == null and !scripts_only) {
        binary = m.unicode.lookupPropertyNormalized(property_name);
    }
    const count = if (group) |value| value.count else if (binary) |value| value.count else return error.InvalidRegex;
    if (count > p.limits.max_ranges) return error.RegexLimitExceeded;
    const ranges = try p.allocator.alloc(m.Range, count);
    if (group) |value| {
        for (ranges, 0..) |*range, index| range.* = value.range(index);
    } else {
        for (ranges, 0..) |*range, index| range.* = binary.?.range(index);
    }
    return .{ .ranges = ranges, .negate = negate, .fold = fold };
}

fn graphemeBoundarySuffix(p: anytype) m.Error!?m.Assertion {
    if (p.peek() != '{') return null;
    const start = p.cursor + 1;
    var end = start;
    while (end < p.pattern.len and p.pattern[end] != '}') end += 1;
    if (end == p.pattern.len) return null;
    const name = p.pattern[start..end];
    if (nameEqual(name, "gcb") or nameEqual(name, "g")) {
        p.cursor = end + 1;
        return .grapheme_boundary;
    }
    if (nameEqual(name, "wb")) {
        p.cursor = end + 1;
        return .word_boundary_uax29;
    }
    if (nameEqual(name, "sb")) {
        p.cursor = end + 1;
        return .sentence_boundary;
    }
    if (nameEqual(name, "start")) {
        p.cursor = end + 1;
        return if (p.limits.unicode_perl_classes) .word_start_unicode else .word_start;
    }
    if (nameEqual(name, "end")) {
        p.cursor = end + 1;
        return if (p.limits.unicode_perl_classes) .word_end_unicode else .word_end;
    }
    if (nameEqual(name, "startend")) {
        p.cursor = end + 1;
        return if (p.limits.unicode_perl_classes) .word_boundary_unicode else .word_boundary;
    }
    return null;
}

fn stringPropertyName(name: []const u8) ?m.StringProperty {
    if (nameEqual(name, "RGI_Emoji")) return .rgi_emoji;
    if (nameEqual(name, "Basic_Emoji")) return .basic_emoji;
    if (nameEqual(name, "Emoji_Keycap_Sequence")) return .emoji_keycap_sequence;
    if (nameEqual(name, "RGI_Emoji_Flag_Sequence")) return .rgi_emoji_flag_sequence;
    if (nameEqual(name, "RGI_Emoji_Tag_Sequence")) return .rgi_emoji_tag_sequence;
    if (nameEqual(name, "RGI_Emoji_Modifier_Sequence")) return .rgi_emoji_modifier_sequence;
    if (nameEqual(name, "RGI_Emoji_ZWJ_Sequence")) return .rgi_emoji_zwj_sequence;
    return null;
}

fn stringProperty(p: anytype, negative: bool, in_class: bool) m.Error!?Atom {
    const saved = p.cursor;
    var name: []const u8 = undefined;
    if (p.take('{')) {
        const offset = p.cursor;
        while (p.peek()) |byte| {
            if (byte == '}') break;
            p.cursor += 1;
        }
        name = p.pattern[offset..p.cursor];
        if (!p.take('}')) return error.InvalidRegex;
    } else {
        if (p.peek() == null) return error.InvalidRegex;
        p.cursor += 1;
        name = p.pattern[saved..p.cursor];
    }
    var negated = negative;
    if (name.len != 0 and name[0] == '^') {
        negated = !negated;
        name = name[1..];
    }
    const found = stringPropertyName(name) orelse {
        p.cursor = saved;
        return null;
    };
    if (negated) return error.UnsupportedRegexFeature;
    if (in_class) return error.InvalidRegex;
    p.extended = true;
    return .{ .string_property = found };
}

fn namedBackref(p: anytype, open: u8) m.Error!Atom {
    const close: u8 = switch (open) {
        '<' => '>',
        '\'' => '\'',
        '{' => '}',
        else => return error.InvalidRegex,
    };
    p.cursor += 1;
    const start = p.cursor;
    while (p.peek()) |byte| {
        if (byte == close) break;
        p.cursor += 1;
    }
    const name = p.pattern[start..p.cursor];
    if (!p.take(close)) return error.InvalidRegex;
    const groups = try p.nameIndices(name) orelse return error.InvalidRegex;
    p.extended = true;
    return .{ .backref = .{ .index = groups[0], .groups = groups } };
}
fn numericBackref(p: anytype, byte: u8) m.Error!?u16 {
    var value: u32 = byte - '0';
    var count: usize = 1;
    while (count < 3) {
        const next = p.peek() orelse break;
        if (next < '0' or next > '9') break;
        const candidate = value * 10 + (next - '0');
        if (candidate > p.captures) break;
        p.cursor += 1;
        value = candidate;
        count += 1;
    }
    if (value == 0 or value > p.captures) return null;
    p.extended = true;
    return @intCast(value);
}
const GroupSpec = union(enum) {
    absolute: u16,
    relative: i16,
    not_number,
};

/// Classify `\g{...}` / `\g<...>` contents as an absolute group number, a
/// relative offset (`-1`, `+1`), or a group name.
fn parseGroupSpec(text: []const u8) m.Error!GroupSpec {
    if (text.len == 0) return .not_number;
    var index: usize = 0;
    var negative = false;
    var signed = false;
    if (text[0] == '-') {
        negative = true;
        signed = true;
        index = 1;
    } else if (text[0] == '+') {
        signed = true;
        index = 1;
    }
    if (index == text.len) return .not_number;
    for (text[index..]) |byte| {
        if (!std.ascii.isDigit(byte)) return .not_number;
    }
    const magnitude = std.fmt.parseInt(u16, text[index..], 10) catch return error.InvalidRegex;
    if (magnitude > 32767) return error.InvalidRegex;
    if (!signed) return .{ .absolute = magnitude };
    return .{ .relative = if (negative) -@as(i16, @intCast(magnitude)) else @as(i16, @intCast(magnitude)) };
}

pub fn parse(p: anytype, in_class: bool, fold: m.Fold) m.Error!Atom {
    const byte = p.peek() orelse return error.InvalidRegex;
    p.cursor += 1;
    // Inside a character class, `\b` is the backspace character.
    if (in_class and byte == 'b') return .{ .set = try literal(p, 0x08, fold) };
    if (std.mem.indexOfScalar(u8, "dDsSwW", byte) != null) {
        const negate = std.ascii.isUpper(byte);
        const ascii_override = switch (std.ascii.toLower(byte)) {
            'd' => p.flags.ascii_bsd,
            's' => p.flags.ascii_space,
            else => p.flags.ascii_word,
        };
        if (p.limits.unicode_perl_classes and !ascii_override) {
            switch (std.ascii.toLower(byte)) {
                'd' => return .{ .set = .{ .ranges = try classes.unicodePropertyRanges(p.allocator, "Nd"), .negate = negate, .fold = fold } },
                'w' => return .{ .set = .{ .ranges = try classes.unicodeWordRanges(p.allocator, p.limits.max_ranges), .negate = negate, .fold = fold } },
                's' => return .{ .set = .{ .ranges = &classes.unicode_space_ranges, .negate = negate, .fold = fold } },
                else => unreachable,
            }
        }
        if ((byte == 's' or byte == 'S') and p.limits.unicode_perl_space and !p.flags.ascii_space) {
            return .{ .set = .{ .ranges = &classes.unicode_space_ranges, .negate = negate, .fold = fold } };
        }
        const name: []const u8 = switch (std.ascii.toLower(byte)) {
            'd' => "digit",
            's' => "perl_space",
            else => "word",
        };
        return .{ .set = .{ .ranges = classes.ascii(name).?, .negate = negate, .fold = fold } };
    }
    if (byte == 'p' or byte == 'P') {
        if (try stringProperty(p, byte == 'P', in_class)) |atom| return atom;
        return .{ .set = try property(p, byte == 'P', fold) };
    }
    if (byte == 'C' and !in_class) return .byte;
    if (byte == 'N') {
        // `\N{U+hhhh}` is an explicit code point; `\N{NAME}` is a Unicode
        // character name. Bare `\N` is the "not newline" set. A brace that
        // starts with a digit or comma stays for the quantifier parser.
        if (p.peek() == '{') {
            const start = p.cursor + 1;
            var end = start;
            while (end < p.pattern.len and p.pattern[end] != '}') end += 1;
            if (end < p.pattern.len) {
                const name = p.pattern[start..end];
                const quantifier = name.len > 0 and (std.ascii.isDigit(name[0]) or name[0] == ',');
                if (!quantifier) {
                    p.cursor = end + 1;
                    if (name.len > 2 and name[0] == 'U' and name[1] == '+') {
                        const value = std.fmt.parseInt(u21, name[2..], 16) catch return error.InvalidRegex;
                        if (value > 0x10ffff) return error.InvalidRegex;
                        return .{ .set = try literal(p, value, fold) };
                    }
                    const value = m.unicode.lookupCharName(name) orelse return error.InvalidRegex;
                    return .{ .set = try literal(p, value, fold) };
                }
            }
        }
        // Bare `\N` behaves like dot without DOTALL; the parser expands it
        // using the active newline convention.
        return .dot;
    }
    if (byte == 'h') return .{ .set = .{ .ranges = &classes.horizontal_space_ranges, .negate = false, .fold = .none } };
    if (byte == 'H') return .{ .set = .{ .ranges = &classes.horizontal_space_ranges, .negate = true, .fold = .none } };
    if (byte == 'c') {
        // PCRE2 `\cX`: control character. `\c?` is DEL; other characters use
        // their low five bits.
        const next = p.peek() orelse return error.InvalidRegex;
        if (next >= 0x80) return error.InvalidRegex;
        p.cursor += 1;
        const value: u21 = if (next == '?') 0x7f else @as(u21, next & 0x1f);
        return .{ .set = try literal(p, value, fold) };
    }
    if (byte == 'o') {
        // PCRE2 `\o{ddd}`: octal code point.
        if (!p.take('{')) return error.InvalidRegex;
        var value: u32 = 0;
        const start = p.cursor;
        while (p.peek()) |digit| {
            if (digit == '}') break;
            const parsed = std.fmt.charToDigit(digit, 8) catch return error.InvalidRegex;
            value = std.math.mul(u32, value, 8) catch return error.InvalidRegex;
            value = std.math.add(u32, value, parsed) catch return error.InvalidRegex;
            p.cursor += 1;
        }
        if (p.cursor == start or !p.take('}')) return error.InvalidRegex;
        return .{ .set = try literal(p, try scalar(value), fold) };
    }
    if ((byte == 'v' or byte == 'V') and p.limits.pcre_vertical_whitespace) {
        return .{ .set = .{ .ranges = &classes.vertical_space_ranges, .negate = byte == 'V', .fold = .none } };
    }
    if (!in_class) switch (byte) {
        'A' => return .{ .assertion = .start_text },
        'z' => return .{ .assertion = .end_text },
        'Z' => return .{ .assertion = .end_text_or_newline },
        'G' => {
            p.extended = true;
            return .{ .assertion = .start_match };
        },
        'b' => {
            if (try graphemeBoundarySuffix(p)) |kind| {
                p.extended = true;
                return .{ .assertion = kind };
            }
            if (p.limits.unicode_perl_classes and !p.flags.ascii_word) {
                p.extended = true;
                return .{ .assertion = .word_boundary_unicode };
            }
            return .{ .assertion = .word_boundary };
        },
        'B' => {
            if (try graphemeBoundarySuffix(p)) |kind| {
                p.extended = true;
                const negated: m.Assertion = switch (kind) {
                    .grapheme_boundary => .no_grapheme_boundary,
                    .word_boundary_uax29 => .no_word_boundary_uax29,
                    .sentence_boundary => .no_sentence_boundary,
                    .word_start => .no_word_start,
                    .word_end => .no_word_end,
                    .word_start_unicode => .no_word_start_unicode,
                    .word_end_unicode => .no_word_end_unicode,
                    .word_boundary => .no_word_boundary,
                    .word_boundary_unicode => .no_word_boundary_unicode,
                    else => unreachable,
                };
                return .{ .assertion = negated };
            }
            if (p.limits.unicode_perl_classes and !p.flags.ascii_word) {
                p.extended = true;
                return .{ .assertion = .no_word_boundary_unicode };
            }
            return .{ .assertion = .no_word_boundary };
        },
        else => {},
    };
    if (!in_class) {
        if (byte == 'k') {
            const open = p.peek() orelse return error.InvalidRegex;
            return namedBackref(p, open);
        }
        if (byte == 'g') {
            const open = p.peek() orelse return error.InvalidRegex;
            if (open == '<' or open == '\'') {
                const close: u8 = if (open == '<') '>' else '\'';
                p.cursor += 1;
                const start = p.cursor;
                while (p.peek()) |next| {
                    if (next == close) break;
                    p.cursor += 1;
                }
                const name = p.pattern[start..p.cursor];
                if (!p.take(close)) return error.InvalidRegex;
                switch (try parseGroupSpec(name)) {
                    .absolute => |index| {
                        if (index == 0) return error.InvalidRegex;
                        p.extended = true;
                        return .{ .subroutine = index };
                    },
                    .relative => |offset| {
                        const base: i32 = @as(i32, p.captures) + @as(i32, if (offset < 0) 1 else 0);
                        const value = base + offset;
                        if (value <= 0 or value > 32767) return error.InvalidRegex;
                        p.extended = true;
                        return .{ .subroutine = @intCast(value) };
                    },
                    .not_number => {},
                }
                const index = p.lookupName(name) orelse return error.InvalidRegex;
                p.extended = true;
                return .{ .subroutine = index };
            }
            if (open != '{') return error.InvalidRegex;
            p.cursor += 1;
            const start = p.cursor;
            while (p.peek()) |next| {
                if (next == '}') break;
                p.cursor += 1;
            }
            const name = p.pattern[start..p.cursor];
            if (!p.take('}')) return error.InvalidRegex;
            switch (try parseGroupSpec(name)) {
                .absolute => |index| {
                    if (index == 0) return error.InvalidRegex;
                    p.extended = true;
                    return .{ .backref = .{ .index = index } };
                },
                .relative => |offset| {
                    // Relative to the most recently opened group; positive
                    // offsets reference groups that are still to be opened.
                    const base: i32 = @as(i32, p.captures) + @as(i32, if (offset < 0) 1 else 0);
                    const value = base + offset;
                    if (value <= 0 or value > 32767) return error.InvalidRegex;
                    p.extended = true;
                    return .{ .backref = .{ .index = @intCast(value) } };
                },
                .not_number => {},
            }
            const groups = try p.nameIndices(name) orelse return error.InvalidRegex;
            p.extended = true;
            return .{ .backref = .{ .index = groups[0], .groups = groups } };
        }
        if (byte >= '1' and byte <= '9') {
            if (try numericBackref(p, byte)) |index| return .{ .backref = .{ .index = index } };
        }
        if (byte == 'K') {
            p.extended = true;
            return .reset_start;
        }
        if (byte == 'R' or byte == 'X') return error.UnsupportedRegexFeature;
    }
    const value: u21 = switch (byte) {
        'a' => 7,
        'f' => '\x0c',
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => '\x0b',
        'x' => try hexadecimal(p),
        '0'...'7' => blk: {
            var number: u32 = byte - '0';
            var count: usize = 1;
            while (count < 3) {
                const next = p.peek() orelse break;
                if (next < '0' or next > '7') break;
                p.cursor += 1;
                count += 1;
                number = number * 8 + next - '0';
            }
            if (byte != '0' and count == 1) return error.InvalidRegex;
            break :blk try scalar(number);
        },
        else => blk: {
            if (std.ascii.isAlphanumeric(byte)) return error.InvalidRegex;
            if (byte < 128) break :blk byte;
            p.cursor -= 1;
            break :blk try p.rune();
        },
    };
    return .{ .set = try literal(p, value, fold) };
}
