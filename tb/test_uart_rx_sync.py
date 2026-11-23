"""Cocotb test for the board UART receiver handshake."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer

BIT_NS = round(1_000_000_000 / 115200)


async def send_byte(dut, value: int) -> None:
    dut._log.info(f"TX byte {value:#04x} bits "
                  f"{[(value >> i) & 1 for i in range(8)]}")
    dut.rxd.value = 0
    for i in range(8):
        await Timer(BIT_NS, units="ns")
        dut.rxd.value = (value >> i) & 1
    await Timer(BIT_NS, units="ns")
    dut.rxd.value = 1
    await Timer(BIT_NS, units="ns")


@cocotb.test()
async def receive_bytes(dut):
    cocotb.start_soon(Clock(dut.clk_fast, 20, units="ns").start())
    cocotb.start_soon(Clock(dut.clk_slow, 80, units="ns").start())
    dut.rst.value = 1
    dut.rxd.value = 1
    await Timer(200, units="ns")
    dut.rst.value = 0
    await Timer(200, units="ns")

    async def watch_rx():
        while True:
            await RisingEdge(dut.clk_fast)
            if int(dut.u_rx.valid.value):
                dut._log.info(f"RX pulse data={int(dut.u_rx.data.value):#04x}")

    cocotb.start_soon(watch_rx())

    for expected in b"ABCDEFGH":
        await send_byte(dut, expected)
        # wait for the level-valid handshake in the slow domain
        for _ in range(2000):
            if int(dut.valid.value):
                break
            await RisingEdge(dut.clk_slow)
        else:
            raise AssertionError("no valid byte received")
        got = int(dut.data.value)
        raw = int(dut.u_rx.data.value)
        dut._log.info(f"received {got:#04x}, raw {raw:#04x}, expected {expected:#04x}")
        assert got == expected
        dut.ack.value = 1
        await RisingEdge(dut.clk_slow)
        dut.ack.value = 0
        await FallingEdge(dut.valid)
