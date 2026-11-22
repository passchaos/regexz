#!/usr/bin/env python3
"""Full comparison sweep with one fresh process per case.

The full-suite harnesses run every case in one process, so a change in one
case can perturb unrelated rows through heap and code layout. This runner
invokes each case in its own process, interleaves the implementations, and
writes medians in the same schema as the full-suite JSON files.

Usage:
    python3 tools/compare/isolated_sweep.py --rounds 5 --out /tmp/samples.json
"""
import argparse
import json
import re
import statistics
import subprocess

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


def cases_of(binary):
    out = subprocess.run([binary], capture_output=True, text=True, check=True).stdout
    return [match.group(1).strip() for line in out.splitlines() if (match := LINE.match(line))]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--out", default="/tmp/isolated_samples.json")
    args = parser.parse_args()
    zig_cases = cases_of(ZIG)
    pcre2_cases = set(cases_of(PCRE2))
    rust_cases = set(cases_of(RUST))
    rounds = []
    for _ in range(args.rounds):
        runs = {"zig": {}, "pcre2": {}, "rust": {}}
        for case in zig_cases:
            runs["zig"][case] = run(ZIG, case)
            if case in pcre2_cases:
                runs["pcre2"][case] = run(PCRE2, case)
            if case in rust_cases:
                runs["rust"][case] = run(RUST, case)
        rounds.append(runs)
        print(f"round done: {len(runs['zig'])} zig, {len(runs['pcre2'])} pcre2, {len(runs['rust'])} rust")
    with open(args.out, "w") as handle:
        json.dump({"rounds": rounds}, handle)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
