#!/usr/bin/env python3
"""Differential fuzz for the extended (backtracking) engine.

Generates random patterns using lookahead, lookbehind, backreferences, named
groups, alternation, and quantifiers; compares full-match, find spans, and the
first match's capture groups against Node/V8. Zig runs with
`Limits.capture_reset = true` to match JavaScript capture reset semantics.

Usage:
    python3 tools/fuzz/extended.py [--cases 500] [--seed 20261118]
"""
import argparse
import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Atoms that Node/V8 and regexz both support.
PLAIN = ["a", "b", "c", ".", "[ab]", "[^a]", "[a-c]"]
GROUPS = ["(a)", "(b)", "(a|b)", "(?:a|b)"]
LOOKAROUND = [
    "a(?=b)", "a(?!b)", "(?<=a)b", "(?<!a)b", "(?=ab)a", "(?!ab)a",
    "(?<=a|b)c", "(?<!a)b", "a(?=b|a)", "a(?![bc])",
]
BACKREF = ["(a)\\1", "(a|b)\\1"]
QUANTIFIERS = ["", "", "*", "+", "?", "{1,2}"]


def random_sequence() -> str:
    out = ""
    for _ in range(random.randint(1, 3)):
        kind = random.random()
        if kind < 0.40:
            out += random.choice(PLAIN) + random.choice(QUANTIFIERS)
        elif kind < 0.62:
            out += random.choice(GROUPS) + random.choice(QUANTIFIERS)
        elif kind < 0.88:
            out += random.choice(LOOKAROUND)
        else:
            out += random.choice(BACKREF)
    return out


def random_pattern() -> str:
    if random.random() < 0.25:
        return random_sequence() + "|" + random_sequence()
    return random_sequence()


def generate(case_count: int, seed: int) -> list[dict]:
    random.seed(seed)
    inputs = [""]
    for _ in range(7):
        inputs.append("".join(random.choice("abc") for _ in range(random.randint(1, 7))))
    inputs += ["a", "b", "c", "ab", "abc", "aab", "aba", "abb", "abcabc", "ba", "cb"]
    cases = []
    seen = set()
    while len(cases) < case_count:
        pattern = random_pattern()
        flags = random.choice(["", "", "i"])
        key = (pattern, flags)
        if key in seen:
            continue
        seen.add(key)
        cases.append({"pattern": pattern, "flags": flags, "inputs": inputs})
    return cases


REFERENCE = r"""
const fs = require("fs");
const cases = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function advance(input, offset) {
  const cp = input.codePointAt(offset);
  return offset + (cp > 0xffff ? 2 : 1);
}
function byteIndex(input, unitIndex) { return Buffer.byteLength(input.slice(0, unitIndex)); }
function hex(input) { return Buffer.from(input).toString("hex"); }
for (const c of cases) {
  for (const input of c.inputs) {
    let full = false;
    try {
      const wrapped = new RegExp(`(?:${c.pattern})(?![\\s\\S])`, c.flags + "y");
      wrapped.lastIndex = 0;
      const m = wrapped.exec(input);
      full = !!m && m.index === 0;
    } catch (e) {
      console.log(`E\t${c.pattern}\t${c.flags}\t${hex(input)}`);
      continue;
    }
    console.log(`M\t${c.pattern}\t${c.flags}\t${hex(input)}\t${full}`);
    let spans = [];
    try {
      const global = new RegExp(c.pattern, c.flags + "g");
      let lastIndex = 0;
      while (lastIndex <= input.length && spans.length < 32) {
        global.lastIndex = lastIndex;
        const m = global.exec(input);
        if (!m) break;
        const start = byteIndex(input, m.index);
        spans.push(`${start}:${start + Buffer.byteLength(m[0])}`);
        if (m[0].length === 0) {
          if (m.index === input.length) break;
          lastIndex = advance(input, m.index);
        } else lastIndex = m.index + m[0].length;
      }
    } catch (e) { spans = ["ERR"]; }
    console.log(`F\t${c.pattern}\t${c.flags}\t${hex(input)}\t${spans.join(",")}`);
    let groups = null;
    try {
      const dm = new RegExp(c.pattern, c.flags + "d").exec(input);
      if (dm) {
        groups = [];
        for (const idx of dm.indices) {
          groups.push(idx ? `${byteIndex(input, idx[0])}:${byteIndex(input, idx[1])}` : "-1");
        }
      }
    } catch (e) { groups = "ERR"; }
    console.log(`G\t${c.pattern}\t${c.flags}\t${hex(input)}\t${groups === null ? "null" : groups.join(",")}`);
  }
}
"""


