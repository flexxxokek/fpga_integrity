"""Wrapper-level tests: TX tag insertion, RX extraction and error reporting."""

from __future__ import annotations

import random

import cocotb
from cocotb.triggers import FallingEdge, RisingEdge, Timer

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


async def _drive_one_packet(dut, packet, keep_valid=True):
    """Drive one packet with all beats presented back-to-back."""
    data_width = _data_width()
    for word, keep, last in make_beats(packet, data_width):
        await FallingEdge(dut.clk)
        dut.s_axis_tdata.value = word
        dut.s_axis_tkeep.value = keep
        dut.s_axis_tlast.value = last
        dut.s_axis_tvalid.value = 1
        while not int(dut.s_axis_tready.value):
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
        await RisingEdge(dut.clk)
        # tvalid stays asserted: the next beat (or packet) follows immediately.
    if not keep_valid:
        await FallingEdge(dut.clk)
        dut.s_axis_tvalid.value = 0


@cocotb.test()
async def latency(dut):
    """Tag must be signalled within the documented number of clock cycles."""
    start_clock(dut)
    await reset_dut(dut)
    dut.m_axis_tready.value = 1
    algo = env_int("ALGO", 0)
    width = _data_width()
    packet = bytes(range(1, 1 + 3 * (width // 8)))

    beats = make_beats(packet, width)
    cycle = 0
    last_handshake_cycle = -1
    for word, keep, last in beats:
        await FallingEdge(dut.clk)
        dut.s_axis_tdata.value = word
        dut.s_axis_tkeep.value = keep
        dut.s_axis_tlast.value = last
        dut.s_axis_tvalid.value = 1
        while not int(dut.s_axis_tready.value):
            await RisingEdge(dut.clk)
            cycle += 1
            await FallingEdge(dut.clk)
        await RisingEdge(dut.clk)
        cycle += 1
        if last:
            last_handshake_cycle = cycle
    dut.s_axis_tvalid.value = 0

    while not int(dut.tag_valid.value):
        await RisingEdge(dut.clk)
        cycle += 1
        assert cycle - last_handshake_cycle < 2000, "tag_valid timeout"
    measured = cycle - last_handshake_cycle
    # The non-SHA cores finalise the tag in about three cycles after the last
    # payload beat, then TX emits ceil(TAG_WIDTH/8) tag bytes.  On an 8-bit bus
    # a 32-bit tag therefore needs four extra beats: a fixed limit of 6 used
    # to fail there even though the RTL is correct.
    tag_width = env_int("TAG_WIDTH", 32)
    beat_bytes = width // 8
    tag_beats = ((tag_width + 7) // 8 + beat_bytes - 1) // beat_bytes
    limit = 1200 if algo == 5 else 4 + tag_beats
    assert measured <= limit, (
        f"algo={algo} width={width}: tag latency {measured} cycles > {limit}"
    )
    dut._log.info("tag latency: %d cycles (algo=%d, width=%d)",
                  measured, algo, width)


@cocotb.test()
async def back_to_back_and_reset(dut):
    """Consecutive packets and a reset in the middle of a packet."""
    start_clock(dut)
    await reset_dut(dut)
    width = _data_width()
    dut.m_axis_tready.value = 1

    packets = (b"first packet", bytes(range(2 * (width // 8))), b"z")
    received: list[tuple[int, int, int, int, int]] = []

    async def multi_sink():
        dut.m_axis_tready.value = 1
        for cycle in range(5000):
            await RisingEdge(dut.clk)
            # Sample after the clock edge has settled: reading on FallingEdge
            # races with the driver, which also updates on FallingEdge.
            await Timer(1, unit="ns")
            if int(dut.m_axis_tvalid.value):
                received.append((
                    int(dut.m_axis_tdata.value),
                    int(dut.m_axis_tkeep.value),
                    int(dut.m_axis_tlast.value),
                    int(dut.tag_error.value),
                    int(dut.tag_valid.value),
                ))
                if sum(1 for beat in received if beat[2]) == len(packets):
                    return
        raise AssertionError(
            f"back-to-back packets lost: {len(received)} beats, "
            f"{[(hex(w), hex(k), l) for w, k, l, _, _ in received]}"
        )

    sink_task = cocotb.start_soon(multi_sink())
    # Consecutive packets: tvalid is re-asserted immediately after the
    # previous beat (one idle cycle), which exercises packet-to-packet reuse
    # of the TX/RX state machines.
    for index, packet in enumerate(packets):
        await drive_stream(dut, make_beats(packet, width),
                           seed=10 + index, stall_prob=0.0)
    await sink_task
    dut._log.info("back-to-back output beats: %s",
                  [(hex(w), hex(k), last) for w, k, last, _, _ in received])
    out, error, valid = _decode(received)
    assert out == b"".join(packets), f"back-to-back payload mismatch: {out!r}"
    assert error == 0 and valid == 1

    # Reset while a packet is in flight, then verify a clean packet works.
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tkeep.value = (1 << (width // 8)) - 1
    dut.s_axis_tlast.value = 0
    for _ in range(3):
        await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    await reset_dut(dut)
    dut.m_axis_tready.value = 1

    sink = AxisSink(dut, seed=5, stall_prob=0.0)
    task = cocotb.start_soon(sink.run())
    await drive_stream(dut, make_beats(b"after reset", width),
                       seed=5, stall_prob=0.0)
    for _ in range(2000):
        await RisingEdge(dut.clk)
        if sink.finished:
            break
    task.kill()
    assert sink.finished, "no packet after mid-stream reset"
    out, error, valid = _decode(sink.beats)
    assert out == b"after reset", f"payload mismatch after reset: {out!r}"
    assert error == 0 and valid == 1


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
