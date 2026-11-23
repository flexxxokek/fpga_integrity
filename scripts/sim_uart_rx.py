#!/usr/bin/env python3
"""Run the cocotb test for the interactive demo UART receiver."""

from pathlib import Path

from cocotb_tools.runner import get_runner

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "boards" / "de2_115_interactive"

runner = get_runner("verilator")
runner.build(
    sources=[SRC / "uart_rx_16x.sv", SRC / "uart_rx_sync.sv"],
    hdl_toplevel="uart_rx_sync",
    build_dir=ROOT / "sim_build" / "uart_rx_sync",
    build_args=["-Wno-fatal"],
    parameters={"CLK_FREQ_HZ": 50_000_000, "BAUD_RATE": 115_200},
    clean=True,
)
runner.test(
    hdl_toplevel="uart_rx_sync",
    test_module="test_uart_rx_sync",
    test_dir=ROOT / "tb",
)
