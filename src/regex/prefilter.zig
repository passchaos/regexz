//! SIMD first-byte prefilter for selective start sets.
//!
//! ASCII first-byte sets are scanned 16 bytes at a time: small sets compare
//! against up to eight byte splats, and sets that form at most four contiguous
//! ranges (classes like `[A-Z]` or `\w`) compare against the range bounds.
//! Pure Unicode start sets skip ASCII in 32-byte blocks. Other sets fall back
//! to the byte-at-a-time bitmap loop.
//! Selective capture runs can later reuse range vectors for UTF-8 lead bytes.
const std = @import("std");
const model = @import("model.zig");
const nibble_filter = @import("nibble_filter.zig");
const utf8_prefix = @import("utf8_prefix.zig");

const max_simd_bytes = 8;
const max_simd_ranges = utf8_prefix.max_ranges;
const Vec = @Vector(16, u8);

/// Sentinel returned by literal probes when no literal matches.
const no_literal = std.math.maxInt(usize);

/// Bit-packed lane mask: bit N is set when lane N matched. Iterating set bits
/// with `@ctz` avoids `std.simd.firstTrue`, whose select plus reduce-min
/// lowering costs a full vector round trip per candidate lane.
inline fn laneMask(mask: @Vector(16, bool)) u16 {
    return @bitCast(mask);
}

/// First offset at or after `start` holding `byte`, scanned 16 bytes at a
/// time. Returns null when the byte is absent.
pub fn indexOfByte(input: []const u8, start: usize, byte: u8) ?usize {
    if (start >= input.len) return null;
    const needle: Vec = @splat(byte);
    var offset = start;
    while (offset + 16 <= input.len) : (offset += 16) {
        const chunk: Vec = input[offset..][0..16].*;
        if (@reduce(.Or, chunk == needle)) {
            while (input[offset] != byte) offset += 1;
            return offset;
        }
    }
    while (offset < input.len) : (offset += 1) {
        if (input[offset] == byte) return offset;
    }
    return null;
}

/// First offset at or after `start` where `a` is immediately followed by
/// `b`, scanned 16 bytes at a time. Returns null when the pair is absent.
pub fn indexOfPair(input: []const u8, start: usize, a: u8, b: u8) ?usize {
    if (start + 1 >= input.len) return null;
    const splat_a: Vec = @splat(a);
    const splat_b: Vec = @splat(b);
    var offset = start;
    while (offset + 16 <= input.len - 1) : (offset += 16) {
        const chunk_a: Vec = input[offset..][0..16].*;
        const chunk_b: Vec = input[offset + 1 ..][0..16].*;
        const mask = (chunk_a == splat_a) & (chunk_b == splat_b);
        if (@reduce(.Or, mask)) {
            var i: usize = 0;
            while (i < 16) : (i += 1) {
                if (input[offset + i] == a and input[offset + i + 1] == b) return offset + i;
            }
        }
    }
    while (offset + 1 < input.len) : (offset += 1) {
        if (input[offset] == a and input[offset + 1] == b) return offset;
    }
    return null;
}

