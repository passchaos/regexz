//! Compile-time regular expressions.
//!
//! The pattern is parsed and turned into a matcher at compile time: the
//! generated code is a recursive-descent matcher with continuation-passing
//! backtracking, so alternation and greedy/lazy repetition explore every
//! path in leftmost-first order. Nothing is allocated at runtime and the
//! compiled pattern carries no data tables.
//!
//! The parser follows the ctregex.zig construction style (comptime locals
//! plus `&local` for the tree), which keeps the whole pipeline inside the
//! comptime evaluator; `std.mem.Allocator` cannot be used there because its
//! byte-allocation wrapper calls `@memset(undefined)`.
//!
//! Supported syntax: literals and escapes (`\n \r \t \\ \d \D \w \W \s \S`),
//! classes (`[a-z0-9_]`, `[^...]`), `.`, repetition (`* + ? {n} {n,} {n,m}`
//! and their lazy forms), alternation, non-capturing groups, anchors
//! (`^ $ \A \z`), and the inline flags `(?i)`, `(?s)`, `(?m)`.
//!
//! ```zig
//! const ct = @import("regexz").comptime_regex;
//! if (ct.search("(?i)foo[0-9]+", "xx FOO42 yy")) |span| {
//!     // span.start == 3, span.end == 8
//! }
//! ```
const std = @import("std");

pub const Span = struct {
    start: usize,
    end: usize,
};

/// Rune range, inclusive.
pub const Range = struct { first: u21, last: u21 };

