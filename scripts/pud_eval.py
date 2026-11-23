#!/usr/bin/env python3
"""Evaluate Pud(Building blocks) from HD-sweep results at a sweep of BERs.

Pud(BER, n) = sum_m HW_m * C(n, m) * BER^m * (1-BER)^(n-m), where HW_m is the
fraction of undetected m-bit corruptions measured by false_rate_suite's
``hd_sweep`` generator.  This follows the FAA/Koopman evaluation methodology.
"""

from __future__ import annotations

import argparse
import csv
import math
from pathlib import Path

def wilson_hi(k: float, n: float, z: float = 1.96) -> float:
    """Upper bound of the 95% Wilson interval for a binomial proportion."""
    if n <= 0:
        return 1.0
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    margin = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
    return min(1.0, centre + margin)


def buckets(value: str) -> list[float]:
    raw = int(float(value))
    return [(raw >> (8 * m)) & 0xFF for m in range(4)]


def pud(hw: list[float], bits: int, ber: float) -> float:
    total = 0.0
    for index, fraction in enumerate(hw):
        if fraction <= 0:
            continue
        m = index + 1
        total += fraction * math.comb(bits, m) * ber ** m * (1 - ber) ** (bits - m)
    return total


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", default="data/model_hd_sweep.csv")
    parser.add_argument("--out", default="docs/results/false_rate/pud.md")
    parser.add_argument("--bers", default="1e-4,1e-5,1e-6,1e-7")
    args = parser.parse_args(argv)

    bers = [float(value) for value in args.bers.split(",")]
    rows: dict[tuple[str, int], dict[str, str]] = {}
    with open(args.input, newline="", encoding="utf-8") as handle:
        for row in csv.DictReader(handle):
            key = (row["algo"], int(row["codeword_bits"]))
            rows.setdefault(key, {}).setdefault(row["metric"], row["value"])

    lines = [
        "# Pud(undetected error probability)",
        "",
        "Upper 95% bound on Pud, estimated from HW_m fractions measured by",
        "`hd_sweep` (m=1..4; zero-miss buckets use the Wilson upper bound).",
        "Source: Koopman FAA TC-14-49 / Maxino & Koopman (2009) methodology.",
        "",
        "Approximation truncates m at 4, so it is valid only for BER·n << 1.",
        "With ~2000 trials per weight the Wilson bound (~2e-3) dominates for",
        "algorithms with no observed misses: the table is sample-limited and",
        "must not be read as a ranking of those algorithms.",
        "",
        "| algorithm | bits | " + " | ".join(f"Pud<= @ {p:g}" for p in bers) + " |",
        "|---|---:|" + "|".join("---:" for _ in bers) + "|",
    ]
    for (algo, bits), metrics in sorted(rows.items()):
        if "corrupted_weights" not in metrics or "missed_weights" not in metrics:
            continue
        cw, mw = buckets(metrics["corrupted_weights"]), buckets(metrics["missed_weights"])
        hw = [wilson_hi(mw[i], cw[i]) if cw[i] > 0 else 0.0 for i in range(4)]
        values = [pud(hw, bits, ber) for ber in bers]
        lines.append(
            f"| {algo} | {bits} | " + " | ".join(f"{value:.3g}" for value in values) + " |"
        )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
