#!/usr/bin/env python3
"""Synthesise every integrity core with Yosys and write static QoR reports.

Yosys is used with the generic gate library (``synth -noabc``): the WASM build
distributed as ``yowasp-yosys`` cannot run ABC's temp-file flow, and no vendor
P&R is available in CI.  Consequently the reports contain *gate-equivalent*
cell counts and flip-flop counts, not vendor LUTs or Fmax.  They are still a
real synthesis result and make the hardware-cost comparison reproducible.

Usage:
    python scripts/synth.py            # all algorithms x widths 8,32,64
    python scripts/synth.py --quick    # one width, one algorithm
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORES = ROOT / "rtl" / "cores"
BUILD = ROOT / "syn" / "yosys" / "build"
REPORTS = ROOT / "syn" / "reports"

# (report name, module, chassis parameters)
ALGOS = [
    ("parity_even", "parity_core", {"PARITY_ODD": 0}),
    ("parity_odd", "parity_core", {"PARITY_ODD": 1}),
    ("checksum16", "checksum_core", {"SUM_WIDTH": 16, "ONES_COMPLEMENT": 1}),
    ("checksum8", "checksum_core", {"SUM_WIDTH": 8, "ONES_COMPLEMENT": 0}),
    ("fletcher16", "fletcher_core", {"BLOCK_WIDTH": 8}),
    ("fletcher32", "fletcher_core", {"BLOCK_WIDTH": 16}),
    ("adler32", "adler32_core", {}),
    ("crc8", "crc_engine", {"CRC_WIDTH": 8, "POLY": "8'h07",
                            "INIT": "8'h00", "REFIN": 0,
                            "REFOUT": 0, "XOROUT": "8'h00"}),
    ("crc16_ccitt_false", "crc_engine",
     {"CRC_WIDTH": 16, "POLY": "16'h1021", "INIT": "16'hFFFF",
      "REFIN": 0, "REFOUT": 0, "XOROUT": "16'h0000"}),
    ("crc16_arc", "crc_engine",
     {"CRC_WIDTH": 16, "POLY": "16'h8005", "INIT": "16'h0000",
      "REFIN": 1, "REFOUT": 1, "XOROUT": "16'h0000"}),
    ("crc32", "crc_engine",
     {"CRC_WIDTH": 32, "POLY": "32'h04C11DB7", "INIT": "32'hFFFFFFFF",
      "REFIN": 1, "REFOUT": 1, "XOROUT": "32'hFFFFFFFF"}),
    ("crc32c", "crc_engine",
     {"CRC_WIDTH": 32, "POLY": "32'h1EDC6F41", "INIT": "32'hFFFFFFFF",
      "REFIN": 1, "REFOUT": 1, "XOROUT": "32'hFFFFFFFF"}),
    ("sha256", "sha256_core", {}),
]


def yosys_command() -> list[str]:
    local = ROOT / ".venv" / "bin" / "yowasp-yosys"
    if local.exists():
        return [str(local)]
    if shutil.which("yosys"):
        return ["yosys"]
    print("error: install yosys or `pip install yowasp-yosys`", file=sys.stderr)
    raise SystemExit(2)


def synthesise(cmd: list[str], name: str, module: str, params: dict,
               width: int) -> Path:
    BUILD.mkdir(parents=True, exist_ok=True)
    REPORTS.mkdir(parents=True, exist_ok=True)
    script = BUILD / f"{name}_w{width}.ys"
    lines = [f"read_verilog -sv {CORES / module}.sv"]
    all_params = {"DATA_WIDTH": width, **params}
    lines.append("chparam " + " ".join(
        f"-set {key} {value}" for key, value in all_params.items()
    ) + f" {module}")
    lines += [
        f"hierarchy -top {module}",
        f"synth -top {module} -noabc",
        "stat",
    ]
    script.write_text("\n".join(lines) + "\n", encoding="utf-8")
    report = REPORTS / f"{name}_w{width}.rpt"
    with report.open("w", encoding="utf-8") as handle:
        handle.write(f"# yosys script: {script.relative_to(ROOT)}\n")
        result = subprocess.run(cmd + ["-s", str(script.relative_to(ROOT))],
                                cwd=ROOT, stdout=handle,
                                stderr=subprocess.STDOUT, check=False,
                                env={**os.environ, "PYTHONPATH": str(ROOT)})
    if result.returncode != 0:
        raise RuntimeError(f"yosys failed for {name} w{width}; see {report}")
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--widths", default="8,32,64")
    parser.add_argument("--only", default=None)
    parser.add_argument("--quick", action="store_true")
    args = parser.parse_args(argv)
    widths = [int(w) for w in args.widths.split(",") if w]
    if args.quick:
        widths = [widths[0]]
    algos = [a for a in ALGOS if args.only is None or args.only in a[0]]
    cmd = yosys_command()
    reports = []
    for name, module, params in algos:
        for width in widths:
            print(f"=== synth {name} w{width} ===", flush=True)
            reports.append(synthesise(cmd, name, module, params, width))
    print(f"wrote {len(reports)} reports to {REPORTS.relative_to(ROOT)}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
