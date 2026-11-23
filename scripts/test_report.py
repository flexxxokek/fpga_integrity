#!/usr/bin/env python3
"""Generate docs/test_report.md from real regression results.

Two sources are accepted:

* ``--log`` — a ``make sim`` / ``make cov`` log with the machine-readable
  ``TESTS=… PASS=… FAIL=… SKIP=…`` lines printed by ``tb/run_tests.py``;
* ``--build-root`` — per-configuration cocotb ``results.xml`` files, used
  when no log is available (this is what the local coverage run produces).

The report used to be maintained by hand and became stale after the first
code change.  Every number here is derived from one of those sources.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

RESULT_RE = re.compile(
    r"TESTS=(\d+)\s+PASS=(\d+)\s+FAIL=(\d+)\s+SKIP=(\d+)\s+"
    r"([\d.]+)\s+([\d.]+)"
)
LABEL_RE = re.compile(r"^=== (\S+?) ===$", re.M)
BUILD_RE = re.compile(r"^(core|wrapper|harness)_(.+)_w(\d+)$")


def version(cmd: list[str]) -> str:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True,
                             check=False).stdout.strip()
        return out.splitlines()[0] if out else "unknown"
    except OSError:
        return "unknown"


def empty_stats() -> dict:
    return {
        "configs": 0, "tests": 0, "passed": 0, "failed": 0,
        "skipped": 0, "sim_ns": 0.0, "cpu_s": 0.0,
        "modes": Counter(), "algos": set(), "widths": set(),
    }


def add_config(stats: dict, label: str, tests: int, passed: int,
               failed: int, skipped: int, sim_ns: float, cpu_s: float) -> None:
    stats["configs"] += 1
    stats["tests"] += tests
    stats["passed"] += passed
    stats["failed"] += failed
    stats["skipped"] += skipped
    stats["sim_ns"] += sim_ns
    stats["cpu_s"] += cpu_s
    parts = label.split(":")
    if len(parts) == 3:  # "core:parity_even:w8"
        mode, name, width = parts
    else:
        match = BUILD_RE.match(label)  # "core_parity_even_w8"
        if not match:
            return
        mode, name, width = match.groups()
    stats["modes"][mode] += 1
    stats["widths"].add(width)
    if mode != "harness":
        stats["algos"].add(name)


def from_log(text: str) -> dict | None:
    results = RESULT_RE.findall(text)
    if not results:
        return None
    stats = empty_stats()
    labels = LABEL_RE.findall(text)
    if len(labels) != len(results):
        return None  # incomplete log: fall back to the XML files
    # A retried configuration appears twice; the later result is the final
    # one, so keep the last summary per label.
    latest = dict(zip(labels, results))
    for label, row in latest.items():
        tests, passed, failed, skipped = (int(row[i]) for i in range(4))
        add_config(stats, label, tests, passed, failed, skipped,
                   float(row[4]), float(row[5]))
    return stats


def from_xml(build_root: Path) -> dict | None:
    files = sorted(build_root.rglob("results.xml"))
    if not files:
        return None
    stats = empty_stats()
    for path in files:
        tree = ET.parse(path)
        suites = tree.findall("testsuite")
        tests = sum(int(s.get("tests", 0)) for s in suites)
        failed = (sum(int(s.get("failures", 0)) for s in suites)
                  + sum(int(s.get("errors", 0)) for s in suites))
        skipped = sum(int(s.get("skipped", 0)) for s in suites)
        sim_ns = cpu_s = 0.0
        for case in tree.iter("testcase"):
            cpu_s += float(case.get("time", 0.0))
            for prop in case.iter("property"):
                if prop.get("name") == "sim_time_duration":
                    sim_ns += float(prop.get("value", 0.0))
        add_config(stats, path.parent.name, tests, tests - failed - skipped,
                   failed, skipped, sim_ns, cpu_s)
    return stats


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", default=None,
                        help="regression log with TESTS= summary lines")
    parser.add_argument("--build-root", default="sim_build/regression",
                        help="directory with per-configuration results.xml")
    parser.add_argument("--out", default="docs/test_report.md")
    args = parser.parse_args(argv)

    stats = None
    source = ""
    if args.log and Path(args.log).is_file():
        text = Path(args.log).read_text(encoding="utf-8", errors="replace")
        stats = from_log(text)
        if stats:
            source = f"the regression log `{args.log}`"
    if stats is None:
        stats = from_xml(Path(args.build_root))
        if stats:
            source = (f"the per-configuration `results.xml` files under "
                      f"`{args.build_root}`")
    if stats is None:
        print("no TESTS= lines in log and no results.xml under build root; "
              "run `make sim` or `make cov` first", file=sys.stderr)
        return 1

    lines = [
        "# Test Report — FPGA Integrity Module",
        "",
        "This file is generated by `scripts/test_report.py` from real",
        f"regression results ({source}); do not edit it by hand.",
        "",
        "## 1. Environment",
        "",
        "| Component | Version |",
        "|---|---|",
        f"| Verilator | {version(['verilator', '--version'])} |",
        f"| Python | {version([sys.executable, '--version'])} |",
        f"| cocotb | {version([sys.executable, '-c', 'import cocotb; print(cocotb.__version__)'])} |",
        "",
        "## 2. Regression results",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Build/test configurations | {stats['configs']} |",
        f"| cocotb tests | {stats['tests']} |",
        f"| Passed | {stats['passed']} |",
        f"| Failed | {stats['failed']} |",
        f"| Skipped | {stats['skipped']} |",
        f"| Aggregate test sim time | {stats['sim_ns']:,.0f} ns |",
        f"| Aggregate test CPU time | {stats['cpu_s']:.2f} s |",
        "",
        "### Configuration matrix",
        "",
        "- Levels: " + ", ".join(f"{k} ({v})" for k, v in
                                 sorted(stats["modes"].items())) + ".",
        f"- Algorithm configurations: {len(stats['algos'])}"
        + (f" ({', '.join(sorted(stats['algos']))})." if stats["algos"] else "."),
        f"- Data widths: {', '.join(sorted(stats['widths']))}.",
        "",
        "### Test groups exercised",
        "",
        "| Level | Test | Content |",
        "|---|---|---|",
        "| core | `directed_and_random` | known vectors, boundaries, 1000 random packets up to 2048 B |",
        "| core | `known_vectors` | CRC catalogue checks, Adler-32, SHA-256 |",
        "| wrapper | `clean_roundtrip` | tag insert/extract under randomized backpressure |",
        "| wrapper | `latency` | tag_valid latency measured in clock cycles |",
        "| wrapper | `back_to_back_and_reset` | consecutive packets, reset mid-packet |",
        "| wrapper | `injected_error_detected` | corrupted payload raises tag_error |",
        "| harness | `campaign` | full stand against a Python oracle for all 6 lanes; weight-bucket accounting |",
        "",
        "## 3. Lint",
        "",
        "`make lint` (Verilator `--lint-only -Wall`) runs for DATA_WIDTH",
        "8/32/64. See the command output in CI for current warnings.",
        "",
        "## 4. Coverage and static metrics",
        "",
        "- RTL line coverage: [docs/coverage.md](coverage.md) (`make cov-report`).",
        "- Yosys synthesis: [docs/results/synthesis.md](results/synthesis.md).",
        "",
        "## 5. Not covered",
        "",
        "- Board bring-up, vendor P&R, Fmax and real LUT/FF (stage 3–4).",
        "- Final conclusions from hardware: [docs/results/conclusion.md](results/conclusion.md).",
        "",
    ]
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {out}: {stats['passed']}/{stats['tests']} passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
