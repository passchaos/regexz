//! Bounded RE2/PCRE-style syntax. Patterns that use backtracking-only
//! features (general lookaround, backreferences, atomic groups, possessive
//! quantifiers, conditionals, `\G`, UCP word boundaries) are marked
//! `extended` and executed by the bounded backtracking VM.
const std = @import("std");
const m = @import("model.zig");
const classes = @import("classes.zig");
const escape = @import("escape.zig");
const newline = @import("newline.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    pattern: []const u8,
    limits: m.Limits,
    cursor: usize = 0,
    nodes: usize = 0,
    captures: u16 = 0,
    current_group: u16 = 0,
    flags: m.Flags = .{},
    newline: m.Newline = .lf,
    bsr_anycrlf: bool = false,
    notempty: bool = false,
    notempty_atstart: bool = false,
    limit_match: usize = std.math.maxInt(usize),
    limit_depth: usize = std.math.maxInt(usize),
    limit_heap_kib: usize = std.math.maxInt(usize),
    turkish_casing: bool = false,
    group_names: std.ArrayList(m.GroupName) = .empty,
    group_nodes: std.ArrayList(?*const m.Node) = .empty,
    marks: std.ArrayList([]const u8) = .empty,
    callouts: std.ArrayList(m.CalloutSpec) = .empty,
    extended: bool = false,
    /// Highest group number referenced before its definition was seen. Forward
    /// references are resolved after parsing, when the group count is final.
    max_reference: u16 = 0,
    max_reference_offset: usize = 0,
    /// Group names collected by a tolerant first pass, used to resolve
    /// forward references in the real pass.
    known_names: []const m.GroupName = &.{},
    /// Tolerant passes substitute group 0 for names that are not defined yet
    /// and set `missing_names`, so the full name table can be collected.
    tolerant: bool = false,
    missing_names: bool = false,

    pub fn peek(self: *Parser) ?u8 {
        return if (self.cursor < self.pattern.len) self.pattern[self.cursor] else null;
    }
    pub fn take(self: *Parser, byte: u8) bool {
        if (self.peek() != byte) return false;
        self.cursor += 1;
        return true;
    }
    pub fn rune(self: *Parser) m.Error!u21 {
        const first = self.peek() orelse return error.InvalidRegex;
        const len = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidRegex;
        if (len > self.pattern.len - self.cursor) return error.InvalidRegex;
        const value = std.unicode.utf8Decode(self.pattern[self.cursor..][0..len]) catch return error.InvalidRegex;
        self.cursor += len;
        return value;
    }
    /// All group indices sharing `name`, sorted by pattern position.
    pub fn nameIndices(self: *Parser, name: []const u8) m.Error!?[]const u16 {
        var list: std.ArrayList(u16) = .empty;
        defer list.deinit(self.allocator);
        for (self.group_names.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) try list.append(self.allocator, entry.index);
        }
        for (self.known_names) |entry| {
            if (std.mem.eql(u8, entry.name, name)) try list.append(self.allocator, entry.index);
        }
        if (list.items.len == 0) return null;
        std.mem.sort(u16, list.items, {}, std.sort.asc(u16));
        var count: usize = 0;
        for (list.items) |index| {
            if (count == 0 or list.items[count - 1] != index) {
                list.items[count] = index;
                count += 1;
            }
        }
        list.shrinkRetainingCapacity(count);
        return try list.toOwnedSlice(self.allocator);
    }
    pub fn lookupName(self: *Parser, name: []const u8) ?u16 {
        for (self.group_names.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.index;
        }
        for (self.known_names) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.index;
        }
        return null;
    }
    /// Resolve a name for a single-group reference. Tolerant passes accept a
    /// forward reference with a placeholder index.
    pub fn resolveName(self: *Parser, name: []const u8) ?u16 {
        if (self.lookupName(name)) |index| return index;
        if (!self.tolerant) return null;
        self.missing_names = true;
        return 0;
    }
    /// Resolve a name for a backreference. Tolerant passes accept a forward
    /// reference with a placeholder group list.
    pub fn resolveIndices(self: *Parser, name: []const u8) m.Error!?[]const u16 {
        if (try self.nameIndices(name)) |groups| return groups;
        if (!self.tolerant) return null;
        self.missing_names = true;
        return &[_]u16{0};
    }
    fn node(self: *Parser, value: m.Node) m.Error!*const m.Node {
        if (self.nodes >= self.limits.max_nodes) return error.RegexLimitExceeded;
        self.nodes += 1;
        const result = try self.allocator.create(m.Node);
        result.* = value;
        return result;
    }
    fn join(self: *Parser, values: []const *const m.Node, alternate: bool) m.Error!*const m.Node {
        if (values.len == 0) return self.node(.empty);
        if (values.len == 1) return values[0];
        const split = values.len / 2;
        const left = try self.join(values[0..split], alternate);
        const right = try self.join(values[split..], alternate);
        return self.node(if (alternate) .{ .alternate = .{ .left = left, .right = right } } else .{ .pair = .{ .left = left, .right = right } });
    }
    fn skipExtended(self: *Parser) void {
        if (!self.flags.extended) return;
        while (self.peek()) |byte| {
            switch (byte) {
                ' ', '\t', '\n', '\r', 0x0b, 0x0c => self.cursor += 1,
                '#' => {
                    while (self.peek()) |comment| {
                        self.cursor += 1;
                        if (comment == '\n') break;
                    }
                },
                else => return,
            }
        }
    }
    fn expressionNoBar(self: *Parser, depth: usize) m.Error!*const m.Node {
        if (depth > self.limits.max_depth) return error.RegexLimitExceeded;
        var sequence: std.ArrayList(*const m.Node) = .empty;
        defer sequence.deinit(self.allocator);
        while (true) {
            self.skipExtended();
            const byte = self.peek() orelse break;
            if (byte == '|' or byte == ')') break;
            if (byte == '*' or byte == '+' or byte == '?') return error.InvalidRegex;
            const value = try self.atom(depth);
            try sequence.append(self.allocator, try self.repetition(value));
        }
        return self.join(sequence.items, false);
    }
    fn expression(self: *Parser, depth: usize) m.Error!*const m.Node {
        if (depth > self.limits.max_depth) return error.RegexLimitExceeded;
        var alternatives: std.ArrayList(*const m.Node) = .empty;
        defer alternatives.deinit(self.allocator);
        while (true) {
            try alternatives.append(self.allocator, try self.expressionNoBar(depth));
            self.skipExtended();
            if (!self.take('|')) break;
        }
        return self.join(alternatives.items, true);
    }
    fn nameAngle(self: *Parser) m.Error![]const u8 {
        const start = self.cursor;
        while (self.peek()) |byte| {
            if (byte == '>') break;
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return error.InvalidRegex;
            self.cursor += 1;
        }
        if (self.cursor == start or !self.take('>')) return error.InvalidRegex;
        return self.pattern[start .. self.cursor - 1];
    }
    fn addGroupName(self: *Parser, name: []const u8, index: u16) m.Error!void {
        // PCRE2 permits duplicate names on the same number (branch reset);
        // distinct numbers need (?J).
        if (!self.flags.duplicate_names) {
            for (self.group_names.items) |entry| {
                if (entry.index != index and std.mem.eql(u8, entry.name, name)) return error.InvalidRegex;
            }
        }
        try self.group_names.append(self.allocator, .{ .name = name, .index = index });
    }
    fn setGroupNode(self: *Parser, index: u16, value: *const m.Node) m.Error!void {
        while (self.group_nodes.items.len <= index) try self.group_nodes.append(self.allocator, null);
        self.group_nodes.items[index] = value;
    }
    fn nameUntil(self: *Parser, close: u8) m.Error![]const u8 {
        const start = self.cursor;
        while (self.peek()) |byte| {
            if (byte == close) break;
            self.cursor += 1;
        }
        if (self.cursor == start or !self.take(close)) return error.InvalidRegex;
        return self.pattern[start .. self.cursor - 1];
    }
    fn subroutine(self: *Parser, group_index: u16) m.Error!*const m.Node {
        self.extended = true;
        if (group_index != 0) self.noteReference(group_index, self.cursor);
        return self.node(.{ .subroutine = .{ .group = group_index } });
    }
    pub fn noteReference(self: *Parser, index: u16, offset: usize) void {
        if (index > self.max_reference) {
            self.max_reference = index;
            self.max_reference_offset = offset;
        }
    }
    fn limitDirective(name: []const u8, prefix: []const u8) ?usize {
        if (!std.mem.startsWith(u8, name, prefix)) return null;
        const text = name[prefix.len..];
        if (text.len == 0) return null;
        for (text) |byte| if (!std.ascii.isDigit(byte)) return null;
        return std.fmt.parseInt(usize, text, 10) catch null;
    }
    fn verb(self: *Parser, depth: usize) m.Error!*const m.Node {
        self.cursor += 1; // '*'
        const start = self.cursor;
        while (self.peek()) |byte| {
            if (byte == ')' or byte == ':') break;
            self.cursor += 1;
        }
        const name = self.pattern[start..self.cursor];
        const script_run = std.mem.eql(u8, name, "sr") or
            std.mem.eql(u8, name, "script_run") or
            std.mem.eql(u8, name, "asr") or
            std.mem.eql(u8, name, "atomic_script_run");
        if (script_run) {
            if (!self.take(':')) return error.InvalidRegex;
            self.extended = true;
            const child = try self.expression(depth + 1);
            if (!self.take(')')) return error.InvalidRegex;
            return self.node(.{ .script_run = .{
                .child = child,
                .atomic = std.mem.eql(u8, name, "asr") or std.mem.eql(u8, name, "atomic_script_run"),
            } });
        }
        if (std.mem.eql(u8, name, "scs") or std.mem.eql(u8, name, "scan_substring")) {
            if (!self.take(':')) return error.InvalidRegex;
            if (!self.take('(')) return error.InvalidRegex;
            var groups: std.ArrayList(u16) = .empty;
            defer groups.deinit(self.allocator);
            while (true) {
                const byte = self.peek() orelse return error.InvalidRegex;
                if (byte == '\'' or byte == '<') {
                    const close: u8 = if (byte == '\'') '\'' else '>';
                    self.cursor += 1;
                    const name_start = self.cursor;
                    while (self.peek()) |next| {
                        if (next == close) break;
                        self.cursor += 1;
                    }
                    const group_name = self.pattern[name_start..self.cursor];
                    if (!self.take(close)) return error.InvalidRegex;
                    var matched = false;
                    for (self.group_names.items) |entry| {
                        if (!std.mem.eql(u8, entry.name, group_name)) continue;
                        try groups.append(self.allocator, entry.index);
                        matched = true;
                    }
                    if (!matched) return error.InvalidRegex;
                } else {
                    const number_start = self.cursor;
                    if (byte == '-' or byte == '+') self.cursor += 1;
                    const digits = self.cursor;
                    while (self.peek()) |next| {
                        if (!std.ascii.isDigit(next)) break;
                        self.cursor += 1;
                    }
                    if (self.cursor == digits) return error.InvalidRegex;
                    const value = std.fmt.parseInt(i32, self.pattern[number_start..self.cursor], 10) catch return error.InvalidRegex;
                    // Relative references count from the most recently opened
                    // group: -1 is that group, +1 is the next one.
                    const index = if (byte == '-' or byte == '+') blk: {
                        const base: i32 = if (value < 0) @as(i32, self.captures) + 1 else @as(i32, self.captures);
                        break :blk base + value;
                    } else value;
                    if (index <= 0 or index > 32767) return error.InvalidRegex;
                    try groups.append(self.allocator, @intCast(index));
                }
                if (self.take(',')) continue;
                break;
            }
            if (!self.take(')')) return error.InvalidRegex;
            if (groups.items.len == 0) return error.InvalidRegex;
            self.extended = true;
            const child = try self.expression(depth + 1);
            if (!self.take(')')) return error.InvalidRegex;
            return self.node(.{ .scan_substring = .{
                .child = child,
                .groups = try groups.toOwnedSlice(self.allocator),
            } });
        }
        const Look = struct { negative: bool, behind: bool, non_atomic: bool };
        const alias: ?Look = if (std.mem.eql(u8, name, "pla") or std.mem.eql(u8, name, "positive_lookahead"))
            .{ .negative = false, .behind = false, .non_atomic = false }
        else if (std.mem.eql(u8, name, "nla") or std.mem.eql(u8, name, "negative_lookahead"))
            .{ .negative = true, .behind = false, .non_atomic = false }
        else if (std.mem.eql(u8, name, "plb") or std.mem.eql(u8, name, "positive_lookbehind"))
            .{ .negative = false, .behind = true, .non_atomic = false }
        else if (std.mem.eql(u8, name, "nlb") or std.mem.eql(u8, name, "negative_lookbehind"))
            .{ .negative = true, .behind = true, .non_atomic = false }
        else if (std.mem.eql(u8, name, "napla") or std.mem.eql(u8, name, "non_atomic_positive_lookahead"))
            .{ .negative = false, .behind = false, .non_atomic = true }
        else if (std.mem.eql(u8, name, "naplb") or std.mem.eql(u8, name, "non_atomic_positive_lookbehind"))
            .{ .negative = false, .behind = true, .non_atomic = true }
        else
            null;
        if (alias) |look| {
            if (!self.take(':')) return error.InvalidRegex;
            self.extended = true;
            const child = try self.expression(depth + 1);
            if (!self.take(')')) return error.InvalidRegex;
            return self.node(.{ .lookaround = .{
                .child = child,
                .negative = look.negative,
                .behind = look.behind,
                .non_atomic = look.non_atomic,
            } });
        }
        if (self.peek() == ':') {
            self.cursor += 1;
            const mark_start = self.cursor;
            while (self.peek()) |byte| {
                if (byte == ')') break;
                self.cursor += 1;
            }
            if (!self.take(')')) return error.InvalidRegex;
            self.extended = true;
            if (std.mem.eql(u8, name, "SKIP")) {
                const mark_name = self.pattern[mark_start .. self.cursor - 1];
                if (mark_name.len == 0) return error.InvalidRegex;
                return self.node(.{ .skip_named = mark_name });
            }
            if (std.mem.eql(u8, name, "MARK")) {
                if (self.marks.items.len >= 65535) return error.RegexLimitExceeded;
                try self.marks.append(self.allocator, self.pattern[mark_start .. self.cursor - 1]);
                return self.node(.{ .mark = @intCast(self.marks.items.len - 1) });
            }
            // Other argument verbs (`(*SKIP:name)`, `(*PRUNE:name)`, ...)
            // accept a mark name but do not expose it.
            return self.node(.empty);
        }
        if (!self.take(')')) return error.InvalidRegex;
        if (std.mem.eql(u8, name, "UCP")) {
            self.limits.unicode_perl_classes = true;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "UTF") or std.mem.eql(u8, name, "NO_JIT")) return self.node(.empty);
        if (std.mem.eql(u8, name, "CR")) {
            self.newline = .cr;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "LF")) {
            self.newline = .lf;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "CRLF")) {
            self.newline = .crlf;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "ANYCRLF")) {
            self.newline = .anycrlf;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "ANY")) {
            self.newline = .any;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "NUL")) {
            self.newline = .nul;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "TURKISH_CASING")) {
            self.turkish_casing = true;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "CASELESS_RESTRICT")) {
            self.flags.caseless_restrict = true;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "BSR_ANYCRLF")) {
            self.bsr_anycrlf = true;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "BSR_UNICODE")) {
            self.bsr_anycrlf = false;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "NOTEMPTY")) {
            self.notempty = true;
            return self.node(.empty);
        }
        if (std.mem.eql(u8, name, "NOTEMPTY_ATSTART")) {
            self.notempty_atstart = true;
            return self.node(.empty);
        }
        // Start-up optimization switches; they do not change match results.
        if (std.mem.eql(u8, name, "NO_AUTO_POSSESS") or
            std.mem.eql(u8, name, "NO_START_OPT") or
            std.mem.eql(u8, name, "NO_DOTSTAR_ANCHOR")) return self.node(.empty);
        if (limitDirective(name, "LIMIT_MATCH=")) |value| {
            self.limit_match = @min(self.limit_match, value);
            return self.node(.empty);
        }
        if (limitDirective(name, "LIMIT_DEPTH=") orelse limitDirective(name, "LIMIT_RECURSION=")) |value| {
            self.limit_depth = @min(self.limit_depth, value);
            return self.node(.empty);
        }
        if (limitDirective(name, "LIMIT_HEAP=")) |value| {
            self.limit_heap_kib = @min(self.limit_heap_kib, value);
            return self.node(.empty);
        }
        self.extended = true;
        if (std.mem.eql(u8, name, "FAIL") or std.mem.eql(u8, name, "F")) return self.node(.fail);
        if (std.mem.eql(u8, name, "ACCEPT")) return self.node(.accept_verb);
        if (std.mem.eql(u8, name, "PRUNE")) return self.node(.prune);
        if (std.mem.eql(u8, name, "SKIP")) return self.node(.skip);
        if (std.mem.eql(u8, name, "COMMIT")) return self.node(.commit);
        if (std.mem.eql(u8, name, "THEN")) return self.node(.then_verb);
        return error.UnsupportedRegexFeature;
    }
    fn lookaround(self: *Parser, negative: bool, behind: bool, depth: usize) m.Error!*const m.Node {
        const child = try self.expression(depth + 1);
        if (!self.take(')')) return error.InvalidRegex;
        self.extended = true;
        return self.node(.{ .lookaround = .{ .child = child, .negative = negative, .behind = behind } });
    }
    fn condition(self: *Parser, depth: usize) m.Error!m.Condition {
        if (std.mem.startsWith(u8, self.pattern[self.cursor..], "VERSION")) {
            self.cursor += "VERSION".len;
            const ge = if (self.take('>')) blk: {
                if (!self.take('=')) return error.InvalidRegex;
                break :blk true;
            } else if (self.take('=')) false else return error.InvalidRegex;
            const start = self.cursor;
            while (self.peek()) |byte| {
                if (!std.ascii.isDigit(byte) and byte != '.') break;
                self.cursor += 1;
            }
            if (self.cursor == start) return error.InvalidRegex;
            const text = self.pattern[start..self.cursor];
            const dot = std.mem.indexOfScalar(u8, text, '.');
            const major = std.fmt.parseInt(u16, text[0 .. dot orelse text.len], 10) catch return error.InvalidRegex;
            const minor = if (dot) |index| std.fmt.parseInt(u16, text[index + 1 ..], 10) catch return error.InvalidRegex else 0;
            if (!self.take(')')) return error.InvalidRegex;
            // The engine targets the PCRE2 10.45 feature level.
            const supported_major: u16 = 10;
            const supported_minor: u16 = 45;
            const satisfied = if (ge)
                supported_major > major or (supported_major == major and supported_minor >= minor)
            else
                major == supported_major and minor == supported_minor;
            return .{ .version = satisfied };
        }
        // Undelimited name condition `(?(name)...)`, including names that
        // start with R (which otherwise introduce recursion conditions).
        {
            var end = self.cursor;
            while (end < self.pattern.len and self.pattern[end] != ')') end += 1;
            const candidate = self.pattern[self.cursor..end];
            if (candidate.len != 0 and self.lookupName(candidate) != null) {
                const groups = try self.nameIndices(candidate) orelse return error.InvalidRegex;
                self.cursor = end + 1;
                if (groups.len == 1) return .{ .group = groups[0] };
                return .{ .groups = groups };
            }
        }
        if (self.peek() == 'R') {
            self.cursor += 1;
            var group_index: ?u16 = null;
            if (self.take('&')) {
                const start = self.cursor;
                while (self.peek()) |byte| {
                    if (byte == ')') break;
                    self.cursor += 1;
                }
                const name = self.pattern[start..self.cursor];
                group_index = self.resolveName(name) orelse return error.InvalidRegex;
            } else if (self.peek()) |byte| {
                if (std.ascii.isDigit(byte)) {
                    const start = self.cursor;
                    while (self.peek()) |digit| {
                        if (!std.ascii.isDigit(digit)) break;
                        self.cursor += 1;
                    }
                    group_index = std.fmt.parseInt(u16, self.pattern[start..self.cursor], 10) catch return error.InvalidRegex;
                }
            }
            if (!self.take(')')) return error.InvalidRegex;
            self.extended = true;
            return .{ .recursion = group_index };
        }
        if (self.take('?')) {
            var negative = false;
            var behind = false;
            if (self.take('=')) {} else if (self.take('!')) {
                negative = true;
            } else if (self.take('<')) {
                behind = true;
                if (self.take('=')) {} else if (self.take('!')) {
                    negative = true;
                } else return error.InvalidRegex;
            } else return error.InvalidRegex;
            const child = try self.expression(depth + 1);
            if (!self.take(')')) return error.InvalidRegex;
            self.extended = true;
            const look = try self.node(.{ .lookaround = .{ .child = child, .negative = negative, .behind = behind } });
            return .{ .assertion = look };
        }
        if (self.take('<')) {
            const start = self.cursor;
            while (self.peek()) |byte| {
                if (byte == '>') break;
                self.cursor += 1;
            }
            const name = self.pattern[start..self.cursor];
            if (!self.take('>')) return error.InvalidRegex;
            if (!self.take(')')) return error.InvalidRegex;
            const groups = try self.resolveIndices(name) orelse return error.InvalidRegex;
            if (groups.len == 1) return .{ .group = groups[0] };
            return .{ .groups = groups };
        }
        if (self.take('\'')) {
            const start = self.cursor;
            while (self.peek()) |byte| {
                if (byte == '\'') break;
                self.cursor += 1;
            }
            const name = self.pattern[start..self.cursor];
            if (!self.take('\'')) return error.InvalidRegex;
            if (!self.take(')')) return error.InvalidRegex;
            const groups = try self.resolveIndices(name) orelse return error.InvalidRegex;
            if (groups.len == 1) return .{ .group = groups[0] };
            return .{ .groups = groups };
        }
        var negative = false;
        var signed = false;
        if (self.peek()) |byte| {
            if (byte == '+' or byte == '-') {
                negative = byte == '-';
                signed = true;
                self.cursor += 1;
            }
        }
        const start = self.cursor;
        while (self.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            self.cursor += 1;
        }
        if (start == self.cursor) return error.UnsupportedRegexFeature;
        const magnitude = std.fmt.parseInt(i32, self.pattern[start..self.cursor], 10) catch return error.InvalidRegex;
        const value: i32 = if (signed) blk: {
            const base: i32 = @as(i32, self.captures) + @as(i32, if (negative) 1 else 0);
            break :blk base + (if (negative) -magnitude else magnitude);
        } else magnitude;
        if (value <= 0 or value > 32767) return error.InvalidRegex;
        if (!signed and value > self.captures) return error.InvalidRegex;
        if (!self.take(')')) return error.InvalidRegex;
        return .{ .group = @intCast(value) };
    }
    fn conditional(self: *Parser, depth: usize) m.Error!*const m.Node {
        const condition_value = try self.condition(depth);
        const yes = try self.expressionNoBar(depth + 1);
        const no = if (self.take('|')) try self.expression(depth + 1) else null;
        if (!self.take(')')) return error.InvalidRegex;
        self.extended = true;
        return self.node(.{ .conditional = .{ .condition = condition_value, .yes = yes, .no = no } });
    }
    fn group(self: *Parser, depth: usize) m.Error!*const m.Node {
        const saved = self.flags;
        var capturing = !self.flags.no_auto_capture;
        var capture_index: ?u16 = null;
        var capture_name: ?[]const u8 = null;
        if (self.take('?')) {
            if (self.take('C')) {
                var spec = m.CalloutSpec{};
                if (self.peek()) |byte| {
                    if (std.ascii.isDigit(byte)) {
                        var value: u32 = 0;
                        while (self.peek()) |digit| {
                            if (!std.ascii.isDigit(digit)) break;
                            value = value * 10 + (digit - '0');
                            if (value > 65535) return error.RegexLimitExceeded;
                            self.cursor += 1;
                        }
                        spec.number = value;
                    } else if (byte == '"' or byte == '\'') {
                        self.cursor += 1;
                        const start = self.cursor;
                        while (self.peek()) |inner| {
                            if (inner == byte) break;
                            self.cursor += 1;
                        }
                        spec.name = self.pattern[start..self.cursor];
                        if (!self.take(byte)) return error.InvalidRegex;
                    } else if (byte == '{') {
                        self.cursor += 1;
                        const start = self.cursor;
                        while (self.peek()) |inner| {
                            if (inner == '}') break;
                            self.cursor += 1;
                        }
                        spec.name = self.pattern[start..self.cursor];
                        if (!self.take('}')) return error.InvalidRegex;
                    } else if (byte != ')') return error.InvalidRegex;
                }
                if (!self.take(')')) return error.InvalidRegex;
                self.extended = true;
                if (self.callouts.items.len >= 65535) return error.RegexLimitExceeded;
                try self.callouts.append(self.allocator, spec);
                return self.node(.{ .callout = @intCast(self.callouts.items.len - 1) });
            }
            // `(?+1)`/`(?-1)` are relative subroutine calls; a `-` followed
            // by a flag letter instead starts negative inline flags.
            if (self.peek() == '+' or
                (self.peek() == '-' and self.cursor + 1 < self.pattern.len and std.ascii.isDigit(self.pattern[self.cursor + 1])))
            {
                const negative = self.peek() == '-';
                self.cursor += 1;
                const start = self.cursor;
                while (self.peek()) |byte| {
                    if (!std.ascii.isDigit(byte)) break;
                    self.cursor += 1;
                }
                if (start == self.cursor) return error.InvalidRegex;
                const offset = std.fmt.parseInt(i32, self.pattern[start..self.cursor], 10) catch return error.InvalidRegex;
                const base: i32 = @as(i32, self.captures) + @as(i32, if (negative) 1 else 0);
                const value = base + (if (negative) -offset else offset);
                if (value <= 0 or value > 32767) return error.InvalidRegex;
                if (!self.take(')')) return error.InvalidRegex;
                return self.subroutine(@intCast(value));
            }
            if (self.take('#')) {
                while (self.peek()) |byte| {
                    self.cursor += 1;
                    if (byte == ')') break;
                }
                if (self.cursor == 0 or self.pattern[self.cursor - 1] != ')') return error.InvalidRegex;
                return self.node(.empty);
            }
            if (self.take(':')) {
                capturing = false;
            } else if (self.take('P')) {
                if (self.take('<')) {
                    capture_name = try self.nameAngle();
                    capturing = true;
                } else if (self.take('=')) {
                    const start = self.cursor;
                    while (self.peek()) |byte| {
                        if (byte == ')') break;
                        self.cursor += 1;
                    }
                    const name = self.pattern[start..self.cursor];
                    if (!self.take(')')) return error.InvalidRegex;
                    self.extended = true;
                    const groups = try self.resolveIndices(name) orelse return error.InvalidRegex;
                    return self.node(.{ .backref = .{ .index = groups[0], .groups = groups, .fold = self.foldMode() } });
                } else if (self.take('>')) {
                    const name = try self.nameUntil(')');
                    const index = self.resolveName(name) orelse return error.InvalidRegex;
                    return self.subroutine(index);
                } else return error.InvalidRegex;
            } else if (self.take('R')) {
                if (!self.take(')')) return error.InvalidRegex;
                return self.subroutine(0);
            } else if (self.take('&')) {
                const name = try self.nameUntil(')');
                const index = self.resolveName(name) orelse return error.InvalidRegex;
                return self.subroutine(index);
            } else if (self.peek() != null and std.ascii.isDigit(self.peek().?)) {
                const start = self.cursor;
                while (self.peek()) |byte| {
                    if (!std.ascii.isDigit(byte)) break;
                    self.cursor += 1;
                }
                const value = std.fmt.parseInt(u16, self.pattern[start..self.cursor], 10) catch return error.InvalidRegex;
                // Forward references are validated after parsing, when the
                // final group count is known (PCRE2 behaviour).
                if (!self.take(')')) return error.InvalidRegex;
                return self.subroutine(value);
            } else if (self.take('<')) {
                if (self.take('*')) {
                    // PCRE2 10.43 non-atomic positive lookbehind: the engine
                    // may backtrack into the child if the continuation fails.
                    self.extended = true;
                    const child = try self.expression(depth + 1);
                    if (!self.take(')')) return error.InvalidRegex;
                    return self.node(.{ .lookaround = .{
                        .child = child,
                        .negative = false,
                        .behind = true,
                        .non_atomic = true,
                    } });
                }
                if (self.peek() == '=' or self.peek() == '!') {
                    const negative = self.peek() == '!';
                    self.cursor += 1;
                    return self.lookaround(negative, true, depth);
                }
                capture_name = try self.nameAngle();
                capturing = true;
            } else if (self.take('*')) {
                // PCRE2 non-atomic positive lookahead: the engine may
                // backtrack into the child if the continuation fails.
                self.extended = true;
                const child = try self.expression(depth + 1);
                if (!self.take(')')) return error.InvalidRegex;
                return self.node(.{ .lookaround = .{
                    .child = child,
                    .negative = false,
                    .behind = false,
                    .non_atomic = true,
                } });
            } else if (self.peek() == '=' or self.peek() == '!') {
                const negative = self.peek() == '!';
                self.cursor += 1;
                // Keep the narrow, linear set-lookahead when the body is one
                // set atom. Otherwise rewind and parse a general expression.
                const attempt_cursor = self.cursor;
                const attempt_nodes = self.nodes;
                const attempt_flags = self.flags;
                const maybe_set: ?m.Set = self.lookaheadSet() catch |err| switch (err) {
                    error.InvalidRegex => null,
                    else => return err,
                };
                if (maybe_set) |set| {
                    if (self.take(')')) return self.node(.{ .lookahead_set = .{ .set = set, .negative = negative } });
                }
                self.cursor = attempt_cursor;
                self.nodes = attempt_nodes;
                self.flags = attempt_flags;
                return self.lookaround(negative, false, depth);
            } else if (self.take('>')) {
                self.extended = true;
                const child = try self.expression(depth + 1);
                if (!self.take(')')) return error.InvalidRegex;
                return self.node(.{ .atomic = child });
            } else if (self.take('(')) {
                if (std.mem.startsWith(u8, self.pattern[self.cursor..], "DEFINE)")) {
                    self.cursor += "DEFINE)".len;
                    _ = try self.expression(depth + 1);
                    if (!self.take(')')) return error.InvalidRegex;
                    return self.node(.empty);
                }
                return self.conditional(depth);
            } else if (self.take('|')) {
                // Branch reset: capture numbering restarts in each
                // alternative and the group's final count is the maximum.
                const base = self.captures;
                var maximum = base;
                var alternatives: std.ArrayList(*const m.Node) = .empty;
                defer alternatives.deinit(self.allocator);
                while (true) {
                    self.captures = base;
                    const alternative = try self.expressionNoBar(depth + 1);
                    maximum = @max(maximum, self.captures);
                    try alternatives.append(self.allocator, alternative);
                    self.skipExtended();
                    if (!self.take('|')) break;
                }
                self.captures = maximum;
                if (!self.take(')')) return error.InvalidRegex;
                return self.node(.{ .group = try self.join(alternatives.items, true) });
            } else {
                var negative = false;
                var caret = false;
                var consumed: usize = 1;
                var flag_count: usize = 0;
                var negative_count: usize = 0;
                if (self.take('^')) {
                    // PCRE2 `(?^)`: unset the Perl-compatible options.
                    caret = true;
                    self.flags.fold = false;
                    self.flags.multiline = false;
                    self.flags.dot_newline = false;
                    self.flags.extended = false;
                    self.flags.extended_more = false;
                    self.flags.no_auto_capture = false;
                    self.flags.caseless_restrict = false;
                    flag_count += 1;
                }
                while (self.peek()) |byte| {
                    if (byte == '-') {
                        if (negative or caret) return error.InvalidRegex;
                        negative = true;
                        self.cursor += 1;
                        continue;
                    }
                    switch (byte) {
                        'i' => self.flags.fold = !negative,
                        'm' => self.flags.multiline = !negative,
                        's' => self.flags.dot_newline = !negative,
                        'x' => {
                            if (self.cursor + 1 < self.pattern.len and self.pattern[self.cursor + 1] == 'x') {
                                consumed = 2;
                                self.flags.extended_more = !negative;
                                self.flags.extended = !negative;
                            } else {
                                self.flags.extended = !negative;
                                if (negative) self.flags.extended_more = false;
                            }
                        },
                        'a' => {
                            const next = if (self.cursor + 1 < self.pattern.len) self.pattern[self.cursor + 1] else 0;
                            if (next == 'D' or next == 'S' or next == 'W' or next == 'P' or next == 'T') {
                                consumed = 2;
                                switch (next) {
                                    'D' => self.flags.ascii_bsd = !negative,
                                    'S' => self.flags.ascii_space = !negative,
                                    'W' => self.flags.ascii_word = !negative,
                                    'P' => {
                                        self.flags.ascii_posix = !negative;
                                        self.flags.ascii_digit = !negative;
                                    },
                                    'T' => self.flags.ascii_digit = !negative,
                                    else => unreachable,
                                }
                            } else {
                                self.flags.ascii_bsd = !negative;
                                self.flags.ascii_space = !negative;
                                self.flags.ascii_word = !negative;
                                self.flags.ascii_posix = !negative;
                                self.flags.ascii_digit = !negative;
                            }
                        },
                        'r' => self.flags.caseless_restrict = !negative,
                        'J' => self.flags.duplicate_names = !negative,
                        'U' => self.flags.ungreedy = !negative,
                        'n' => self.flags.no_auto_capture = !negative,
                        else => break,
                    }
                    self.cursor += consumed;
                    flag_count += 1;
                    if (negative) negative_count += 1;
                }
                if (flag_count == 0 or (negative and negative_count == 0)) return error.InvalidRegex;
                if (self.take(')')) return self.node(.flag_change);
                if (!self.take(':')) return error.InvalidRegex;
                capturing = false;
            }
        }
        if (capturing) {
            // Capture slots are u16: index*2+1 must fit, so 32767 is the
            // largest group index that can be represented.
            if (self.captures >= 32767) return error.RegexLimitExceeded;
            self.captures += 1;
            capture_index = self.captures;
        }
        // Register the name before parsing the body so recursive named
        // subroutine calls inside the group can resolve it.
        if (capture_index) |index| {
            if (capture_name) |name| try self.addGroupName(name, index);
        }
        const saved_group = self.current_group;
        if (capture_index) |index| self.current_group = index;
        defer self.current_group = saved_group;
        defer self.flags = saved;
        const value = try self.expression(depth + 1);
        if (!self.take(')')) return error.InvalidRegex;
        if (capture_index) |index| {
            const result = try self.node(.{ .capture = .{ .index = index, .name = capture_name, .child = value } });
            try self.setGroupNode(index, result);
            return result;
        }
        return self.node(.{ .group = value });
    }
    fn materialize(self: *Parser, parsed: m.ParsedSet) m.Error!m.Set {
        // Parsed single-range sets are already canonical and owned by the
        // parser arena or static tables, so avoid a duplicate allocation.
        if (parsed.ranges.len == 1 and !parsed.negate and parsed.fold == .none) {
            if (parsed.ranges[0].first > parsed.ranges[0].last) return error.InvalidRegex;
            return classes.fromRanges(parsed.ranges);
        }
        return classes.normalize(self.allocator, parsed.ranges, parsed.negate, parsed.fold, self.limits.max_ranges);
    }
    fn element(self: *Parser, fold: m.Fold) m.Error!m.ParsedSet {
        if (self.take('\\')) {
            const escaped = try escape.parse(self, true, fold);
            return if (escaped == .set) escaped.set else error.InvalidRegex;
        }
        if (self.peek() == '[' and std.mem.startsWith(u8, self.pattern[self.cursor..], "[:")) {
            self.cursor += 2;
            const negate = self.take('^');
            const start = self.cursor;
            while (self.peek()) |byte| {
                if (byte == ':') break;
                self.cursor += 1;
            }
            const name_value = self.pattern[start..self.cursor];
            if (!self.take(':') or !self.take(']')) return error.InvalidRegex;
            return .{
                .ranges = try classes.posixRanges(
                    self.allocator,
                    name_value,
                    self.limits.unicode_perl_classes,
                    self.flags.ascii_posix,
                    self.flags.ascii_digit,
                    self.limits.max_ranges,
                ),
                .negate = negate,
                .fold = fold,
            };
        }
        if (self.peek() == '[') {
            // Nested class used as an operand (`[a-z&&[^aeiou]]`). The nested
            // class is already folded and materialized.
            self.cursor += 1;
            const nested = try self.characterClass();
            return switch (nested.*) {
                .set => |set| .{ .ranges = set.ranges, .negate = false, .fold = .none },
                else => error.InvalidRegex,
            };
        }
        return escape.literal(self, try self.rune(), fold);
    }
    fn foldMode(self: *Parser) m.Fold {
        if (!self.flags.fold) return .none;
        if (self.flags.caseless_restrict) return .ascii;
        return if (self.turkish_casing) .turkish else .unicode;
    }
    /// `.` and bare `\N`: any rune except the configured line terminators.
    /// CRLF needs a composite node because an isolated CR or LF still matches.
    fn dotNode(self: *Parser) m.Error!*const m.Node {
        if (self.flags.dot_newline) {
            return self.node(.{ .set = try classes.normalize(self.allocator, &.{.{ .first = 0, .last = 0x10ffff }}, false, .none, self.limits.max_ranges) });
        }
        if (self.newline == .crlf) {
            const not_cr = try self.node(.{ .set = try classes.normalize(self.allocator, &.{.{ .first = '\r', .last = '\r' }}, true, .none, self.limits.max_ranges) });
            const cr = try self.literalNode('\r');
            const not_lf = try self.node(.{ .lookahead_set = .{
                .set = try classes.normalize(self.allocator, &.{.{ .first = '\n', .last = '\n' }}, false, .none, self.limits.max_ranges),
                .negative = true,
            } });
            const cr_only = try self.node(.{ .pair = .{ .left = cr, .right = not_lf } });
            return self.node(.{ .alternate = .{ .left = not_cr, .right = cr_only } });
        }
        return self.node(.{ .set = try classes.normalize(self.allocator, newline.excluded(self.newline), true, .none, self.limits.max_ranges) });
    }
    fn dotSet(self: *Parser) m.Error!m.Set {
        return classes.normalize(self.allocator, if (self.flags.dot_newline) &.{.{ .first = 0, .last = 0x10ffff }} else newline.excluded(self.newline), !self.flags.dot_newline, .none, self.limits.max_ranges);
    }
    fn lookaheadSet(self: *Parser) m.Error!m.Set {
        const byte = self.peek() orelse return error.InvalidRegex;
        if (byte == '[') {
            self.cursor += 1;
            const value = try self.characterClass();
            return switch (value.*) {
                .set => |set| set,
                else => error.InvalidRegex,
            };
        }
        if (byte == '.') {
            self.cursor += 1;
            return self.dotSet();
        }
        return self.materialize(try self.element(.unicode));
    }
    /// Recognize `&&`, `--`, and `~~` between class operands. A `-` that is
    /// part of a range or a literal is consumed by the element parser first,
    /// so only a doubled operator reaches this point.
    fn takeClassOp(self: *Parser) ?classes.SetOp {
        if (self.cursor + 1 >= self.pattern.len) return null;
        const pair = self.pattern[self.cursor..][0..2];
        if (std.mem.eql(u8, pair, "&&")) {
            self.cursor += 2;
            return .intersection;
        }
        if (std.mem.eql(u8, pair, "--")) {
            self.cursor += 2;
            return .difference;
        }
        if (std.mem.eql(u8, pair, "~~")) {
            self.cursor += 2;
            return .symmetric_difference;
        }
        return null;
    }
    fn skipClassSpace(self: *Parser) void {
        while (self.peek()) |byte| {
            if (byte != ' ' and byte != '\t') break;
            self.cursor += 1;
        }
    }
    fn characterClass(self: *Parser) m.Error!*const m.Node {
        const negate = self.take('^');
        var accumulator: ?m.Set = null;
        var pending: classes.SetOp = .intersection;
        var operand: std.ArrayList(m.Range) = .empty;
        defer operand.deinit(self.allocator);
        var first = true;
        while (self.peek()) |_| {
            if (self.flags.extended_more) self.skipClassSpace();
            if (!first and self.take(']')) {
                const right = try classes.normalize(self.allocator, operand.items, false, self.foldMode(), self.limits.max_ranges);
                const combined = if (accumulator) |left|
                    try classes.combine(self.allocator, left, pending, right, self.limits.max_ranges)
                else
                    right;
                return self.node(.{ .set = try classes.normalize(self.allocator, combined.ranges, negate, .none, self.limits.max_ranges) });
            }
            if (!first) {
                if (self.takeClassOp()) |op| {
                    const right = try classes.normalize(self.allocator, operand.items, false, self.foldMode(), self.limits.max_ranges);
                    operand.clearRetainingCapacity();
                    accumulator = if (accumulator) |left|
                        try classes.combine(self.allocator, left, pending, right, self.limits.max_ranges)
                    else
                        right;
                    pending = op;
                    continue;
                }
            }
            first = false;
            // Parse the first element unfolded so `[a-z]` endpoints stay
            // single runes even when `(?i)` is active. The operand
            // normalization folds the union.
            const start = try self.element(.none);
            if (self.flags.extended_more) self.skipClassSpace();
            if (self.peek() == '-' and self.cursor + 1 < self.pattern.len and
                self.pattern[self.cursor + 1] != ']' and self.pattern[self.cursor + 1] != '-')
            {
                self.cursor += 1;
                if (self.flags.extended_more) self.skipClassSpace();
                const end = try self.element(.none);
                if (start.negate or end.negate or start.ranges.len != 1 or end.ranges.len != 1 or start.ranges[0].first != start.ranges[0].last or end.ranges[0].first != end.ranges[0].last) return error.InvalidRegex;
                if (operand.items.len >= self.limits.max_ranges) return error.RegexLimitExceeded;
                try operand.append(self.allocator, .{ .first = start.ranges[0].first, .last = end.ranges[0].first });
            } else {
                const folded = try classes.normalize(self.allocator, start.ranges, start.negate, self.foldMode(), self.limits.max_ranges);
                try classes.append(&operand, self.allocator, folded, self.limits.max_ranges);
            }
        }
        return error.InvalidRegex;
    }
    fn literalNode(self: *Parser, value: u21) m.Error!*const m.Node {
        return self.node(.{ .set = try self.materialize(try escape.literal(self, value, .none)) });
    }
    fn newlineSequence(self: *Parser) m.Error!*const m.Node {
        const crlf = try self.node(.{ .pair = .{ .left = try self.literalNode('\r'), .right = try self.literalNode('\n') } });
        const single = try self.node(.{ .set = try self.materialize(.{ .ranges = if (self.bsr_anycrlf) &.{
            .{ .first = '\n', .last = '\n' },
            .{ .first = '\r', .last = '\r' },
        } else &.{
            .{ .first = '\n', .last = '\n' },
            .{ .first = 0x0b, .last = 0x0c },
            .{ .first = '\r', .last = '\r' },
            .{ .first = 0x85, .last = 0x85 },
            .{ .first = 0x2028, .last = 0x2029 },
        } }) });
        const alternate = try self.node(.{ .alternate = .{ .left = crlf, .right = single } });
        self.extended = true;
        return self.node(.{ .atomic = alternate });
    }
    fn atom(self: *Parser, depth: usize) m.Error!*const m.Node {
        const byte = self.peek() orelse return error.InvalidRegex;
        self.cursor += 1;
        return switch (byte) {
            '(' => if (self.peek() == '*') self.verb(depth) else self.group(depth),
            '[' => self.characterClass(),
            '.' => self.dotNode(),
            '^' => self.node(.{ .assertion = if (self.flags.multiline) .start_line else .start_text }),
            '$' => self.node(.{ .assertion = if (self.flags.multiline) .end_line else .end_text }),
            '\\' => blk: {
                if (self.peek() == 'R') {
                    self.cursor += 1;
                    break :blk try self.newlineSequence();
                }
                if (self.peek() == 'X') {
                    self.cursor += 1;
                    self.extended = true;
                    break :blk self.node(.grapheme);
                }
                break :blk switch (try escape.parse(self, false, self.foldMode())) {
                    .set => |parsed| self.node(.{ .set = try self.materialize(parsed) }),
                    .dot => self.dotNode(),
                    .byte => self.node(.byte),
                    .assertion => |assertion| self.node(.{ .assertion = assertion }),
                    .backref => |ref| self.node(.{ .backref = .{ .index = ref.index, .groups = ref.groups, .fold = self.foldMode() } }),
                    .subroutine => |index| self.node(.{ .subroutine = .{ .group = index } }),
                    .reset_start => self.node(.reset_start),
                    .string_property => |property| self.node(.{ .string_property = property }),
                };
            },
            '{' => blk: {
                self.cursor -= 1;
                if (try self.counted() != null) return error.InvalidRegex;
                break :blk self.node(.{ .set = try self.materialize(try escape.literal(self, try self.rune(), self.foldMode())) });
            },
            else => blk: {
                self.cursor -= 1;
                break :blk self.node(.{ .set = try self.materialize(try escape.literal(self, try self.rune(), self.foldMode())) });
            },
        };
    }
    fn number(self: *Parser) ?usize {
        const start = self.cursor;
        while (self.peek()) |byte| {
            if (!std.ascii.isDigit(byte)) break;
            self.cursor += 1;
        }
        if (start == self.cursor) return null;
        return std.fmt.parseInt(usize, self.pattern[start..self.cursor], 10) catch std.math.maxInt(usize);
    }
    fn counted(self: *Parser) m.Error!?struct { minimum: usize, maximum: ?usize } {
        const saved = self.cursor;
        if (!self.take('{')) return null;
        const minimum = self.number() orelse {
            self.cursor = saved;
            return null;
        };
        var maximum: ?usize = minimum;
        if (self.take(',')) maximum = self.number();
        if (!self.take('}')) {
            self.cursor = saved;
            return null;
        }
        if (minimum > 1000 or (maximum != null and (maximum.? > 1000 or maximum.? < minimum))) return error.InvalidRegex;
        if (minimum > self.limits.max_repeat or (maximum != null and maximum.? > self.limits.max_repeat)) return error.RegexLimitExceeded;
        return .{ .minimum = minimum, .maximum = maximum };
    }
    fn zeroWidthNode(value: *const m.Node) bool {
        return switch (value.*) {
            .empty, .flag_change, .assertion, .lookahead_set, .lookaround => true,
            .group => |child| zeroWidthNode(child),
            .capture => |capture| zeroWidthNode(capture.child),
            .atomic => |child| zeroWidthNode(child),
            .pair => |pair| zeroWidthNode(pair.left) and zeroWidthNode(pair.right),
            .alternate => |pair| zeroWidthNode(pair.left) and zeroWidthNode(pair.right),
            else => false,
        };
    }
    fn repetition(self: *Parser, child: *const m.Node) m.Error!*const m.Node {
        self.skipExtended();
        var minimum: usize = 0;
        var maximum: ?usize = null;
        if (self.take('*')) {} else if (self.take('+')) {
            minimum = 1;
        } else if (self.take('?')) {
            maximum = 1;
        } else if (self.peek() == '{') {
            const count = try self.counted() orelse return child;
            minimum = count.minimum;
            maximum = count.maximum;
        } else return child;
        if (child.* == .flag_change or child.* == .fail or child.* == .accept_verb or child.* == .prune or child.* == .skip or child.* == .commit) return error.InvalidRegex;
        var lazy = false;
        var possessive = false;
        if (self.take('?')) {
            lazy = true;
        } else if (self.take('+')) {
            possessive = true;
            self.extended = true;
        }
        // `(?U)` swaps the default: bare quantifiers become lazy and `?`
        // makes them greedy again. Possessive quantifiers are unaffected.
        if (self.flags.ungreedy and !possessive) lazy = !lazy;
        if (self.peek()) |byte| if (byte == '*' or byte == '+' or byte == '?') return error.InvalidRegex;
        // PCRE2 caps unbounded repetition of zero-width assertions at one
        // more than the minimum, preventing non-progressing loops.
        if (maximum == null and zeroWidthNode(child)) {
            maximum = if (minimum >= self.limits.max_repeat) minimum else minimum + 1;
        }
        return self.node(.{ .repeat = .{
            .child = child,
            .minimum = minimum,
            .maximum = maximum,
            .lazy = lazy,
            .possessive = possessive,
        } });
    }
};

