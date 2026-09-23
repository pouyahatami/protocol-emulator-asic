# SPDX-FileCopyrightText: 2026 Pouya Hatami
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

CLOCK_PERIOD_NS = 20

# The inputs are driven this far away from a clock edge so that the testbench never races the
# sampling edge, and outputs are read this far after one so that nonblocking updates have settled.
SETTLE_NS = 1

INPUT_PATTERNS = (
    (0x00, 0x00),
    (0xFF, 0x00),
    (0x00, 0xFF),
    (0xA5, 0x5A),
    (0xFF, 0xFF),
)


def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())


async def reset(dut):
    """Hold rst_n low across two clock edges and leave the design running with ena asserted."""
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    await Timer(SETTLE_NS, unit="ns")
    dut.rst_n.value = 1


async def drive(dut, ui_value, uio_value):
    """Apply one input pattern and return once the following sample edge has propagated."""
    await RisingEdge(dut.clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.ui_in.value = ui_value
    dut.uio_in.value = uio_value
    await RisingEdge(dut.clk)
    await Timer(SETTLE_NS, unit="ns")


@cocotb.test()
async def test_reset_holds_outputs_low(dut):
    """An asserted reset must clear the dedicated outputs whatever the input pins carry."""
    start_clock(dut)

    dut.ena.value = 1
    dut.ui_in.value = 0xFF
    dut.uio_in.value = 0x00
    dut.rst_n.value = 0

    await ClockCycles(dut.clk, 2)
    await Timer(SETTLE_NS, unit="ns")
    assert dut.uo_out.value == 0, "reset must hold the dedicated outputs low"


@cocotb.test()
async def test_every_input_pin_reaches_an_output(dut):
    """Stage-0 keeps all input pins connected, so both buses must reach uo_out after one clock."""
    start_clock(dut)
    await reset(dut)

    for ui_value, uio_value in INPUT_PATTERNS:
        await drive(dut, ui_value, uio_value)
        expected = ui_value ^ uio_value
        assert dut.uo_out.value == expected, (
            f"ui_in={ui_value:#04x} uio_in={uio_value:#04x} "
            f"expected uo_out={expected:#04x}, got {int(dut.uo_out.value):#04x}"
        )


@cocotb.test()
async def test_bidirectional_bus_is_never_driven(dut):
    """No protocol owns the bidirectional bus yet, so it must stay released in every state."""
    start_clock(dut)
    await reset(dut)

    for ui_value, uio_value in INPUT_PATTERNS:
        await drive(dut, ui_value, uio_value)
        assert dut.uio_oe.value == 0, "the bidirectional bus must remain an input"
        assert dut.uio_out.value == 0, "the bidirectional output data must stay tied low"


@cocotb.test()
async def test_digest_holds_while_disabled(dut):
    """Deasserting ena must freeze the captured value rather than corrupt the outputs."""
    start_clock(dut)
    await reset(dut)

    await drive(dut, 0xA5, 0x5A)
    held = int(dut.uo_out.value)
    assert held == 0xA5 ^ 0x5A

    await RisingEdge(dut.clk)
    await Timer(SETTLE_NS, unit="ns")
    dut.ena.value = 0
    dut.ui_in.value = 0x00
    dut.uio_in.value = 0x00

    await ClockCycles(dut.clk, 3)
    await Timer(SETTLE_NS, unit="ns")
    assert int(dut.uo_out.value) == held, "a disabled design must hold its last captured value"
