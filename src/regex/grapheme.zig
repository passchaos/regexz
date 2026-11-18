//! UAX #29 extended grapheme cluster boundaries.
//!
//! Data is generated from Unicode 16.0.0 GraphemeBreakProperty.txt,
//! emoji-data.txt (Extended_Pictographic), and DerivedCoreProperties.txt
//! (Indic_Conjunct_Break) by `tools/codegen/generate.py`.
const std = @import("std");
const unicode = @import("unicode.zig");
const Gcb = unicode.grapheme.Gcb;
const InCB = unicode.grapheme.InCB;

const Rune = struct { value: u21, len: usize };

fn runeAt(input: []const u8, offset: usize) ?Rune {
    if (offset >= input.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn shouldJoin(
    previous: Gcb,
    current: Gcb,
    current_incb: InCB,
    current_extpict: bool,
    ri_count: usize,
    emoji_state: u2,
    incb_state: u2,
) bool {
    // GB3: CR × LF
    if (previous == .cr and current == .lf) return true;
    // GB4: (Control | CR | LF) ÷
    if (previous == .control or previous == .cr or previous == .lf) return false;
    // GB5: ÷ (Control | CR | LF)
    if (current == .control or current == .cr or current == .lf) return false;
    // GB6: L × (L | V | LV | LVT)
    if (previous == .l and (current == .l or current == .v or current == .lv or current == .lvt)) return true;
    // GB7: (LV | V) × (V | T)
    if ((previous == .lv or previous == .v) and (current == .v or current == .t)) return true;
    // GB8: (LVT | T) × T
    if ((previous == .lvt or previous == .t) and current == .t) return true;
    // GB9: × (Extend | ZWJ)
    if (current == .extend or current == .zwj) return true;
    // GB9a: × SpacingMark
    if (current == .spacing_mark) return true;
    // GB9b: Prepend ×
    if (previous == .prepend) return true;
    // GB9c: Consonant [Extend Linker]* Linker [Extend Linker]* × Consonant
    if (incb_state == 2 and current_incb == .consonant) return true;
    // GB11: ExtPict Extend* ZWJ × ExtPict
    if (emoji_state == 3 and current_extpict) return true;
    // GB12/GB13: RI RI* × RI (odd number of preceding RIs)
    if (previous == .regional_indicator and current == .regional_indicator and (ri_count & 1) == 1) return true;
    // GB999: ÷
    return false;
}

/// Whether `offset` is an extended grapheme cluster boundary. The scan starts
/// at the beginning of the input, which is exact but O(offset); assertions are
/// rare enough that this stays out of the hot matching paths.
pub fn isBoundary(input: []const u8, offset: usize) bool {
    if (offset == 0 or offset >= input.len) return true;
    var pos: usize = 0;
    while (pos < offset) {
        const next_pos = next(input, pos);
        if (next_pos > offset) return false;
        if (next_pos == offset) return true;
        pos = next_pos;
    }
    return pos == offset;
}

/// Returns the byte offset just past the extended grapheme cluster that
/// starts at `offset`. Invalid UTF-8 is treated as a one-byte cluster.
pub fn next(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return input.len;
    const first = runeAt(input, offset) orelse return offset + 1;
    var pos = offset + first.len;
    var previous = unicode.gcbOf(first.value);
    var ri_count: usize = if (previous == .regional_indicator) 1 else 0;
    var emoji_state: u2 = if (unicode.isExtendedPictographic(first.value)) 1 else 0;
    var incb_state: u2 = if (unicode.incbOf(first.value) == .consonant) 1 else 0;
    while (pos < input.len) {
        const current_rune = runeAt(input, pos) orelse break;
        const current = unicode.gcbOf(current_rune.value);
        const current_incb = unicode.incbOf(current_rune.value);
        const current_extpict = unicode.isExtendedPictographic(current_rune.value);
        if (!shouldJoin(previous, current, current_incb, current_extpict, ri_count, emoji_state, incb_state)) break;

        // Update the state used by GB9c, GB11, and GB12/13.
        if (current_incb == .consonant) {
            incb_state = 1;
        } else if (current_incb == .linker) {
            if (incb_state != 0) incb_state = 2;
        } else if (current_incb == .extend) {
            // Keep the current consonant/linker state.
        } else if (current != .extend and current != .zwj and current != .spacing_mark) {
            incb_state = 0;
        }

        if (current_extpict) {
            emoji_state = 1;
        } else if (current == .extend) {
            if (emoji_state != 0) emoji_state = 2;
        } else if (current == .zwj) {
            emoji_state = if (emoji_state == 1 or emoji_state == 2) 3 else 0;
        } else {
            emoji_state = 0;
        }

        if (current == .regional_indicator) {
            ri_count = if (previous == .regional_indicator) ri_count + 1 else 1;
        } else {
            ri_count = 0;
        }

        previous = current;
        pos += current_rune.len;
    }
    return pos;
}