fn unquote(gpa: std.mem.Allocator, pattern: []const u8) m.Error![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(gpa);
    var index: usize = 0;
    var quoted = false;
    while (index < pattern.len) : (index += 1) {
        const byte = pattern[index];
        if (byte == '\\' and index + 1 < pattern.len) {
            const next = pattern[index + 1];
            if (!quoted and next == 'Q') {
                quoted = true;
                index += 1;
                continue;
            }
            // `\E` ends quoting; without a preceding `\Q` PCRE2 ignores it.
            if (next == 'E') {
                quoted = false;
                index += 1;
                continue;
            }
            if (!quoted) {
                try bytes.appendSlice(gpa, pattern[index..][0..2]);
                index += 1;
                continue;
            }
        }
        if (quoted and std.mem.indexOfScalar(u8, "\\.^$[]{}()*+?|-", byte) != null) try bytes.append(gpa, '\\');
        try bytes.append(gpa, byte);
    }
    return bytes.toOwnedSlice(gpa);
}

fn diagnosticKind(err: m.Error) ?m.DiagnosticKind {
    return switch (err) {
        error.InvalidRegex => .syntax,
        error.UnsupportedRegexFeature => .unsupported,
        error.RegexLimitExceeded => .limit,
        error.OutOfMemory => null,
    };
}

