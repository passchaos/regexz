#!/usr/bin/env python3
"""Differential fuzz harness for the linear engine.

Generates random patterns over the syntax shared by regexz and JavaScript,
computes the reference results with Node (V8), runs the same cases through the
Zig engine, and diffs full-match plus find-span output.

Usage:
    python3 tools/fuzz/run.py [--cases 700] [--seed 20261118]

Requires `node` on PATH and the Zig toolchain used by the repo.
"""
import argparse
import json
import random
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

ATOMS = [
    "a", "b", "A", "1", " ", "\u732b", "\u0394",
    "[ab]", "[^a]", "[a-c]", "[A-Z]", "\\d", "\\w", "\\s",
    ".", "\\p{L}", "\\p{Script=Greek}", "\\p{Nd}", "(a)", "(?:b)", "(a|b)",
]
QUANTIFIERS = ["", "", "", "*", "+", "?", "*?", "+?", "??", "{0,2}", "{1,2}", "{2,3}", "{1,}"]
COMPLEX_ATOMS = ["\\s*[\\r\\n]+", "\\s+(?!\\S)", "\\p{L}+[\\r\\n]*"]
FLAGS = ["", "i", "s", "m", "u", "iu", "su", "mu"]
ALPHABET = "abAB 12\n\u732b\u0394\u03c3"


def random_sequence() -> str:
    out = ""
    for _ in range(random.randint(1, 3)):
        if random.random() < 0.22:
            out += random.choice(COMPLEX_ATOMS)
        else:
            out += random.choice(ATOMS) + random.choice(QUANTIFIERS)
    return out


def random_pattern() -> str:
    pattern = "|".join(random_sequence() for _ in range(random.randint(1, 3)))
    if random.random() < 0.15:
        pattern = "^" + pattern
    if random.random() < 0.15:
        pattern = pattern + "$"
    return pattern


