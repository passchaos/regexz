//! RE2 Unicode categories/scripts and simple folding, decoded on any endian.
const std = @import("std");
pub const Range = struct { first: u21, last: u21 };
pub const Entry = struct { name: []const u8, offset: usize, count: usize };
const groups = @import("unicode/groups.zig").entries;
const group_data = @embedFile("unicode/groups.bin");
const fold_data = @embedFile("unicode/fold.bin");
const upper_data = @embedFile("unicode/upper.bin");
const lower_data = @embedFile("unicode/lower.bin");
const string_props_data = @embedFile("unicode/string_props.bin");
const properties = @import("unicode/props.zig").entries;
const property_data = @embedFile("unicode/props.bin");
const blocks = @import("unicode/blocks.zig").entries;
const block_data = @embedFile("unicode/blocks.bin");
const script_extensions = @import("unicode/script_extensions.zig").entries;
const script_extension_data = @embedFile("unicode/script_extensions.bin");
pub const Alias = struct { name: []const u8, canonical: []const u8 };
const aliases = @import("unicode/aliases.zig");
pub const grapheme = @import("unicode/grapheme.zig");
const gcb_data = @embedFile("unicode/grapheme_gcb.bin");
const extpict_data = @embedFile("unicode/grapheme_extpict.bin");
const incb_data = @embedFile("unicode/grapheme_incb.bin");
const word_break_data = @embedFile("unicode/word_break.bin");
pub const Wb = @import("unicode/word_break.zig").Wb;
const wb_count = @import("unicode/word_break.zig").wb_count;
const sentence_break_data = @embedFile("unicode/sentence_break.bin");
const char_names_data = @embedFile("unicode/char_names.bin");
pub const Sb = @import("unicode/sentence_break.zig").Sb;
const sb_count = @import("unicode/sentence_break.zig").sb_count;
pub const fold_range_count = fold_data.len / 12;
pub fn foldRange(index: usize) Range {
    const bytes = fold_data[index * 12 ..];
    return .{ .first = @intCast(std.mem.readInt(u32, bytes[0..4], .little)), .last = @intCast(std.mem.readInt(u32, bytes[4..8], .little)) };
}
pub const Group = struct {
    offset: usize,
    count: usize,
    pub fn range(self: Group, index: usize) Range {
        const bytes = group_data[self.offset + index * 8 ..];
        return .{ .first = @intCast(std.mem.readInt(u32, bytes[0..4], .little)), .last = @intCast(std.mem.readInt(u32, bytes[4..8], .little)) };
    }
};
pub fn lookup(name: []const u8) ?Group {
    if (std.mem.eql(u8, name, "Any")) return null; // parser handles universal set
    var first: usize = 0;
    var last = groups.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const entry = groups[middle];
        switch (std.mem.order(u8, name, entry.name)) {
            .lt => last = middle,
            .gt => first = middle + 1,
            .eq => return .{ .offset = entry.offset, .count = entry.count },
        }
    }
    return null;
}

/// A binary Unicode property such as `Alphabetic`, `White_Space`, or `Emoji`.
pub const Property = struct {
    offset: usize,
    count: usize,
    pub fn range(self: Property, index: usize) Range {
        const bytes = property_data[self.offset + index * 8 ..];
        return .{ .first = @intCast(std.mem.readInt(u32, bytes[0..4], .little)), .last = @intCast(std.mem.readInt(u32, bytes[4..8], .little)) };
    }
};
pub fn lookupProperty(name: []const u8) ?Property {
    var first: usize = 0;
    var last = properties.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const entry = properties[middle];
        switch (std.mem.order(u8, name, entry.name)) {
            .lt => last = middle,
            .gt => first = middle + 1,
            .eq => return .{ .offset = entry.offset, .count = entry.count },
        }
    }
    return null;
}

/// Script_Extensions ranges (`ScriptExtensions.txt`) for one script.
pub const ScriptExtension = struct {
    offset: usize,
    count: usize,
    pub fn range(self: ScriptExtension, index: usize) Range {
        const bytes = script_extension_data[self.offset + index * 8 ..];
        return .{ .first = @intCast(std.mem.readInt(u32, bytes[0..4], .little)), .last = @intCast(std.mem.readInt(u32, bytes[4..8], .little)) };
    }
};

