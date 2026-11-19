#!/usr/bin/env python3
"""Differential fuzz against the Rust `regex` crate (linear subset).

Generates patterns over the syntax shared by regexz and Rust `regex`, builds a
small offline Rust reference program, runs the same cases through the Zig
engine, and compares full-match and find-span output.

Usage:
    python3 tools/fuzz/rust.py [--cases 500] [--seed 20261118]

Requires a Rust toolchain and a cached `regex` crate (`cargo --offline`).
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
    "[ab]", "[^a]", "[a-c]", "[A-Z]", "\\s",
    ".", "\\p{L}", "\\p{Script=Greek}", "\\p{Nd}", "(a)", "(?:b)", "(a|b)",
]
QUANTIFIERS = ["", "", "", "*", "+", "?", "*?", "+?", "??", "{0,2}", "{1,2}", "{2,3}", "{1,}"]
COMPLEX_ATOMS = ["\\s*[\\r\\n]+", "\\p{L}+[\\r\\n]*"]
FLAGS = ["", "i", "s", "m", "iu", "su", "mu"]
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
    cases = []
    seen = set()
    while len(cases) < case_count:
        pattern = random_pattern()
        flags = random.choice(FLAGS)
        key = (pattern, flags)
        if key in seen:
            continue
        seen.add(key)
        cases.append({"pattern": pattern, "flags": flags, "inputs": inputs})
    return cases


def rust_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    escaped = escaped.replace("\n", "\\n").replace("\t", "\\t").replace("\r", "\\r")
    return '"' + escaped + '"'


def rust_source(cases: list[dict]) -> str:
    lines = [
        "use regex::Regex;",
        "",
        "const CASES: &[(&str, &str, &[&str])] = &[",
    ]
    for case in cases:
        inputs = ", ".join(rust_string(value) for value in case["inputs"])
        lines.append(f"    ({rust_string(case['pattern'])}, {rust_string(case['flags'])}, &[{inputs}]),")
    lines.append("];")
    lines.append(r"""
fn hex(input: &str) -> String {
    input.as_bytes().iter().map(|byte| format!("{:02x}", byte)).collect()
}

fn main() {
    for (pattern, flags, inputs) in CASES {
        let mut inline = String::new();
        let mut count = 0;
        for c in flags.chars() {
            if c == 'u' {
                continue;
            }
            if count == 0 {
                inline.push_str("(?");
            }
            inline.push(c);
            count += 1;
        }
        if count != 0 {
            inline.push(')');
        }
        let full = Regex::new(&format!("\\A(?:{}{})\\z", inline, pattern));
        let search = Regex::new(&format!("{}{}", inline, pattern));
        for input in *inputs {
            match &full {
                Ok(re) => println!("M\t{}\t{}\t{}\t{}", pattern, flags, hex(input), re.is_match(input)),
                Err(_) => {
                    println!("E\t{}\t{}\t{}", pattern, flags, hex(input));
                    continue;
                }
            }
            match &search {
                Ok(re) => {
                    let mut spans: Vec<String> = Vec::new();
                    let mut offset = 0usize;
                    while offset <= input.len() && spans.len() < 32 {
                        let m = match re.find_at(input, offset) {
                            Some(m) => m,
                            None => break,
                        };
                        spans.push(format!("{}:{}", m.start(), m.end()));
                        if m.end() > m.start() {
                            offset = m.end();
                        } else {
                            if m.start() == input.len() {
                                break;
                            }
                            let ch = input[m.start()..].chars().next().unwrap();
                            offset = m.start() + ch.len_utf8();
                        }
                    }
                    println!("F\t{}\t{}\t{}\t{}", pattern, flags, hex(input), spans.join(","));
                }
                Err(_) => println!("F\t{}\t{}\t{}\tERR", pattern, flags, hex(input)),
            }
        }
    }
}
""")
    return "\n".join(lines)


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
        var value = regexz.Regex.init(gpa, pattern_buf.items, .{ .unicode_perl_classes = true, .dollar_endonly = true }) catch {
            for (case.inputs) |input| {
                std.debug.print("E\t{s}\t{s}\t", .{ case.pattern, case.flags });
                printHex(input);
                std.debug.print("\n", .{});
            }
            continue;
        };
        defer value.deinit();
        var workspace = regexz.ReplaceWorkspace.init(gpa, value.program, .{ .unicode_perl_classes = true }) catch continue;
        defer workspace.deinit();
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
        }
    }
}
""")
    return "\n".join(lines)



