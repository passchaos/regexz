#!/usr/bin/env python3
"""Benchmark regression smoke gate.

Runs `zig build bench -Doptimize=ReleaseFast` several times, takes the median
ns/iter per case, and compares against `tools/bench/baseline.json`. A case that
regresses by more than the configured tolerance fails the check.

The host is shared/noisy, so this is a smoke gate for large regressions (for
example losing a DFA fast path), not a precise performance certification.
Run with `--update` on a quiet host to refresh the baseline.

Usage:
    python3 tools/bench/check.py [--runs 3] [--tolerance 1.8]
    python3 tools/bench/check.py --update
"""
import argparse
import json
import re
import statistics
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = Path(__file__).resolve().parent / "baseline.json"
LINE = re.compile(r"^(.*?)\s+([0-9]+(?:\.[0-9]+)?) ns/iter")


def run_bench() -> dict[str, float]:
    result = subprocess.run(
        ["zig", "build", "bench", "-Doptimize=ReleaseFast"],
        cwd=ROOT, capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(1)
    cases = {}
    for line in result.stdout.splitlines():
        match = LINE.match(line)
        if not match:
            continue
        cases[match.group(1).strip()] = float(match.group(2))
    return cases


def collect(runs: int) -> dict[str, float]:
    samples: dict[str, list[float]] = {}
    for _ in range(runs):
        for name, value in run_bench().items():
            samples.setdefault(name, []).append(value)
    return {name: statistics.median(values) for name, values in samples.items()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--tolerance", type=float, default=1.8)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()

    current = collect(args.runs)
    if args.update:
        BASELINE.write_text(
            json.dumps({"tolerance": args.tolerance, "cases": current}, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        print(f"baseline updated: {len(current)} cases -> {BASELINE}")
        return 0
    if not BASELINE.exists():
        print(f"missing baseline: {BASELINE}; run with --update", file=sys.stderr)
        return 1
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    expected = baseline.get("cases", {})
    tolerance = max(args.tolerance, float(baseline.get("tolerance", 1.0)))
    regressions = []
    improvements = []
    missing = []
    for name, base in sorted(expected.items()):
        if name not in current:
            missing.append(name)
            continue
        value = current[name]
        ratio = value / base if base > 0 else 0.0
        if ratio > tolerance:
            regressions.append((name, base, value, ratio))
        elif ratio < 0.7:
            improvements.append((name, base, value, ratio))
    for name, base, value, ratio in regressions:
        print(f"REGRESSION {name}: {base:.1f} -> {value:.1f} ns ({ratio:.2f}x)")
    for name, base, value, ratio in improvements:
        print(f"improved   {name}: {base:.1f} -> {value:.1f} ns ({ratio:.2f}x)")
    for name in missing:
        print(f"missing    {name}")
    if regressions or missing:
        return 1
    print(f"bench ok: {len(current)} cases, tolerance {tolerance:.2f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