fn setDiagnostic(diagnostic: ?*m.Diagnostic, offset: usize, err: m.Error) void {
    const kind = diagnosticKind(err) orelse return;
    if (diagnostic) |value| value.* = .{ .offset = offset, .kind = kind };
}

/// First byte of an invalid UTF-8 sequence (or the length when truncated).
fn invalidUtf8Offset(pattern: []const u8) usize {
    var index: usize = 0;
    while (index < pattern.len) {
        const len = std.unicode.utf8ByteSequenceLength(pattern[index]) catch return index;
        if (len > pattern.len - index) return index;
        if (!std.unicode.utf8ValidateSlice(pattern[index..][0..len])) return index;
        index += len;
    }
    return index;
}

pub fn parse(gpa: std.mem.Allocator, pattern: []const u8, limits: m.Limits) m.Error!m.ParseResult {
    return parseWithDiagnostic(gpa, pattern, limits, null);
}

const PassOptions = struct {
    /// Names collected by an earlier tolerant pass, used for forward refs.
    known_names: []const m.GroupName = &.{},
    /// Substitute group 0 for undefined names instead of failing, so the
    /// complete name table can be collected.
    tolerant: bool = false,
    missing_names: ?*bool = null,
};

fn parsePass(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    limits: m.Limits,
    options: PassOptions,
    diagnostic: ?*m.Diagnostic,
) m.Error!m.ParseResult {
    if (pattern.len > limits.max_pattern_bytes) {
        setDiagnostic(diagnostic, pattern.len, error.RegexLimitExceeded);
        return error.RegexLimitExceeded;
    }
    if (!std.unicode.utf8ValidateSlice(pattern)) {
        setDiagnostic(diagnostic, invalidUtf8Offset(pattern), error.InvalidRegex);
        return error.InvalidRegex;
    }
    var parser = Parser{
        .allocator = gpa,
        .pattern = try unquote(gpa, pattern),
        .limits = limits,
        .known_names = options.known_names,
        .tolerant = options.tolerant,
    };
    defer parser.group_names.deinit(gpa);
    defer parser.group_nodes.deinit(gpa);
    defer parser.marks.deinit(gpa);
    defer parser.callouts.deinit(gpa);
    const root = parser.expression(0) catch |err| {
        setDiagnostic(diagnostic, parser.cursor, err);
        if (options.missing_names) |flag| flag.* = parser.missing_names;
        return err;
    };
    if (options.missing_names) |flag| flag.* = parser.missing_names;
    if (parser.cursor != parser.pattern.len) {
        setDiagnostic(diagnostic, parser.cursor, error.InvalidRegex);
        return error.InvalidRegex;
    }
    // Numeric back/subroutine references may point forward; validate them
    // against the final group count, as PCRE2 does.
    if (parser.max_reference > parser.captures) {
        setDiagnostic(diagnostic, parser.max_reference_offset, error.InvalidRegex);
        return error.InvalidRegex;
    }
    const nodes = try gpa.alloc(*const m.Node, @as(usize, parser.captures) + 1);
    nodes[0] = root;
    for (1..@as(usize, parser.captures) + 1) |index| {
        if (index >= parser.group_nodes.items.len) return error.InvalidRegex;
        nodes[index] = parser.group_nodes.items[index] orelse return error.InvalidRegex;
    }
    return .{
        .root = root,
        .group_names = try parser.group_names.toOwnedSlice(gpa),
        .marks = try parser.marks.toOwnedSlice(gpa),
        .callouts = try parser.callouts.toOwnedSlice(gpa),
        .group_nodes = nodes,
        .capture_count = parser.captures,
        .extended = parser.extended,
        .newline = parser.newline,
        .notempty = parser.notempty,
        .notempty_atstart = parser.notempty_atstart,
        .limit_match = parser.limit_match,
        .limit_depth = parser.limit_depth,
        .limit_heap_kib = parser.limit_heap_kib,
    };
}

/// Like `parse`, but records where parsing stopped on failure. Undefined names
/// may be forward references: a tolerant pass then collects the complete name
/// table and the parse is retried.
pub fn parseWithDiagnostic(
    gpa: std.mem.Allocator,
    pattern: []const u8,
    limits: m.Limits,
    diagnostic: ?*m.Diagnostic,
) m.Error!m.ParseResult {
    return parsePass(gpa, pattern, limits, .{}, diagnostic) catch |err| {
        if (err == error.OutOfMemory) return err;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var missing = false;
        const collected = parsePass(
            arena.allocator(),
            pattern,
            limits,
            .{ .tolerant = true, .missing_names = &missing },
            diagnostic,
        ) catch return err;
        if (!missing) return err;
        return parsePass(gpa, pattern, limits, .{ .known_names = collected.group_names }, diagnostic);
    };
}