/// Conservative multi-literal absence filter for start literals with
/// distinct first bytes: an exact bitmap of each literal's first two bytes.
/// A literal occurrence implies a bitmap hit, so a scan without hits proves
/// that no literal occurs. Hits verify the full literals.
pub const PairSet = struct {
    literals: []const []const u8,
    bits: [8192]u8 = .{0} ** 8192,
    /// First-byte SIMD prefilter, enabled only for sparse first-byte sets:
    /// when the set covers many bytes the vector scan would hit on most
    /// chunks and lose to the byte-at-a-time pair probe.
    first: FirstFilter = undefined,
    use_first: bool = false,
    candidates: ?nibble_filter.Filter = null,
    /// Distinct third-byte splats, applied only when every literal has a
    /// third byte. Candidate pairs usually diverge there.
    third_splats: [32]Vec = undefined,
    third_count: u8 = 0,
    use_third: bool = false,

    /// Returns null unless every literal is at least two bytes (a shorter
    /// literal could occur without a pair hit).
    pub fn init(literals: []const []const u8) ?PairSet {
        if (literals.len == 0) return null;
        var set = PairSet{ .literals = literals };
        var first = model.FirstSet{ .nonascii = false };
        var ascii_count: usize = 0;
        var nonascii = false;
        set.use_third = true;
        for (literals) |literal| {
            if (literal.len < 2) return null;
            const pair = (@as(u16, literal[0]) << 8) | literal[1];
            set.bits[pair >> 3] |= @as(u8, 1) << @intCast(pair & 7);
            const byte = literal[0];
            if (byte < 0x80) {
                const word = &first.ascii[byte >> 6];
                const bit = @as(u64, 1) << @intCast(byte & 63);
                if (word.* & bit == 0) {
                    word.* |= bit;
                    ascii_count += 1;
                }
            } else {
                nonascii = true;
            }
            if (literal.len < 3) {
                set.use_third = false;
            } else if (set.use_third) {
                var seen = false;
                for (set.third_splats[0..set.third_count]) |splat| {
                    if (splat[0] == literal[2]) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    set.third_splats[set.third_count] = @splat(literal[2]);
                    set.third_count += 1;
                }
            }
        }
        // Sparse sets skip most chunks; dense sets keep the plain byte loop.
        if (!nonascii and ascii_count <= max_simd_bytes) {
            set.first = FirstFilter.init(first);
            set.use_first = true;
        }
        if (nibble_filter.supported and !set.use_first) set.candidates = nibble_filter.Filter.init(literals);
        return set;
    }

    /// First offset at or after `start` where a literal occurs, or null.
    pub inline fn indexOfAny(self: *const PairSet, input: []const u8, start: usize) ?usize {
        var ignored: usize = undefined;
        return self.scanAny(input, start, &ignored);
    }

    /// Like `indexOfAny`, but also reports which literal matched.
    pub inline fn indexOfAnyMatch(self: *const PairSet, input: []const u8, start: usize, literal_index: *usize) ?usize {
        return self.scanAny(input, start, literal_index);
    }

    inline fn scanAny(self: *const PairSet, input: []const u8, start: usize, literal_index: *usize) ?usize {
        if (start >= input.len or input.len - start < 2) return null;
        if (self.use_first) return self.indexOfAnySparse(input, start, literal_index);
        if (self.candidates) |*filter| return self.indexOfAnyVector(filter, input, start, literal_index);
        return self.indexOfAnyScalar(input, start, literal_index);
    }

    fn indexOfAnyScalar(self: *const PairSet, input: []const u8, start: usize, literal_index: *usize) ?usize {
        var offset = start;
        while (offset < input.len - 1) : (offset += 1) {
            const found = self.matchesAt(input, offset);
            if (found != no_literal) {
                literal_index.* = found;
                return offset;
            }
        }
        return null;
    }

    fn matchesAt(self: *const PairSet, input: []const u8, offset: usize) usize {
        const first = input[offset];
        const second = input[offset + 1];
        const pair = (@as(u16, first) << 8) | second;
        if (self.bits[pair >> 3] & (@as(u8, 1) << @intCast(pair & 7)) == 0) return no_literal;
        for (self.literals, 0..) |literal, index| {
            if (literal.len > input.len - offset) continue;
            if (literal[0] != first or literal[1] != second) continue;
            // Most shared-prefix candidates diverge at the third byte; check
            // it before the full comparison.
            if (literal.len > 2 and literal[2] != input[offset + 2]) continue;
            if (std.mem.eql(u8, input[offset..][0..literal.len], literal)) return index;
        }
        return no_literal;
    }

    fn indexOfAnyVector(self: *const PairSet, filter: *const nibble_filter.Filter, input: []const u8, start: usize, literal_index: *usize) ?usize {
        var offset = start;
        while (offset + 17 <= input.len) : (offset += 16) {
            var mask = filter.candidates(input[offset..][0..16].*, input[offset + 1 ..][0..16].*);
            // The absence case is the common one; a reduce avoids packing the
            // lane mask when no position can start a literal.
            if (!@reduce(.Or, mask)) continue;
            // The last block has no third-byte lane; skipping the filter
            // there only leaves more candidates for exact verification.
            if (self.use_third and offset + 18 <= input.len) {
                const third: Vec = input[offset + 2 ..][0..16].*;
                var allowed = third == self.third_splats[0];
                var third_index: usize = 1;
                while (third_index < self.third_count) : (third_index += 1) {
                    allowed = allowed | (third == self.third_splats[third_index]);
                }
                mask = mask & allowed;
                if (!@reduce(.Or, mask)) continue;
            }
            const bits = laneMask(mask);
            if (bits == 0xFFFF) {
                // Every position needs an exact probe. Avoid repeated SIMD
                // setup on collision-dense input and keep the scalar tail.
                return self.indexOfAnyScalar(input, offset, literal_index);
            }
            var pending = bits;
            while (pending != 0) {
                const index: usize = @ctz(pending);
                pending &= pending - 1;
                const found = self.matchesAt(input, offset + index);
                if (found != no_literal) {
                    literal_index.* = found;
                    return offset + index;
                }
            }
        }
        return self.indexOfAnyScalar(input, offset, literal_index);
    }

    /// Sparse first-byte variant: the SIMD filter jumps between candidate
    /// bytes, so the pair table is read only at plausible starts.
    fn indexOfAnySparse(self: *const PairSet, input: []const u8, start: usize, literal_index: *usize) ?usize {
        var offset = start;
        while (offset + 1 < input.len) {
            offset = self.first.indexOf(input, offset) orelse return null;
            if (offset + 1 >= input.len) return null;
            const found = self.matchesAt(input, offset);
            if (found != no_literal) {
                literal_index.* = found;
                return offset;
            }
            offset += 1;
        }
        return null;
    }

    /// Whether any literal occurs at or after `start`.
    pub fn containsAny(self: *const PairSet, input: []const u8, start: usize) bool {
        return self.indexOfAny(input, start) != null;
    }
};