const SetSpec = struct {
    ranges: []const Range,
    negated: bool,
    caseless: bool,
    /// ASCII membership bitmap, computed at comptime with negation applied.
    ascii: [2]u64 = .{ 0, 0 },
    /// Some non-ASCII rune can match.
    nonascii: bool = false,

    fn make(ranges: []const Range, negated: bool, caseless: bool) SetSpec {
        var spec = SetSpec{ .ranges = ranges, .negated = negated, .caseless = caseless };
        var byte: u21 = 0;
        while (byte < 128) : (byte += 1) {
            if (setContains(spec, byte)) spec.ascii[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
        }
        if (negated) {
            spec.nonascii = true;
        } else {
            for (ranges) |range| {
                if (range.last >= 0x80) {
                    spec.nonascii = true;
                    break;
                }
            }
        }
        return spec;
    }
};

const max_repeat = 1024;
const max_captures = 32;

const Ast = union(enum) {
    empty,
    literal: struct { value: u21, caseless: bool },
    /// A run of plain literals coalesced into UTF-8 bytes, so the matcher
    /// compares bytes instead of decoding one rune per node.
    literal_seq: struct { bytes: []const u8 },
    set: SetSpec,
    any: struct { dotall: bool },
    concat: struct { left: *const Ast, right: *const Ast },
    alternate: struct { left: *const Ast, right: *const Ast },
    repeat: struct { child: *const Ast, min: u32, max: ?u32, lazy: bool },
    capture: struct { index: u16, child: *const Ast },
    anchor_start: struct { multiline: bool },
    anchor_end: struct { multiline: bool, strict: bool },
};

const Parser = struct {
    pattern: []const u8,
    pos: usize = 0,
    caseless: bool = false,
    dotall: bool = false,
    multiline: bool = false,
    capture_count: u16 = 0,
    names: [max_captures]?[]const u8 = .{null} ** max_captures,

    fn peek(self: *const Parser) ?u8 {
        if (self.pos >= self.pattern.len) return null;
        return self.pattern[self.pos];
    }

    fn consume(self: *Parser) ?u8 {
        if (self.pos >= self.pattern.len) return null;
        const byte = self.pattern[self.pos];
        self.pos += 1;
        return byte;
    }

    fn parseAlternation(self: *Parser) ?Ast {
        var left = self.parseSequence() orelse return null;
        while (self.peek() == '|') {
            _ = self.consume();
            const right = self.parseSequence() orelse return null;
            // The tree stores pointers to `const` locals only; a reference to
            // a mutated `var` is rejected by the comptime evaluator.
            const left_copy = left;
            const node = Ast{ .alternate = .{ .left = &left_copy, .right = &right } };
            left = node;
        }
        return left;
    }

    fn parseSequence(self: *Parser) ?Ast {
        var items: [256]*const Ast = undefined;
        var count: usize = 0;
        while (self.peek()) |byte| {
            if (byte == '|' or byte == ')') break;
            const atom = self.parseAtom() orelse return null;
            if (count == items.len) @compileError("comptime regex: sequence too long");
            items[count] = &atom;
            count += 1;
        }
        if (count == 0) return Ast.empty;
        // Coalesce runs of plain literals into byte strings.
        var nodes: [256]*const Ast = undefined;
        var node_count: usize = 0;
        var index: usize = 0;
        while (index < count) {
            if (std.meta.activeTag(items[index].*) == .literal and !items[index].literal.caseless) {
                var buffer: [1024]u8 = undefined;
                var length: usize = 0;
                while (index < count and std.meta.activeTag(items[index].*) == .literal and
                    !items[index].literal.caseless) : (index += 1)
                {
                    length += std.unicode.utf8Encode(items[index].literal.value, buffer[length..]) catch
                        @compileError("comptime regex: invalid literal");
                }
                const owned = buffer;
                const node = Ast{ .literal_seq = .{ .bytes = owned[0..length] } };
                nodes[node_count] = &node;
                node_count += 1;
            } else {
                nodes[node_count] = items[index];
                node_count += 1;
                index += 1;
            }
        }
        var result: Ast = nodes[0].*;
        var node_index: usize = 1;
        while (node_index < node_count) : (node_index += 1) {
            const left_copy = result;
            const node = Ast{ .concat = .{ .left = &left_copy, .right = nodes[node_index] } };
            result = node;
        }
        return result;
    }

    fn parseAtom(self: *Parser) ?Ast {
        var atom = self.parsePrimary() orelse return null;
        while (self.peek()) |byte| {
            const bounds: ?struct { min: u32, max: ?u32 } = switch (byte) {
                '*' => .{ .min = 0, .max = null },
                '+' => .{ .min = 1, .max = null },
                '?' => .{ .min = 0, .max = 1 },
                '{' => self.parseBraces(),
                else => null,
            };
            if (bounds == null) break;
            if (byte != '{') _ = self.consume();
            var lazy = false;
            if (self.peek() == '?') {
                _ = self.consume();
                lazy = true;
            }
            const child_copy = atom;
            const node = Ast{ .repeat = .{
                .child = &child_copy,
                .min = bounds.?.min,
                .max = bounds.?.max,
                .lazy = lazy,
            } };
            atom = node;
        }
        return atom;
    }

    fn parseBraces(self: *Parser) ?struct { min: u32, max: ?u32 } {
        const save = self.pos;
        _ = self.consume();
        const min = self.parseNumber() orelse {
            self.pos = save;
            return null;
        };
        if (self.peek() == '}') {
            _ = self.consume();
            return .{ .min = min, .max = min };
        }
        if (self.peek() != ',') {
            self.pos = save;
            return null;
        }
        _ = self.consume();
        if (self.peek() == '}') {
            _ = self.consume();
            return .{ .min = min, .max = null };
        }
        const max = self.parseNumber() orelse {
            self.pos = save;
            return null;
        };
        if (self.peek() != '}') {
            self.pos = save;
            return null;
        }
        _ = self.consume();
        if (max < min) @compileError("comptime regex: repetition upper bound below lower bound");
        return .{ .min = min, .max = max };
    }

    fn parseNumber(self: *Parser) ?u32 {
        var value: u32 = 0;
        var digits: usize = 0;
        while (self.peek()) |byte| {
            if (byte < '0' or byte > '9') break;
            _ = self.consume();
            value = value * 10 + (byte - '0');
            digits += 1;
            if (value > max_repeat) @compileError("comptime regex: repetition count too large");
        }
        if (digits == 0) return null;
        return value;
    }

    fn parsePrimary(self: *Parser) ?Ast {
        const byte = self.peek() orelse return null;
        switch (byte) {
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '.' => {
                _ = self.consume();
                return Ast{ .any = .{ .dotall = self.dotall } };
            },
            '^' => {
                _ = self.consume();
                return Ast{ .anchor_start = .{ .multiline = self.multiline } };
            },
            '$' => {
                _ = self.consume();
                return Ast{ .anchor_end = .{ .multiline = self.multiline, .strict = false } };
            },
            '\\' => return self.parseEscape(),
            ')' => return null,
            '*', '+', '?' => @compileError("comptime regex: repetition without an atom"),
            else => {
                const rune = self.parseRune() orelse return null;
                return Ast{ .literal = .{ .value = rune, .caseless = self.caseless } };
            },
        }
    }

    fn parseGroup(self: *Parser) ?Ast {
        _ = self.consume();
        var capturing = true;
        var name: ?[]const u8 = null;
        if (self.peek() == '?') {
            _ = self.consume();
            const flag = self.peek() orelse @compileError("comptime regex: unterminated group");
            if (flag == 'P' or flag == '<') {
                // Named capture: `(?P<name>...)` or `(?<name>...)`.
                _ = self.consume();
                if (flag == 'P') {
                    if (self.peek() != '<') @compileError("comptime regex: expected '<' after '(?P'");
                    _ = self.consume();
                }
                name = self.parseCaptureName();
            } else {
                switch (flag) {
                    'i' => {
                        _ = self.consume();
                        self.caseless = true;
                    },
                    's' => {
                        _ = self.consume();
                        self.dotall = true;
                    },
                    'm' => {
                        _ = self.consume();
                        self.multiline = true;
                    },
                    ':' => {
                        _ = self.consume();
                        capturing = false;
                    },
                    else => @compileError("comptime regex: unsupported group prefix"),
                }
                if (flag == 'i' or flag == 's' or flag == 'm') {
                    if (self.peek() != ')') @compileError("comptime regex: flag group must be empty");
                    _ = self.consume();
                    return Ast.empty;
                }
            }
        }
        const inner = self.parseAlternation() orelse @compileError("comptime regex: empty group");
        if (self.peek() != ')') @compileError("comptime regex: missing ')'");
        _ = self.consume();
        if (!capturing) return inner;
        self.capture_count += 1;
        if (name) |capture_name| {
            if (self.capture_count > max_captures) @compileError("comptime regex: too many capture groups");
            self.names[self.capture_count - 1] = capture_name;
        }
        const node = Ast{ .capture = .{ .index = self.capture_count, .child = &inner } };
        return node;
    }

    fn parseCaptureName(self: *Parser) []const u8 {
        const start = self.pos;
        while (self.peek()) |byte| {
            if (byte == '>') break;
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') {
                @compileError("comptime regex: invalid capture name");
            }
            _ = self.consume();
        }
        if (self.peek() != '>') @compileError("comptime regex: unterminated capture name");
        const name = self.pattern[start..self.pos];
        _ = self.consume();
        if (name.len == 0) @compileError("comptime regex: empty capture name");
        return name;
    }

    fn parseEscape(self: *Parser) ?Ast {
        _ = self.consume();
        const byte = self.peek() orelse @compileError("comptime regex: trailing backslash");
        _ = self.consume();
        switch (byte) {
            'n' => return Ast{ .literal = .{ .value = '\n', .caseless = false } },
            'r' => return Ast{ .literal = .{ .value = '\r', .caseless = false } },
            't' => return Ast{ .literal = .{ .value = '\t', .caseless = false } },
            'A' => return Ast{ .anchor_start = .{ .multiline = false } },
            'z' => return Ast{ .anchor_end = .{ .multiline = false, .strict = true } },
            'd' => return classAst(.{ .first = '0', .last = '9' }, false),
            'D' => return classAst(.{ .first = '0', .last = '9' }, true),
            'w' => return Ast{ .set = SetSpec.make(&.{
                .{ .first = '0', .last = '9' },
                .{ .first = 'A', .last = 'Z' },
                .{ .first = '_', .last = '_' },
                .{ .first = 'a', .last = 'z' },
            }, false, false) },
            'W' => return Ast{ .set = SetSpec.make(&.{
                .{ .first = '0', .last = '9' },
                .{ .first = 'A', .last = 'Z' },
                .{ .first = '_', .last = '_' },
                .{ .first = 'a', .last = 'z' },
            }, true, false) },
            's' => return Ast{ .set = SetSpec.make(&.{
                .{ .first = 0x09, .last = 0x0D },
                .{ .first = ' ', .last = ' ' },
            }, false, false) },
            'S' => return Ast{ .set = SetSpec.make(&.{
                .{ .first = 0x09, .last = 0x0D },
                .{ .first = ' ', .last = ' ' },
            }, true, false) },
            else => {
                // Escaped punctuation stands for itself.
                if (byte >= 0x80) @compileError("comptime regex: unsupported escape");
                return Ast{ .literal = .{ .value = byte, .caseless = self.caseless } };
            },
        }
    }

    fn classAst(range: Range, negated: bool) Ast {
        return Ast{ .set = SetSpec.make(&[_]Range{range}, negated, false) };
    }

    fn parseClass(self: *Parser) ?Ast {
        _ = self.consume();
        var negated = false;
        if (self.peek() == '^') {
            _ = self.consume();
            negated = true;
        }
        var ranges: [64]Range = undefined;
        var count: usize = 0;
        var first = true;
        while (true) {
            const byte = self.peek() orelse @compileError("comptime regex: unterminated class");
            if (byte == ']' and !first) {
                _ = self.consume();
                break;
            }
            first = false;
            const low = self.parseClassRune() orelse @compileError("comptime regex: empty class");
            if (self.peek() == '-' and self.pos + 1 < self.pattern.len and self.pattern[self.pos + 1] != ']') {
                _ = self.consume();
                const high = self.parseClassRune() orelse @compileError("comptime regex: bad class range");
                if (high < low) @compileError("comptime regex: class range out of order");
                if (count == ranges.len) @compileError("comptime regex: class too large");
                ranges[count] = .{ .first = low, .last = high };
                count += 1;
            } else {
                if (count == ranges.len) @compileError("comptime regex: class too large");
                ranges[count] = .{ .first = low, .last = low };
                count += 1;
            }
        }
        // Copy into a `const` so the returned slice does not reference a
        // comptime var (the evaluator rejects such captures).
        const owned = ranges;
        return Ast{ .set = SetSpec.make(owned[0..count], negated, self.caseless) };
    }

    fn parseClassRune(self: *Parser) ?u21 {
        const byte = self.peek() orelse return null;
        if (byte == '\\') {
            _ = self.consume();
            const escaped = self.peek() orelse @compileError("comptime regex: trailing backslash in class");
            _ = self.consume();
            return switch (escaped) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => escaped,
            };
        }
        return self.parseRune();
    }

    fn parseRune(self: *Parser) ?u21 {
        if (self.pos >= self.pattern.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(self.pattern[self.pos]) catch
            @compileError("comptime regex: invalid UTF-8");
        if (self.pos + len > self.pattern.len) @compileError("comptime regex: truncated UTF-8");
        const rune = std.unicode.utf8Decode(self.pattern[self.pos..][0..len]) catch
            @compileError("comptime regex: invalid UTF-8");
        self.pos += len;
        return rune;
    }
};

