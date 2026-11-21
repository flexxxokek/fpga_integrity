#!/usr/bin/env python3
"""Collect measurement reports from UART (or a saved log) into a CSV file.

The harness emits one line per lane:

    RESULT,<lane>,<packets>,<corrupted>,<detected>,<missed>,<false>
    DONE

The specification also allows the generic form:

    RESULT,<algo>,<campaign>,<metric>,<value>
    DONE,<campaign>

Both formats are accepted.  Use ``--input`` for offline logs and ``--port`` for
a live serial connection.  Metadata (board, git revision, seed) is copied into
every row so later analysis never depends on the file name alone.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import re
import subprocess
import sys
from pathlib import Path

LANE_NAMES = ["parity", "checksum16", "fletcher16", "adler32", "crc32", "sha256"]

HARNESS_METRICS = ["packets", "corrupted", "detected", "missed", "false"]

FIELDS = ["timestamp", "board", "git", "seed", "campaign", "algo", "metric", "value"]


def git_revision() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            stderr=subprocess.DEVNULL,
            text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def parse_line(line: str) -> list[tuple[str, str, str, str]] | None:
    """Return (campaign, algo, metric, value) rows, or None for non-data lines."""
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    parts = [part.strip() for part in line.split(",")]
    if not parts or parts[0].upper() != "RESULT":
        return None

    # Generic protocol: RESULT,<algo>,<campaign>,<metric>,<value>
    if len(parts) == 5 and not re.fullmatch(r"\d+", parts[1]):
        _, algo, campaign, metric, value = parts
        return [(campaign, algo, metric, value)]

    # Harness protocol: RESULT,<lane>,<packets>,<corrupted>,<detected>,<missed>,<false>
    if len(parts) == 7 and all(re.fullmatch(r"-?\d+", p) for p in parts[1:]):
        lane = int(parts[1])
        algo = LANE_NAMES[lane] if 0 <= lane < len(LANE_NAMES) else f"lane{lane}"
        values = parts[2:]
        return [
            ("harness", algo, metric, value)
            for metric, value in zip(HARNESS_METRICS, values)
        ]

    # Tolerate a lane report with extra fields by using the first five metrics.
    if len(parts) > 3 and re.fullmatch(r"\d+", parts[1]):
        lane = int(parts[1])
        algo = LANE_NAMES[lane] if 0 <= lane < len(LANE_NAMES) else f"lane{lane}"
        rows = []
        for metric, value in zip(HARNESS_METRICS, parts[2:]):
            if not re.fullmatch(r"-?\d+", value):
                break
            rows.append(("harness", algo, metric, value))
        return rows or None

    return None


def read_lines(args: argparse.Namespace):
    if args.input == "-":
        yield from sys.stdin
        return
    if args.input:
        with open(args.input, encoding="utf-8") as handle:
            yield from handle
        return

    try:
        import serial  # type: ignore
    except ImportError as exc:  # pragma: no cover - depends on environment
        raise SystemExit(
            "pyserial is required for --port; use --input for an offline log"
        ) from exc

    with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
        while True:
            raw = port.readline()
            if not raw:
                if args.timeout:
                    break
                continue
            yield raw.decode("utf-8", errors="replace")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--port", help="serial port, e.g. /dev/ttyUSB0")
    source.add_argument("--input", help="offline log file, or '-' for stdin")
    parser.add_argument("--baud", type=int, default=115_200)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--out", default=None, help="output CSV path")
    parser.add_argument("--board", default="unknown")
    parser.add_argument("--git", default=None)
    parser.add_argument("--seed", default="")
    parser.add_argument("--campaign", default="")
    args = parser.parse_args(argv)

    if not args.port and not args.input:
        parser.error("one of --port or --input is required")

    revision = args.git or git_revision()
    stamp = dt.datetime.now().astimezone()
    out_path = Path(
        args.out
        or f"data/{stamp:%Y%m%d_%H%M%S}_{args.board}.csv"
    )
    out_path.parent.mkdir(parents=True, exist_ok=True)

    rows = 0
    with open(out_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        for line in read_lines(args):
            parsed = parse_line(line)
            if parsed is None:
                continue
            for campaign, algo, metric, value in parsed:
                writer.writerow(
                    {
                        "timestamp": stamp.isoformat(timespec="seconds"),
                        "board": args.board,
                        "git": revision,
                        "seed": args.seed,
                        "campaign": campaign or args.campaign,
                        "algo": algo,
                        "metric": metric,
                        "value": value,
                    }
                )
                rows += 1

    print(f"wrote {rows} rows to {out_path}")
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