/// Cached first-byte filter. Building the ASCII byte list costs 128 set
/// probes, so workspaces construct this once instead of on every search.
pub const FirstFilter = struct {
    first: model.FirstSet,
    bytes: [max_simd_bytes]u8 = undefined,
    byte_splats: [max_simd_bytes]Vec = undefined,
    count: u8 = 0,
    /// The set has more ASCII bytes than the byte-splat path can compare.
    too_many: bool = false,
    /// Contiguous candidate-byte runs (at most `max_simd_ranges`); zero
    /// when the set needs more runs than the range path supports.
    ranges: [max_simd_ranges][2]u8 = undefined,
    range_lo: [max_simd_ranges]Vec = undefined,
    range_hi: [max_simd_ranges]Vec = undefined,
    range_count: u8 = 0,
    /// Selective rune sets prepare exact lead ranges after rejected probes.
    prefix_state: enum { unprepared, ready, disabled } = .unprepared,
    /// Valid misses across ordinary searches; fits the filter's padding.
    prefix_probes: u8 = 0,

    pub fn init(first: model.FirstSet) FirstFilter {
        var result = FirstFilter{ .first = first };
        // The ASCII bitmap is authoritative, so walk its set bits instead of
        // probing all 128 byte values twice.
        var run_count: usize = 0;
        var run_disabled = false;
        var run_start: u8 = 0;
        var run_end: u8 = 0;
        var in_run = false;
        for (first.ascii, 0..) |word, word_index| {
            var remaining = word;
            while (remaining != 0) {
                const bit: u6 = @intCast(@ctz(remaining));
                const byte: u8 = @intCast(word_index * 64 + bit);
                remaining &= remaining - 1;
                if (!result.too_many) {
                    if (result.count == max_simd_bytes) {
                        result.too_many = true;
                    } else {
                        result.bytes[result.count] = byte;
                        result.count += 1;
                    }
                }
                // Contiguous runs: classes like `[A-Z]` or `\w` are far
                // cheaper to match as ranges than as byte splats.
                if (in_run and byte == run_end + 1) {
                    run_end = byte;
                    continue;
                }
                if (in_run) {
                    if (run_count == max_simd_ranges) {
                        run_disabled = true;
                    } else {
                        result.ranges[run_count] = .{ run_start, run_end };
                        run_count += 1;
                    }
                }
                run_start = byte;
                run_end = byte;
                in_run = true;
            }
        }
        if (in_run) {
            if (run_count == max_simd_ranges) {
                run_disabled = true;
            } else {
                result.ranges[run_count] = .{ run_start, run_end };
                run_count += 1;
            }
        }
        result.range_count = if (run_disabled) 0 else @intCast(run_count);
        var index: usize = 0;
        while (index < result.count) : (index += 1) result.byte_splats[index] = @splat(result.bytes[index]);
        index = 0;
        while (index < result.range_count) : (index += 1) {
            result.range_lo[index] = @splat(result.ranges[index][0]);
            result.range_hi[index] = @splat(result.ranges[index][1]);
        }
        return result;
    }

    /// The caller owns a single-set run summarized by `first`. Reuse the
    /// existing range vectors; keep the symbolic summary unchanged.
    pub noinline fn prepareRunePrefixes(self: *FirstFilter, set: model.Set) void {
        if (self.prefix_state != .unprepared) return;
        self.prefix_state = .disabled;
        const prefix = utf8_prefix.fromSet(set) orelse return;
        self.ranges = prefix.values;
        self.range_count = prefix.count;
        for (0..prefix.count) |index| {
            self.range_lo[index] = @splat(prefix.values[index][0]);
            self.range_hi[index] = @splat(prefix.values[index][1]);
        }
        self.prefix_state = .ready;
    }

    /// Returns true only when this valid miss attempts prefix preparation.
    pub fn noteRuneMiss(self: *FirstFilter, set: model.Set, needed: u8) bool {
        if (self.prefix_state != .unprepared) return false;
        self.prefix_probes +|= 1;
        if (self.prefix_probes < needed) return false;
        self.prepareRunePrefixes(set);
        return true;
    }

    /// Single-set capture scans use selective prefixes once prepared.
    /// Ordinary first-rune scans keep their original dispatch and code.
    pub inline fn indexOfRuneCandidates(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        if (self.prefix_state != .ready) return self.indexOf(input, start);
        if (start >= input.len) return null;
        return self.indexOfPrefixes(input, start);
    }

    /// True when `indexOf` would return `start` for any non-ASCII byte:
    /// the set has no ASCII members or ranges and no prepared rune prefixes.
    pub inline fn plainNonAscii(self: *const FirstFilter) bool {
        return self.count == 0 and self.range_count == 0 and self.first.nonascii and self.prefix_state != .ready;
    }

    /// Return the first offset at or after `start` whose byte can begin a
    /// match, or null when no such byte exists.
    pub fn indexOf(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        if (start >= input.len) return null;
        if (self.first.empty) return start;
        if (self.range_count != 0) return self.indexOfRanges(input, start);
        if (self.too_many) return byteLoop(input, start, self.first);
        const count: usize = self.count;
        if (count == 0) {
            if (!self.first.nonascii) return null;
            if (input[start] >= 0x80) return start;
            const probe_end = start + @min(input.len - start, 16);
            var probe = start + 1;
            while (probe < probe_end) : (probe += 1) {
                if (input[probe] >= 0x80) return probe;
            }
            if (probe == input.len) return null;
            return indexOfNonAscii(input, probe);
        }
        const nonascii: Vec = @splat(@as(u8, 0x80));
        var offset = start;
        while (offset + 16 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var mask = chunk == self.byte_splats[0];
            var index: usize = 1;
            while (index < count) : (index += 1) mask = mask | (chunk == self.byte_splats[index]);
            if (self.first.nonascii) mask = mask | (chunk >= nonascii);
            if (@reduce(.Or, mask)) {
                var i: usize = 0;
                while (i < 16) : (i += 1) {
                    if (self.first.allowsByte(raw[i])) return offset + i;
                }
            }
        }
        return byteLoop(input, offset, self.first);
    }

    noinline fn indexOfNonAscii(input: []const u8, start: usize) ?usize {
        var offset = start;
        while (offset + 32 <= input.len) : (offset += 32) {
            const a: Vec = input[offset..][0..16].*;
            const b: Vec = input[offset + 16 ..][0..16].*;
            if (@reduce(.Max, @max(a, b)) >= 0x80) {
                for (0..32) |index| {
                    if (input[offset + index] >= 0x80) return offset + index;
                }
            }
        }
        while (offset < input.len) : (offset += 1) {
            if (input[offset] >= 0x80) return offset;
        }
        return null;
    }

    fn indexOfRanges(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        const nonascii: Vec = @splat(@as(u8, 0x80));
        var offset = start;
        while (offset + 16 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var mask = (chunk >= self.range_lo[0]) & (chunk <= self.range_hi[0]);
            var index: usize = 1;
            while (index < self.range_count) : (index += 1) {
                mask = mask | ((chunk >= self.range_lo[index]) & (chunk <= self.range_hi[index]));
            }
            if (self.first.nonascii) mask = mask | (chunk >= nonascii);
            if (@reduce(.Or, mask)) {
                var i: usize = 0;
                while (i < 16) : (i += 1) {
                    if (self.first.allowsByte(raw[i])) return offset + i;
                }
            }
        }
        return byteLoop(input, offset, self.first);
    }

    fn indexOfPrefixes(self: *const FirstFilter, input: []const u8, start: usize) ?usize {
        if (self.prefixCandidate(input[start])) return start;
        var offset = start;
        while (offset + 16 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var mask = (chunk >= self.range_lo[0]) & (chunk <= self.range_hi[0]);
            var index: usize = 1;
            while (index < self.range_count) : (index += 1) {
                mask = mask | ((chunk >= self.range_lo[index]) & (chunk <= self.range_hi[index]));
            }
            const bits = laneMask(mask);
            if (bits != 0) return offset + @ctz(bits);
        }
        while (offset < input.len) : (offset += 1) {
            if (self.prefixCandidate(input[offset])) return offset;
        }
        return null;
    }

    fn prefixCandidate(self: *const FirstFilter, byte: u8) bool {
        for (self.ranges[0..self.range_count]) |range| {
            if (byte >= range[0] and byte <= range[1]) return true;
        }
        return false;
    }
};

