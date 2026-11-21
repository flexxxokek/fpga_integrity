#!/usr/bin/env python3
"""Build and run the cocotb regression matrix with the Verilator runner."""

from __future__ import annotations

import argparse
import os
import shutil
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
TB = ROOT / "tb"
CORES = ROOT / "rtl" / "cores"
WRAPPERS = ROOT / "rtl" / "wrappers"

CORE_SOURCES = [
    CORES / "integrity_pkg.sv",
    CORES / "parity_core.sv",
    CORES / "checksum_core.sv",
    CORES / "fletcher_core.sv",
    CORES / "adler32_core.sv",
    CORES / "crc_engine.sv",
    CORES / "sha256_core.sv",
]
WRAPPER_SOURCES = [WRAPPERS / "integrity_tx.sv", WRAPPERS / "integrity_rx.sv"]
HARNESS_SOURCES = [
    CORES / "integrity_pkg.sv",
    *[p for p in CORE_SOURCES if p.name != "integrity_pkg.sv"],
    *WRAPPER_SOURCES,
    ROOT / "rtl" / "harness" / "stimulus_gen.sv",
    ROOT / "rtl" / "harness" / "error_injector.sv",
    ROOT / "rtl" / "harness" / "integrity_lane.sv",
    ROOT / "rtl" / "harness" / "uart_tx.sv",
    ROOT / "rtl" / "harness" / "uart_rx.sv",
    ROOT / "rtl" / "harness" / "report_uart.sv",
    ROOT / "rtl" / "harness" / "exp_harness_top.sv",
]

CRC_VARIANTS = [
    dict(
        name="crc8",
        CRC_WIDTH=8,
        CRC_POLY=0x07,
        CRC_INIT=0x00,
        CRC_REFIN=False,
        CRC_REFOUT=False,
        CRC_XOROUT=0x00,
    ),
    dict(
        name="crc16_ccitt_false",
        CRC_WIDTH=16,
        CRC_POLY=0x1021,
        CRC_INIT=0xFFFF,
        CRC_REFIN=False,
        CRC_REFOUT=False,
        CRC_XOROUT=0x0000,
    ),
    dict(
        name="crc16_arc",
        CRC_WIDTH=16,
        CRC_POLY=0x8005,
        CRC_INIT=0x0000,
        CRC_REFIN=True,
        CRC_REFOUT=True,
        CRC_XOROUT=0x0000,
    ),
    dict(
        name="crc32",
        CRC_WIDTH=32,
        CRC_POLY=0x04C11DB7,
        CRC_INIT=0xFFFFFFFF,
        CRC_REFIN=True,
        CRC_REFOUT=True,
        CRC_XOROUT=0xFFFFFFFF,
    ),
    dict(
        name="crc32c",
        CRC_WIDTH=32,
        CRC_POLY=0x1EDC6F41,
        CRC_INIT=0xFFFFFFFF,
        CRC_REFIN=True,
        CRC_REFOUT=True,
        CRC_XOROUT=0xFFFFFFFF,
    ),
]


def algorithm_cases(quick: bool):
    """Return (name, parameters) tuples for every configuration."""
    cases = []

    def add(name, algo, tag_width, **extra):
        params = {
            "ALGO": algo,
            "TAG_WIDTH": tag_width,
        }
        params.update(extra)
        cases.append((name, params))

    add("parity_even", 0, 1, PARITY_ODD=False)
    add("parity_odd", 0, 1, PARITY_ODD=True)
    add("checksum16_ones", 1, 16, SUM_WIDTH=16, ONES_COMPLEMENT=True)
    add("checksum8_wrap", 1, 8, SUM_WIDTH=8, ONES_COMPLEMENT=False)
    add("fletcher16", 2, 16, BLOCK_WIDTH=8)
    add("fletcher32", 2, 32, BLOCK_WIDTH=16)
    add("adler32", 3, 32)
    if quick:
        chosen = [CRC_VARIANTS[3]]
    else:
        chosen = CRC_VARIANTS
    for variant in chosen:
        extra = {k: v for k, v in variant.items() if k != "name"}
        extra["TAG_WIDTH"] = variant["CRC_WIDTH"]
        cases.append((f"crc_{variant['name']}", {"ALGO": 4, **extra}))
    add("sha256", 5, 256)
    return cases


def base_params(params):
    result = {
        "DATA_WIDTH": 32,
    }
    result.update(params)
    return result


