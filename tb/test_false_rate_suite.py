"""Regression tests for the scientifically grounded false-rate generators.

Run with: python -m pytest tb/test_false_rate_suite.py -q
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tb"))

import model  # noqa: E402
from scripts.false_rate_suite import GilbertElliott, corrupt  # noqa: E402

VECTORS = json.loads(
    (ROOT / "tb/vectors/koopman_hd.json").read_text(encoding="utf-8")
)["vectors"]
DERIVED_VECTORS = json.loads(
    (ROOT / "tb/vectors/koopman_random.json").read_text(encoding="utf-8")
)["vectors"]


def linear_tag(name: str, data: bytes) -> int:
    preset = model.CRC_PRESETS[name]
    return model.crc(
        data, preset["width"], preset["poly"], 0,
        preset["refin"], preset["refout"], 0,
    )


def test_koopman_vectors_are_zero_syndrome():
    """Every HDLen-derived pattern is undetected by its target CRC."""
    assert VECTORS
    for vector in VECTORS:
        pattern = bytes.fromhex(vector["pattern_hex"])
        clean = bytes(len(pattern))
        assert linear_tag(vector["preset"], clean) == 0
        assert linear_tag(vector["preset"], pattern) == 0, vector["preset"]


def test_koopman_vectors_detected_by_sha256():
    """A cryptographic hash catches all adversarial CRC patterns."""
    for vector in VECTORS:
        pattern = bytes.fromhex(vector["pattern_hex"])
        clean = bytes(len(pattern))
        assert model.sha256(clean) != model.sha256(pattern)


def test_derived_zero_syndrome_vectors():
    """Every GF(2)-solved vector is undetected by its CRC, caught by SHA-256."""
    assert len(DERIVED_VECTORS) >= 500
    for vector in DERIVED_VECTORS:
        pattern = bytes.fromhex(vector["pattern_hex"])
        clean = bytes(len(pattern))
        preset = vector["preset"]
        assert linear_tag(preset, clean) == 0
        assert linear_tag(preset, pattern) == 0, preset
        assert model.sha256(clean) != model.sha256(pattern)


def test_gilbert_elliott_is_deterministic():
    first = GilbertElliott(seed=42, mean_gap=100, mean_burst=4)
    second = GilbertElliott(seed=42, mean_gap=100, mean_burst=4)
    assert first.positions(20_000) == second.positions(20_000)


def test_gilbert_elliott_burst_length():
    """Mean burst length follows the 1/p_bg parameter of the Markov model."""
    channel = GilbertElliott(seed=7, mean_gap=16, mean_burst=8, h=1.0)
    positions = set(channel.positions(200_000))
    lengths = []
    current = 0
    for index in range(200_000):
        if index in positions:
            current += 1
        elif current:
            lengths.append(current)
            current = 0
    if current:
        lengths.append(current)
    assert len(lengths) > 100
    mean_burst = sum(lengths) / len(lengths)
    assert 6.0 <= mean_burst <= 10.0, mean_burst


def test_corrupt_flips_selected_bits():
    clean = b"\x00\x00"
    assert corrupt(clean, [0, 8, 15]) == b"\x01\x81"
    assert corrupt(clean, []) == clean