/// English letter frequency ranks (0 = most common) used to pick the rarest
/// two-byte pair of a case-folded literal; other bytes rank as rare.
const letter_rarity: [256]u8 = blk: {
    var table = [_]u8{26} ** 256;
    const order = "etaoinshrdlucmfwypvbgkqjxz";
    for (order, 0..) |byte, rank| table[byte] = @intCast(rank);
    break :blk table;
};

fn foldByte(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + 32 else byte;
}

fn foldChunk(chunk: Vec) Vec {
    const upper = (chunk >= @as(Vec, @splat('A'))) & (chunk <= @as(Vec, @splat('Z')));
    return chunk + @select(u8, upper, @as(Vec, @splat(32)), @as(Vec, @splat(0)));
}

/// Absence filter for a case-folded literal: scans 16 bytes at a time for the
/// rarest adjacent folded byte pair. A hit keeps the candidate; non-ASCII
/// bytes stay conservative because a UTF-8 rune can fold to an ASCII letter
/// (U+017F folds to `s`), so the caller verifies with the engine.
pub const FoldFilter = struct {
    a: u8,
    b: u8,
    /// Offset of the pair inside the literal; a hit at `p` implies a match
    /// can only start at `p - offset`.
    offset: usize,

    pub fn init(literal: []const u8) ?FoldFilter {
        if (literal.len < 2) return null;
        var best: ?FoldFilter = null;
        var best_score: u16 = 0;
        var index: usize = 0;
        while (index + 1 < literal.len) : (index += 1) {
            const a = literal[index];
            const b = literal[index + 1];
            // A non-ASCII literal byte never equals a folded input byte.
            if (a >= 0x80 or b >= 0x80) continue;
            const score = @as(u16, letter_rarity[a]) + letter_rarity[b];
            if (best == null or score > best_score) {
                best = .{ .a = a, .b = b, .offset = index };
                best_score = score;
            }
        }
        return best;
    }

    /// Earliest possible match start given the first pair hit at or after
    /// `start`, or null when the pair is absent.
    pub fn indexOf(self: FoldFilter, input: []const u8, start: usize) ?usize {
        if (start >= input.len or input.len - start < 2) return null;
        const splat_a: Vec = @splat(self.a);
        const splat_b: Vec = @splat(self.b);
        const nonascii: Vec = @splat(@as(u8, 0x80));
        var offset = start;
        while (offset + 16 <= input.len - 1) : (offset += 16) {
            const raw_a: [16]u8 = input[offset..][0..16].*;
            const raw_b: [16]u8 = input[offset + 1 ..][0..16].*;
            const chunk_a: Vec = @bitCast(raw_a);
            const chunk_b: Vec = @bitCast(raw_b);
            var mask = (foldChunk(chunk_a) == splat_a) & (foldChunk(chunk_b) == splat_b);
            mask = mask | (chunk_a >= nonascii) | (chunk_b >= nonascii);
            const bits = laneMask(mask);
            if (bits != 0) return self.candidateStart(offset + @ctz(bits), start);
        }
        while (offset + 1 < input.len) : (offset += 1) {
            if (self.matchesAt(input, offset)) return self.candidateStart(offset, start);
        }
        return null;
    }

    fn candidateStart(self: FoldFilter, hit: usize, start: usize) usize {
        return @max(start, hit -| self.offset);
    }

    fn matchesAt(self: FoldFilter, input: []const u8, offset: usize) bool {
        const a = input[offset];
        const b = input[offset + 1];
        if (a >= 0x80 or b >= 0x80) return true;
        return foldByte(a) == self.a and foldByte(b) == self.b;
    }
};

