# SPDX-FileCopyrightText: 2026 Pouya Hatami
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles


@cocotb.test()
async def test_stage_zero_outputs_are_safe(dut):
    """The empty project must never drive a protocol pin."""

    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)
    dut.rst_n.value = 1

    for ui_value, uio_value in ((0x00, 0x00), (0xFF, 0xFF), (0xA5, 0x5A)):
        dut.ui_in.value = ui_value
        dut.uio_in.value = uio_value
        await ClockCycles(dut.clk, 1)
        assert dut.uo_out.value == 0
        assert dut.uio_out.value == 0
        assert dut.uio_oe.value == 0