fn aliasLookup(entries: []const Alias, name: []const u8) ?[]const u8 {
    var first: usize = 0;
    var last = entries.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const entry = entries[middle];
        switch (std.mem.order(u8, name, entry.name)) {
            .lt => last = middle,
            .gt => first = middle + 1,
            .eq => return entry.canonical,
        }
    }
    for (entries) |entry| {
        if (blockNameEqual(name, entry.name)) return entry.canonical;
    }
    return null;
}

/// Resolve a general-category alias (long name, extra alias, or canonical
/// short name) to the short name used by the group table.
pub fn lookupGcAlias(name: []const u8) ?[]const u8 {
    return aliasLookup(aliases.gc[0..], name);
}

/// Resolve a script alias (ISO 15924 code, long name, or separator/case
/// variant) to the long script name used by the group table.
pub fn lookupScriptAlias(name: []const u8) ?[]const u8 {
    return aliasLookup(aliases.sc[0..], name);
}

/// Case/separator-insensitive binary-property lookup.
pub fn lookupPropertyNormalized(name: []const u8) ?Property {
    for (properties) |entry| {
        if (blockNameEqual(name, entry.name)) return .{ .offset = entry.offset, .count = entry.count };
    }
    return null;
}

/// Look up `Script_Extensions` by long name (`Hiragana`) or ISO 15924 code
/// (`Hira`). Separators in the query (`_`, `-`, space) are ignored.
pub fn lookupScriptExtension(name: []const u8) ?ScriptExtension {
    var first: usize = 0;
    var last = script_extensions.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const entry = script_extensions[middle];
        switch (std.mem.order(u8, name, entry.name)) {
            .lt => last = middle,
            .gt => first = middle + 1,
            .eq => return .{ .offset = entry.offset, .count = entry.count },
        }
    }
    for (script_extensions) |entry| {
        if (blockNameEqual(name, entry.name)) return .{ .offset = entry.offset, .count = entry.count };
    }
    return null;
}

/// A Unicode block (`Blocks.txt`), e.g. `Basic_Latin` or `Emoticons`.
pub const Block = struct {
    offset: usize,
    count: usize,
    pub fn range(self: Block, index: usize) Range {
        const bytes = block_data[self.offset + index * 8 ..];
        return .{ .first = @intCast(std.mem.readInt(u32, bytes[0..4], .little)), .last = @intCast(std.mem.readInt(u32, bytes[4..8], .little)) };
    }
};
fn blockNameEqual(query: []const u8, name: []const u8) bool {
    var qi: usize = 0;
    var ni: usize = 0;
    while (true) {
        while (qi < query.len and (query[qi] == '_' or query[qi] == '-' or query[qi] == ' ')) qi += 1;
        while (ni < name.len and (name[ni] == '_' or name[ni] == '-' or name[ni] == ' ')) ni += 1;
        if (qi == query.len or ni == name.len) return qi == query.len and ni == name.len;
        if (std.ascii.toLower(query[qi]) != std.ascii.toLower(name[ni])) return false;
        qi += 1;
        ni += 1;
    }
}
pub fn lookupBlock(name: []const u8) ?Block {
    var first: usize = 0;
    var last = blocks.len;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const entry = blocks[middle];
        switch (std.mem.order(u8, name, entry.name)) {
            .lt => last = middle,
            .gt => first = middle + 1,
            .eq => return .{ .offset = entry.offset, .count = entry.count },
        }
    }
    for (blocks) |entry| {
        if (blockNameEqual(name, entry.name)) return .{ .offset = entry.offset, .count = entry.count };
    }
    if (std.ascii.eqlIgnoreCase(name, "Greek")) return lookupBlock("Greek_and_Coptic");
    return null;
}
pub fn foldNext(rune: u21) u21 {
    var first: usize = 0;
    var last = fold_data.len / 12;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = fold_data[middle * 12 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) last = middle else if (rune > high) first = middle + 1 else {
            const delta = std.mem.readInt(i32, bytes[8..12], .little);
            return switch (delta) {
                1 => if (rune & 1 == 0) rune + 1 else rune - 1,
                -1 => if (rune & 1 == 1) rune + 1 else rune - 1,
                else => @intCast(@as(i32, rune) + delta),
            };
        }
    }
    return rune;
}