/// Multi-literal start filter: scans 16 bytes at a time for the two-byte
/// prefixes of a small literal set, then verifies the full literal.
pub const MultiFilter = struct {
    literals: []const []const u8,
    pairs: [max_pairs]u16 = undefined,
    pair_count: u8 = 0,
    /// Every literal starts with the same byte, so one splat answers the
    /// first-byte lane test. Distinct first bytes OR one splat per pair.
    shared_first: bool = true,
    /// Precomputed lane splats; rebuilding them per search call dominated
    /// short candidate gaps.
    first: Vec = undefined,
    first_splats: [max_pairs]Vec = undefined,
    second_splats: [max_pairs]Vec = undefined,
    /// Third-byte splats, applied only when every literal has a third byte.
    /// Shared-prefix candidates usually diverge there.
    third_splats: [max_pairs]Vec = undefined,
    third_count: u8 = 0,
    use_third: bool = false,

    const max_pairs = 16;

    pub fn init(literals: []const []const u8) ?MultiFilter {
        return build(literals, true);
    }

    /// Like `init`, but accepts literals with distinct first bytes; the lane
    /// test then ORs one first-byte splat per pair.
    pub fn initAny(literals: []const []const u8) ?MultiFilter {
        return build(literals, false);
    }

    fn build(literals: []const []const u8, require_shared: bool) ?MultiFilter {
        if (literals.len == 0 or literals.len > max_pairs) return null;
        if (literals[0].len < 2) return null;
        var filter = MultiFilter{ .literals = literals };
        const shared_first = literals[0][0];
        filter.use_third = true;
        for (literals) |literal| {
            // A shared-first set uses one splat; distinct firsts add a splat
            // per pair in `indexOf`.
            if (literal.len < 2) return null;
            if (require_shared and literal[0] != shared_first) return null;
            if (literal[0] != shared_first) filter.shared_first = false;
            const pair = (@as(u16, literal[0]) << 8) | literal[1];
            var exists = false;
            for (filter.pairs[0..filter.pair_count]) |existing| {
                if (existing == pair) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                if (filter.pair_count == max_pairs) return null;
                filter.pairs[filter.pair_count] = pair;
                filter.pair_count += 1;
            }
            if (literal.len < 3) {
                filter.use_third = false;
            } else if (filter.use_third) {
                var seen = false;
                for (filter.third_splats[0..filter.third_count]) |splat| {
                    if (splat[0] == literal[2]) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) {
                    filter.third_splats[filter.third_count] = @splat(literal[2]);
                    filter.third_count += 1;
                }
            }
        }
        if (filter.pair_count == 0) return null;
        filter.first = @splat(@intCast(filter.pairs[0] >> 8));
        var index: usize = 0;
        while (index < filter.pair_count) : (index += 1) {
            const pair = filter.pairs[index];
            filter.first_splats[index] = @splat(@intCast(pair >> 8));
            filter.second_splats[index] = @splat(@intCast(pair & 0xFF));
        }
        return filter;
    }

    fn matchesAt(self: *const MultiFilter, input: []const u8, offset: usize) usize {
        const second = input[offset + 1];
        for (self.literals, 0..) |literal, index| {
            if (offset + literal.len > input.len) continue;
            if (literal[1] != second) continue;
            // Candidates already share the first byte; most diverge at the
            // third, so check it before the full comparison.
            if (literal.len > 2 and literal[2] != input[offset + 2]) continue;
            if (std.mem.eql(u8, input[offset..][0..literal.len], literal)) return index;
        }
        return no_literal;
    }

    pub inline fn indexOf(self: *const MultiFilter, input: []const u8, start: usize) ?usize {
        var ignored: usize = undefined;
        return self.scan(false, input, start, &ignored);
    }

    /// Like `indexOf`, but also reports which literal matched. The index is
    /// the first exact match in source order, so a caller can return the
    /// span without verifying the literals again.
    pub inline fn indexOfMatch(self: *const MultiFilter, input: []const u8, start: usize, literal_index: *usize) ?usize {
        return self.scan(true, input, start, literal_index);
    }

    fn scan(self: *const MultiFilter, comptime want_index: bool, input: []const u8, start: usize, literal_index: *usize) ?usize {
        if (start >= input.len or input.len - start < 2) return null;
        const count: usize = self.pair_count;
        var offset = start;
        while (offset + 17 <= input.len) : (offset += 16) {
            const raw: [16]u8 = input[offset..][0..16].*;
            const chunk: Vec = @bitCast(raw);
            var first_mask = chunk == self.first;
            if (!self.shared_first) {
                var pair_index: usize = 0;
                while (pair_index < count) : (pair_index += 1) {
                    first_mask = first_mask | (chunk == self.first_splats[pair_index]);
                }
            }
            if (!@reduce(.Or, first_mask)) continue;
            const next_raw: [16]u8 = input[offset + 1 ..][0..16].*;
            const next: Vec = @bitCast(next_raw);
            var seconds = @as(@Vector(16, bool), @splat(false));
            var pair_index: usize = 0;
            while (pair_index < count) : (pair_index += 1) {
                seconds = seconds | (next == self.second_splats[pair_index]);
            }
            var mask = first_mask & seconds;
            // The last block has no third-byte lane; skipping the filter
            // there only leaves more candidates for exact verification.
            if (self.use_third and offset + 18 <= input.len and @reduce(.Or, mask)) {
                const third_raw: [16]u8 = input[offset + 2 ..][0..16].*;
                const third: Vec = @bitCast(third_raw);
                var allowed = third == self.third_splats[0];
                var third_index: usize = 1;
                while (third_index < self.third_count) : (third_index += 1) {
                    allowed = allowed | (third == self.third_splats[third_index]);
                }
                mask = mask & allowed;
            }
            const bits = laneMask(mask);
            if (bits == 0) continue;
            if (bits == 0xFFFF) {
                // Dense collisions already require every literal check;
                // a scalar pass avoids extracting the same 16 candidates.
                var index: usize = 0;
                while (index < 16) : (index += 1) {
                    const found = self.matchesAt(input, offset + index);
                    if (found != no_literal) {
                        if (want_index) literal_index.* = found;
                        return offset + index;
                    }
                }
            } else {
                var pending = bits;
                while (pending != 0) {
                    const index: usize = @ctz(pending);
                    pending &= pending - 1;
                    const found = self.matchesAt(input, offset + index);
                    if (found != no_literal) {
                        if (want_index) literal_index.* = found;
                        return offset + index;
                    }
                }
            }
        }
        while (offset < input.len - 1) : (offset += 1) {
            if (self.shared_first and input[offset] != @as(u8, @intCast(self.pairs[0] >> 8))) continue;
            const found = self.matchesAt(input, offset);
            if (found != no_literal) {
                if (want_index) literal_index.* = found;
                return offset;
            }
        }
        return null;
    }
};

