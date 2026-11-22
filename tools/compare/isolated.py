#!/usr/bin/env python3
"""Measure selected comparison cases one process at a time.

The full-suite harnesses run every case in one process; a change in one
case's code or heap layout can perturb unrelated rows. This runner invokes
each selected case in a fresh process for both implementations, interleaving
them, and reports medians. Build the harnesses first (see README.md).

Usage:
    python3 tools/compare/isolated.py 5 "find IPv4" "find IPv6"
"""
import re
import statistics
import subprocess
import sys

ZIG = "/tmp/regexz-compare"
PCRE2 = "/tmp/regexz-pcre2"
RUST = "tools/compare/rust_regex/target/release/rust_regex"

LINE = re.compile(r"^(.*?)\s+([0-9]+(?:\.[0-9]+)?) ns/iter$")


def run(binary, case):
    out = subprocess.run(
        ["taskset", "-c", "0", binary, case],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for line in out.splitlines():
        match = LINE.match(line)
        if match:
            return float(match.group(2))
    raise SystemExit(f"no measurement for {case!r} from {binary}")


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    rounds = int(sys.argv[1])
    cases = sys.argv[2:]
    samples = {case: {"zig": [], "pcre2": [], "rust": []} for case in cases}
    for _ in range(rounds):
        for case in cases:
            samples[case]["zig"].append(run(ZIG, case))
            samples[case]["pcre2"].append(run(PCRE2, case))
            samples[case]["rust"].append(run(RUST, case))
    print(f"{'case':<32} {'zig':>10} {'pcre2':>10} {'rust':>10} {'pcre2/z':>8} {'rust/z':>8}")
    for case in cases:
        z = statistics.median(samples[case]["zig"])
        p = statistics.median(samples[case]["pcre2"])
        r = statistics.median(samples[case]["rust"])
        print(f"{case:<32} {z:>10.1f} {p:>10.1f} {r:>10.1f} {p / z:>8.2f} {r / z:>8.2f}")


if __name__ == "__main__":
    main()
