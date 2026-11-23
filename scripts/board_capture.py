#!/usr/bin/env python3
"""Capture the DE2-115 UART report and compare it with the simulator reference.

Usage:
    python scripts/board_capture.py --port /dev/ttyUSB0

The script waits for six RESULT lines followed by DONE, then compares them
with data/sim_clean_w32.csv (same SEED, MODE=0, 64-byte packets).
Press KEY[0] on the board while the script is waiting to start a campaign.
"""

from __future__ import annotations

import argparse
import csv
import sys
import time
from pathlib import Path

LANES = ["parity", "checksum16", "fletcher16", "adler32", "crc32", "sha256"]
FIELDS = ["packets", "corrupted", "detected", "missed", "false", "bytes", "cycles"]


def reference(path: Path) -> dict[str, dict[str, int]]:
    with path.open(newline="", encoding="utf-8") as handle:
        rows = list(csv.DictReader(handle))
    out: dict[str, dict[str, int]] = {lane: {} for lane in LANES}
    for row in rows:
        algo = row["algo"]
        if algo in out:
            out[algo][row["metric"]] = int(row["value"])
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--reference", default="data/sim_clean_w32.csv")
    parser.add_argument("--out", default="data/board_clean_w32.log")
    args = parser.parse_args(argv)

    try:
        import serial  # pyserial, see requirements.txt
    except ImportError:
        print("pyserial is not installed; run `pip install -r requirements.txt`",
              file=sys.stderr)
        return 1

    ref = reference(Path(args.reference))
    print(f"Listening on {args.port} @ {args.baud} 8N1 ...")
    print("Press KEY[0] on the DE2-115 to start a campaign.", flush=True)

    with serial.Serial(args.port, args.baud, timeout=1) as link:
        lines: list[str] = []
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            raw = link.readline().decode("ascii", errors="replace").strip()
            if not raw:
                continue
            print(raw)
            if raw.startswith("RESULT,"):
                lines.append(raw)
            if raw == "DONE":
                break
        else:
            print("timeout: no DONE received", file=sys.stderr)
            return 1

    if len(lines) != len(LANES):
        print(f"expected {len(LANES)} RESULT lines, got {len(lines)}",
              file=sys.stderr)
        return 1

    out_lines = []
    failures = 0
    for line in lines:
        parts = line.split(",")
        lane = int(parts[1])
        algo = LANES[lane]
        values = {name: int(parts[2 + i], 16) for i, name in enumerate(FIELDS)}
        out_lines.append(line)
        for name, expected in ref[algo].items():
            if name in values and values[name] != expected:
                failures += 1
                print(f"MISMATCH lane {lane} ({algo}) {name}: "
                      f"board={values[name]} sim={expected}", file=sys.stderr)

    Path(args.out).write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    if failures:
        print(f"{failures} mismatch(es); raw report saved to {args.out}",
              file=sys.stderr)
        return 1
    print(f"OK: all 6 lanes match the simulator reference; saved {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