/// Candidate scan for a whole-pattern literal alternation. Small literal
/// sets use the splat filter; larger sets use the nibble pair filter. Both
/// report the matching literal so the caller can skip a second verification.
pub fn literalSetMulti(literals: []const []const u8) ?MultiFilter {
    var seen = [_]bool{false} ** 256;
    var distinct: usize = 0;
    for (literals) |literal| {
        if (literal.len < 2) return null;
        const byte = literal[0];
        if (!seen[byte]) {
            seen[byte] = true;
            distinct += 1;
            if (distinct > 8) return null;
        }
    }
    return MultiFilter.initAny(literals);
}

/// One-shot variant for callers that do not keep a workspace. Hot paths
/// should cache `FirstFilter` instead.
pub fn indexOfFirstSet(input: []const u8, start: usize, first: model.FirstSet) ?usize {
    const filter = FirstFilter.init(first);
    return filter.indexOf(input, start);
}

fn byteLoop(input: []const u8, start: usize, first: model.FirstSet) ?usize {
    var offset = start;
    while (offset < input.len) : (offset += 1) {
        if (first.allowsByte(input[offset])) return offset;
    }
    return null;
}

fn testSet(bytes: []const u8, nonascii: bool) model.FirstSet {
    var set = model.FirstSet{ .nonascii = nonascii };
    for (bytes) |byte| set.ascii[byte >> 6] |= @as(u64, 1) << @intCast(byte & 63);
    return set;
}

