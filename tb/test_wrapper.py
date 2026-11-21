"""Wrapper-level tests: TX tag insertion, RX extraction and error reporting."""

from __future__ import annotations

import random

import cocotb
from cocotb.triggers import RisingEdge

from model import ALGO_ADLER32, ALGO_CRC, ALGO_PARITY
from test_utils import (
    AxisSink,
    drive_stream,
    env_bool,
    env_int,
    make_beats,
    reset_dut,
    start_clock,
)


def _data_width():
    return env_int("DATA_WIDTH", 32)


def _decode(beats):
    out = bytearray()
    last_error = 0
    last_valid = 0
    for word, keep, last, error, valid in beats:
        for i in range(12):
            if not (keep >> i) & 1:
                break
            out.append((word >> (8 * i)) & 0xFF)
        if last:
            last_error = error
            last_valid = valid
    return bytes(out), last_error, last_valid


async def _run_packet(dut, packet, inject=0, seed=1):
    data_width = _data_width()
    sink = AxisSink(dut, seed=seed, stall_prob=0.3)
    sink_task = cocotb.start_soon(sink.run())
    await drive_stream(dut, make_beats(packet, data_width), seed=seed + 1)
    for _ in range(200000):
        await RisingEdge(dut.clk)
        if sink.finished:
            break
    sink_task.kill()
    assert sink.finished, "no output tlast"
    return _decode(sink.beats)


@cocotb.test()
async def clean_roundtrip(dut):
    start_clock(dut)
    await reset_dut(dut)
    width = _data_width()
    beat_bytes = width // 8
    packets = [
        b"",
        b"A",
        b"123456789",
        bytes(range(beat_bytes - 1)) if beat_bytes > 1 else b"",
        bytes(range(beat_bytes)),
        bytes(range(beat_bytes + 1)),
        bytes([0x5A]) * 257,
    ]
    rng = random.Random(7 + width)
    for _ in range(12):
        packets.append(bytes(rng.randrange(256) for _ in range(rng.randrange(1, 200))))

    for idx, packet in enumerate(packets):
        dut.inject.value = 0
        out, error, valid = await _run_packet(dut, packet, seed=idx + 11)
        assert out == packet, (
            f"payload mismatch len={len(packet)} got_len={len(out)} "
            f"expected={packet.hex()} got={out.hex()}"
        )
        assert error == 0, "unexpected tag error on clean packet"
        assert valid == 1, "tag_valid missing on output tlast"


@cocotb.test()
async def injected_error_detected(dut):
    start_clock(dut)
    await reset_dut(dut)
    width = _data_width()
    packet = bytes(range(1, 1 + 4 * (width // 8)))
    expected = bytearray(packet)
    expected[0] ^= 0x01  # tb_wrapper flips bit 0 of the first payload beat

    dut.inject.value = 1
    out, error, valid = await _run_packet(dut, packet, seed=99)
    assert out == bytes(expected), "RX should pass the corrupted packet through"
    assert error == 1, "tag error was not reported"
    assert valid == 1
