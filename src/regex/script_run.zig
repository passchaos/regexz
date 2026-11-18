//! PCRE2 script-run validation for `(*sr:...)` and `(*asr:...)`, following
//! UAX #24 and UTS #39: characters must share a script after augmenting Han
//! with the Japanese, Korean, and Bopomofo virtual scripts, Common/Inherited
//! characters are ignored, and decimal digits must come from one digit set.
const std = @import("std");
const unicode = @import("unicode.zig");

const Decoded = struct { value: u21, len: usize };

fn decode(input: []const u8, offset: usize, end: usize) ?Decoded {
    if (offset >= end) return null;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
    if (len > end - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn neutral(ids: []const u16) bool {
    for (ids) |id| {
        if (id == unicode.script_common or id == unicode.script_inherited) return true;
    }
    return false;
}

fn empty(mask: *const [unicode.script_mask_words]u64) bool {
    for (mask) |word| if (word != 0) return false;
    return true;
}

/// The first code point of the decimal-digit set containing `rune`, or null.
fn digitBlock(group: unicode.Group, rune: u21) ?u21 {
    var first: usize = 0;
    var last = group.count;
    while (first < last) {
        const middle = first + (last - first) / 2;
        const range = group.range(middle);
        if (rune < range.first) {
            last = middle;
        } else if (rune > range.last) {
            first = middle + 1;
        } else return range.first;
    }
    return null;
}

/// True when `input[start..end]` is a script run. Bytes that do not decode are
/// treated as Unknown script, which is only allowed for runs shorter than two
/// characters.
pub fn isScriptRun(input: []const u8, start: usize, end: usize) bool {
    if (end <= start) return true;
    const nd = unicode.lookup("Nd");
    var offset = start;
    var count: usize = 0;
    var unknown = false;
    var intersection: [unicode.script_mask_words]u64 = undefined;
    for (&intersection) |*word| word.* = ~@as(u64, 0);
    var block: ?u21 = null;
    while (offset < end) {
        const decoded = decode(input, offset, end) orelse {
            unknown = true;
            count += 1;
            offset += 1;
            continue;
        };
        count += 1;
        offset += decoded.len;
        if (unicode.scriptSetFor(decoded.value)) |set| {
            if (!neutral(set.ids)) {
                for (&intersection, set.mask) |*word, mask_word| word.* &= mask_word;
                if (empty(&intersection)) return false;
            }
        } else unknown = true;
        if (nd) |group| {
            if (digitBlock(group, decoded.value)) |value| {
                if (block) |existing| {
                    if (existing != value) return false;
                } else block = value;
            }
        }
    }
    if (count < 2) return true;
    return !unknown;
}
