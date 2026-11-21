"""Whole-harness simulation: stimulus -> injector -> lanes -> counters."""

from __future__ import annotations

import cocotb
from cocotb.triggers import RisingEdge

from test_utils import env_int, reset_dut, start_clock

LANES = 6


def unpack(value) -> list[int]:
    raw = int(value)
    return [(raw >> (32 * i)) & 0xFFFFFFFF for i in range(LANES)]


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

    dut._log.info("packets=%s", packets_total)
    dut._log.info("corrupted=%s", corrupted)
    dut._log.info("detected=%s", detected)
    dut._log.info("missed=%s", missed)
    dut._log.info("false=%s", false_alarms)

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
