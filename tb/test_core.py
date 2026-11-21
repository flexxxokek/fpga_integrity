"""Unit tests for the bare integrity cores."""

from __future__ import annotations

import random

import cocotb
from cocotb.triggers import RisingEdge

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
from test_utils import (
    drive_core_packet,
    env_bool,
    env_int,
    make_beats,
    reset_dut,
    start_clock,
)


def _params():
    algo = env_int("ALGO", ALGO_PARITY)
    return {
        "algo": algo,
        "data_width": env_int("DATA_WIDTH", 32),
        "parity_odd": env_bool("PARITY_ODD", False),
        "sum_width": env_int("SUM_WIDTH", 16),
        "ones_complement": env_bool("ONES_COMPLEMENT", True),
        "block_width": env_int("BLOCK_WIDTH", 8),
        "crc": {
            "width": env_int("CRC_WIDTH", 32),
            "poly": env_int("CRC_POLY", 0x04C11DB7),
            "init": env_int("CRC_INIT", 0xFFFFFFFF),
            "refin": env_bool("CRC_REFIN", True),
            "refout": env_bool("CRC_REFOUT", True),
            "xorout": env_int("CRC_XOROUT", 0xFFFFFFFF),
        },
    }


@cocotb.test()
async def directed_and_random(dut):
    start_clock(dut)
    await reset_dut(dut)
    p = _params()
    data_width = p["data_width"]
    beat_bytes = data_width // 8

    directed = [
        b"",
        b"\x00",
        b"\x01",
        b"123456789",
        bytes(range(16)),
        bytes(range(beat_bytes - 1)) if beat_bytes > 1 else b"",
        bytes(range(beat_bytes)),
        bytes(range(beat_bytes + 1)),
        bytes([0xFF]) * (3 * beat_bytes),
    ]
    rng = random.Random(1234 + p["algo"] * 17 + data_width)
    for _ in range(24):
        length = rng.randrange(0, 320)
        directed.append(bytes(rng.randrange(256) for _ in range(length)))

    for packet in directed:
        beats = make_beats(packet, data_width)
        got = await drive_core_packet(dut, beats)
        expected = tag_for(
            p["algo"],
            packet,
            parity_odd=p["parity_odd"],
            sum_width=p["sum_width"],
            ones_complement=p["ones_complement"],
            block_width=p["block_width"],
            crc=p["crc"],
        )
        assert got == expected, (
            f"algo={p['algo']} width={data_width} len={len(packet)} "
            f"expected={expected:#x} got={got:#x}"
        )


@cocotb.test()
async def known_vectors(dut):
    start_clock(dut)
    await reset_dut(dut)
    p = _params()
    data_width = p["data_width"]

    # Catalogue check values for "123456789".
    if p["algo"] == ALGO_CRC:
        name = {
            0x07: "crc8",
            0x1021: "crc16_ccitt_false",
            0x8005: "crc16_arc",
            0x04C11DB7: "crc32",
            0x1EDC6F41: "crc32c",
        }.get(p["crc"]["poly"])
        if name is not None and p["crc"] == CRC_PRESETS[name]:
            got = await drive_core_packet(
                dut, make_beats(b"123456789", data_width)
            )
            expected = tag_for(ALGO_CRC, b"123456789", crc=p["crc"])
            assert got == expected

    if p["algo"] == ALGO_ADLER32:
        got = await drive_core_packet(dut, make_beats(b"123456789", data_width))
        assert got == 0x091E01DE

    if p["algo"] == ALGO_SHA256:
        got = await drive_core_packet(dut, make_beats(b"abc", data_width))
        expected = int(
            "ba7816bf8f01cfea414140de5dae2223"
            "b00361a396177a9cb410ff61f20015ad",
            16,
        )
        # Tag is the digest serialised little-endian.
        assert got == int.from_bytes(expected.to_bytes(32, "big"), "little")