fn naiveIndex(input: []const u8, start: usize, first: model.FirstSet) ?usize {
    var offset = start;
    while (offset < input.len) : (offset += 1) {
        if (first.allowsByte(input[offset])) return offset;
    }
    return null;
}

test "FirstFilter matches the naive scan for small and large sets" {
    const small = testSet("abc", false);
    const large = testSet("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", false);
    const nonascii = testSet("ab", true);
    const inputs = [_][]const u8{
        "",
        "zzz",
        "a",
        "xxabcxx",
        "0123456789abcdefghij0123456789abcdefghij",
        "héllo abc",
        "\xff\x80ab",
    };
    for ([_]model.FirstSet{ small, large, nonascii }) |first| {
        for (inputs) |input| {
            var start: usize = 0;
            while (start <= input.len) : (start += 1) {
                const filter = FirstFilter.init(first);
                try std.testing.expectEqual(naiveIndex(input, start, first), filter.indexOf(input, start));
                try std.testing.expectEqual(naiveIndex(input, start, first), indexOfFirstSet(input, start, first));
            }
        }
    }
}

test "FirstFilter flags sets too large for the vector path" {
    const small = FirstFilter.init(testSet("abc", false));
    try std.testing.expect(!small.too_many);
    try std.testing.expectEqual(@as(u8, 3), small.count);
    const large = FirstFilter.init(testSet("abcdefghijklmnopqrstuvwxyz", false));
    try std.testing.expect(large.too_many);
    const empty = FirstFilter.init(.{});
    try std.testing.expectEqual(@as(u8, 0), empty.count);
    try std.testing.expect(empty.indexOf("abc", 0) == null);
}

