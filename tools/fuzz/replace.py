#!/usr/bin/env python3
"""Differential fuzz for replacement expansion against Node (V8).

Generates random linear patterns, inputs, and substitutions that use the
syntax shared by regexz and JavaScript (`$1`..`$9`, `$&`, `$$`, literals),
then compares `replaceAll` output byte-for-byte.

Usage:
    python3 tools/fuzz/replace.py [--cases 400] [--seed 20261119]

Requires `node` on PATH and the Zig toolchain used by the repo.
"""
import argparse
import json
import random
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

ATOMS = ["a", "b", "c", "[ab]", "[^a]", "[a-c]", ".", "\\d", "(a)", "(b)", "(a|b)", "(?:ab)"]
QUANTIFIERS = ["", "", "", "*", "+", "?", "{0,2}", "{1,2}", "{1,3}"]
ALPHABET = "abc12 "
SUB_TOKENS = ["x", "-", "$&", "$$", " ", "[]"]


def random_pattern() -> str:
    out = ""
    for _ in range(random.randint(1, 3)):
        out += random.choice(ATOMS) + random.choice(QUANTIFIERS)
    return out


def group_count(pattern: str) -> int:
    try:
        return re.compile(pattern).groups
    except re.error:
        return 0


def random_substitution(groups: int) -> str:
    tokens = list(SUB_TOKENS)
    for index in range(1, min(groups, 3) + 1):
        tokens.append(f"${index}")
    out = ""
    for _ in range(random.randint(1, 3)):
        out += random.choice(tokens)
    return out


def generate(case_count: int, seed: int) -> list[dict]:
    random.seed(seed)
    inputs = ["", "a", "b", "ab", "aab", "abc", "a1", "  ", "cba", "aaab", "1a2b"]
    for _ in range(8):
        inputs.append("".join(random.choice(ALPHABET) for _ in range(random.randint(1, 10))))
    cases = []
    seen = set()
    while len(cases) < case_count:
        pattern = random_pattern()
        groups = group_count(pattern)
        substitution = random_substitution(groups)
        flags = random.choice(["", "", "", "i"])
        key = (pattern, substitution, flags)
        if key in seen:
            continue
        seen.add(key)
        cases.append({"pattern": pattern, "flags": flags, "substitution": substitution, "inputs": inputs})
    return cases


REFERENCE = r"""
const fs = require("fs");
const cases = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function hex(input) { return Buffer.from(input, "utf8").toString("hex"); }
for (const c of cases) {
  for (const input of c.inputs) {
    let out;
    try {
      const re = new RegExp(c.pattern, c.flags + "g");
      out = input.replace(re, c.substitution);
    } catch (e) {
      out = null;
    }
    console.log(out === null ? `E\t${hex(input)}` : `R\t${hex(input)}\t${hex(out)}`);
  }
}
"""


def quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def zig_source(cases: list[dict]) -> str:
    lines = [
        'const std = @import("std");',
        'const regexz = @import("regexz");',
        "const Case = struct { pattern: []const u8, flags: []const u8, substitution: []const u8, inputs: []const []const u8 };",
        "const cases = [_]Case{",
    ]
    for case in cases:
        inputs = ", ".join(quote(value) for value in case["inputs"])
        lines.append(
            f'    .{{ .pattern = {quote(case["pattern"])}, .flags = {quote(case["flags"])}, '
            f'.substitution = {quote(case["substitution"])}, .inputs = &.{{{inputs}}} }},'
        )
    lines.append("};")
    lines.append(r"""
fn printHex(input: []const u8) void {
    for (input) |byte| std.debug.print("{x:0>2}", .{byte});
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    for (cases) |case| {
        var pattern_buf: std.ArrayList(u8) = .empty;
        defer pattern_buf.deinit(gpa);
        if (case.flags.len != 0) {
            try pattern_buf.appendSlice(gpa, "(?");
            try pattern_buf.appendSlice(gpa, case.flags);
            try pattern_buf.append(gpa, ')');
        }
        try pattern_buf.appendSlice(gpa, case.pattern);
        var value = regexz.Regex.init(gpa, pattern_buf.items, .{ .dollar_endonly = true }) catch {
            for (case.inputs) |input| {
                std.debug.print("E\t", .{});
                printHex(input);
                std.debug.print("\n", .{});
            }
            continue;
        };
        defer value.deinit();
        var workspace = regexz.ReplaceWorkspace.init(gpa, value.program, .{}) catch continue;
        defer workspace.deinit();
        for (case.inputs) |input| {
            const out = workspace.replaceAll(input, case.substitution) catch {
                std.debug.print("E\t", .{});
                printHex(input);
                std.debug.print("\n", .{});
                continue;
            };
            defer gpa.free(out);
            std.debug.print("R\t", .{});
            printHex(input);
            std.debug.print("\t", .{});
            printHex(out);
            std.debug.print("\n", .{});
        }
    }
}
""")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=int, default=400)
    parser.add_argument("--seed", type=int, default=20261119)
    args = parser.parse_args()

    cases = generate(args.cases, args.seed)
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        cases_path = temp_path / "cases.json"
        cases_path.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
        reference_path = temp_path / "reference.js"
        reference_path.write_text(REFERENCE, encoding="utf-8")
        zig_path = temp_path / "fuzz_replace.zig"
        zig_path.write_text(zig_source(cases), encoding="utf-8")

        node = subprocess.run(["node", str(reference_path), str(cases_path)], capture_output=True, text=True, check=True)
        executable_path = temp_path / "fuzz_replace"
        compiled = subprocess.run(
            [
                "zig", "build-exe", "-OReleaseFast", "--dep", "regexz",
                f"-Mroot={zig_path}", f"-Mregexz={ROOT / 'src/root.zig'}",
                f"-femit-bin={executable_path}",
            ],
            capture_output=True,
            text=True,
        )
        if compiled.returncode != 0:
            sys.stderr.write(compiled.stderr)
            return 1
        # Keep compiler/wrapper diagnostics separate from the result protocol.
        zig = subprocess.run([str(executable_path)], capture_output=True, text=True)
        if zig.returncode != 0:
            sys.stderr.write(zig.stderr)
            return 1
        expected = node.stdout.splitlines()
        actual = zig.stderr.splitlines()
        if expected == actual:
            print(f"replace fuzz ok: {len(cases)} cases, {len(expected)} comparisons")
            return 0
        for index, (want, got) in enumerate(zip(expected, actual)):
            if want != got:
                sys.stderr.write(f"mismatch at line {index}:\n  node: {want}\n  zig:  {got}\n")
                return 1
        sys.stderr.write(f"line count mismatch: node {len(expected)}, zig {len(actual)}\n")
        return 1


if __name__ == "__main__":
    sys.exit(main())
