#!/usr/bin/env python3
"""Measure compiled before/after benchmarks in alternating execution order.

Example:
  python3 tools/bench/interleave.py --baseline a933a4b --rounds 3 \
      --suite startup BEFORE_EXE AFTER_EXE --output samples.json
Multiple --suite arguments run sequentially within each before/after sample.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import statistics
import subprocess
from pathlib import Path

LINE = re.compile(r"^(.*?)\s+([0-9]+(?:\.[0-9]+)?) ns/(iter|pass|search)\b(.*)$")
COUNTER = re.compile(r"\b(\w+)=(\d+)\b")


def parse(output: str) -> dict:
    cases = {}
    for line in output.splitlines():
        match = LINE.match(line)
        if match is None:
            continue
        name, value, unit, tail = match.groups()
        name = " ".join(name.split())
        if name in cases:
            raise ValueError(f"duplicate benchmark case: {name}")
        cases[name] = {
            "ns": float(value),
            "unit": f"ns/{unit}",
            "counters": {key: int(value) for key, value in COUNTER.findall(tail)},
        }
    if not cases:
        raise ValueError("benchmark emitted no timing cases")
    return cases


def save(path: Path, result: dict) -> None:
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def measure(suites: dict, rounds: int, output: Path, baseline: str | None) -> dict:
    result = {
        "baseline": baseline,
        "method": "alternating before/after executions; suites run sequentially",
        "executables": suites,
        "rounds": [],
    }
    for index in range(rounds):
        order = ["before", "after"] if index % 2 == 0 else ["after", "before"]
        sample = {"order": order, "runs": {}}
        result["rounds"].append(sample)
        for label in order:
            cases = {}
            sample["runs"][label] = cases
            for suite, executables in suites.items():
                run = subprocess.run([executables[label]["path"]], capture_output=True, text=True)
                if run.returncode != 0:
                    raise RuntimeError(f"{suite}/{label} failed ({run.returncode})\n{run.stdout}\n{run.stderr}")
                parsed = parse(run.stdout)
                cases.update({f"{suite}/{name}": values for name, values in parsed.items()})
                save(output, result)
            print(f"round {index + 1} {label}: {len(cases)} cases", flush=True)
        before, after = sample["runs"]["before"], sample["runs"]["after"]
        if before.keys() != after.keys():
            raise ValueError(f"case mismatch in round {index + 1}")
        if index and before.keys() != result["rounds"][0]["runs"]["before"].keys():
            raise ValueError(f"case mismatch between rounds 1 and {index + 1}")
        for name in before:
            if before[name]["unit"] != after[name]["unit"]:
                raise ValueError(f"unit mismatch for {name}")
    medians = {}
    for name in result["rounds"][0]["runs"]["before"]:
        values = {
            label: statistics.median(sample["runs"][label][name]["ns"] for sample in result["rounds"])
            for label in ["before", "after"]
        }
        values["unit"] = result["rounds"][0]["runs"]["before"][name]["unit"]
        values["speedup"] = values["before"] / values["after"] if values["after"] else None
        medians[name] = values
    result["medians"] = medians
    save(output, result)
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--suite", nargs=3, action="append", required=True, metavar=("NAME", "BEFORE", "AFTER"))
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--baseline")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.rounds <= 0:
        parser.error("--rounds must be positive")
    suites = {}
    for name, before, after in args.suite:
        if name in suites:
            parser.error(f"duplicate suite: {name}")
        suites[name] = {}
        for label, executable in [("before", before), ("after", after)]:
            path = Path(executable).resolve(strict=True)
            suites[name][label] = {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    result = measure(suites, args.rounds, args.output, args.baseline)
    for name, values in result["medians"].items():
        speedup = f"{values['speedup']:.2f}x" if values["speedup"] is not None else "undefined"
        print(f"{name:<50} {values['before']:12.1f} -> {values['after']:12.1f} {values['unit']} {speedup}")


if __name__ == "__main__":
    main()
