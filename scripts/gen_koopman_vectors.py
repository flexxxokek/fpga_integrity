#!/usr/bin/env python3
"""Convert Koopman HDLen examples into project test vectors.

Input is the raw output of Philip Koopman's HDLen tool saved verbatim in
``tb/vectors/koopman_hdlen_examples.txt``.  Each example lists the bit
positions of a minimum-weight codeword that violates a claimed Hamming
distance.  A codeword consists of data bits followed by FCS bits; flipping
exactly those bits of a zero payload leaves the CRC unchanged, i.e. produces
an undetected error ("false negative").

The HDLen FCS value uses Koopman's implicit +1 / right-shift notation.  When
it does not map directly onto this project's reference model (reflected
32-bit CRCs), the script solves for the equivalent FCS bits over GF(2) using
the model itself.  Every emitted pattern is verified to have zero syndrome in
the model before being written.

Source and citation are documented in docs/false_rate.md.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tb"))
import model  # noqa: E402

SOURCE = "http://users.ece.cmu.edu/~koopman/crc/hdlen.html"
EXAMPLE_RE = re.compile(
    r"^(0x[0-9a-fA-F]+)\s+HD=(\d+)\s+len=(\d+)\s+"
    r"Example:\s+Len=(\d+)\s+\{([^}]*)\}\s+\((0x[0-9a-fA-F]+)\)"
)

# Koopman implicit +1 (reversed reciprocal) notation -> project preset name.
PRESETS = {
    "0x83": "crc8",
    "0x8810": "crc16_ccitt_false",
    "0xc002": "crc16_arc",
    "0x82608edb": "crc32",
    "0x8f6e37a0": "crc32c",
}


def linear_tag(name: str, data: bytes) -> int:
    """Tag with init/xorout removed: purely linear part of the CRC."""
    preset = model.CRC_PRESETS[name]
    return model.crc(
        data, preset["width"], preset["poly"], 0,
        preset["refin"], preset["refout"], 0,
    )


def pack(bits: list[int], reflected: bool) -> bytes:
    """Pack a stream of bits (bit 0 first) into project byte order.

    Reflected CRCs consume the least significant bit of each byte first;
    non-reflected ones consume the most significant bit first.
    """
    out = bytearray((len(bits) + 7) // 8)
    for index, bit in enumerate(bits):
        if bit:
            shift = index % 8 if reflected else 7 - (index % 8)
            out[index // 8] |= 1 << shift
    return bytes(out)


def solve_fcs(name: str, data_bits: list[int], width: int,
              reflected: bool) -> int:
    """Solve for FCS bits that make the whole codeword's CRC zero."""
    base = linear_tag(name, pack(data_bits + [0] * width, reflected))
    pivots: dict[int, tuple[int, int]] = {}
    for position in range(width):
        trial = [0] * width
        trial[position] = 1
        vector = linear_tag(name, pack(data_bits + trial, reflected)) ^ base
        combination = 1 << position
        while vector:
            pivot = vector.bit_length() - 1
            if pivot in pivots:
                old_vector, old_combination = pivots[pivot]
                vector ^= old_vector
                combination ^= old_combination
            else:
                pivots[pivot] = (vector, combination)
                break
    remaining = base
    solution = 0
    while remaining:
        pivot = remaining.bit_length() - 1
        if pivot not in pivots:
            raise RuntimeError(f"cannot solve FCS for {name}")
        vector, combination = pivots[pivot]
        remaining ^= vector
        solution ^= combination
    return solution


def build_vector(preset: str, poly: str, hd: int, length: int,
                 positions: list[int], source_fcs: int) -> dict:
    settings = model.CRC_PRESETS[preset]
    width = settings["width"]
    reflected = settings["refin"]

    data_bits = [0] * length
    for position in positions:
        data_bits[position] = 1

    # HDLen always computes the FCS with the right-shift algorithm, so its
    # bits are streamed least-significant bit first regardless of preset.
    def fcs_bits(value: int) -> list[int]:
        return [(value >> i) & 1 for i in range(width)]

    pattern = pack(data_bits + fcs_bits(source_fcs), reflected)
    fcs = source_fcs
    if linear_tag(preset, pattern) != 0:
        # HDLen uses the reversed polynomial for its FCS; solve the equivalent
        # FCS value in the notation used by this project's CRC model.
        fcs = solve_fcs(preset, data_bits, width, reflected)
        pattern = pack(data_bits + fcs_bits(fcs), reflected)

    if linear_tag(preset, pattern) != 0:
        raise RuntimeError(f"invalid vector for {preset}")

    return {
        "preset": preset,
        "koopman_poly": poly,
        "hd": hd,
        "dataword_bits": length,
        "data_bit_positions": positions,
        "source_fcs": f"0x{source_fcs:0{width // 4}x}",
        "project_fcs": f"0x{fcs:0{width // 4}x}",
        "pattern_hex": pattern.hex(),
        "pattern_bytes": len(pattern),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--input", default=str(ROOT / "tb/vectors/koopman_hdlen_examples.txt")
    )
    parser.add_argument(
        "--out", default=str(ROOT / "tb/vectors/koopman_hd.json")
    )
    args = parser.parse_args(argv)

    text = Path(args.input).read_text(encoding="utf-8")
    vectors: list[dict] = []
    seen: set[tuple[str, int, tuple[int, ...]]] = set()
    for line in text.splitlines():
        match = EXAMPLE_RE.match(line.strip())
        if not match:
            continue
        poly, hd, _, length, positions_text, fcs_text = match.groups()
        preset = PRESETS.get(poly.lower())
        if preset is None:
            print(f"skip unknown polynomial {poly}", file=sys.stderr)
            continue
        positions = [int(part) for part in positions_text.split(",")]
        key = (preset, length, tuple(positions))
        if key in seen:
            continue
        seen.add(key)
        vectors.append(
            build_vector(preset, poly.lower(), int(hd), int(length),
                         positions, int(fcs_text, 16))
        )

    if not vectors:
        print("no HDLen examples found", file=sys.stderr)
        return 1

    payload = {
        "source": SOURCE,
        "tool": "HDLen v2.1 (Philip Koopman, Carnegie Mellon University)",
        "citation": (
            "P. Koopman, '32-Bit Cyclic Redundancy Codes for Internet "
            "Applications', Proc. IEEE International Conference on Network "
            "Protocols (ICNP), 2002. doi:10.1109/ICNP.2002.1115615"
        ),
        "notation": (
            "Pattern bits are flips on a zero payload.  Flipping all set bits "
            "yields a zeroCRC codeword for the given preset."
        ),
        "vectors": vectors,
    }
    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(
        json.dumps(payload, indent=2, sort_keys=False) + "\n", encoding="utf-8"
    )
    print(f"wrote {len(vectors)} vectors to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