/// Unicode string properties that match a sequence of code points.
pub const StringProperty = enum {
    rgi_emoji,
    basic_emoji,
    emoji_keycap_sequence,
    rgi_emoji_flag_sequence,
    rgi_emoji_tag_sequence,
    rgi_emoji_modifier_sequence,
    rgi_emoji_zwj_sequence,
};

/// Match a string property at `offset`, returning the end of the longest
/// matching sequence, or null.
pub fn matchStringProperty(property: StringProperty, input: []const u8, offset: usize) ?usize {
    const index: usize = @intFromEnum(property);
    const header = string_props_data[2 + index * 16 ..];
    const node_offset = std.mem.readInt(u32, header[0..4], .little);
    const edge_offset = std.mem.readInt(u32, header[8..12], .little);
    return matchSequence(
        string_props_data[@as(usize, node_offset)..],
        string_props_data[@as(usize, edge_offset)..],
        input,
        offset,
    );
}

fn matchSequence(nodes: []const u8, edges: []const u8, input: []const u8, offset: usize) ?usize {
    var node: u32 = 0;
    var pos = offset;
    var best: ?usize = null;
    while (pos < input.len) {
        const length = std.unicode.utf8ByteSequenceLength(input[pos]) catch return best;
        if (length > input.len - pos) return best;
        const rune = std.unicode.utf8Decode(input[pos..][0..length]) catch return best;
        const node_bytes = nodes[@as(usize, node) * 8 ..];
        const first = std.mem.readInt(u32, node_bytes[0..4], .little);
        const count = std.mem.readInt(u16, node_bytes[4..6], .little);
        node = findChild(edges, first, count, rune) orelse return best;
        pos += length;
        if (nodes[@as(usize, node) * 8 + 6] != 0) best = pos;
    }
    return best;
}

fn findChild(edges: []const u8, first: u32, count: u16, rune: u21) ?u32 {
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const bytes = edges[(first + @as(u32, @intCast(middle))) * 8 ..];
        const edge_rune = std.mem.readInt(u32, bytes[0..4], .little);
        if (rune < edge_rune) {
            high = middle;
        } else if (rune > edge_rune) {
            low = middle + 1;
        } else {
            return std.mem.readInt(u32, bytes[4..8], .little);
        }
    }
    return null;
}

/// Simple Unicode uppercase mapping (UnicodeData.txt field 12).
pub fn toUpper(rune: u21) u21 {
    return caseMap(upper_data, rune);
}

/// Simple Unicode lowercase mapping (UnicodeData.txt field 13).
pub fn toLower(rune: u21) u21 {
    return caseMap(lower_data, rune);
}

fn caseMap(data: []const u8, rune: u21) u21 {
    var first: usize = 0;
    var last = data.len / 12;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = data[middle * 12 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) {
            last = middle;
        } else if (rune > high) {
            first = middle + 1;
        } else {
            const delta = std.mem.readInt(i32, bytes[8..12], .little);
            const value: i64 = @as(i64, rune) + delta;
            if (value < 0 or value > 0x10ffff) return rune;
            return @intCast(value);
        }
    }
    return rune;
}

/// Grapheme_Cluster_Break property.
pub fn gcbOf(rune: u21) grapheme.Gcb {
    var first: usize = 0;
    var last: usize = grapheme.gcb_count;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = gcb_data[middle * 12 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) last = middle else if (rune > high) first = middle + 1 else return @enumFromInt(bytes[8]);
    }
    return .other;
}

/// Word_Break property.
pub fn wbOf(rune: u21) Wb {
    var first: usize = 0;
    var last: usize = wb_count;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = word_break_data[middle * 12 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) last = middle else if (rune > high) first = middle + 1 else return @enumFromInt(bytes[8]);
    }
    return .other;
}

