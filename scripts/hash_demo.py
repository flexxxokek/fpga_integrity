#!/usr/bin/env python3
"""Interactive hash demo for the DE2-115 (boards/de2_115_interactive).

Sends a packet over UART, reads six FPGA tags with their latencies (a fixed
binary reply: 32-byte tag + 4-byte ticks per lane, then "DONE") and compares
every tag with the Python reference from tb/model.py.

Example:
    python scripts/hash_demo.py --port /dev/ttyUSB0 --text 123456789
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tb"))

from model import CRC_PRESETS, tag_for  # noqa: E402

MAGIC1, MAGIC2 = 0xA5, 0x5A
LANES = [
    ("parity", {}),
    ("checksum16", dict(sum_width=16, ones_complement=True)),
    ("fletcher16", dict(block_width=8)),
    ("adler32", {}),
    ("crc32", dict(crc=CRC_PRESETS["crc32"])),
    ("sha256", {}),
]
TAG_DIGITS = [1, 4, 4, 8, 8, 64]


def build_frame(payload: bytes) -> bytes:
    if not 1 <= len(payload) <= 64:
        raise ValueError("packet length must be 1..64 bytes")
    frame = bytes([MAGIC1, MAGIC2, len(payload)]) + payload
    xor = 0
    for byte in frame:
        xor ^= byte
    return frame + bytes([xor])


def payload_from_args(args) -> bytes:
    if args.file:
        return Path(args.file).read_bytes()
    if args.hex is not None:
        return bytes.fromhex(args.hex)
    return args.text.encode("utf-8")


def read_exact(link, count: int, deadline: float) -> bytes:
    buf = bytearray()
    while len(buf) < count and time.monotonic() < deadline:
        chunk = link.read(count - len(buf))
        if chunk:
            buf.extend(chunk)
    if len(buf) != count:
        raise TimeoutError(f"expected {count} bytes, got {len(buf)}")
    return bytes(buf)


def read_report(link, timeout: float) -> list[tuple[int, int, int]]:
    """Return [(lane, tag, ticks), ...] from the fixed binary FPGA reply."""
    deadline = time.monotonic() + timeout
    result: list[tuple[int, int, int]] = []
    for lane in range(len(LANES)):
        data = read_exact(link, 36, deadline)
        tag = int.from_bytes(data[:32], "big")
        ticks = int.from_bytes(data[32:36], "little")
        result.append((lane, tag, ticks))
    if read_exact(link, 4, deadline) != b"DONE":
        raise ValueError("missing DONE sentinel in board reply")
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--text", default="123456789")
    parser.add_argument("--hex", default=None)
    parser.add_argument("--file", default=None)
    args = parser.parse_args(argv)

    payload = payload_from_args(args)
    frame = build_frame(payload)
    print(f"payload ({len(payload)} B): {payload.hex(' ')}")

    try:
        import serial
    except ImportError:
        print("pyserial is not installed; run `pip install -r requirements.txt`",
              file=sys.stderr)
        return 1

    report = None
    last_error: Exception | None = None
    for attempt in range(1, 6):
        try:
            with serial.Serial(args.port, args.baud, timeout=0.5) as link:
                link.reset_input_buffer()
                time.sleep(0.1)  # let the USB-serial port settle
                # Small gaps let the board's UART handshake retire one byte
                # before the next start bit arrives.
                for byte in frame:
                    link.write(bytes([byte]))
                    link.flush()
                    time.sleep(0.0005)
                report = read_report(link, args.timeout)
            break
        except (TimeoutError, ValueError) as exc:
            last_error = exc
            print(f"attempt {attempt}: no valid reply ({exc}); retrying",
                  file=sys.stderr)
            time.sleep(0.1)
    if report is None:
        print(f"board did not answer after 5 attempts: {last_error}",
              file=sys.stderr)
        return 1

    if len(report) != len(LANES):
        print(f"expected {len(LANES)} HASH lines, got {len(report)}",
              file=sys.stderr)
        return 1

    report.sort(key=lambda row: row[0])
    print()
    print("| lane | algorithm  | ticks | ticks/byte | FPGA tag | Python tag | match |")
    print("|-----:|------------|------:|-----------:|----------|------------|:-----:|")
    failures = 0
    for (lane, fpga_tag, ticks), (name, kwargs) in zip(report, LANES):
        expected = tag_for(lane, payload, **kwargs)
        ok = fpga_tag == expected
        failures += not ok
        print(f"| {lane} | {name:<10} | {ticks:>5} | "
              f"{ticks / len(payload):>10.2f} | {fpga_tag:0{TAG_DIGITS[lane]}X} | "
              f"{expected:0{TAG_DIGITS[lane]}X} | {'OK' if ok else 'FAIL'} |")
    print()
    if failures:
        print(f"FAIL: {failures} lane(s) differ from the Python reference")
        return 1
    print("PASS: all 6 FPGA tags match the Python reference")
    return 0


if __name__ == "__main__":
    sys.exit(main())
