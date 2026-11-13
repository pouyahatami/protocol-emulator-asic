# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_pc against the PC logic in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20


def reference(pc, pc_advance, jump_taken, jmp_addr, wrap_top, wrap_bottom):
    """Return the PC after one clock edge."""
    if not pc_advance:
        return pc
    if jump_taken:
        return jmp_addr
    if pc == wrap_top:
        return wrap_bottom
    return (pc + 1) & 0x1F


async def start(dut, wrap_top=31, wrap_bottom=0):
    """Start the clock, then reset with the given wrap settings."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    await reset(dut, wrap_top, wrap_bottom)


async def reset(dut, wrap_top, wrap_bottom):
    """Hold reset for two edges with the given wrap settings."""
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.pc_advance.value = 0
    dut.jump_taken.value = 0
    dut.jmp_addr.value = 0
    dut.wrap_top.value = wrap_top
    dut.wrap_bottom.value = wrap_bottom
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def step(dut, pc_advance=1, jump_taken=0, jmp_addr=0):
    """Drive one cycle's inputs away from the clock edge and return the PC during that cycle."""
    await FallingEdge(dut.clk)
    dut.pc_advance.value = pc_advance
    dut.jump_taken.value = jump_taken
    dut.jmp_addr.value = jmp_addr
    await ReadOnly()
    return int(dut.pc.value)


async def pc_now(dut):
    """Return the PC after the previous edge without advancing."""
    return await step(dut, pc_advance=0)


@cocotb.test()
async def test_reset_to_zero(dut):
    """Reset puts the PC at 0 whatever the other inputs say."""
    await start(dut)
    assert await pc_now(dut) == 0


@cocotb.test()
async def test_holds_without_advance(dut):
    """Without pc_advance the PC holds, even with a jump or at wrap_top."""
    await start(dut, wrap_top=0, wrap_bottom=9)
    for _ in range(4):
        assert await step(dut, pc_advance=0, jump_taken=1, jmp_addr=17) == 0
    assert await pc_now(dut) == 0


@cocotb.test()
async def test_increments_and_rolls_over(dut):
    """With wrap at the top of memory, the PC counts 0 to 31 and returns to 0."""
    await start(dut, wrap_top=31, wrap_bottom=0)
    for expected in list(range(32)) + [0, 1]:
        assert await step(dut) == expected


@cocotb.test()
async def test_wrap(dut):
    """After wrap_top the PC goes to wrap_bottom with no extra step."""
    await start(dut, wrap_top=5, wrap_bottom=3)
    got = [await step(dut) for _ in range(10)]
    assert got == [0, 1, 2, 3, 4, 5, 3, 4, 5, 3], f"PC sequence {got}"


@cocotb.test()
async def test_single_instruction_loop(dut):
    """wrap_top equal to wrap_bottom repeats one instruction."""
    await start(dut, wrap_top=0, wrap_bottom=0)
    for _ in range(4):
        assert await step(dut) == 0


@cocotb.test()
async def test_past_wrap_top_runs_on(dut):
    """A PC above wrap_top counts up, rolls over at 31, and then wraps normally."""
    await start(dut, wrap_top=1, wrap_bottom=0)
    assert await step(dut, jump_taken=1, jmp_addr=30) == 0
    got = [await step(dut) for _ in range(6)]
    assert got == [30, 31, 0, 1, 0, 1], f"PC sequence {got}"


@cocotb.test()
async def test_jump_beats_wrap(dut):
    """A taken jump at wrap_top goes to the jump target, not wrap_bottom."""
    await start(dut, wrap_top=2, wrap_bottom=0)
    assert await step(dut) == 0
    assert await step(dut) == 1
    assert await step(dut, jump_taken=1, jmp_addr=20) == 2
    assert await pc_now(dut) == 20


@cocotb.test()
async def test_jmp_addr_ignored_when_not_taken(dut):
    """jmp_addr has no effect unless jump_taken is high."""
    await start(dut, wrap_top=31, wrap_bottom=0)
    assert await step(dut, jump_taken=0, jmp_addr=25) == 0
    assert await pc_now(dut) == 1


@cocotb.test()
async def test_uart_tx_sequence(dut):
    """The UART TX program's PC sequence for one byte, one entry per committed instruction.

    pull and set run once, then out and jmp X-- alternate 8 times. The jump is taken for the
    first 7 bits and falls through on the last, wrapping from 3 back to 0.
    """
    await start(dut, wrap_top=3, wrap_bottom=0)
    expected = [0, 1] + [2, 3] * 8 + [0]
    jumps = [0, 0] + [0, 1] * 7 + [0, 0] + [0]
    got = []
    for taken in jumps:
        got.append(await step(dut, jump_taken=taken, jmp_addr=2))
    assert got == expected, f"PC sequence {got}"


@cocotb.test()
async def test_random_against_reference(dut):
    """Random advance and jump inputs match the reference under several wrap settings."""
    rng = random.Random(0x9C)
    await start(dut)
    for _ in range(5):
        wrap_top = rng.randrange(32)
        wrap_bottom = rng.randrange(32)
        await reset(dut, wrap_top, wrap_bottom)
        pc = 0
        for cycle in range(2000):
            inputs = {
                "pc_advance": int(rng.random() < 0.6),
                "jump_taken": int(rng.random() < 0.2),
                "jmp_addr": rng.randrange(32),
            }
            got = await step(dut, **inputs)
            assert got == pc, (
                f"wrap {wrap_bottom}..{wrap_top} cycle {cycle}: PC {got}, expected {pc}"
            )
            pc = reference(pc, wrap_top=wrap_top, wrap_bottom=wrap_bottom, **inputs)