test "MultiFilter finds literal prefixes and agrees with a naive scan" {
    const literals = [_][]const u8{ "sunday", "saturday", "september" };
    const filter = MultiFilter.init(&literals).?;
    const input = "xx symbol sunday saturday september";
    const naive = struct {
        fn index(haystack: []const u8, start: usize, needles: []const []const u8) ?usize {
            var offset = start;
            while (offset < haystack.len) : (offset += 1) {
                for (needles) |needle| {
                    if (offset + needle.len <= haystack.len and std.mem.eql(u8, haystack[offset..][0..needle.len], needle)) return offset;
                }
            }
            return null;
        }
    };
    var start: usize = 0;
    while (start <= input.len) : (start += 1) {
        try std.testing.expectEqual(naive.index(input, start, &literals), filter.indexOf(input, start));
    }
    try std.testing.expectEqual(@as(?usize, 10), filter.indexOf(input, 0));
    try std.testing.expectEqual(@as(?usize, 17), filter.indexOf(input, 11));
    try std.testing.expectEqual(@as(?usize, 26), filter.indexOf(input, 18));
    try std.testing.expectEqual(@as(?usize, null), filter.indexOf(input, 27));
    const short = [_][]const u8{"a"};
    try std.testing.expect(MultiFilter.init(&short) == null);
}
