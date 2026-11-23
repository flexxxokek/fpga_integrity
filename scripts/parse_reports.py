#!/usr/bin/env python3
"""Extract static QoR metrics from synthesis reports into a CSV.

Supported report families (auto-detected from the file contents):

* Vivado utilisation / timing summaries (``Slice LUTs``, ``Slice Registers``,
  ``Block RAM Tile``, ``DSPs``, ``WNS``, ``Fmax``).
* Quartus fitter summaries (``Total logic elements``, ``Total registers``,
  ``Total block memory bits``, ``DSP Blocks``, ``Fmax``).
* Yosys ``stat`` output (cell names are classified into LUT/FF/BRAM/DSP).

The algorithm and DATA_WIDTH are inferred from the file name when possible,
for example ``crc32_w32.rpt`` becomes ``algo=crc32``, ``width=32``.

Example:
    python scripts/parse_reports.py --input syn/reports/*.rpt
    python scripts/parse_reports.py --input syn/ --out data/synthesis.csv
"""

from __future__ import annotations

import argparse
import csv
import glob
import re
import sys
from pathlib import Path

FIELDS = [
    "source",
    "tool",
    "algo",
    "width",
    "luts",
    "ffs",
    "brams",
    "dsps",
    "fmax_mhz",
    "wns_ns",
]


def to_int(text: str | None) -> int | None:
    if not text:
        return None
    cleaned = re.sub(r"[^0-9]", "", text)
    return int(cleaned) if cleaned else None


def to_float(text: str | None) -> float | None:
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def first(pattern: str, text: str, flags: int = re.IGNORECASE) -> str | None:
    match = re.search(pattern, text, flags)
    return match.group(1) if match else None


def parse_vivado(text: str) -> dict[str, object]:
    return {
        "luts": to_int(first(r"\|\s*Slice LUTs\s*\|\s*([\d,]+)", text)),
        "ffs": to_int(first(r"\|\s*Slice Registers\s*\|\s*([\d,]+)", text)),
        "brams": to_int(first(r"\|\s*Block RAM Tile\s*\|\s*([\d,]+)", text)),
        "dsps": to_int(first(r"\|\s*DSPs\s*\|\s*([\d,]+)", text)),
        "wns_ns": to_float(
            first(r"WNS\s*\(ns\)\s*[:|]?\s*(-?[\d.]+)", text)
            or first(r"Worst Negative Slack[^\n]*?(-?\d+\.\d+)", text)
        ),
        "fmax_mhz": to_float(
            first(r"Fmax\s*[:=]\s*([\d.]+)\s*MHz", text)
            or first(r"Maximum frequency[^\n]*?([\d.]+)\s*MHz", text)
        ),
    }


def parse_quartus(text: str) -> dict[str, object]:
    return {
        "luts": to_int(first(r"Total logic elements\s*[:|]\s*([\d,]+)", text)),
        "ffs": to_int(first(r"Total registers\s*[:|]\s*([\d,]+)", text)),
        "brams": to_int(first(r"Total block memory bits\s*[:|]\s*([\d,]+)", text)),
        "dsps": to_int(first(r"Total DSP Blocks\s*[:|]\s*([\d,]+)", text)),
        "wns_ns": to_float(first(r"Worst-case slack\s*[:=]\s*(-?[\d.]+)", text)),
        "fmax_mhz": to_float(
            first(r";\s*Fmax\s*=\s*([\d.]+)\s*MHz", text)
            or first(r"Fmax\s*[:=]\s*([\d.]+)\s*MHz", text)
        ),
    }


def parse_yosys(text: str) -> dict[str, object]:
    luts = ffs = brams = dsps = 0
    found = False
    # Internal Yosys gate cells ($_AND_, $_MUX_, ...) from `synth -noabc` are
    # used as a gate-equivalent proxy when no mapped LUT cells are present.
    # This happens with the WASM Yosys build, which cannot run ABC.
    generic_gates = (
        "$_AND_", "$_NAND_", "$_OR_", "$_NOR_", "$_XOR_", "$_XNOR_",
        "$_NOT_", "$_MUX_", "$_AOI_", "$_OAI_", "$_ANDNOT_",
    )
    for match in re.finditer(r"^\s+(\d+)\s+([A-Za-z0-9_$\\]+)\s*$", text, re.M):
        count = int(match.group(1))
        name = match.group(2).upper()
        if "LUT" in name or name in generic_gates:
            luts += count
            found = True
        if any(token in name for token in ("DFF", "FDRE", "FDCE", "FDPE", "FDSE")):
            ffs += count
            found = True
        if any(token in name for token in ("RAM", "BRAM", "DPRAM")):
            brams += count
            found = True
        if any(token in name for token in ("DSP", "MULT")):
            dsps += count
            found = True
    if not found:
        return {}
    return {
        "luts": luts or None,
        "ffs": ffs or None,
        "brams": brams or None,
        "dsps": dsps or None,
        "wns_ns": None,
        "fmax_mhz": None,
    }


def detect_tool(text: str) -> str:
    lowered = text.lower()
    if "yosys" in lowered or "number of cells:" in lowered:
        return "yosys"
    if "quartus" in lowered or "total logic elements" in lowered:
        return "quartus"
    if "vivado" in lowered or "slice luts" in lowered:
        return "vivado"
    return "unknown"


def infer_identity(path: Path) -> tuple[str, str]:
    stem = path.stem
    match = re.search(
        r"(?P<algo>[A-Za-z][A-Za-z0-9_]*?)[_-]?(?:w|width)(?P<width>\d+)",
        stem,
        re.IGNORECASE,
    )
    if match:
        return match.group("algo"), match.group("width")
    return stem, ""


def expand(paths: list[str]) -> list[Path]:
    result: list[Path] = []
    for path in paths:
        if Path(path).is_dir():
            result.extend(sorted(Path(path).rglob("*.rpt")))
            result.extend(sorted(Path(path).rglob("*.log")))
            result.extend(sorted(Path(path).rglob("*.txt")))
        else:
            result.extend(Path(match) for match in sorted(glob.glob(path)))
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", nargs="+", required=True, help="report files/dirs")
    parser.add_argument("--out", default="data/synthesis.csv")
    args = parser.parse_args(argv)

    paths = expand(args.input)
    if not paths:
        print("no report files found", file=sys.stderr)
        return 1

    rows = []
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"skip {path}: {exc}", file=sys.stderr)
            continue
        tool = detect_tool(text)
        parser_fn = {
            "vivado": parse_vivado,
            "quartus": parse_quartus,
            "yosys": parse_yosys,
        }.get(tool)
        metrics = parser_fn(text) if parser_fn else {}
        if not any(value is not None for value in metrics.values()):
            print(f"skip {path}: no known metrics (tool={tool})", file=sys.stderr)
            continue
        algo, width = infer_identity(path)
        row = {"source": str(path), "tool": tool, "algo": algo, "width": width}
        row.update(metrics)
        rows.append(row)
        print(f"{path}: tool={tool} algo={algo} width={width} {metrics}")

    if not rows:
        print("no metrics extracted", file=sys.stderr)
        return 1

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    print(f"wrote {len(rows)} rows to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
