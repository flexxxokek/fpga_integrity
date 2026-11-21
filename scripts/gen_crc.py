#!/usr/bin/env python3
"""CRC parameter helper and reference implementation.

The RTL uses one parameterised engine (`rtl/cores/crc_engine.sv`).  This script
provides the parameter sets from the specification, an independent bitwise
reference model, and a small Verilog snippet printer.

Examples:
    python scripts/gen_crc.py --selftest
    python scripts/gen_crc.py --preset crc32 --data-text 123456789
    python scripts/gen_crc.py --preset crc16-arc --verilog

The reference implementation follows the Ross Williams model: bytes are
optionally reflected before entering an MSB-first LFSR, and the final register
is optionally reflected before XOR-out.  This yields the published check values
for all presets in `PRESETS`.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class CrcParams:
    name: str
    width: int
    poly: int
    init: int
    refin: bool
    refout: bool
    xorout: int
    check: int

    @property
    def mask(self) -> int:
        return (1 << self.width) - 1


PRESETS: dict[str, CrcParams] = {
    "crc8-smbus": CrcParams(
        "CRC-8/SMBUS", 8, 0x07, 0x00, False, False, 0x00, 0xF4
    ),
    "crc16-ccitt-false": CrcParams(
        "CRC-16/CCITT-FALSE", 16, 0x1021, 0xFFFF, False, False, 0x0000, 0x29B1
    ),
    "crc16-arc": CrcParams(
        "CRC-16/ARC", 16, 0x8005, 0x0000, True, True, 0x0000, 0xBB3D
    ),
    "crc32": CrcParams(
        "CRC-32/ISO-HDLC", 32, 0x04C11DB7, 0xFFFFFFFF,
        True, True, 0xFFFFFFFF, 0xCBF43926,
    ),
    "crc32c": CrcParams(
        "CRC-32C", 32, 0x1EDC6F41, 0xFFFFFFFF,
        True, True, 0xFFFFFFFF, 0xE3069283,
    ),
}


def _reflect(value: int, width: int) -> int:
    result = 0
    for _ in range(width):
        result = (result << 1) | (value & 1)
        value >>= 1
    return result


def crc(data: bytes, params: CrcParams) -> int:
    """Return the CRC of *data* using *params*."""
    reg = params.init & params.mask
    top = 1 << (params.width - 1)
    for byte in data:
        if params.refin:
            byte = _reflect(byte, 8)
        reg ^= (byte << (params.width - 8)) & params.mask
        for _ in range(8):
            if reg & top:
                reg = ((reg << 1) ^ params.poly) & params.mask
            else:
                reg = (reg << 1) & params.mask
    if params.refout:
        reg = _reflect(reg, params.width)
    return (reg ^ params.xorout) & params.mask


def parse_data(text: str, is_hex: bool) -> bytes:
    if is_hex:
        cleaned = text.replace(",", " ").replace("0x", " ").split()
        return bytes(int(part, 16) for part in cleaned)
    return text.encode("utf-8")


def verilog_snippet(params: CrcParams) -> str:
    return "\n".join(
        (
            f"// {params.name}",
            f"localparam int unsigned CRC_WIDTH = {params.width};",
            f"localparam logic [{params.width - 1}:0] CRC_POLY   = "
            f"{params.width}'h{params.poly:0{(params.width + 3) // 4}X};",
            f"localparam logic [{params.width - 1}:0] CRC_INIT   = "
            f"{params.width}'h{params.init:0{(params.width + 3) // 4}X};",
            f"localparam logic [{params.width - 1}:0] CRC_XOROUT = "
            f"{params.width}'h{params.xorout:0{(params.width + 3) // 4}X};",
            f"localparam bit CRC_REFIN  = 1'b{int(params.refin)};",
            f"localparam bit CRC_REFOUT = 1'b{int(params.refout)};",
        )
    )


def selftest() -> int:
    payload = b"123456789"
    failures = 0
    for key, params in PRESETS.items():
        got = crc(payload, params)
        ok = got == params.check
        status = "ok" if ok else "FAIL"
        print(
            f"{key:20s} {params.name:20s} "
            f"got=0x{got:0{(params.width + 3) // 4}X} "
            f"expected=0x{params.check:0{(params.width + 3) // 4}X} {status}"
        )
        failures += 0 if ok else 1
    return 1 if failures else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preset", choices=sorted(PRESETS), default="crc32")
    parser.add_argument("--width", type=int, help="override polynomial width")
    parser.add_argument("--poly", help="override polynomial (hex)")
    parser.add_argument("--init", help="override initial value (hex)")
    parser.add_argument("--xorout", help="override XOR-out value (hex)")
    parser.add_argument("--refin", type=int, choices=(0, 1))
    parser.add_argument("--refout", type=int, choices=(0, 1))
    parser.add_argument("--data-text", default="123456789")
    parser.add_argument("--data-hex", help="space/comma separated hex bytes")
    parser.add_argument("--verilog", action="store_true", help="print SV parameters")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args(argv)

    if args.selftest:
        return selftest()

    base = PRESETS[args.preset]
    params = CrcParams(
        name=base.name,
        width=args.width if args.width is not None else base.width,
        poly=int(args.poly, 16) if args.poly else base.poly,
        init=int(args.init, 16) if args.init else base.init,
        refin=bool(args.refin) if args.refin is not None else base.refin,
        refout=bool(args.refout) if args.refout is not None else base.refout,
        xorout=int(args.xorout, 16) if args.xorout else base.xorout,
        check=base.check,
    )
    data = parse_data(args.data_hex, True) if args.data_hex else parse_data(
        args.data_text, False
    )
    value = crc(data, params)
    digits = (params.width + 3) // 4
    print(f"algorithm : {params.name}")
    print(f"width     : {params.width}")
    print(f"data      : {data.hex() or '<empty>'}")
    print(f"crc       : 0x{value:0{digits}X}")
    if args.verilog:
        print()
        print(verilog_snippet(params))
    return 0


if __name__ == "__main__":
    sys.exit(main())
