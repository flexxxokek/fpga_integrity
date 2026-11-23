"""Whole-harness simulation: stimulus -> injector -> lanes -> counters."""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.triggers import RisingEdge

from test_utils import env_int, reset_dut, start_clock

LANES = 6


def unpack(value) -> list[int]:
    raw = int(value)
    return [(raw >> (32 * i)) & 0xFFFFFFFF for i in range(LANES)]


def report_lines(packets, corrupted, detected, missed, false_alarms,
                 byte_counts, cycles, corrupted_weights,
                 missed_weights) -> list[str]:
    """Build RESULT lines in the format accepted by scripts/collect.py."""
    lines = []
    for lane in range(LANES):
        values = [
            packets[lane], corrupted[lane], detected[lane],
            missed[lane], false_alarms[lane], byte_counts[lane], cycles[lane],
            corrupted_weights[lane], missed_weights[lane],
        ]
        # Same fixed-width hexadecimal fields as report_uart on the board.
        fields = [str(lane)] + [f"{value:08X}" for value in values]
        lines.append("RESULT," + ",".join(fields))
    return lines


@cocotb.test()
async def campaign(dut):
    start_clock(dut)
    await reset_dut(dut)
    mode = env_int("MODE", 0)
    packets = env_int("NUM_PACKETS", 16)

    dut.start.value = 1
    dut.uart_rxd.value = 1

    for _ in range(4_000_000):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        raise AssertionError("harness did not finish")

    packets_total = unpack(dut.packets_total.value)
    corrupted = unpack(dut.corrupted_total.value)
    detected = unpack(dut.detected_total.value)
    missed = unpack(dut.missed_total.value)
    false_alarms = unpack(dut.false_total.value)
    byte_counts = unpack(dut.bytes_total.value)
    cycles = unpack(dut.cycles_total.value)
    corrupted_weights = unpack(dut.corrupted_weights.value)
    missed_weights = unpack(dut.missed_weights.value)

    dut._log.info("packets=%s", packets_total)
    dut._log.info("corrupted=%s", corrupted)
    dut._log.info("detected=%s", detected)
    dut._log.info("missed=%s", missed)
    dut._log.info("false=%s", false_alarms)
    dut._log.info("bytes=%s", byte_counts)
    dut._log.info("cycles=%s", cycles)
    dut._log.info("corrupted_weights=%s", corrupted_weights)
    dut._log.info("missed_weights=%s", missed_weights)

    lines = report_lines(
        packets_total, corrupted, detected, missed, false_alarms,
        byte_counts, cycles, corrupted_weights, missed_weights,
    )
    for line in lines:
        dut._log.info("report: %s", line)

    # Optional offline log for the simulator data-collection flow.  The same
    # lines are what report_uart sends over UART on the board.
    report_log = os.environ.get("SIM_REPORT_LOG")
    if report_log:
        path = Path(report_log)
        if not path.is_absolute():
            path = Path(__file__).resolve().parents[1] / path
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(f"# campaign={os.environ.get('CAMPAIGN', 'harness')}\n")
            for line in lines:
                handle.write(line + "\n")

    assert sum(cycles) > 0, "cycle counters are not wired"

    for lane in range(LANES):
        assert packets_total[lane] == packets
        if mode == 0:
            assert corrupted[lane] == 0
            assert detected[lane] == 0
            assert missed[lane] == 0
            assert false_alarms[lane] == 0
        else:
            assert corrupted[lane] > 0
            assert detected[lane] + missed[lane] == corrupted[lane]
            assert false_alarms[lane] == 0
