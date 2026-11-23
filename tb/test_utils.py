"""Shared helpers for the cocotb testbenches."""

from __future__ import annotations

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer


def env_int(name: str, default: int) -> int:
    return int(os.environ.get(name, str(default)))


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value not in ("0", "", "false", "False")


def make_beats(data: bytes, data_width: int):
    """Split a packet into (tdata, tkeep, tlast) beats."""
    beat_bytes = data_width // 8
    beats = []
    if not data:
        return [(0, 0, 1)]
    for pos in range(0, len(data), beat_bytes):
        chunk = data[pos : pos + beat_bytes]
        word = int.from_bytes(chunk, "little")
        keep = (1 << len(chunk)) - 1
        last = 1 if pos + beat_bytes >= len(data) else 0
        beats.append((word, keep, last))
    return beats


async def reset_dut(dut):
    dut.rst.value = 1
    if hasattr(dut, "init"):
        dut.init.value = 0
    if hasattr(dut, "valid"):
        dut.valid.value = 0
    if hasattr(dut, "s_axis_tvalid"):
        dut.s_axis_tvalid.value = 0
    if hasattr(dut, "m_axis_tready"):
        dut.m_axis_tready.value = 0
    if hasattr(dut, "inject"):
        dut.inject.value = 0
    if hasattr(dut, "clean"):
        dut.clean.value = 1
    for _ in range(3):
        await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


def start_clock(dut, period_ns: int = 10):
    cocotb.start_soon(Clock(dut.clk, period_ns, unit="ns").start())


async def drive_core_packet(dut, beats):
    """Drive one packet into a bare core and return (tag, tag_done_seen)."""
    await FallingEdge(dut.clk)
    dut.init.value = 1
    dut.valid.value = 0
    await RisingEdge(dut.clk)

    for word, keep, last in beats:
        await FallingEdge(dut.clk)
        dut.init.value = 0
        dut.valid.value = 1
        dut.data.value = word
        dut.keep.value = keep
        dut.last.value = last
        await Timer(1, unit="ns")
        while not int(dut.ready.value):
            await RisingEdge(dut.clk)
            await FallingEdge(dut.clk)
            await Timer(1, unit="ns")
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if last and int(dut.tag_done.value):
            return int(dut.tag.value)
        await FallingEdge(dut.clk)
        dut.valid.value = 0

    for _ in range(200000):
        await RisingEdge(dut.clk)
        await Timer(1, unit="ps")
        if int(dut.tag_done.value):
            return int(dut.tag.value)
    raise AssertionError("tag_done timeout")


class AxisSink:
    def __init__(self, dut, seed: int = 1, stall_prob: float = 0.25):
        self.dut = dut
        self.rng = random.Random(seed)
        self.stall_prob = stall_prob
        self.beats = []
        self.finished = False

    async def run(self):
        dut = self.dut
        await RisingEdge(dut.clk)
        while not self.finished:
            ready = 0 if self.rng.random() < self.stall_prob else 1
            dut.m_axis_tready.value = ready
            await FallingEdge(dut.clk)
            valid = int(dut.m_axis_tvalid.value)
            word = int(dut.m_axis_tdata.value)
            keep = int(dut.m_axis_tkeep.value)
            last = int(dut.m_axis_tlast.value)
            error = int(dut.tag_error.value) if hasattr(dut, "tag_error") else 0
            tag_ok = int(dut.tag_valid.value) if hasattr(dut, "tag_valid") else 0
            await RisingEdge(dut.clk)
            if ready and valid:
                self.beats.append((word, keep, last, error, tag_ok))
                if last:
                    self.finished = True


async def drive_stream(dut, beats, seed: int = 2, stall_prob: float = 0.2):
    rng = random.Random(seed)
    await RisingEdge(dut.clk)
    for word, keep, last in beats:
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tdata.value = word
        dut.s_axis_tkeep.value = keep
        dut.s_axis_tlast.value = last
        while True:
            await FallingEdge(dut.clk)
            ready = int(dut.s_axis_tready.value)
            # AXI4-Stream stability: the source must not change the payload
            # while it is valid but not accepted.
            assert int(dut.s_axis_tdata.value) == word, "tdata changed under stall"
            assert int(dut.s_axis_tkeep.value) == keep, "tkeep changed under stall"
            assert int(dut.s_axis_tlast.value) == last, "tlast changed under stall"
            await RisingEdge(dut.clk)
            if ready:
                break
        dut.s_axis_tvalid.value = 0
        if rng.random() < stall_prob:
            await RisingEdge(dut.clk)