/// First-byte summary of a pattern, computed at comptime and embedded as a
/// constant so the search loop can skip impossible starts.
const First = struct {
    ascii: [2]u64 = .{ 0, 0 },
    nonascii: bool = false,
    empty: bool = false,

    fn allowsByte(self: First, byte: u8) bool {
        if (byte < 0x80) {
            return (self.ascii[byte >> 6] >> @intCast(byte & 63)) & 1 != 0;
        }
        return self.nonascii;
    }
};

fn markAscii(first: *First, byte: u8) void {
    first.ascii[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
}

fn markRune(first: *First, rune: u21) void {
    if (rune < 0x80) markAscii(first, @intCast(rune)) else {
        first.nonascii = true;
    }
}

fn computeFirst(comptime node: Ast) First {
    return switch (node) {
        .empty => .{ .empty = true },
        .literal => |literal| blk: {
            var first = First{};
            markRune(&first, literal.value);
            if (literal.caseless and literal.value < 0x80) {
                const lower = asciiLower(literal.value);
                markAscii(&first, @intCast(lower));
                markAscii(&first, @intCast(lower - 32));
            }
            break :blk first;
        },
        .literal_seq => |seq| blk: {
            var first = First{};
            markAscii(&first, seq.bytes[0]);
            break :blk first;
        },
        .set => |set| blk: {
            var first = First{};
            var byte: u21 = 0;
            while (byte < 128) : (byte += 1) {
                if (setContains(set, byte)) markAscii(&first, @intCast(byte));
            }
            if (set.negated) {
                first.nonascii = true;
            } else {
                for (set.ranges) |range| {
                    if (range.last >= 0x80) {
                        first.nonascii = true;
                        break;
                    }
                }
            }
            break :blk first;
        },
        .any => .{ .ascii = .{ ~@as(u64, 0), ~@as(u64, 0) }, .nonascii = true },
        .concat => |concat| blk: {
            const left = computeFirst(concat.left.*);
            if (!left.empty) break :blk left;
            const right = computeFirst(concat.right.*);
            break :blk .{
                .ascii = .{ left.ascii[0] | right.ascii[0], left.ascii[1] | right.ascii[1] },
                .nonascii = left.nonascii or right.nonascii,
                .empty = right.empty,
            };
        },
        .alternate => |alternate| blk: {
            const left = computeFirst(alternate.left.*);
            const right = computeFirst(alternate.right.*);
            break :blk .{
                .ascii = .{ left.ascii[0] | right.ascii[0], left.ascii[1] | right.ascii[1] },
                .nonascii = left.nonascii or right.nonascii,
                .empty = left.empty or right.empty,
            };
        },
        .repeat => |repeat| blk: {
            const child = computeFirst(repeat.child.*);
            if (repeat.min >= 1) break :blk child;
            break :blk .{ .ascii = child.ascii, .nonascii = child.nonascii, .empty = true };
        },
        .capture => |capture| computeFirst(capture.child.*),
        .anchor_start, .anchor_end => .{ .empty = true },
    };
}

/// A parsed pattern. Build it at comptime: `const re = comptime Regex("...")`.
pub fn Regex(comptime pattern: []const u8) type {
    const parsed = compile: {
        @setEvalBranchQuota(200_000);
        comptime var parser = Parser{ .pattern = pattern };
        const root = parser.parseAlternation() orelse
            @compileError("comptime regex: invalid pattern '" ++ pattern ++ "'");
        if (parser.pos != pattern.len) @compileError("comptime regex: unexpected input at end of pattern");
        break :compile .{ .ast = root, .captures = parser.capture_count, .names = parser.names };
    };
    const ast = parsed.ast;
    const capture_count = parsed.captures;
    // Copy the names out of the parse result so the slice below points at a
    // plain `const` array, not at memory the evaluator traces back to the
    // parser's comptime var.
    const capture_names = parsed.names;
    const names = capture_names[0..capture_count];
    return struct {
        pub const source = pattern;
        pub const capture_total = capture_count;

        pub const Match = struct {
            start: usize,
            end: usize,
            captures: [capture_count]?Span,

            pub fn span(self: Match) Span {
                return .{ .start = self.start, .end = self.end };
            }

            /// Span of capture group `index` (1-based), or null when the
            /// group did not participate in the match.
            pub fn group(self: Match, index: usize) ?Span {
                if (index == 0) return self.span();
                if (index > capture_count) return null;
                return self.captures[index - 1];
            }

            /// Span of the named capture group `name`; a compile error when
            /// the pattern has no such group.
            pub fn named(self: Match, comptime name: []const u8) ?Span {
                inline for (names, 0..) |maybe_name, index| {
                    if (maybe_name) |stored| {
                        if (comptime std.mem.eql(u8, name, stored)) return self.group(index + 1);
                    }
                }
                @compileError("comptime regex: no capture named '" ++ name ++ "'");
            }
        };

        /// Full match: the whole input must match.
        pub fn match(input: []const u8) ?Match {
            var slots: [capture_count]?Span = .{null} ** capture_count;
            const end = matchNode(ast, input, 0, EndCont(){}, &slots) orelse return null;
            if (end != input.len) return null;
            return .{ .start = 0, .end = end, .captures = slots };
        }

        /// Leftmost-first search.
        pub fn search(input: []const u8) ?Match {
            const first = comptime computeFirst(ast);
            var start: usize = 0;
            while (start <= input.len) {
                if (!first.empty and start < input.len and !first.allowsByte(input[start])) {
                    const len = std.unicode.utf8ByteSequenceLength(input[start]) catch 1;
                    start += @min(len, input.len - start);
                    continue;
                }
                var slots: [capture_count]?Span = .{null} ** capture_count;
                if (matchNode(ast, input, start, AnyCont(){}, &slots)) |end| {
                    return .{ .start = start, .end = end, .captures = slots };
                }
                if (start == input.len) break;
                const len = std.unicode.utf8ByteSequenceLength(input[start]) catch 1;
                start += @min(len, input.len - start);
            }
            return null;
        }
    };
}

fn EndCont() type {
    return struct {
        pub fn match(self: @This(), input: []const u8, pos: usize, slots: []?Span) ?usize {
            _ = self;
            _ = input;
            _ = slots;
            return pos;
        }
    };
}

fn AnyCont() type {
    return struct {
        pub fn match(self: @This(), input: []const u8, pos: usize, slots: []?Span) ?usize {
            _ = self;
            _ = input;
            _ = slots;
            return pos;
        }
    };
}

fn RepeatCont(comptime Cont: type, comptime child: Ast, comptime min: u32, comptime max: ?u32, comptime lazy: bool) type {
    return struct {
        cont: Cont,
        count: u32,
        last: usize,

        pub fn match(self: @This(), input: []const u8, pos: usize, slots: []?Span) ?usize {
            const can_repeat = (max == null or self.count < max.?) and
                !(self.count > 0 and pos == self.last);
            if (can_repeat) {
                const Next = RepeatCont(Cont, child, min, max, lazy);
                const next_cont = Next{ .cont = self.cont, .count = self.count + 1, .last = pos };
                if (lazy) {
                    // Lazy: prefer the continuation, fall back to more repeats.
                    if (self.count >= min) {
                        if (self.cont.match(input, pos, slots)) |result| return result;
                    }
                    if (matchNode(child, input, pos, next_cont, slots)) |result| return result;
                    return null;
                }
                if (matchNode(child, input, pos, next_cont, slots)) |result| return result;
            }
            if (self.count >= min) return self.cont.match(input, pos, slots);
            return null;
        }
    };
}

fn ConcatCont(comptime Cont: type, comptime right: Ast) type {
    return struct {
        cont: Cont,
        pub fn match(self: @This(), input: []const u8, pos: usize, slots: []?Span) ?usize {
            return matchNode(right, input, pos, self.cont, slots);
        }
    };
}

fn matchNode(comptime node: Ast, input: []const u8, pos: usize, cont: anytype, slots: []?Span) ?usize {
    switch (node) {
        .empty => return cont.match(input, pos, slots),
        .literal => |literal| {
            const decoded = decodeRune(input, pos) orelse return null;
            if (!runeEquals(decoded.value, literal.value, literal.caseless)) return null;
            return cont.match(input, pos + decoded.len, slots);
        },
        .literal_seq => |seq| {
            if (input.len - pos < seq.bytes.len) return null;
            if (!std.mem.eql(u8, input[pos..][0..seq.bytes.len], seq.bytes)) return null;
            return cont.match(input, pos + seq.bytes.len, slots);
        },
        .set => |set| {
            const byte = input[pos];
            if (byte < 0x80) {
                const member = (set.ascii[byte >> 6] >> @intCast(byte & 63)) & 1 != 0;
                if (!member) return null;
                return cont.match(input, pos + 1, slots);
            }
            if (!set.nonascii) return null;
            const decoded = decodeRune(input, pos) orelse return null;
            if (!setContains(set, decoded.value)) return null;
            return cont.match(input, pos + decoded.len, slots);
        },
        .any => |any| {
            const decoded = decodeRune(input, pos) orelse return null;
            if (!any.dotall and decoded.value == '\n') return null;
            return cont.match(input, pos + decoded.len, slots);
        },
        .concat => |concat| {
            return matchNode(concat.left.*, input, pos, ConcatCont(@TypeOf(cont), concat.right.*){ .cont = cont }, slots);
        },
        .alternate => |alternate| {
            if (matchNode(alternate.left.*, input, pos, cont, slots)) |result| return result;
            return matchNode(alternate.right.*, input, pos, cont, slots);
        },
        .repeat => |repeat| {
            const Start = RepeatCont(@TypeOf(cont), repeat.child.*, repeat.min, repeat.max, repeat.lazy);
            const start = Start{ .cont = cont, .count = 0, .last = pos };
            return start.match(input, pos, slots);
        },
        .capture => |capture| {
            const CaptureCont = struct {
                cont: @TypeOf(cont),
                start: usize,
                index: usize,

                pub fn match(self: @This(), text: []const u8, offset: usize, track: []?Span) ?usize {
                    const saved = track[self.index];
                    track[self.index] = .{ .start = self.start, .end = offset };
                    if (self.cont.match(text, offset, track)) |end| {
                        track[self.index] = .{ .start = self.start, .end = end };
                        return end;
                    }
                    // Backtrack: restore the previous capture value.
                    track[self.index] = saved;
                    return null;
                }
            };
            const capture_cont = CaptureCont{ .cont = cont, .start = pos, .index = capture.index - 1 };
            return capture_cont.match(input, pos, slots);
        },
        .anchor_start => |anchor| {
            if (anchor.multiline) {
                if (!(pos == 0 or input[pos - 1] == '\n')) return null;
            } else if (pos != 0) return null;
            return cont.match(input, pos, slots);
        },
        .anchor_end => |anchor| {
            if (anchor.multiline) {
                if (!(pos == input.len or input[pos] == '\n')) return null;
            } else if (pos != input.len) {
                // `$` also matches before a final newline (PCRE2 default).
                const final_newline = !anchor.strict and pos + 1 == input.len and input[pos] == '\n';
                if (!final_newline) return null;
            }
            return cont.match(input, pos, slots);
        },
    }
}

const Decoded = struct { value: u21, len: usize };

fn decodeRune(input: []const u8, pos: usize) ?Decoded {
    if (pos >= input.len) return null;
    if (input[pos] < 0x80) return .{ .value = input[pos], .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(input[pos]) catch return null;
    if (pos + len > input.len) return null;
    const value = std.unicode.utf8Decode(input[pos..][0..len]) catch return null;
    return .{ .value = value, .len = len };
}

fn asciiLower(rune: u21) u21 {
    return if (rune >= 'A' and rune <= 'Z') rune + 32 else rune;
}

fn runeEquals(a: u21, b: u21, caseless: bool) bool {
    if (a == b) return true;
    if (!caseless) return false;
    // ASCII folding only; the runtime engine owns full Unicode folding.
    return a < 0x80 and b < 0x80 and asciiLower(a) == asciiLower(b);
}

fn setContains(set: SetSpec, rune: u21) bool {
    var member = false;
    for (set.ranges) |range| {
        if (rune >= range.first and rune <= range.last) {
            member = true;
            break;
        }
        if (set.caseless and rune < 0x80) {
            const lower = asciiLower(rune);
            if (lower >= range.first and lower <= range.last) {
                member = true;
                break;
            }
            if (lower != rune) {
                const upper = lower - 32;
                if (upper >= range.first and upper <= range.last) {
                    member = true;
                    break;
                }
            }
        }
    }
    return member != set.negated;
}

test "comptime regex full match and search" {
    const re = Regex("(?:foo|bar)[0-9]+");
    try std.testing.expect(re.match("foo42") != null);
    try std.testing.expect(re.match("bar7") != null);
    try std.testing.expect(re.match("foo") == null);
    try std.testing.expect(re.match("baz7") == null);
    const found = re.search("xx bar42 yy").?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 8), found.end);
}

