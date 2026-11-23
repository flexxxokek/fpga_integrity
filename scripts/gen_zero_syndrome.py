#!/usr/bin/env python3
"""Generate many zero-syndrome (undetected-error) vectors for every CRC preset.

This is the *derived* counterpart of the HDLen-based vector set in
``tb/vectors/koopman_hd.json``:

* HDLen (Koopman) performs an exhaustive search and yields a few minimal-weight
  counterexamples with published provenance.
* This generator takes a random data error pattern and solves the FCS bits
  over GF(2) with the project's reference CRC model, producing an arbitrary
  number of valid codewords (data + FCS) whose CRC is zero.  Flipping exactly
  those bits of a zero payload is therefore undetected by that CRC.

Both sets use the same polynomial presets and the same notation; only the
provenance differs.  Every generated vector is verified twice: the linear
(noise-free) tag is zero and the full preset tag of the clean word equals the
tag of the corrupted word.

Source of the methodology:
  P. Koopman, "32-Bit Cyclic Redundancy Codes for Internet Applications",
  ICNP 2002, doi:10.1109/ICNP.2002.1115615;
  FAA report TC-14-49 (2015), Hamming weight / Pud evaluation.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "tb"))

import model  # noqa: E402
from gen_koopman_vectors import PRESETS, linear_tag, pack, solve_fcs  # noqa: E402,F401

DEFAULT_LENGTHS = (64, 128, 256, 512, 1024)
DEFAULT_SEED = 0x12345678


def build_vector(preset: str, bits: int, positions: list[int],
                 rng: random.Random) -> dict | None:
    settings = model.CRC_PRESETS[preset]
    width = settings["width"]
    reflected = settings["refin"]

    data = [0] * bits
    for position in positions:
        data[position] = 1

    try:
        fcs = solve_fcs(preset, data, width, reflected)
    except RuntimeError:
        return None  # singular GF(2) system for this pattern, try another one

    fcs_bits = [((fcs >> i) & 1) for i in range(width)]
    pattern = pack(data + fcs_bits, reflected)
    if linear_tag(preset, pattern) != 0:
        return None

    clean = bytes(len(pattern))
    settings_dict = dict(settings)
    if model.crc(clean, **settings_dict) != model.crc(pattern, **settings_dict):
        return None

    total_flips = sum(byte.bit_count() for byte in pattern)
    return {
        "preset": preset,
        "preset_settings": settings,
        "dataword_bits": bits,
        "data_bit_positions": positions,
        "fcs": f"0x{fcs:0{width // 4}x}",
        "data_flips": len(positions),
        "total_flips": total_flips,
        "pattern_hex": pattern.hex(),
        "pattern_bytes": len(pattern),
    }


def generate(args) -> list[dict]:
    rng = random.Random(args.seed)
    lengths = [int(value) for value in args.lengths.split(",")]
    vectors = []
    for preset in PRESETS.values():
        made = 0
        attempts = 0
        while made < args.per_preset and attempts < args.per_preset * 20:
            attempts += 1
            bits = lengths[(made + attempts) % len(lengths)]
            weight = 1 + (made % 4)
            positions = sorted(rng.sample(range(bits), weight))
            vector = build_vector(preset, bits, positions, rng)
            if vector is None:
                continue
            # Strip settings: it is already in model.CRC_PRESETS, keeping the
            # JSON compact and free of redundant type information.
            vector.pop("preset_settings")
            vectors.append(vector)
            made += 1
        if made < args.per_preset:
            raise RuntimeError(f"only {made}/{args.per_preset} vectors for {preset}")
    return vectors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--per-preset", type=int, default=100)
    parser.add_argument("--lengths", default=",".join(str(value) for value in DEFAULT_LENGTHS))
    parser.add_argument("--seed", type=int, default=DEFAULT_SEED)
    parser.add_argument("--out", default=str(ROOT / "tb/vectors/koopman_random.json"))
    args = parser.parse_args(argv)

    vectors = generate(args)
    payload = {
        "source": "https://users.ece.cmu.edu/~koopman/crc/",
        "generator": "GF(2) FCS solver over tb/model.py CRC presets",
        "provenance": (
            "Derived vectors: FCS bits solved for random data error patterns. "
            "They are NOT independently found by HDLen's exhaustive search; "
            "use tb/vectors/koopman_hd.json for published counterexamples."
        ),
        "seed": args.seed,
        "lengths_bits": [int(value) for value in args.lengths.split(",")],
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