def generate(case_count: int, seed: int) -> list[dict]:
    random.seed(seed)
    inputs = [""]
    for _ in range(6):
        inputs.append("".join(random.choice(ALPHABET) for _ in range(random.randint(1, 8))))
    inputs += ["a", "b", "ab", "aab", "abc", "a1", "  ", "\n", "\u732b", "\u0394\u03c3", "AaBb"]
    inputs += ["sunday saturday september", "seed suit sail", "STRASSE xx strasse", "x" * 15 + "sunday", "foobax foobar foobaz"]
    inputs += ["alpha bravo whiskey xray", "Δ1σ2Δ", "一1伀0币", "hello一", "abcdefghijZ hello123XYZ aab"]
    inputs += ["'s 'S foo café 猫。\n"]
    cases = []
    seen = set()
    # Keep capture-of-run shapes represented: quantifying the existing `(a)`
    # atom generates `(a)+`, whose capture changes on every iteration.
    capture_runs = [
        "(a+)", "([ab]+)", "(\\w+)", "((\\d+))", "()(\\w+)()",
        "(?<run>[a-c]+)", "()([a-c]+)", "([a-c]+)()",
    ]
    seeds = [(pattern, flags) for pattern in capture_runs for flags in ["", "i", "u"]]
    seeds += [(pattern, "u") for pattern in ["(a*)", "(a+?)", "(a)+", "(\\p{L}+)"]]
    seeds += [(pattern, "u") for pattern in [
        "(?:sunday|saturday|september)", "((?:sunday|saturday|september))",
        "(?:sun|sunday|saturday)", "foo(?:bar|baz)", "(?:sunday|saturday)([0-9]+)",
    ]]
    seeds += [("strasse", flags) for flags in ["i", "iu"]]
    wide = "alpha|bravo|charlie|delta|echo|foxtrot|golf|hotel|india|juliet|kilo|lima|mike|november|oscar|papa|quebec|romeo|sierra|tango|uniform|victor|whiskey|xray"
    seeds += [("(?:" + wide + ")", "u"), ("(" + wide + ")", "u")]
    seeds += [("(?:\\p{Script=Greek}|[0-9])+", "u"), ("(?:\\p{Script=Han}|[0-9])+", "u")]
    seeds += [(pattern, "u") for pattern in [
        "[a-z]+(?=\\p{Script=Han})", "[a-z]+(?!\\p{Script=Han})", "\\p{L}+(?!\\p{L})",
    ]]
    seeds += [(pattern, "u") for pattern in [
        "(?:ab)?(?:cd)?(?:ef)?(?:gh)?(?:ij)?Z", "([a-z]+[0-9]+[A-Z]+)", "a*?b*",
    ]]
    seeds += [("(?:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?[\\p{L}\\p{M}]+|\\p{N}| ?[^\\s\\p{L}\\p{M}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+", "iu")]
    for pattern, flags in seeds[:case_count]:
        seen.add((pattern, flags))
        cases.append({"pattern": pattern, "flags": flags, "inputs": inputs})
    while len(cases) < case_count:
        pattern = random_pattern()
        flags = random.choice(FLAGS)
        # V8 only accepts \p{...} in Unicode mode.
        if ("\\p" in pattern or "\\P" in pattern) and "u" not in flags:
            flags += "u"
        key = (pattern, flags)
        if key in seen:
            continue
        seen.add(key)
        cases.append({"pattern": pattern, "flags": flags, "inputs": inputs})
    # Legacy JS /i does not fold long s into ASCII word characters.
    # Keep this Unicode-caseless probe on the explicit Qwen seed.
    for case in cases:
        if case["flags"] == "iu" and case["pattern"].startswith("(?:'s|'t|'re|'ve|'m|'ll|'d)|"):
            case["inputs"] = case["inputs"] + ["'ſ café 猫。\n"]
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
        var inline_buf: [8]u8 = undefined;
        var inline_len: usize = 0;
        var flag_count: usize = 0;
        inline_buf[inline_len] = '(';
        inline_len += 1;
        inline_buf[inline_len] = '?';
        inline_len += 1;
        for (case.flags) |flag| {
            if (flag == 'u') continue;
            inline_buf[inline_len] = flag;
            inline_len += 1;
            flag_count += 1;
        }
        inline_buf[inline_len] = ')';
        inline_len += 1;
        if (flag_count != 0) try pattern_buf.appendSlice(gpa, inline_buf[0..inline_len]);
        try pattern_buf.appendSlice(gpa, case.pattern);
        var value = regexz.Regex.init(gpa, pattern_buf.items, .{ .unicode_perl_space = true, .capture_reset = true, .dollar_endonly = true }) catch {
            for (case.inputs) |input| {
                std.debug.print("E\t{s}\t{s}\t", .{ case.pattern, case.flags });
                printHex(input);
                std.debug.print("\n", .{});
            }
            continue;
        };
        defer value.deinit();
        var full_workspace = regexz.Workspace.init(gpa, value.program) catch continue;
        defer full_workspace.deinit();
        var workspace = regexz.ReplaceWorkspace.init(gpa, value.program, .{ .unicode_perl_space = true, .capture_reset = true, .dollar_endonly = true }) catch continue;
        defer workspace.deinit();
        var captures = regexz.Captures.init(gpa, value.program) catch continue;
        defer captures.deinit(gpa);
        for (case.inputs) |input| {
            const full = value.matches(gpa, input) catch false;
            if (!value.program.extended) {
                // Exercise both cold and reused full-match paths, including
                // lazy DFA construction for short Unicode inputs.
                for (0..3) |_| {
                    if (full_workspace.matchesBorrowed(&value.program, input) != full) return error.CachedMatchMismatch;
                }
            }
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
    parser.add_argument("--cases", type=int, default=700)
    parser.add_argument("--seed", type=int, default=20261118)
    args = parser.parse_args()

    cases = generate(args.cases, args.seed)
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        cases_path = temp_path / "cases.json"
        cases_path.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
        reference_path = temp_path / "reference.js"
        reference_path.write_text(REFERENCE, encoding="utf-8")
        zig_path = temp_path / "fuzz_cases.zig"
        zig_path.write_text(zig_source(cases), encoding="utf-8")

        node = subprocess.run(
            ["node", str(reference_path), str(cases_path)],
            capture_output=True, text=True, check=True,
        )
        executable_path = temp_path / "fuzz_cases"
        compiled = subprocess.run(
            [
                "zig", "build-exe", "-OReleaseFast", "--dep", "regexz",
                f"-Mroot={zig_path}", f"-Mregexz={ROOT / 'src/root.zig'}",
                f"-femit-bin={executable_path}",
            ],
            capture_output=True, text=True,
        )
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stderr)
            return 1
        # Compare program records without compiler/wrapper diagnostics.
        zig = subprocess.run([str(executable_path)], capture_output=True, text=True)
        if zig.returncode != 0:
            sys.stderr.write(zig.stderr)
            return 1
        expected = node.stdout.splitlines()
        actual = zig.stderr.splitlines()
        if expected == actual:
            print(f"fuzz ok: {len(cases)} patterns, {len(expected)} comparisons")
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