def zig_source(cases: list[dict]) -> str:
    def quote(value: str) -> str:
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'

    lines = [
        'const std = @import("std");',
        'const regexz = @import("regexz");',
        "const Case = struct { pattern: []const u8, flags: []const u8, inputs: []const []const u8 };",
        "const cases = [_]Case{",
    ]
    for case in cases:
        inputs = ", ".join(quote(value) for value in case["inputs"])
        lines.append(f'    .{{ .pattern = {quote(case["pattern"])}, .flags = {quote(case["flags"])}, .inputs = &.{{{inputs}}} }},')
    lines.append("};")
    lines.append(r"""
fn advance(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return offset + 1;
    const len = std.unicode.utf8ByteSequenceLength(input[offset]) catch 1;
    return offset + len;
}

fn printHex(input: []const u8) void {
    for (input) |byte| std.debug.print("{x:0>2}", .{byte});
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    for (cases) |case| {
        var pattern_buf: std.ArrayList(u8) = .empty;
        defer pattern_buf.deinit(gpa);
        if (case.flags.len != 0) {
            var inline_buf: [8]u8 = undefined;
            var inline_len: usize = 0;
            inline_buf[inline_len] = '(';
            inline_len += 1;
            inline_buf[inline_len] = '?';
            inline_len += 1;
            for (case.flags) |flag| {
                inline_buf[inline_len] = flag;
                inline_len += 1;
            }
            inline_buf[inline_len] = ')';
            inline_len += 1;
            try pattern_buf.appendSlice(gpa, inline_buf[0..inline_len]);
        }
        try pattern_buf.appendSlice(gpa, case.pattern);
        var value = regexz.Regex.init(gpa, pattern_buf.items, .{ .capture_reset = true, .unset_backref_empty = true }) catch {
            for (case.inputs) |input| {
                std.debug.print("E\t{s}\t{s}\t", .{ case.pattern, case.flags });
                printHex(input);
                std.debug.print("\n", .{});
            }
            continue;
        };
        defer value.deinit();
        var workspace = regexz.ReplaceWorkspace.init(gpa, value.program, .{ .capture_reset = true, .unset_backref_empty = true }) catch continue;
        defer workspace.deinit();
        var captures = regexz.Captures.init(gpa, value.program) catch continue;
        defer captures.deinit(gpa);
        for (case.inputs) |input| {
            const full = value.matches(gpa, input) catch false;
            std.debug.print("M\t{s}\t{s}\t", .{ case.pattern, case.flags });
            printHex(input);
            std.debug.print("\t{}\n", .{full});
            std.debug.print("F\t{s}\t{s}\t", .{ case.pattern, case.flags });
            printHex(input);
            std.debug.print("\t", .{});
            var offset: usize = 0;
            var spans: usize = 0;
            while (offset <= input.len and spans < 32) {
                const found = (workspace.find(input, offset) catch null) orelse break;
                if (spans != 0) std.debug.print(",", .{});
                std.debug.print("{d}:{d}", .{ found.start, found.end });
                spans += 1;
                if (found.end <= found.start) {
                    if (found.start == input.len) break;
                    offset = advance(input, found.start);
                } else offset = found.end;
            }
            std.debug.print("\n", .{});
            const first = value.find(gpa, input, &captures) catch null;
            std.debug.print("G\t{s}\t{s}\t", .{ case.pattern, case.flags });
            printHex(input);
            std.debug.print("\t", .{});
            if (first) |_| {
                var group: usize = 0;
                while (group <= value.program.capture_count) : (group += 1) {
                    if (group != 0) std.debug.print(",", .{});
                    const begin = captures.slots[group * 2];
                    const end = captures.slots[group * 2 + 1];
                    if (begin == std.math.maxInt(usize) or end == std.math.maxInt(usize) or end < begin) {
                        std.debug.print("-1", .{});
                    } else {
                        std.debug.print("{d}:{d}", .{ begin, end });
                    }
                }
            } else {
                std.debug.print("null", .{});
            }
            std.debug.print("\n", .{});
        }
    }
}
""")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=int, default=500)
    parser.add_argument("--seed", type=int, default=20261118)
    args = parser.parse_args()

    cases = generate(args.cases, args.seed)
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        cases_path = temp_path / "cases.json"
        cases_path.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
        reference_path = temp_path / "reference.js"
        reference_path.write_text(REFERENCE, encoding="utf-8")
        zig_path = temp_path / "fuzz_extended.zig"
        zig_path.write_text(zig_source(cases), encoding="utf-8")

        node = subprocess.run(
            ["node", str(reference_path), str(cases_path)],
            capture_output=True, text=True, check=True,
        )
        zig = subprocess.run(
            [
                "zig", "run", "-OReleaseFast", "--dep", "regexz",
                f"-Mroot={zig_path}", f"-Mregexz={ROOT / 'src/root.zig'}",
            ],
            capture_output=True, text=True,
        )
        if zig.returncode != 0:
            sys.stderr.write(zig.stderr)
            return 1
        expected = node.stdout.splitlines()
        actual = zig.stderr.splitlines()
        if expected == actual:
            print(f"extended fuzz ok: {len(cases)} patterns, {len(expected)} comparisons")
            return 0
        for index, (want, got) in enumerate(zip(expected, actual)):
            if want != got:
                print(f"mismatch at line {index + 1}:\n  node: {want}\n  zig:  {got}")
                break
        if len(expected) != len(actual):
            print(f"line count differs: node={len(expected)} zig={len(actual)}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
