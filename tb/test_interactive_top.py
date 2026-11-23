"""Cocotb end-to-end test for the interactive hash demo top."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer

BIT_NS = round(1_000_000_000 / 115200)
CLK_NS = 20  # CLOCK_50 at 50 MHz


def build_frame(payload: bytes) -> bytes:
    frame = bytes([0xA5, 0x5A, len(payload)]) + payload
    xor = 0
    for byte in frame:
        xor ^= byte
    return frame + bytes([xor])


async def uart_send(dut, value: int) -> None:
    dut.UART_RXD.value = 0
    for i in range(8):
        await Timer(BIT_NS, unit="ns")
        dut.UART_RXD.value = (value >> i) & 1
    await Timer(BIT_NS, unit="ns")
    dut.UART_RXD.value = 1
    await Timer(BIT_NS, unit="ns")


async def uart_recv(dut) -> int:
    deadline = cocotb.utils.get_sim_time("ns") + 2_000_000
    while int(dut.UART_TXD.value) != 0:
        if cocotb.utils.get_sim_time("ns") > deadline:
            raise AssertionError("no UART start bit from board")
        await Timer(CLK_NS, unit="ns")
    await Timer(BIT_NS * 1.5, unit="ns")  # centre of the first data bit
    value = 0
    for i in range(8):
        if i:
            await Timer(BIT_NS, unit="ns")
        if int(dut.UART_TXD.value):
            value |= 1 << i
    await Timer(BIT_NS, unit="ns")
    return value


@cocotb.test()
async def hash_roundtrip(dut):
    cocotb.start_soon(Clock(dut.CLOCK_50, CLK_NS, units="ns").start())
    dut.UART_RXD.value = 1
    await Timer(30_000_000, units="ns")  # wait out the ~26 ms POR

    payload = b"A" * 16
    for byte in build_frame(payload):
        await uart_send(dut, byte)
    await Timer(20000, units="ns")
    dut._log.info(f"after frame: len_q={int(dut.len_q.value)} "
                  f"run_q={int(dut.run_q.value)}")

    data = bytearray()
    for _ in range(220):
        data.append(await uart_recv(dut))
    dut._log.info(f"reply {len(data)} bytes, head {bytes(data[:40]).hex()} "
                  f"tail {bytes(data[216:]).hex()} "
                  f"DONE at {bytes(data).find(b'DONE')}")
    assert bytes(data[216:]) == b"DONE", "missing DONE sentinel"
    for lane in range(6):
        tag = int.from_bytes(bytes(data[lane * 36:lane * 36 + 32]), "big")
        ticks = int.from_bytes(bytes(data[lane * 36 + 32:lane * 36 + 36]), "little")
        dut._log.info(f"lane {lane}: tag={tag:#x} ticks={ticks}")