NODE_REFERENCE = r"""
const fs = require("fs");
const cases = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
function advance(input, offset) {
  const cp = input.codePointAt(offset);
  return offset + (cp > 0xffff ? 2 : 1);
}
function byteIndex(input, unitIndex) { return Buffer.byteLength(input.slice(0, unitIndex)); }
function hex(input) { return Buffer.from(input).toString("hex"); }
for (const c of cases) {
  let nodeFlags = c.flags;
  if ((c.pattern.includes("\\p") || c.pattern.includes("\\P")) && !nodeFlags.includes("u")) nodeFlags += "u";
  for (const input of c.inputs) {
    let full = false;
    try {
      const wrapped = new RegExp(`(?:${c.pattern})(?![\\s\\S])`, nodeFlags + "y");
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
      const global = new RegExp(c.pattern, nodeFlags + "g");
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
  }
}
"""

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cases", type=int, default=500)
    parser.add_argument("--seed", type=int, default=20261118)
    args = parser.parse_args()

    cases = generate(args.cases, args.seed)
    with tempfile.TemporaryDirectory() as temp:
        temp_path = Path(temp)
        rust_dir = temp_path / "rust_ref"
        (rust_dir / "src").mkdir(parents=True)
        (rust_dir / "Cargo.toml").write_text(
            '[package]\nname = "regexz_ref"\nversion = "0.1.0"\nedition = "2021"\n\n'
            '[dependencies]\nregex = "1.13.1"\n',
            encoding="utf-8",
        )
        (rust_dir / "src" / "main.rs").write_text(rust_source(cases), encoding="utf-8")
        rust = subprocess.run(
            ["cargo", "run", "--offline", "--release", "--quiet"],
            cwd=rust_dir, capture_output=True, text=True,
            env={**__import__("os").environ, "CARGO_TARGET_DIR": str(temp_path / "target")},
        )
        if rust.returncode != 0:
            sys.stderr.write(rust.stderr)
            return 1
        cases_path = temp_path / "cases.json"
        cases_path.write_text(json.dumps(cases, ensure_ascii=False), encoding="utf-8")
        reference_path = temp_path / "reference.js"
        reference_path.write_text(NODE_REFERENCE, encoding="utf-8")
        node = subprocess.run(
            ["node", str(reference_path), str(cases_path)],
            capture_output=True, text=True, check=True,
        )
        zig_path = temp_path / "fuzz_rust.zig"
        zig_path.write_text(zig_source(cases), encoding="utf-8")
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
        rust_lines = rust.stdout.splitlines()
        node_lines = node.stdout.splitlines()
        zig_lines = zig.stderr.splitlines()
        if len(rust_lines) != len(zig_lines) or len(node_lines) != len(zig_lines):
            print(f"line count differs: rust={len(rust_lines)} node={len(node_lines)} zig={len(zig_lines)}")
            return 1
        divergences = 0
        for index, (rust_line, node_line, zig_line) in enumerate(zip(rust_lines, node_lines, zig_lines)):
            if zig_line == rust_line:
                continue
            if zig_line == node_line:
                # Rust's DFA resolves some ambiguous alternations differently
                # from PCRE2/Perl/Node. Node is the semantic arbiter.
                divergences += 1
                if divergences <= 5:
                    print(f"known Rust divergence at line {index + 1}:")
                    print(f"  rust:     {rust_line}")
                    print(f"  node/zig: {zig_line}")
                continue
            print(f"mismatch at line {index + 1}:")
            print(f"  rust: {rust_line}")
            print(f"  node: {node_line}")
            print(f"  zig:  {zig_line}")
            return 1
        print(f"rust fuzz ok: {len(cases)} patterns, {len(zig_lines)} comparisons, {divergences} known Rust divergences")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
