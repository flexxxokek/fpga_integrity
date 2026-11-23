#!/usr/bin/env python3
"""Scientifically grounded false-rate campaign for the integrity algorithms.

Two error generators with published, reproducible methodology are available:

* ``gilbert_elliott`` - the two-state Markov burst-noise channel.  It emits
  correlated bit errors (bursts) with a configurable mean burst length and
  mean gap.  This is the standard model for bursty transmission errors.

* ``koopman`` - adversarial minimum-weight undetected-error codewords produced
  by Philip Koopman's HDLen tool (exhaustive Hamming-distance search).  Each
  pattern is a zero-syndrome codeword for one concrete CRC polynomial.

Both generators are applied to all algorithm models in ``tb/model.py``.  The
output is a CSV in the long format accepted by ``scripts/analyze.py``, with
``undetected_rate`` and ``false_rate`` derived there.

References (also in docs/false_rate.md):
  E. N. Gilbert, "Capacity of a Burst-Noise Channel", BSTJ 39(5), 1960,
      doi:10.1002/j.1538-7305.1960.tb03959.x
  E. O. Elliott, "Estimates of Error Rates for Codes on Burst-Noise Channels",
      BSTJ 42(5), 1963, doi:10.1002/j.1538-7305.1963.tb00955.x
  P. Koopman, "32-Bit Cyclic Redundancy Codes for Internet Applications",
      ICNP 2002, doi:10.1109/ICNP.2002.1115615
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import random
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tb"))
import model  # noqa: E402

FIELDS = [
    "timestamp", "board", "git", "seed", "campaign", "algo", "metric", "value",
    "ber", "codeword_bits", "data_pattern", "fault_source",
]

ALGORITHMS = {
    "parity": dict(algo=model.ALGO_PARITY),
    "checksum16": dict(algo=model.ALGO_CHECKSUM, sum_width=16, ones_complement=True),
    "fletcher16": dict(algo=model.ALGO_FLETCHER, block_width=8),
    "adler32": dict(algo=model.ALGO_ADLER32),
    "crc32": dict(algo=model.ALGO_CRC, crc=model.CRC_PRESETS["crc32"]),
    "sha256": dict(algo=model.ALGO_SHA256),
}


def git_revision() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=ROOT, stderr=subprocess.DEVNULL, text=True,
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


class GilbertElliott:
    """Two-state burst-noise channel (Gilbert 1960, Elliott 1963).

    State G ("good") advances to B with probability ``p_gb``; state B
    ("bad") returns to G with probability ``p_bg``.  In state G no bits are
    flipped (k = 1); in state B each bit is flipped with probability ``h``
    (Gilbert's original example uses h = 0.5, h = 1 gives pure bursts).
    The mean burst length is 1/p_bg bits, the mean gap is 1/p_gb bits.
    """

    def __init__(self, seed: int, mean_gap: float, mean_burst: float,
                 h: float = 1.0):
        self.rng = random.Random(seed)
        self.p_gb = 1.0 / mean_gap
        self.p_bg = 1.0 / mean_burst
        self.h = h
        self.state = "G"

    def positions(self, nbits: int) -> list[int]:
        result = []
        for index in range(nbits):
            if self.state == "G":
                if self.rng.random() < self.p_gb:
                    self.state = "B"
                continue
            if self.rng.random() < self.h:
                result.append(index)
            if self.rng.random() < self.p_bg:
                self.state = "G"
        return result


def corrupt(data: bytes, positions: list[int]) -> bytes:
    """Flip the given stream bits (bit 0 = LSB of the first byte)."""
    out = bytearray(data)
    for position in positions:
        out[position // 8] ^= 1 << (position % 8)
    return bytes(out)


# packet = (clean payload, corrupted payload, injected bit flips 1..4)
Packet = tuple[bytes, bytes, int]


def count_outcomes(packets: list[Packet]) -> dict[str, dict[str, int]]:
    """Compare clean/corrupted tags for every algorithm, including HW buckets."""
    outcomes = {
        name: dict(packets=len(packets), corrupted=0, detected=0,
                   missed=0, false=0, bytes=0,
                   corrupted_weights=0, missed_weights=0)
        for name in ALGORITHMS
    }
    for clean, damaged, weight in packets:
        bucket = (min(max(weight, 1), 4) - 1) if clean != damaged else 0
        for name, settings in ALGORITHMS.items():
            options = {key: value for key, value in settings.items()
                       if key != "algo"}
            clean_tag = model.tag_for(settings["algo"], clean, **options)
            bad_tag = model.tag_for(settings["algo"], damaged, **options)
            stats = outcomes[name]
            stats["bytes"] += len(clean)
            if clean == damaged:
                if clean_tag != bad_tag:
                    stats["false"] += 1
            else:
                stats["corrupted"] += 1
                stats["corrupted_weights"] += 1 << (8 * bucket)
                if clean_tag == bad_tag:
                    stats["missed"] += 1
                    stats["missed_weights"] += 1 << (8 * bucket)
                else:
                    stats["detected"] += 1
    return outcomes


def gilbert_elliott_packets(args) -> list[Packet]:
    channel = GilbertElliott(
        seed=args.seed, mean_gap=args.mean_gap,
        mean_burst=args.mean_burst, h=args.h,
    )
    packets = []
    for _ in range(args.packets):
        clean = bytes((index * 37 + 11) & 0xFF for index in range(args.length))
        positions = channel.positions(args.length * 8)
        packets.append((clean, corrupt(clean, positions), len(positions)))
    return packets


def koopman_packets() -> list[Packet]:
    vectors = json.loads(
        (ROOT / "tb/vectors/koopman_hd.json").read_text(encoding="utf-8")
    )
    packets = []
    for vector in vectors["vectors"]:
        pattern = bytes.fromhex(vector["pattern_hex"])
        weight = sum(byte.bit_count() for byte in pattern)
        packets.append((bytes(len(pattern)), pattern, weight))
    return packets


def koopman_random_packets() -> list[Packet]:
    """Derived zero-syndrome vectors produced by gen_zero_syndrome.py."""
    data = json.loads(
        (ROOT / "tb/vectors/koopman_random.json").read_text(encoding="utf-8")
    )
    packets = []
    for vector in data["vectors"]:
        pattern = bytes.fromhex(vector["pattern_hex"])
        packets.append((bytes(len(pattern)), pattern, vector["total_flips"]))
    return packets


def hd_sweep_packets(args, bits: int) -> list[Packet]:
    """Inject random m-bit errors (m=1..3) into words of a fixed bit length."""
    rng = random.Random(args.seed ^ bits)
    nbytes = (bits + 7) // 8
    per_weight = max(1, args.packets // 3)
    packets = []
    for weight in (1, 2, 3):
        for _ in range(per_weight):
            clean = bytes(rng.randrange(256) for _ in range(nbytes))
            positions = rng.sample(range(bits), weight)
            packets.append((clean, corrupt(clean, positions), weight))
    return packets


def write_csv(path: Path, outcomes: dict[str, dict[str, int]],
              campaign: str, seed: str, meta: dict[str, str] | None = None,
              append: bool = False) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().astimezone().isoformat(timespec="seconds")
    revision = git_revision()
    meta = meta or {}
    rows = 0
    with path.open("a" if append else "w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS, lineterminator="\n")
        if not append:
            writer.writeheader()
        for algo, stats in outcomes.items():
            for metric, value in stats.items():
                writer.writerow({
                    "timestamp": stamp, "board": "model", "git": revision,
                    "seed": seed, "campaign": campaign, "algo": algo,
                    "metric": metric, "value": value,
                    "ber": meta.get("ber", ""),
                    "codeword_bits": meta.get("codeword_bits", ""),
                    "data_pattern": meta.get("data_pattern", ""),
                    "fault_source": meta.get("fault_source", ""),
                })
                rows += 1
    return rows


def report(campaign: str, count: int, outcomes: dict[str, dict[str, int]]) -> None:
    print(f"\n{campaign}: {count} packets")
    print(f"{'algorithm':14s} {'corrupted':>10s} {'missed':>8s} "
          f"{'undetected':>11s}")
    for algo, stats in outcomes.items():
        corrupted = stats["corrupted"]
        rate = stats["missed"] / corrupted if corrupted else 0.0
        print(f"{algo:14s} {corrupted:10d} {stats['missed']:8d} "
              f"{rate:10.3%}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--generator",
                        choices=["gilbert_elliott", "koopman", "koopman_random",
                                 "hd_sweep"],
                        default="gilbert_elliott")
    parser.add_argument("--packets", type=int, default=2000)
    parser.add_argument("--length", type=int, default=64, help="payload bytes")
    parser.add_argument("--mean-gap", type=float, default=8000.0,
                        help="mean number of error-free bits between bursts")
    parser.add_argument("--mean-burst", type=float, default=8.0)
    parser.add_argument("--h", type=float, default=1.0,
                        help="bit error probability inside the bad state")
    parser.add_argument("--seed", type=int, default=0x12345678)
    parser.add_argument("--ber", type=float, default=None,
                        help="BER used for Pud (derived from GE model if omitted)")
    parser.add_argument("--min-missed-events", type=int, default=0,
                        help="double the packet count until parity misses this many")
    parser.add_argument("--hd-lengths", default="64,256,1024,2048",
                        help="codeword lengths in bits for hd_sweep")
    parser.add_argument("--out", default=None)
    args = parser.parse_args(argv)

    stamp = dt.datetime.now().astimezone()
    out_path = Path(args.out or f"data/model_{args.generator}_{stamp:%Y%m%d_%H%M%S}.csv")

    if args.generator in ("koopman", "koopman_random"):
        if args.generator == "koopman":
            packets = koopman_packets()
            campaign, seed = "koopman_hd", "hdlen_v2.1"
            pattern_name = "hdlen_codewords"
        else:
            packets = koopman_random_packets()
            campaign, seed = "koopman_random", "gf2_solver_seed305419896"
            pattern_name = "derived_zero_syndrome"
        meta = {"data_pattern": pattern_name, "fault_source": "adversarial"}
        outcomes = count_outcomes(packets)
        write_csv(out_path, outcomes, campaign, seed, meta)
        report(campaign, len(packets), outcomes)
        print(f"wrote {out_path}")
        return 0

    ber = args.ber
    if ber is None and args.generator != "koopman":
        # Fraction of time spent in the bad state, times h: an approximate BER
        # for the two-state channel (documented in docs/false_rate.md).
        bad_fraction = args.mean_burst / (args.mean_gap + args.mean_burst)
        ber = args.h * bad_fraction
    ber_text = f"{ber:.8g}" if ber is not None else ""

    if args.generator == "gilbert_elliott":
        attempts = 0
        while True:
            packets = gilbert_elliott_packets(args)
            outcomes = count_outcomes(packets)
            enough = (args.min_missed_events <= 0 or
                      outcomes["parity"]["missed"] >= args.min_missed_events)
            if enough or attempts >= 4:
                break
            args.packets *= 2
            attempts += 1
        campaign = f"gilbert_elliott_b{args.mean_burst:g}"
        meta = {
            "ber": ber_text, "codeword_bits": str(args.length * 8),
            "data_pattern": "prng", "fault_source": "gilbert_elliott",
        }
        write_csv(out_path, outcomes, campaign, str(args.seed), meta)
        report(campaign, len(packets), outcomes)
    else:
        first = True
        for bits_text in args.hd_lengths.split(","):
            bits = int(bits_text)
            packets = hd_sweep_packets(args, bits)
            campaign = f"hd_n{bits}"
            meta = {
                "ber": ber_text, "codeword_bits": str(bits),
                "data_pattern": "random", "fault_source": "exhaustive_m_bit",
            }
            outcomes = count_outcomes(packets)
            write_csv(out_path, outcomes, campaign, str(args.seed), meta,
                      append=not first)
            report(campaign, len(packets), outcomes)
            first = False
    print(f"wrote {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
