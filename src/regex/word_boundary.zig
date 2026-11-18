//! UAX #29 word boundaries.
//!
//! The boundary check is local: it inspects the significant characters around
//! the position, skipping Extend/Format/ZWJ as required by WB4, and applies
//! the WB3..WB16 rules. Official WordBreakTest.txt cases are checked by
//! `word_boundary_tests.zig`.
const std = @import("std");
const unicode = @import("unicode.zig");
const Wb = unicode.Wb;

const Rune = struct { value: u21, start: usize, len: usize };

fn runeAt(input: []const u8, offset: usize) ?Rune {
    if (offset >= input.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return null;
    if (len > input.len - offset) return null;
    const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
    return .{ .value = value, .start = offset, .len = len };
}

fn runeBefore(input: []const u8, offset: usize) ?Rune {
    if (offset == 0) return null;
    var start = offset - 1;
    while (start > 0 and (input[start] & 0xc0) == 0x80) start -= 1;
    const value = std.unicode.utf8Decode(input[start..offset]) catch return null;
    return .{ .value = value, .start = start, .len = offset - start };
}

fn isIgnored(wb: Wb) bool {
    return wb == .extend or wb == .format or wb == .zwj;
}

fn significantBefore(input: []const u8, offset: usize) ?Rune {
    var pos = offset;
    while (pos > 0) {
        const rune = runeBefore(input, pos) orelse return null;
        if (!isIgnored(unicode.wbOf(rune.value))) return rune;
        pos = rune.start;
    }
    return null;
}

fn significantAfter(input: []const u8, offset: usize) ?Rune {
    var pos = offset;
    while (pos < input.len) {
        const rune = runeAt(input, pos) orelse return null;
        if (!isIgnored(unicode.wbOf(rune.value))) return rune;
        pos += rune.len;
    }
    return null;
}

fn isNewline(wb: Wb) bool {
    return wb == .newline or wb == .cr or wb == .lf;
}

fn isAHLetter(wb: Wb) bool {
    return wb == .aletter or wb == .hebrew_letter;
}

fn isMidLetterQ(wb: Wb) bool {
    return wb == .midletter or wb == .midnumlet or wb == .single_quote;
}

fn isMidNumQ(wb: Wb) bool {
    return wb == .midnum or wb == .midnumlet or wb == .single_quote;
}

fn isExtendNumLetLeft(wb: Wb) bool {
    return isAHLetter(wb) or wb == .numeric or wb == .katakana or wb == .extendnumlet;
}

fn isExtendNumLetRight(wb: Wb) bool {
    return isAHLetter(wb) or wb == .numeric or wb == .katakana;
}

fn regionalIndicatorCount(input: []const u8, start: usize) usize {
    var count: usize = 0;
    var pos = start;
    while (true) {
        const rune = significantBefore(input, pos) orelse break;
        if (unicode.wbOf(rune.value) != .regional_indicator) break;
        count += 1;
        pos = rune.start;
    }
    return count;
}

pub fn isBoundary(input: []const u8, offset: usize) bool {
    if (offset == 0 or offset >= input.len) return true;
    const immediate_prev = runeBefore(input, offset);
    const immediate_next = runeAt(input, offset);
    const immediate_prev_wb: ?Wb = if (immediate_prev) |rune| unicode.wbOf(rune.value) else null;
    const immediate_next_wb: ?Wb = if (immediate_next) |rune| unicode.wbOf(rune.value) else null;
    // WB3c: ZWJ × Extended_Pictographic
    if (immediate_prev_wb != null and immediate_prev_wb.? == .zwj and immediate_next != null and
        unicode.isExtendedPictographic(immediate_next.?.value)) return false;
    const prev_opt = significantBefore(input, offset);
    if (prev_opt == null) {
        // All preceding characters are ignored. A boundary before another
        // ignored character is suppressed; otherwise the run attaches to sot
        // and the boundary is allowed (WB4 exception).
        if (immediate_next_wb != null and isIgnored(immediate_next_wb.?)) return false;
        return true;
    }
    const prev = prev_opt.?;
    const prev_wb = unicode.wbOf(prev.value);
    // WB4: ignore Extend/Format/ZWJ, except at the start and after newlines.
    // This must run before WB3b: a boundary before an ignored character is
    // suppressed even when the next significant character is a newline or the
    // input ends inside the ignored run. WB3a's newline exception is checked
    // with the immediate previous character.
    if (immediate_next_wb != null and isIgnored(immediate_next_wb.?)) {
        if (immediate_prev_wb != null and isNewline(immediate_prev_wb.?)) return true;
        return false;
    }
    const next = significantAfter(input, offset) orelse return true;
    const next_wb = unicode.wbOf(next.value);
    // WB3: CR × LF (only when adjacent; an intervening Extend breaks it).
    if (immediate_prev_wb == .cr and immediate_next_wb == .lf) return false;
    // WB3a/WB3b: newlines break words, using the adjacent characters.
    if ((immediate_prev_wb != null and isNewline(immediate_prev_wb.?)) or
        (immediate_next_wb != null and isNewline(immediate_next_wb.?))) return true;
    // WB3d: WSegSpace × WSegSpace (adjacent only).
    if (immediate_prev_wb == .wsegspace and immediate_next_wb == .wsegspace) return false;
    const prev2 = significantBefore(input, prev.start);
    const next2 = significantAfter(input, next.start + next.len);
    const prev2_wb: ?Wb = if (prev2) |rune| unicode.wbOf(rune.value) else null;
    const next2_wb: ?Wb = if (next2) |rune| unicode.wbOf(rune.value) else null;
    // WB5-WB13b.
    if (isAHLetter(prev_wb) and isAHLetter(next_wb)) return false;
    if (isAHLetter(prev_wb) and isMidLetterQ(next_wb) and next2_wb != null and isAHLetter(next2_wb.?)) return false;
    if (prev2_wb != null and isAHLetter(prev2_wb.?) and isMidLetterQ(prev_wb) and isAHLetter(next_wb)) return false;
    if (prev_wb == .hebrew_letter and next_wb == .single_quote) return false;
    if (prev_wb == .hebrew_letter and next_wb == .double_quote and next2_wb != null and next2_wb.? == .hebrew_letter) return false;
    if (prev2_wb != null and prev2_wb.? == .hebrew_letter and prev_wb == .double_quote and next_wb == .hebrew_letter) return false;
    if (prev_wb == .numeric and next_wb == .numeric) return false;
    if (isAHLetter(prev_wb) and next_wb == .numeric) return false;
    if (prev_wb == .numeric and isAHLetter(next_wb)) return false;
    if (prev2_wb != null and prev2_wb.? == .numeric and isMidNumQ(prev_wb) and next_wb == .numeric) return false;
    if (prev_wb == .numeric and isMidNumQ(next_wb) and next2_wb != null and next2_wb.? == .numeric) return false;
    if (prev_wb == .katakana and next_wb == .katakana) return false;
    if (isExtendNumLetLeft(prev_wb) and next_wb == .extendnumlet) return false;
    if (prev_wb == .extendnumlet and isExtendNumLetRight(next_wb)) return false;
    // WB15/WB16: pair regional indicators from the start.
    if (prev_wb == .regional_indicator and next_wb == .regional_indicator) {
        const count = regionalIndicatorCount(input, prev.start);
        if ((count + 1) % 2 == 1) return false;
    }
    return true;
}
