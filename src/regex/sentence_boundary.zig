//! UAX #29 sentence boundaries.
//!
//! Sentence boundaries are sparse: SB998 is "Any × Any" (no boundary), and
//! boundaries are created by SB4 (after a paragraph separator) and SB11
//! (after a terminator, trailing close punctuation, spaces, and an optional
//! paragraph separator). SB3 and SB5..SB10 suppress boundaries. Official
//! SentenceBreakTest.txt cases are checked by `sentence_boundary_tests.zig`.
const std = @import("std");
const unicode = @import("unicode.zig");
const Sb = unicode.Sb;

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

fn isIgnored(sb: Sb) bool {
    return sb == .extend or sb == .format;
}

fn significantBefore(input: []const u8, offset: usize) ?Rune {
    var pos = offset;
    while (pos > 0) {
        const rune = runeBefore(input, pos) orelse return null;
        if (!isIgnored(unicode.sbOf(rune.value))) return rune;
        pos = rune.start;
    }
    return null;
}

fn significantAfter(input: []const u8, offset: usize) ?Rune {
    var pos = offset;
    while (pos < input.len) {
        const rune = runeAt(input, pos) orelse return null;
        if (!isIgnored(unicode.sbOf(rune.value))) return rune;
        pos += rune.len;
    }
    return null;
}

fn isParaSep(sb: Sb) bool {
    return sb == .sep or sb == .cr or sb == .lf;
}

fn isTerminator(sb: Sb) bool {
    return sb == .aterm or sb == .sterm;
}

/// Scan back over Close* (and optionally Sp* before that) and return the
/// terminator immediately before the run.
fn scanBack(input: []const u8, offset: usize, allow_sp: bool) ?Sb {
    var pos = offset;
    if (allow_sp) {
        while (true) {
            const rune = significantBefore(input, pos) orelse return null;
            if (unicode.sbOf(rune.value) != .sp) break;
            pos = rune.start;
        }
    }
    while (true) {
        const rune = significantBefore(input, pos) orelse return null;
        const sb = unicode.sbOf(rune.value);
        if (sb == .close) {
            pos = rune.start;
            continue;
        }
        if (isTerminator(sb)) return sb;
        return null;
    }
}

/// SB8 lookahead: (not OLetter/Upper/Lower/ParaSep/STerm/ATerm)* Lower.
fn lowerAhead(input: []const u8, offset: usize) bool {
    var pos = offset;
    while (pos < input.len) {
        const rune = runeAt(input, pos) orelse return false;
        const sb = unicode.sbOf(rune.value);
        if (sb == .lower) return true;
        if (sb == .oletter or sb == .upper or isParaSep(sb) or isTerminator(sb)) return false;
        pos += rune.len;
    }
    return false;
}

/// SB11: (STerm | ATerm) Close* Sp* (Sep | CR | LF)? ÷
fn sentenceEnd(input: []const u8, offset: usize) ?Sb {
    var pos = offset;
    if (significantBefore(input, pos)) |rune| {
        const sb = unicode.sbOf(rune.value);
        if (isParaSep(sb)) pos = rune.start;
    }
    while (true) {
        const rune = significantBefore(input, pos) orelse return null;
        if (unicode.sbOf(rune.value) != .sp) break;
        pos = rune.start;
    }
    while (true) {
        const rune = significantBefore(input, pos) orelse return null;
        const sb = unicode.sbOf(rune.value);
        if (sb == .close) {
            pos = rune.start;
            continue;
        }
        if (isTerminator(sb)) return sb;
        return null;
    }
}

pub fn isBoundary(input: []const u8, offset: usize) bool {
    if (offset == 0 or offset >= input.len) return true;
    const immediate_prev = runeBefore(input, offset);
    const immediate_next = runeAt(input, offset);
    const immediate_prev_sb: ?Sb = if (immediate_prev) |rune| unicode.sbOf(rune.value) else null;
    const immediate_next_sb: ?Sb = if (immediate_next) |rune| unicode.sbOf(rune.value) else null;
    // SB3: CR × LF
    if (immediate_prev_sb == .cr and immediate_next_sb == .lf) return false;
    // SB4: ParaSep ÷
    if (immediate_prev_sb != null and isParaSep(immediate_prev_sb.?)) return true;
    // SB5: X (Extend | Format)* -> X; a boundary before an ignored character
    // is suppressed unless SB4 already created one.
    if (immediate_next_sb != null and isIgnored(immediate_next_sb.?)) return false;
    const prev_opt = significantBefore(input, offset);
    if (prev_opt == null) {
        // Only ignored characters precede the boundary; they attach to the
        // start of text and SB998 keeps them joined to what follows.
        return false;
    }
    const prev = prev_opt.?;
    const prev_sb = unicode.sbOf(prev.value);
    // SB4 creates the boundary before an ignored run that follows a
    // paragraph separator; SB5 attaches that run to the separator, so there
    // is no second boundary after it.
    if (immediate_prev_sb != null and isIgnored(immediate_prev_sb.?) and isParaSep(prev_sb)) return false;
    const next = significantAfter(input, offset) orelse return true;
    const next_sb = unicode.sbOf(next.value);
    // SB6: ATerm × Numeric
    if (prev_sb == .aterm and next_sb == .numeric) return false;
    // SB7: (Upper | Lower) ATerm × Upper
    if (prev_sb == .aterm and next_sb == .upper) {
        if (significantBefore(input, prev.start)) |prev2| {
            const prev2_sb = unicode.sbOf(prev2.value);
            if (prev2_sb == .upper or prev2_sb == .lower) return false;
        }
    }
    const terminator_sp = scanBack(input, offset, true);
    const terminator_close = scanBack(input, offset, false);
    // SB8: ATerm Close* Sp* × (not OLetter/Upper/Lower/ParaSep/STerm/ATerm)* Lower
    if (terminator_sp != null and terminator_sp.? == .aterm and lowerAhead(input, next.start)) return false;
    // SB8a: (STerm | ATerm) Close* Sp* × (SContinue | STerm | ATerm)
    if (terminator_sp != null and isTerminator(terminator_sp.?) and
        (next_sb == .scontinue or next_sb == .sterm or next_sb == .aterm)) return false;
    // SB9: (STerm | ATerm) Close* × (Close | Sp | Sep | CR | LF)
    if (terminator_close != null and isTerminator(terminator_close.?) and
        (next_sb == .close or next_sb == .sp or isParaSep(next_sb))) return false;
    // SB10: (STerm | ATerm) Close* Sp* × (Sp | Sep | CR | LF)
    if (terminator_sp != null and isTerminator(terminator_sp.?) and
        (next_sb == .sp or isParaSep(next_sb))) return false;
    // SB11: (STerm | ATerm) Close* Sp* (Sep | CR | LF)? ÷
    if (sentenceEnd(input, offset) != null) return true;
    // SB998: Any × Any
    return false;
}
