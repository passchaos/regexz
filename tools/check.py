#!/usr/bin/env python3
"""Run the full local verification gate.

Usage:
    python3 tools/check.py [--fuzz 400] [--bench] [--skip-codegen]

Steps: formatting, tests, generated-data determinism, differential fuzzers,
and optionally the benchmark regression gate. The Rust fuzzer is skipped when
cargo is unavailable; `--skip-codegen` avoids the network when the UCD and RE2
sources cannot be fetched.
"""
import argparse
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SEED = "191"


def run(name: str, command: list[str]) -> bool:
    print(f"== {name}", flush=True)
    result = subprocess.run(command, cwd=ROOT)
    if result.returncode != 0:
        print(f"FAILED: {name}", file=sys.stderr)
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fuzz", type=int, default=400)
    parser.add_argument("--bench", action="store_true")
    parser.add_argument("--skip-codegen", action="store_true")
    args = parser.parse_args()

    steps: list[tuple[str, list[str]]] = [
        ("format", ["zig", "fmt", "--check", "src", "build.zig"]),
        ("tests", ["zig", "build", "test"]),
    ]
    if not args.skip_codegen:
        steps.append(("codegen", [sys.executable, "tools/codegen/generate.py", "--verify"]))
    steps.append(("v8 fuzz", [sys.executable, "tools/fuzz/run.py", "--cases", str(args.fuzz), "--seed", SEED]))
    steps.append(("extended fuzz", [sys.executable, "tools/fuzz/extended.py", "--cases", str(args.fuzz), "--seed", SEED]))
    if shutil.which("cargo"):
        steps.append(("rust fuzz", [sys.executable, "tools/fuzz/rust.py", "--cases", str(args.fuzz), "--seed", SEED]))
    else:
        print("== rust fuzz: skipped (cargo not found)")
    if args.bench:
        steps.append(("bench gate", [sys.executable, "tools/bench/check.py", "--runs", "1"]))

    for name, command in steps:
        if not run(name, command):
            print(f"check failed: {name}", file=sys.stderr)
            return 1
    print(f"check ok: {len(steps)} steps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
