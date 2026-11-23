#!/usr/bin/env python3
"""Run the cocotb end-to-end test for the interactive hash demo."""

from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
DIR = ROOT / "boards" / "de2_115_interactive"

sources = [DIR / "de2_115_interactive.sv", DIR / "interactive_lane_tx.sv",
           DIR / "uart_rx_sync.sv", DIR / "uart_rx_16x.sv"]
sources += sorted((ROOT / "rtl" / "cores").glob("*.sv"))
sources += [ROOT / "rtl" / "wrappers" / "integrity_tx.sv",
            ROOT / "rtl" / "harness" / "uart_tx.sv"]

runner = get_runner("verilator")
runner.build(sources=sources, hdl_toplevel="de2_115_interactive",
             build_dir=ROOT / "sim_build" / "interactive_top",
             build_args=["-Wno-fatal", "-Wno-WIDTHEXPAND"],
             clean=True)
runner.test(hdl_toplevel="de2_115_interactive",
            test_module="test_interactive_top", test_dir=ROOT / "tb")