test "comptime regex backtracking through alternation" {
    // Greedy alternation must backtrack: the first branch matches 'a' but
    // the continuation needs 'c', so the engine retries with 'ab'.
    const re = Regex("(?:a|ab)c");
    const found = re.search("abc").?;
    try std.testing.expectEqual(@as(usize, 0), found.start);
    try std.testing.expectEqual(@as(usize, 3), found.end);
}

test "comptime regex greedy and lazy repetition" {
    const greedy = Regex("a+");
    const g = greedy.search("aaa b").?;
    try std.testing.expectEqual(@as(usize, 3), g.end);
    const lazy = Regex("a+?");
    const l = lazy.search("aaa b").?;
    try std.testing.expectEqual(@as(usize, 1), l.end);
    const bounded = Regex("[0-9]{2,3}");
    const b = bounded.search("x12345").?;
    try std.testing.expectEqual(@as(usize, 1), b.start);
    try std.testing.expectEqual(@as(usize, 4), b.end);
}

test "comptime regex classes flags and anchors" {
    const ci = Regex("(?i)hello");
    try std.testing.expect(ci.match("HeLLo") != null);
    try std.testing.expect(ci.match("HELLO") != null);
    try std.testing.expect(ci.match("hell") == null);

    const negated = Regex("[^0-9]+");
    const n = negated.match("abc").?;
    try std.testing.expectEqual(@as(usize, 3), n.end);
    try std.testing.expect(negated.match("a1c") == null);

    const anchored = Regex("\\Aabc\\z");
    try std.testing.expect(anchored.match("abc") != null);
    try std.testing.expect(anchored.match("xabc") == null);
    try std.testing.expect(anchored.search("xabc") == null);

    const words = Regex("\\w+\\s+\\w+");
    const w = words.search("  hello world  ").?;
    try std.testing.expectEqual(@as(usize, 2), w.start);
    try std.testing.expectEqual(@as(usize, 13), w.end);
}

