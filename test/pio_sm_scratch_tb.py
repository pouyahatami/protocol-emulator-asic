# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_scratch against the X and Y rows in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20

DEST_PINS, DEST_X, DEST_Y = 0b000, 0b001, 0b010
COND_ALWAYS, COND_X_DEC = 0b000, 0b010


def reference(x, y, commit, is_jmp, is_set, set_dest, set_data, jmp_cond):
    """Return (x, y) after one clock edge."""
    if not commit:
        return x, y
    if is_set and set_dest == DEST_X:
        return set_data, y
    if is_set and set_dest == DEST_Y:
        return x, set_data
    if is_jmp and jmp_cond == COND_X_DEC:
        return (x - 1) & 0xFF, y
    return x, y


async def start(dut):
    """Start the clock and hold reset for two edges."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    idle_inputs(dut)
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


def idle_inputs(dut):
    dut.commit.value = 0
    dut.is_jmp.value = 0
    dut.is_set.value = 0
    dut.set_dest.value = 0
    dut.set_data.value = 0
    dut.jmp_cond.value = 0


async def step(dut, commit=0, is_jmp=0, is_set=0, set_dest=0, set_data=0, jmp_cond=0):
    """Drive one cycle's inputs away from the clock edge and return (x, y) during that cycle."""
    await FallingEdge(dut.clk)
    dut.commit.value = commit
    dut.is_jmp.value = is_jmp
    dut.is_set.value = is_set
    dut.set_dest.value = set_dest
    dut.set_data.value = set_data
    dut.jmp_cond.value = jmp_cond
    await ReadOnly()
    return int(dut.x.value), int(dut.y.value)


async def now(dut):
    return await step(dut)


async def set_reg(dut, dest, value):
    await step(dut, commit=1, is_set=1, set_dest=dest, set_data=value)


async def jmp_x_dec(dut):
    await step(dut, commit=1, is_jmp=1, jmp_cond=COND_X_DEC)


@cocotb.test()
async def test_reset_to_zero(dut):
    """Reset clears X and Y."""
    await start(dut)
    assert await now(dut) == (0, 0)


@cocotb.test()
async def test_set_x_and_y(dut):
    """SET X and SET Y load the immediate, zero-extended to 8 bits, into only their register."""
    await start(dut)
    await set_reg(dut, DEST_X, 31)
    assert await now(dut) == (31, 0)
    await set_reg(dut, DEST_Y, 17)
    assert await now(dut) == (31, 17)
    await set_reg(dut, DEST_X, 0)
    assert await now(dut) == (0, 17)


@cocotb.test()
async def test_nothing_changes_without_commit(dut):
    """SET and JMP X-- are ignored on clocks without commit, as between ticks or while stalled."""
    await start(dut)
    await set_reg(dut, DEST_X, 5)
    await step(dut, commit=0, is_set=1, set_dest=DEST_X, set_data=20)
    await step(dut, commit=0, is_set=1, set_dest=DEST_Y, set_data=20)
    await step(dut, commit=0, is_jmp=1, jmp_cond=COND_X_DEC)
    assert await now(dut) == (5, 0)


@cocotb.test()
async def test_jmp_x_dec_wraps(dut):
    """JMP X-- decrements on every commit, and 0 wraps to 255 like the end of a UART byte."""
    await start(dut)
    await set_reg(dut, DEST_X, 2)
    seen = []
    for _ in range(4):
        await jmp_x_dec(dut)
        seen.append((await now(dut))[0])
    assert seen == [1, 0, 255, 254], f"X sequence {seen}"


@cocotb.test()
async def test_other_instructions_leave_x_and_y(dut):
    """Unconditional JMP, SET PINS, and commits with neither flag never touch X or Y."""
    await start(dut)
    await set_reg(dut, DEST_X, 9)
    await set_reg(dut, DEST_Y, 3)
    await step(dut, commit=1, is_jmp=1, jmp_cond=COND_ALWAYS)
    await step(dut, commit=1, is_set=1, set_dest=DEST_PINS, set_data=1)
    # Like OUT or PULL: args that would match SET X and JMP X--, but neither flag
    await step(dut, commit=1, set_dest=DEST_X, set_data=30, jmp_cond=COND_X_DEC)
    assert await now(dut) == (9, 3)


@cocotb.test()
async def test_uart_tx_bit_counter(dut):
    """set x, 7 then eight JMP X-- commits: the jump sees 7 down to 0, and X ends at 255."""
    await start(dut)
    await set_reg(dut, DEST_X, 7)
    seen_by_jump = []
    for _ in range(8):
        seen_by_jump.append((await now(dut))[0])
        await jmp_x_dec(dut)
    assert seen_by_jump == [7, 6, 5, 4, 3, 2, 1, 0], f"X seen by each jump {seen_by_jump}"
    assert (await now(dut))[0] == 255


@cocotb.test()
async def test_random_against_reference(dut):
    """Random commits of JMP, SET, and other instructions with every field value match."""
    rng = random.Random(0x5C7A)
    await start(dut)
    x, y = 0, 0
    for cycle in range(10000):
        kind = rng.choice(("jmp", "set", "other"))
        inputs = {
            "commit": int(rng.random() < 0.5),
            "is_jmp": int(kind == "jmp"),
            "is_set": int(kind == "set"),
            "set_dest": rng.randrange(8),
            "set_data": rng.randrange(32),
            "jmp_cond": rng.randrange(8),
        }
        got = await step(dut, **inputs)
        assert got == (x, y), f"cycle {cycle}: (x, y) = {got}, expected {(x, y)}"
        x, y = reference(x, y, **inputs)
