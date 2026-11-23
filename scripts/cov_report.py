#!/usr/bin/env python3
"""Merge all per-build Verilator coverage files into one report.

`make cov` writes one `coverage.dat` per build directory.  Without merging
them, a single small configuration can be mistaken for 95% coverage — this is
exactly the mistake the earlier test report made.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", default="sim_build/regression")
    parser.add_argument("--out", default="docs/coverage.md")
    args = parser.parse_args(argv)

    root = Path(args.build_root)
    files = sorted(root.rglob("coverage.dat"))
    if not files:
        print(f"no coverage.dat under {root}; run `make cov` first",
              file=sys.stderr)
        return 1
    tool = shutil.which("verilator_coverage")
    if tool is None:
        print("verilator_coverage not found", file=sys.stderr)
        return 1

    tmp_root = Path("/tmp/opencode") if Path("/tmp/opencode").is_dir() else None
    with tempfile.TemporaryDirectory(prefix="cov-", dir=tmp_root) as tmp:
        info = Path(tmp) / "merged.info"
        cmd = [tool, "--write-info", str(info), *(str(f) for f in files)]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(result.stderr, file=sys.stderr)
            return 1
        lines = info.read_text(encoding="utf-8", errors="replace").splitlines()

    hits: dict[str, list[int]] = defaultdict(list)
    source = ""
    for line in lines:
        if line.startswith("SF:"):
            source = line[3:]
        elif line.startswith("DA:"):
            parts = line[3:].split(",")
            if len(parts) >= 2:
                try:
                    hits[source].append(int(parts[1]))
                except ValueError:
                    pass

    total = sum(len(v) for v in hits.values())
    covered = sum(1 for v in hits.values() for hit in v if hit > 0)
    pct = 100.0 * covered / total if total else 0.0

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    text = [
        "# RTL line coverage",
        "",
        f"Merged from **{len(files)}** build directories by `make cov-report`.",
        "",
        f"**Total: {covered}/{total} executable lines = {pct:.2f}%**",
        "",
        "| Source file | Lines covered | Total | Coverage |",
        "|---|---:|---:|---:|",
    ]
    for source in sorted(hits):
        values = hits[source]
        hit = sum(1 for v in values if v > 0)
        name = Path(source).name
        text.append(f"| {name} | {hit} | {len(values)} | "
                    f"{100.0 * hit / len(values):.2f}% |")
    text.append("")
    out.write_text("\n".join(text), encoding="utf-8")
    print(f"wrote {out}: {covered}/{total} = {pct:.2f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