def build_and_test(
    name,
    params,
    width,
    mode,
    build_root,
    coverage=False,
):
    runner = get_runner("verilator")
    build_dir = build_root / f"{mode}_{name}_w{width}"
    full_params = dict(params)
    full_params["DATA_WIDTH"] = width

    if mode == "core":
        hdl_toplevel = "tb_core_wrap"
        sources = CORE_SOURCES + [TB / "tb_core_wrap.sv"]
        test_module = "test_core"
    elif mode == "wrapper":
        hdl_toplevel = "tb_wrapper"
        sources = CORE_SOURCES + WRAPPER_SOURCES + [TB / "tb_wrapper.sv"]
        test_module = "test_wrapper"
    else:
        hdl_toplevel = "exp_harness_top"
        sources = HARNESS_SOURCES
        test_module = "test_harness"

    build_args = ["-Wno-fatal"]
    if coverage:
        build_args += ["--coverage", "--coverage-line"]

    runner_params = {
        key: (int(value) if isinstance(value, bool) else value)
        for key, value in full_params.items()
    }

    runner.build(
        verilog_sources=[str(p) for p in sources],
        includes=[str(CORES)],
        hdl_toplevel=hdl_toplevel,
        parameters=runner_params,
        build_dir=build_dir,
        build_args=build_args,
        clean=True,
        timescale=("1ns", "1ps"),
    )

    env = {"PYTHONPATH": str(TB), "ALGO": str(full_params.get("ALGO", 0))}
    for key, value in full_params.items():
        if isinstance(value, bool):
            env[f"TEST_{key}"] = "1" if value else "0"
            env[key] = "1" if value else "0"
        else:
            env[f"TEST_{key}"] = str(value)
            env[key] = str(value)
    results_file = runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module=test_module,
        build_dir=build_dir,
        test_dir=TB,
        extra_env=env,
        waves=False,
    )

    tree = ET.parse(results_file)
    failed = []
    for testcase in tree.iter("testcase"):
        for child in testcase:
            if child.tag in ("failure", "error"):
                failed.append(
                    f"{testcase.get('name')}: {child.get('message', child.text)}"
                )
    if failed:
        raise RuntimeError("; ".join(failed))
    return build_dir


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=["core", "wrapper", "harness", "all"], default="all")
    parser.add_argument("--widths", default="8,32,64")
    parser.add_argument("--quick", action="store_true", help="small regression subset")
    parser.add_argument("--only", default=None, help="run cases whose name contains this")
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--clean", action="store_true")
    parser.add_argument(
        "--build-root", default=str(ROOT / "sim_build" / "regression")
    )
    args = parser.parse_args()

    build_root = Path(args.build_root)
    if args.clean and build_root.exists():
        shutil.rmtree(build_root)
    build_root.mkdir(parents=True, exist_ok=True)

    widths = [int(w) for w in args.widths.split(",") if w]
    if args.quick and len(widths) > 2:
        widths = [8, 32]
    cases = algorithm_cases(args.quick)
    if args.only:
        cases = [case for case in cases if args.only in case[0]]
    modes = ["core", "wrapper", "harness"] if args.mode == "all" else [args.mode]

    failures = []
    for mode in modes:
        if mode == "harness":
            harness_cases = [
                (
                    "harness_clean",
                    {
                        "NUM_PACKETS": 16,
                        "LEN_MIN": 0,
                        "LEN_MAX": 64,
                        "SEED": 0x12345678,
                        "MODE": 0,
                        "INCLUDE_SHA": 1,
                        "ENABLE_UART": 0,
                    },
                ),
                (
                    "harness_single_bit",
                    {
                        "NUM_PACKETS": 16,
                        "LEN_MIN": 0,
                        "LEN_MAX": 64,
                        "SEED": 0x12345678,
                        "MODE": 1,
                        "INCLUDE_SHA": 1,
                        "ENABLE_UART": 0,
                    },
                ),
            ]
            for name, params in harness_cases:
                if args.only and args.only not in name:
                    continue
                label = f"{mode}:{name}:w{widths[0]}"
                print(f"\n=== {label} ===", flush=True)
                try:
                    build_and_test(
                        name, params, widths[0], mode, build_root,
                        coverage=args.coverage,
                    )
                except Exception as exc:  # pragma: no cover
                    print(f"FAILED {label}: {exc}", file=sys.stderr)
                    failures.append(label)
            continue

        for name, params in cases:
            for width in widths:
                label = f"{mode}:{name}:w{width}"
                print(f"\n=== {label} ===", flush=True)
                try:
                    build_and_test(
                        name,
                        params,
                        width,
                        mode,
                        build_root,
                        coverage=args.coverage,
                    )
                except Exception as exc:  # pragma: no cover - diagnostic path
                    print(f"FAILED {label}: {exc}", file=sys.stderr)
                    failures.append(label)

    if failures:
        print("\nFAILURES:", file=sys.stderr)
        for item in failures:
            print(f"  {item}", file=sys.stderr)
        return 1
    print("\nAll tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
