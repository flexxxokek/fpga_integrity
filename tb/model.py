"""Reference models for the FPGA integrity cores.

All models operate on ``bytes`` and return the tag as an integer in the same
bit order used by the RTL (tag byte 0 occupies bits 7:0).
"""

from __future__ import annotations

import hashlib
import zlib

# ---------------------------------------------------------------------------
# Algorithm selector (must match integrity_pkg::algo_t)
# ---------------------------------------------------------------------------

ALGO_PARITY = 0
ALGO_CHECKSUM = 1
ALGO_FLETCHER = 2
ALGO_ADLER32 = 3
ALGO_CRC = 4
ALGO_SHA256 = 5


def parity(data: bytes, odd: bool = False) -> int:
    value = 0
    for byte in data:
        value ^= bin(byte).count("1") & 1
    return (value & 1) ^ int(odd)


def _checksum_words(data: bytes, width: int, ones_complement: bool):
    block_bytes = (width + 7) // 8
    mask = (1 << width) - 1
    total = 0
    for pos in range(0, len(data), block_bytes):
        chunk = data[pos : pos + block_bytes]
        word = int.from_bytes(chunk, "big") << (8 * (block_bytes - len(chunk)))
        if ones_complement:
            total += word
            # Single carry fold is sufficient for each addition.
            if total > mask:
                total = (total & mask) + 1
                if total > mask:
                    total = (total & mask) + 1
        else:
            total = (total + word) & mask
    return total


def checksum(data: bytes, width: int = 16, ones_complement: bool = True) -> int:
    total = _checksum_words(data, width, ones_complement)
    mask = (1 << width) - 1
    if ones_complement:
        return (~total) & mask
    return total


def fletcher(data: bytes, block_width: int = 8) -> int:
    block_bytes = (block_width + 7) // 8
    modulus = (1 << block_width) - 1
    sum1 = 0
    sum2 = 0
    for pos in range(0, len(data), block_bytes):
        chunk = data[pos : pos + block_bytes]
        word = int.from_bytes(chunk, "big") << (8 * (block_bytes - len(chunk)))
        sum1 = (sum1 + word) % modulus
        sum2 = (sum2 + sum1) % modulus
    tag_width = 2 * block_width
    return ((sum2 & ((1 << block_width) - 1)) << block_width) | (
        sum1 & ((1 << block_width) - 1)
    )


def adler32(data: bytes) -> int:
    return zlib.adler32(data) & 0xFFFFFFFF


def _reverse_bits(value: int, width: int) -> int:
    result = 0
    for i in range(width):
        result = (result << 1) | ((value >> i) & 1)
    return result


_CRC_TABLES: dict[tuple[int, int], list[int]] = {}


def _crc_table(width: int, poly: int) -> list[int]:
    """MSB-first byte table; cached per (width, polynomial)."""
    key = (width, poly)
    cached = _CRC_TABLES.get(key)
    if cached is not None:
        return cached
    mask = (1 << width) - 1
    top = 1 << (width - 1)
    table = []
    for byte in range(256):
        value = byte << (width - 8) if width >= 8 else byte
        for _ in range(8):
            value = ((value << 1) & mask) ^ (poly if value & top else 0)
        table.append(value & mask)
    _CRC_TABLES[key] = table
    return table


def crc(
    data: bytes,
    width: int,
    poly: int,
    init: int,
    refin: bool,
    refout: bool,
    xorout: int,
) -> int:
    # Table-driven equivalent of the MSB-first bitwise LFSR in crc_engine.sv.
    # It keeps 1000-packet random regressions practical while producing
    # bit-identical results (verified by the catalogue check values).
    mask = (1 << width) - 1
    poly &= mask
    table = _crc_table(width, poly)
    value = init & mask
    shift = width - 8
    for byte in data:
        fed = _reverse_bits(byte, 8) if refin else byte
        index = fed ^ ((value >> shift) & 0xFF) if shift >= 0 else fed
        value = ((value << 8) & mask) ^ table[index]
    if refout:
        value = _reverse_bits(value, width)
    return (value ^ xorout) & mask


CRC_PRESETS = {
    "crc8": dict(
        width=8, poly=0x07, init=0x00, refin=False, refout=False, xorout=0x00
    ),
    "crc16_ccitt_false": dict(
        width=16, poly=0x1021, init=0xFFFF, refin=False, refout=False, xorout=0x0000
    ),
    "crc16_arc": dict(
        width=16, poly=0x8005, init=0x0000, refin=True, refout=True, xorout=0x0000
    ),
    "crc32": dict(
        width=32,
        poly=0x04C11DB7,
        init=0xFFFFFFFF,
        refin=True,
        refout=True,
        xorout=0xFFFFFFFF,
    ),
    "crc32c": dict(
        width=32,
        poly=0x1EDC6F41,
        init=0xFFFFFFFF,
        refin=True,
        refout=True,
        xorout=0xFFFFFFFF,
    ),
}


def crc_preset(name: str, data: bytes) -> int:
    return crc(data, **CRC_PRESETS[name])


def sha256(data: bytes) -> int:
    digest = hashlib.sha256(data).digest()
    # TX serialises tag bytes little-endian.
    return int.from_bytes(digest, "little")


def tag_for(algo: int, data: bytes, **kwargs) -> int:
    if algo == ALGO_PARITY:
        return parity(data, odd=kwargs.get("parity_odd", False))
    if algo == ALGO_CHECKSUM:
        return checksum(
            data,
            width=kwargs.get("sum_width", 16),
            ones_complement=kwargs.get("ones_complement", True),
        )
    if algo == ALGO_FLETCHER:
        return fletcher(data, block_width=kwargs.get("block_width", 8))
    if algo == ALGO_ADLER32:
        return adler32(data)
    if algo == ALGO_CRC:
        return crc(data, **kwargs["crc"])
    if algo == ALGO_SHA256:
        return sha256(data)
    raise ValueError(f"unknown algorithm {algo}")
