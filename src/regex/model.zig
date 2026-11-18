//! Immutable syntax/character sets and bounded Thompson instructions.
const std = @import("std");
pub const unicode = @import("unicode.zig");
pub const StringProperty = unicode.StringProperty;
pub const Error = std.mem.Allocator.Error || error{ InvalidRegex, UnsupportedRegexFeature, RegexLimitExceeded };
/// Result of a full-match partiality query.
pub const PartialResult = enum { none, partial, full };

pub const CalloutAction = enum { proceed, fail };
/// One `(?C...)` site: either a numeric id or a string name.
pub const CalloutSpec = struct {
    number: u32 = 0,
    name: ?[]const u8 = null,
};
/// `(?C...)` callback. `position` is the byte offset in the subject.
pub const Callout = struct {
    context: ?*anyopaque = null,
    function: *const fn (context: ?*anyopaque, callout: CalloutSpec, position: usize) CalloutAction,
};
pub const Limits = struct {
    max_pattern_bytes: usize = 4096,
    max_nodes: usize = 8192,
    max_instructions: usize = 8192,
    max_depth: usize = 64,
    /// Maximum repetitions. Values above 1000 are rejected as invalid
    /// syntax for RE2 compatibility; lowering this limit tightens parsing.
    max_repeat: usize = 1000,
    max_ranges: usize = 4096,
    /// Use Unicode White_Space for `\s` and its negation for `\S`.
    unicode_perl_space: bool = false,
    /// Use Unicode property sets for `\d` (`\p{Nd}`) and `\w`
    /// (`\p{L}\p{M}\p{N}\p{Pc}`). UCP `\b` is also enabled by this flag.
    unicode_perl_classes: bool = false,
    /// Bounded backtracking budget for capture-aware replacement. Boolean
    /// matching remains linear and does not use these.
    max_execution_steps: usize = 4_000_000,
    max_backtrack_choices: usize = 262_144,
    max_capture_trail: usize = 262_144,
    /// Maximum nesting depth for lookaround/atomic/conditional sub-runs.
    max_recursion_depth: usize = 64,
    /// Retry non-extended searches with the capture-aware linear Pike engine
    /// when the backtracking budget is exhausted. Enabled by default so
    /// ordinary linear patterns keep the RE2-style linear-time guarantee;
    /// set false to keep the backtracking budget fail-closed.
    linear_fallback: bool = true,
    /// Leftmost-longest (POSIX) matching for search/replace. When false,
    /// leftmost-first (Perl/PCRE) semantics are used.
    longest: bool = false,
    /// PCRE2-style `\v`/`\V`: vertical whitespace and its negation. When
    /// false, `\v` is the RE2/Go vertical-tab escape.
    pcre_vertical_whitespace: bool = false,
    /// Optional `(?C...)` callout invoked by the extended VM.
    callout: ?Callout = null,
    /// Insert callout 255 before every consuming atom (PCRE2-style
    /// `PCRE2_AUTO_CALLOUT`). Auto-callouts force the extended VM.
    auto_callout: bool = false,
    /// JavaScript-style capture reset: groups inside a repeated subexpression
    /// are cleared at the start of every iteration. Defaults to PCRE2/Rust
    /// semantics, which keep the last participating value.
    capture_reset: bool = false,
    /// PCRE2 `PCRE2_MATCH_UNSET_BACKREF` / JavaScript semantics: a
    /// backreference to a group that did not participate matches the empty
    /// string. The default is to fail the path (PCRE2/Perl/Rust).
    unset_backref_empty: bool = false,
    /// Use full Unicode SpecialCasing in replacement case transforms. The
    /// default is the PCRE2-compatible simple one-to-one mapping; enabling
    /// this allows multi-character mappings such as `ß` -> `SS`.
    full_case_mapping: bool = false,
};
pub const Flags = struct {
    fold: bool = false,
    dot_newline: bool = false,
    multiline: bool = false,
    extended: bool = false,
    /// `(?U)`: swap greedy and lazy quantifier defaults.
    ungreedy: bool = false,
    /// `(?n)`: plain `(...)` groups do not capture; named groups still do.
    no_auto_capture: bool = false,
    /// `(?J)`: allow duplicate capture-group names.
    duplicate_names: bool = false,
};
pub const GroupName = struct { name: []const u8, index: u16 };
pub const ParseResult = struct {
    root: *const Node,
    group_names: []const GroupName,
    /// Names from `(*MARK:name)` in source order.
    marks: []const []const u8 = &.{},
    /// Callout sites in source order.
    callouts: []const CalloutSpec = &.{},
    /// Capture node for each group index (0 is the root pattern).
    group_nodes: []const *const Node,
    capture_count: u16,
    extended: bool,
};
pub const Range = unicode.Range;
/// Pre-materialization set: positive ranges plus the requested fold/negate.
/// The parser keeps this form until a class is complete so folding happens
/// before complementing.
pub const ParsedSet = struct {
    ranges: []const Range,
    negate: bool = false,
    fold: bool = false,
};
/// A positive, case-folded set. Negation and `(?i)` folding are materialized
/// at compile time so matching is a binary search (plus a 128-bit ASCII
/// bitmap fast path).
pub const Set = struct {
    ranges: []const Range,
    /// Membership for ASCII runes, indexed by `rune >> 6`.
    ascii: [2]u64 = .{ 0, 0 },
    /// True when every range is below U+0080, allowing non-ASCII rejection
    /// without a binary search.
    ascii_only: bool = false,
    fn includes(self: Set, rune: u21) bool {
        // Parser merges and sorts ranges before instruction construction.
        var first: usize = 0;
        var last = self.ranges.len;
        while (first < last) {
            const middle = first + (last - first) / 2;
            const range = self.ranges[middle];
            if (rune < range.first) last = middle else if (rune > range.last) first = middle + 1 else return true;
        }
        return false;
    }
    pub fn matches(self: Set, rune: u21) bool {
        if (rune < 128) {
            const word = self.ascii[@intCast(rune >> 6)];
            return (word >> @intCast(rune & 63)) & 1 != 0;
        }
        if (self.ascii_only) return false;
        return self.includes(rune);
    }
    /// Offset just past the rune at `offset` when that rune belongs to the
    /// set; null when the rune is absent, malformed, or not a member.
    pub fn matchAdvance(self: Set, input: []const u8, offset: usize) ?usize {
        if (offset >= input.len) return null;
        const byte = input[offset];
        if (byte < 0x80) return if (self.matches(byte)) offset + 1 else null;
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return null;
        if (len > input.len - offset) return null;
        const value = std.unicode.utf8Decode(input[offset..][0..len]) catch return null;
        return if (self.matches(value)) offset + len else null;
    }
};
/// Conservative ASCII/non-ASCII first-rune summary for an instruction
/// subgraph. `empty` is true when the subgraph can match without consuming
/// input, in which case the summary must not be used to skip the subgraph.
pub const FirstSet = struct {
    ascii: [2]u64 = .{ 0, 0 },
    /// Some consuming instruction can match a rune at or above U+0080 (or an
    /// arbitrary byte). When false, a non-ASCII byte can never start a match.
    nonascii: bool = false,
    /// The subgraph can reach `accept` without consuming input.
    empty: bool = false,
    pub fn merge(a: FirstSet, b: FirstSet) FirstSet {
        return .{
            .ascii = .{ a.ascii[0] | b.ascii[0], a.ascii[1] | b.ascii[1] },
            .nonascii = a.nonascii or b.nonascii,
            .empty = a.empty or b.empty,
        };
    }
    pub fn eql(a: FirstSet, b: FirstSet) bool {
        return a.ascii[0] == b.ascii[0] and a.ascii[1] == b.ascii[1] and
            a.nonascii == b.nonascii and a.empty == b.empty;
    }
    /// Whether the summary can rule out at least some input bytes.
    pub fn selective(self: FirstSet) bool {
        return !self.nonascii or self.ascii[0] != ~@as(u64, 0) or self.ascii[1] != ~@as(u64, 0);
    }
    /// Whether a raw input byte can start the summarized subgraph.
    pub fn allowsByte(self: FirstSet, byte: u8) bool {
        if (byte < 128) return (self.ascii[byte >> 6] >> @intCast(byte & 63)) & 1 != 0;
        return self.nonascii;
    }
};
/// Compiled multi-way alternation dispatch. `branches` are in priority
/// order; `ascii[b]`, `nonascii`, and `eof` are bitmasks of branches that can
/// start at the corresponding position.
pub const Dispatch = struct {
    branches: []const usize,
    ascii: [128]u16 = .{0} ** 128,
    nonascii: u16 = 0,
    eof: u16 = 0,
};
pub const Assertion = enum {
    start_text,
    end_text,
    start_line,
    end_line,
    word_boundary,
    no_word_boundary,
    /// `\G`: true only at the start of the current match attempt.
    start_match,
    /// `\Z`: end of text, or immediately before a final newline.
    end_text_or_newline,
    /// Unicode word boundary (requires `Limits.unicode_perl_classes`).
    word_boundary_unicode,
    no_word_boundary_unicode,
    /// UAX #29 extended grapheme cluster boundary (`\b{gcb}`).
    grapheme_boundary,
    no_grapheme_boundary,
    /// UAX #29 word boundary (`\b{wb}`).
    word_boundary_uax29,
    no_word_boundary_uax29,
    /// UAX #29 sentence boundary (`\b{sb}`).
    sentence_boundary,
    no_sentence_boundary,
};
/// Condition for `(?(cond)yes|no)`.
pub const Condition = union(enum) {
    group: u16,
    /// Lookaround/assertion condition, stored as a `lookaround` node.
    assertion: *const Node,
    /// `(?(R))`: true while executing inside a recursion/subroutine call.
    /// A non-null payload restricts the check to a specific group.
    recursion: ?u16,
};
pub const Node = union(enum) {
    empty,
    flag_change,
    group: *const Node,
    /// Numbered capturing group. `index` is 1-based in opening-paren order.
    capture: struct { index: u16, name: ?[]const u8 = null, child: *const Node },
    byte,
    set: Set,
    pair: struct { left: *const Node, right: *const Node },
    alternate: struct { left: *const Node, right: *const Node },
    repeat: struct {
        child: *const Node,
        minimum: usize,
        maximum: ?usize,
        lazy: bool = false,
        possessive: bool = false,
    },
    assertion: Assertion,
    /// Zero-width set assertion. `negative` is true for `(?!set)`.
    lookahead_set: struct { set: Set, negative: bool },
    /// General lookaround. `behind` selects lookbehind. `non_atomic` is
    /// PCRE2 `(?*...)`: the engine may backtrack into the lookaround.
    lookaround: struct { child: *const Node, negative: bool, behind: bool, non_atomic: bool = false },
    /// Numeric or named backreference. Names are resolved to an index at
    /// parse time.
    backref: struct { index: u16 },
    /// `(?>...)`: the first match of the child is committed.
    atomic: *const Node,
    /// `(?(cond)yes|no)`: `no` is null when the else branch is omitted.
    conditional: struct { condition: Condition, yes: *const Node, no: ?*const Node },
    /// `\K`: reset the reported match start to the current position.
    reset_start,
    /// `\X`: one extended grapheme cluster.
    grapheme,
    /// Unicode string property (`\p{RGI_Emoji}`): matches a code point
    /// sequence, not a single rune.
    string_property: StringProperty,
    /// Backtracking control verbs.
    fail,
    accept_verb,
    prune,
    skip,
    /// `(*SKIP:name)`: skip to the last position of the named mark.
    skip_named: []const u8,
    commit,
    /// `(*THEN)`: abandon the current alternative on failure.
    then_verb,
    /// Recursion/subroutine call: `(?R)`, `(?1)`, `(?&name)`, `(?P>name)`.
    subroutine: struct { group: u16 },
    /// `(*MARK:name)`: record a mark index for the match result.
    mark: u16,
    /// `(?C...)` callout site index.
    callout: u16,
};
pub const Instruction = union(enum) {
    accept,
    /// Internal terminator for lookaround/atomic/conditional sub-runs.
    sub_accept,
    byte: usize,
    /// ASCII literal fast path: exactly one byte, no set lookup.
    literal_byte: struct { value: u8, next: usize },
    /// Non-ASCII literal fast path: exactly one rune.
    literal_rune: struct { value: u21, next: usize },
    consume: struct { set: Set, next: usize },
    /// Greedy single-rune loop: zero or more matches of `set` followed by
    /// `next`. Backtracking re-enters the loop one rune earlier instead of
    /// keeping one choice per iteration, so runs cost O(1) memory.
    /// `backtrack` is false when the continuation cannot fail (it leads
    /// directly to accept), so the search VM can skip the choice record.
    star: struct { set: Set, next: usize, backtrack: bool = true },
    split: struct {
        left: usize,
        right: usize,
        /// True for alternation splits, false for quantifier splits. Used by
        /// `(*THEN)` to find the closest enclosing alternative.
        alternation: bool = false,
        /// First-rune summary of `left`. When `skip` is set and the current
        /// byte is not in `first`, the left branch is dead at this position
        /// and execution can jump straight to `right`.
        first: FirstSet = .{ .nonascii = true, .empty = true },
        skip: bool = false,
    },
    assertion: struct { kind: Assertion, next: usize },
    /// Zero-width set assertion. The set is tested against the rune at the
    /// current input offset; the offset itself never advances.
    lookahead: struct { set: Set, negative: bool, next: usize },
    /// General lookaround. `child` is a sub-program terminated by
    /// `sub_accept`.
    lookaround: struct { child: usize, negative: bool, behind: bool, next: usize },
    /// Backreference to a captured group.
    backref: struct { group: u16, next: usize },
    /// Atomic sub-expression: commit to the first match of `child`.
    atomic: struct { child: usize, next: usize },
    /// Zero-width conditional branch on whether `group` participated.
    conditional: struct { group: u16, yes: usize, no: usize },
    /// Zero-width conditional branch on a lookaround/assertion condition.
    conditional_assert: struct { child: usize, negative: bool, behind: bool, yes: usize, no: usize },
    /// Zero-width conditional branch on being inside a recursion call.
    /// `group == null` means any recursion; otherwise a specific group.
    conditional_recursion: struct { group: ?u16, yes: usize, no: usize },
    /// Reset the reported match start (`\K`).
    reset_start: usize,
    /// Consume one extended grapheme cluster (`\X`).
    grapheme: usize,
    /// Match a Unicode string property (`\p{RGI_Emoji}`).
    string_property: struct { property: StringProperty, next: usize },
    /// Always fail (`(*FAIL)`).
    fail,
    /// Accept immediately (`(*ACCEPT)`).
    accept_verb,
    /// Discard choices before this point on failure.
    prune: usize,
    /// Discard choices and resume the search at this position (or the named
    /// mark position) on failure.
    skip: struct { next: usize, name: ?[]const u8 = null },
    /// Abort the search on failure.
    commit: usize,
    /// `(*THEN)`: on failure, discard choices made inside the current
    /// alternative and resume at the next alternative.
    then: usize,
    /// Zero-width mark recording for `(*MARK:name)`.
    mark: struct { index: u16, next: usize },
    /// `(?C...)` callout invoked by the extended VM.
    callout: struct { id: u16, next: usize },
    /// Auto-callout 255 before a consuming atom.
    auto_callout: usize,
    /// Clear capture slots `[first, last)` at the start of a repetition
    /// iteration (`Limits.capture_reset`).
    reset_captures: struct { first: u16, last: u16, next: usize },
    /// Multi-way alternation dispatch; `table` indexes `Program.dispatches`.
    dispatch: struct { table: u16 },
    /// Restore the current position from a hidden slot. Used by non-atomic
    /// lookahead: the child consumes input, then the position is reset before
    /// the continuation, while the child's choices stay backtrackable.
    restore_pos: struct { slot: u16, next: usize },
    /// Recursion/subroutine call. `child` is the subroutine body start and
    /// `next` is the return continuation.
    call: struct { group: u16, child: usize, next: usize },
    /// Return from a subroutine call.
    ret,
    /// Capture boundary. Slot 0/1 are the whole match; group `i` uses
    /// slots `2*i` and `2*i+1`.
    save: struct { slot: u16, next: usize },
};
