"""Whole-harness simulation: stimulus -> injector -> lanes -> counters.

The campaign test is self-checking against the Python reference models.  A
per-lane monitor captures the bytes that actually entered the RX (including
the trailing tag) and the ``tag_error`` it reported.  For every packet the
test recomputes the tag with ``model.tag_for`` and verifies that the RX made
the correct decision.  This is an oracle independent of the injector and of
the on-chip counters: a bug in either can no longer hide behind the trivial
identity ``detected + missed == corrupted``.
"""

from __future__ import annotations

import os
from pathlib import Path

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

from model import (
    ALGO_ADLER32,
    ALGO_CHECKSUM,
    ALGO_CRC,
    ALGO_FLETCHER,
    ALGO_PARITY,
    ALGO_SHA256,
    CRC_PRESETS,
    tag_for,
)
from test_utils import env_bool, env_int, reset_dut, start_clock

LANES = 6

# Must match the lane instantiation in rtl/harness/exp_harness_top.sv.
LANE_PARAMS = [
    dict(algo=ALGO_PARITY),
    dict(algo=ALGO_CHECKSUM, sum_width=16, ones_complement=True),
    dict(algo=ALGO_FLETCHER, block_width=8),
    dict(algo=ALGO_ADLER32),
    dict(algo=ALGO_CRC, crc=CRC_PRESETS["crc32"]),
    dict(algo=ALGO_SHA256),
]


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


async def lane_oracle(dut, lane: int, sink: list) -> None:
    """Capture (payload, tag, tag_error) triples for one RX."""
    # Lane 5 lives inside the optional SHA generate block.
    parent = dut.g_sha_lane if lane == 5 else dut
    rx = getattr(parent, f"u_lane{lane}").u_rx
    beat_bytes = env_int("DATA_WIDTH", 32) // 8
    payload = bytearray()
    tag = bytearray()
    in_tag = False
    while True:
        await RisingEdge(dut.clk)
        if int(rx.s_axis_tvalid.value) and int(rx.s_axis_tready.value):
            word = int(rx.s_axis_tdata.value)
            keep = int(rx.s_axis_tkeep.value)
            for i in range(beat_bytes):
                if (keep >> i) & 1:
                    (tag if in_tag else payload).append((word >> (8 * i)) & 0xFF)
            if int(rx.s_axis_tlast.value):
                if in_tag:
                    sink.append((bytes(payload), bytes(tag), None))
                    payload = bytearray()
                    tag = bytearray()
                    in_tag = False
                else:
                    in_tag = True
        if (int(rx.m_axis_tvalid.value) and int(rx.m_axis_tready.value)
                and int(rx.m_axis_tlast.value)):
            # The output tlast is released after the tag has been checked.
            sink[-1] = (sink[-1][0], sink[-1][1], int(rx.tag_error.value))


async def uart_capture(dut, div: int, out: bytearray) -> None:
    """Decode 8N1 frames from uart_txd; one clock cycle is 10 ns here."""
    bit_ns = div * 10
    while True:
        await FallingEdge(dut.uart_txd)
        await Timer(bit_ns // 2, unit="ns")  # centre of the start bit
        await Timer(bit_ns, unit="ns")       # centre of the first data bit
        value = 0
        for index in range(8):
            if int(dut.uart_txd.value):
                value |= 1 << index
            await Timer(bit_ns, unit="ns")
        out.append(value)


@cocotb.test()
async def campaign(dut):
    start_clock(dut)
    await reset_dut(dut)
    mode = env_int("MODE", 0)
    packets = env_int("NUM_PACKETS", 16)
    active_lanes = LANES if env_bool("INCLUDE_SHA", True) else LANES - 1

    oracles: list[list] = [[] for _ in range(LANES)]
    monitors = [cocotb.start_soon(lane_oracle(dut, i, oracles[i]))
                for i in range(active_lanes)]

    uart_bytes = bytearray()
    uart_task = None
    if env_bool("ENABLE_UART", False):
        baud = env_int("BAUD_RATE", 115_200)
        clk_freq = env_int("CLK_FREQ_HZ", 50_000_000)
        div = (clk_freq + baud // 2) // baud
        uart_task = cocotb.start_soon(uart_capture(dut, div, uart_bytes))

    dut.start.value = 1
    dut.uart_rxd.value = 1

    for _ in range(4_000_000):
        await RisingEdge(dut.clk)
        if int(dut.done.value):
            break
    else:
        raise AssertionError("harness did not finish")
    # Let the final tag handshakes drain before inspecting the oracles.
    for _ in range(64):
        await RisingEdge(dut.clk)
    for task in monitors:
        task.kill()

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

    # --- Oracle: independent recomputation of every RX decision ----------
    for lane in range(active_lanes):
        observations = oracles[lane]
        assert len(observations) == packets, (
            f"lane {lane}: captured {len(observations)} packets, "
            f"expected {packets}"
        )
        params = LANE_PARAMS[lane]
        for index, (payload, tag_bytes, error) in enumerate(observations):
            assert error is not None, f"lane {lane} packet {index}: no tag_error"
            expected = tag_for(params["algo"], payload,
                               **{k: v for k, v in params.items()
                                  if k != "algo"})
            received = int.from_bytes(tag_bytes, "little")
            assert error == (received != expected), (
                f"lane {lane} packet {index}: RX reported tag_error={error} "
                f"for payload={payload.hex()} tag={tag_bytes.hex()}, "
                f"reference tag={expected:#x}"
            )

    lines = report_lines(
        packets_total, corrupted, detected, missed, false_alarms,
        byte_counts, cycles, corrupted_weights, missed_weights,
    )
    for line in lines:
        dut._log.info("report: %s", line)

    if uart_task is not None:
        for _ in range(4_000_000):
            await RisingEdge(dut.clk)
            if b"DONE\n" in uart_bytes:
                break
        else:
            raise AssertionError("UART report did not finish")
        uart_task.kill()
        report = bytes(uart_bytes).decode("ascii", errors="replace")
        received = [line for line in report.splitlines()
                    if line.startswith("RESULT,")]
        # The offline RESULT log also carries the two weight buckets; the
        # UART formatter sends only the seven counters + the lane index.
        expected_uart = [",".join(line.split(",")[:9]) for line in lines]
        assert received == expected_uart, (
            f"UART report differs from the on-chip counters:\n"
            f"received={received}\nexpected={expected_uart}"
        )
        dut._log.info("UART report: %d lines + DONE", len(received))

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

    for lane in range(active_lanes):
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

    # The four 8-bit weight buckets must add up to the corresponding packet
    # count (unless an individual bucket overflowed, which needs >255 events
    # of the same weight in one campaign).
    for lane in range(active_lanes):
        if 0 < corrupted[lane] < 255:
            weight_sum = sum((corrupted_weights[lane] >> (8 * m)) & 0xFF
                             for m in range(4))
            assert weight_sum == corrupted[lane], (
                f"lane {lane}: weight buckets {weight_sum} != {corrupted[lane]}"
            )
        if 0 < missed[lane] < 255:
            missed_sum = sum((missed_weights[lane] >> (8 * m)) & 0xFF
                             for m in range(4))
            assert missed_sum == missed[lane], (
                f"lane {lane}: missed buckets {missed_sum} != {missed[lane]}"
            )