/// Sentence_Break property.
pub fn sbOf(rune: u21) Sb {
    var first: usize = 0;
    var last: usize = sb_count;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = sentence_break_data[middle * 12 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) last = middle else if (rune > high) first = middle + 1 else return @enumFromInt(bytes[8]);
    }
    return .other;
}

/// Look up an explicit Unicode character name (`\N{LATIN SMALL LETTER A}`).
/// Matching is case-insensitive and ignores spaces, hyphens, and underscores.
/// Algorithmic names for CJK/Hangul ranges are not included.
pub fn lookupCharName(query: []const u8) ?u21 {
    var buffer: [128]u8 = undefined;
    var length: usize = 0;
    for (query) |byte| {
        if (byte == ' ' or byte == '-' or byte == '_' or byte == '\t') continue;
        if (byte >= 0x80) return null;
        if (length == buffer.len) return null;
        buffer[length] = std.ascii.toUpper(byte);
        length += 1;
    }
    if (length == 0) return null;
    const key = buffer[0..length];
    const count = std.mem.readInt(u32, char_names_data[0..4], .little);
    const names_start = 4 + @as(usize, count) * 10;
    var low: usize = 0;
    var high: usize = count;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const entry = char_names_data[4 + middle * 10 ..];
        const offset = std.mem.readInt(u32, entry[0..4], .little);
        const name_length = std.mem.readInt(u16, entry[4..6], .little);
        const cp = std.mem.readInt(u32, entry[6..10], .little);
        const name = char_names_data[names_start + offset ..][0..name_length];
        const order = std.mem.order(u8, key, name);
        if (order == .lt) {
            high = middle;
        } else if (order == .gt) {
            low = middle + 1;
        } else {
            return @intCast(cp);
        }
    }
    return algorithmicName(key);
}

fn hexNameSuffix(key: []const u8, prefix: []const u8) ?u21 {
    if (!std.mem.startsWith(u8, key, prefix)) return null;
    const suffix = key[prefix.len..];
    if (suffix.len < 4 or suffix.len > 6) return null;
    return std.fmt.parseInt(u21, suffix, 16) catch null;
}

fn isCjkIdeograph(cp: u21) bool {
    return (cp >= 0x3400 and cp <= 0x4dbf) or
        (cp >= 0x4e00 and cp <= 0x9fff) or
        (cp >= 0x20000 and cp <= 0x2a6df) or
        (cp >= 0x2a700 and cp <= 0x2b73f) or
        (cp >= 0x2b740 and cp <= 0x2b81f) or
        (cp >= 0x2b820 and cp <= 0x2ceaf) or
        (cp >= 0x2ceb0 and cp <= 0x2ebef) or
        (cp >= 0x30000 and cp <= 0x3134f) or
        (cp >= 0x31350 and cp <= 0x323af);
}

fn isCjkCompatibility(cp: u21) bool {
    return (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0x2f800 and cp <= 0x2fa1f);
}

fn algorithmicName(key: []const u8) ?u21 {
    if (hexNameSuffix(key, "CJKUNIFIEDIDEOGRAPH")) |cp| {
        if (isCjkIdeograph(cp)) return cp;
    }
    if (hexNameSuffix(key, "CJKCOMPATIBILITYIDEOGRAPH")) |cp| {
        if (isCjkCompatibility(cp)) return cp;
    }
    return null;
}

/// Extended_Pictographic property.
pub fn isExtendedPictographic(rune: u21) bool {
    var first: usize = 0;
    var last: usize = grapheme.extpict_count;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = extpict_data[middle * 8 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) last = middle else if (rune > high) first = middle + 1 else return true;
    }
    return false;
}

/// Indic_Conjunct_Break property.
pub fn incbOf(rune: u21) grapheme.InCB {
    var first: usize = 0;
    var last: usize = grapheme.incb_count;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const bytes = incb_data[middle * 12 ..];
        const low = std.mem.readInt(u32, bytes[0..4], .little);
        const high = std.mem.readInt(u32, bytes[4..8], .little);
        if (rune < low) last = middle else if (rune > high) first = middle + 1 else return @enumFromInt(bytes[8]);
    }
    return .none;
}