test "comptime regex unicode literals" {
    const han = Regex("\u{4f60}\u{597d}+");
    const found = han.search("xx \u{4f60}\u{597d}\u{597d} yy").?;
    try std.testing.expectEqual(@as(usize, 3), found.start);
    try std.testing.expectEqual(@as(usize, 12), found.end);
}

test "comptime regex matches the runtime engine" {
    const regex = @import("../root.zig").Regex;
    const cases = [_]struct { pattern: []const u8, inputs: []const []const u8 }{
        .{ .pattern = "abc", .inputs = &.{ "abc", "xabc", "ab", "abcd", "" } },
        .{ .pattern = "a+b", .inputs = &.{ "ab", "aaab", "b", "aaa", "xaabz" } },
        .{ .pattern = "[0-9]+", .inputs = &.{ "123", "x42y", "abc", "" } },
        .{ .pattern = "(?:foo|bar)", .inputs = &.{ "foo", "bar", "baz", "xxbar" } },
        .{ .pattern = "(?:a|ab)c", .inputs = &.{ "abc", "ac", "ab", "xabc" } },
        .{ .pattern = "a*", .inputs = &.{ "", "aaa", "baaa" } },
        .{ .pattern = "a+?", .inputs = &.{ "aaa", "b", "ba" } },
        .{ .pattern = "(?i)hello", .inputs = &.{ "Hello", "HELLO", "hello", "hell" } },
        .{ .pattern = "\\w+\\s+\\w+", .inputs = &.{ "hello world", "  a b  ", "abc", "a\nb" } },
        .{ .pattern = "^abc$", .inputs = &.{ "abc", "abc\n", "xabc", "abcx" } },
        .{ .pattern = "[^0-9]+", .inputs = &.{ "abc", "a1c", "123" } },
        .{ .pattern = "a{2,3}", .inputs = &.{ "a", "aa", "aaaa", "xaaaay" } },
        .{ .pattern = "(?:ab)*c", .inputs = &.{ "c", "abc", "ababc", "abab" } },
        .{ .pattern = "\\Aabc\\z", .inputs = &.{ "abc", "xabc", "abc\n" } },
        .{ .pattern = "a.c", .inputs = &.{ "abc", "a\nc", "a\r c" } },
        .{ .pattern = "(?s)a.c", .inputs = &.{ "a\nc", "abc" } },
    };
    for (cases) |case| {
        const compiled = @field(Compiled, case.pattern);
        var value = try regex.Regex.init(std.testing.allocator, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(std.testing.allocator, value.program, .{});
        defer workspace.deinit();
        for (case.inputs) |input| {
            const runtime_full = try value.matches(std.testing.allocator, input);
            const ct_full = compiled.match(input) != null;
            try std.testing.expectEqual(runtime_full, ct_full);
            const runtime_find = try workspace.find(input, 0);
            const ct_find = compiled.search(input);
            if (runtime_find) |found| {
                try std.testing.expect(ct_find != null);
                try std.testing.expectEqual(found.start, ct_find.?.start);
                try std.testing.expectEqual(found.end, ct_find.?.end);
            } else {
                try std.testing.expect(ct_find == null);
            }
        }
    }
}

const Compiled = struct {
    pub const abc = Regex("abc");
    pub const a_plus_b = Regex("a+b");
    pub const digits = Regex("[0-9]+");
    pub const foo_bar = Regex("(?:foo|bar)");
    pub const alt_backtrack = Regex("(?:a|ab)c");
    pub const a_star = Regex("a*");
    pub const a_lazy = Regex("a+?");
    pub const hello_ci = Regex("(?i)hello");
    pub const words = Regex("\\w+\\s+\\w+");
    pub const anchors = Regex("^abc$");
    pub const not_digit = Regex("[^0-9]+");
    pub const bounded = Regex("a{2,3}");
    pub const ab_star_c = Regex("(?:ab)*c");
    pub const strict_anchors = Regex("\\Aabc\\z");
    pub const a_dot_c = Regex("a.c");
    pub const dotall = Regex("(?s)a.c");
};

test "comptime regex evaluates during compilation" {
    const re = Regex("abc[0-9]+");
    // The whole match runs in the comptime evaluator here.
    const span = comptime re.match("abc42");
    try std.testing.expect(span != null);
    try std.testing.expectEqual(@as(usize, 5), span.?.end);
    const missing = comptime re.match("abc");
    try std.testing.expect(missing == null);
}

test "comptime regex captures match the runtime engine" {
    const regex = @import("../root.zig").Regex;
    const unset = std.math.maxInt(usize);
    const cases = [_]struct { pattern: []const u8, inputs: []const []const u8 }{
        .{ .pattern = "(a)(b)", .inputs = &.{ "ab", "xab", "a" } },
        .{ .pattern = "(a|ab)c", .inputs = &.{ "abc", "ac", "ab" } },
        .{ .pattern = "(a)+", .inputs = &.{ "aaa", "b", "ba" } },
        .{ .pattern = "((a)(b))", .inputs = &.{ "ab", "xab" } },
        .{ .pattern = "(x)?y", .inputs = &.{ "y", "xy", "z" } },
        .{ .pattern = "(a*)b", .inputs = &.{ "b", "aab", "c" } },
        .{ .pattern = "(?i)(foo|bar)[0-9]+", .inputs = &.{ "FOO42", "xx bar7", "baz" } },
        .{ .pattern = "(\\w+)@(\\w+)", .inputs = &.{ "user@host", "a b@c", "nope" } },
    };
    for (cases) |case| {
        const compiled = @field(Captures, case.pattern);
        var value = try regex.Regex.init(std.testing.allocator, case.pattern, .{});
        defer value.deinit();
        var workspace = try regex.ReplaceWorkspace.init(std.testing.allocator, value.program, .{});
        defer workspace.deinit();
        for (case.inputs) |input| {
            const runtime_find = try workspace.find(input, 0);
            const ct_find = compiled.search(input);
            if (runtime_find) |found| {
                try std.testing.expect(ct_find != null);
                try std.testing.expectEqual(found.start, ct_find.?.start);
                try std.testing.expectEqual(found.end, ct_find.?.end);
                var group: usize = 1;
                while (group <= compiled.capture_total) : (group += 1) {
                    const runtime_start = found.slots[group * 2];
                    const runtime_end = found.slots[group * 2 + 1];
                    const ct_span = ct_find.?.group(group);
                    if (runtime_start == unset or runtime_end == unset) {
                        try std.testing.expect(ct_span == null);
                    } else {
                        try std.testing.expect(ct_span != null);
                        try std.testing.expectEqual(runtime_start, ct_span.?.start);
                        try std.testing.expectEqual(runtime_end, ct_span.?.end);
                    }
                }
            } else {
                try std.testing.expect(ct_find == null);
            }
        }
    }
}

const Captures = struct {
    pub const ab = Regex("(a)(b)");
    pub const alt = Regex("(a|ab)c");
    pub const plus = Regex("(a)+");
    pub const nested = Regex("((a)(b))");
    pub const optional = Regex("(x)?y");
    pub const empty_group = Regex("(a*)b");
    pub const ci = Regex("(?i)(foo|bar)[0-9]+");
    pub const words = Regex("(\\w+)@(\\w+)");
};

test "comptime regex capture group access" {
    const re = Regex("(?i)(foo|bar)-([0-9]+)");
    try std.testing.expectEqual(@as(usize, 2), re.capture_total);
    const m = re.search("xx BAR-42 yy").?;
    try std.testing.expectEqual(@as(usize, 3), m.start);
    try std.testing.expectEqual(@as(usize, 9), m.end);
    try std.testing.expectEqual(@as(usize, 3), m.group(1).?.start);
    try std.testing.expectEqual(@as(usize, 6), m.group(1).?.end);
    try std.testing.expectEqual(@as(usize, 7), m.group(2).?.start);
    try std.testing.expectEqual(@as(usize, 9), m.group(2).?.end);
    try std.testing.expect(m.group(3) == null);
    try std.testing.expectEqual(m.span().start, m.group(0).?.start);
}

test "comptime regex named captures" {
    const re = Regex("(?P<user>\\w+)@(?<host>\\w+)");
    try std.testing.expectEqual(@as(usize, 2), re.capture_total);
    const m = re.search("mail user@host now").?;
    try std.testing.expectEqual(@as(usize, 5), m.start);
    try std.testing.expectEqual(@as(usize, 15), m.end);
    try std.testing.expectEqual(@as(usize, 5), m.named("user").?.start);
    try std.testing.expectEqual(@as(usize, 9), m.named("user").?.end);
    try std.testing.expectEqual(@as(usize, 10), m.named("host").?.start);
    try std.testing.expectEqual(@as(usize, 14), m.named("host").?.end);
    // Positional access agrees with named access.
    try std.testing.expectEqual(m.group(1).?.start, m.named("user").?.start);
    try std.testing.expectEqual(m.group(2).?.start, m.named("host").?.start);

    // A named group inside alternation still backtracks correctly.
    const alt = Regex("(?P<kind>foo|bar)-(?P<num>[0-9]+)");
    const a = alt.search("x bar-42 y").?;
    try std.testing.expectEqual(@as(usize, 2), a.named("kind").?.start);
    try std.testing.expectEqual(@as(usize, 5), a.named("kind").?.end);
    try std.testing.expectEqual(@as(usize, 6), a.named("num").?.start);
    try std.testing.expectEqual(@as(usize, 8), a.named("num").?.end);
}
