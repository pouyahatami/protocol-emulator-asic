# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_osr against the OSR rows in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20


def shifted_out(osr, n, shift_right):
    """The n bits an OUT sends, right-aligned."""
    return osr & ((1 << n) - 1) if shift_right else osr >> (8 - n)


def reference(osr, count, commit, is_out, is_pull, out_bits, shift_right, txf_data):
    """Return (osr, osr_count) after one clock edge."""
    if not commit:
        return osr, count
    if is_pull:
        return txf_data, 0
    if is_out:
        new = osr >> out_bits if shift_right else (osr << out_bits) & 0xFF
        return new, min(count + out_bits, 8)
    return osr, count


async def start(dut, shift_right=1):
    """Start the clock, then reset with the given shift direction."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    await reset(dut, shift_right)


async def reset(dut, shift_right):
    """Hold reset for two edges with the given shift direction."""
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.shift_right.value = shift_right
    dut.commit.value = 0
    dut.is_out.value = 0
    dut.is_pull.value = 0
    dut.out_bits.value = 0
    dut.txf_data.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def step(dut, commit=0, is_out=0, is_pull=0, out_bits=0, txf_data=0):
    """Drive one cycle's inputs away from the clock edge.

    Returns (osr, osr_count, out_data) during that cycle, before the edge applies the inputs.
    """
    await FallingEdge(dut.clk)
    dut.commit.value = commit
    dut.is_out.value = is_out
    dut.is_pull.value = is_pull
    dut.out_bits.value = out_bits
    dut.txf_data.value = txf_data
    await ReadOnly()
    return int(dut.osr.value), int(dut.osr_count.value), int(dut.out_data.value)


async def now(dut):
    osr, count, _ = await step(dut)
    return osr, count


async def pull(dut, value):
    await step(dut, commit=1, is_pull=1, txf_data=value)


async def out(dut, n):
    """Commit OUT n and return the bits it sent."""
    _, _, out_data = await step(dut, commit=1, is_out=1, out_bits=n)
    return out_data


@cocotb.test()
async def test_reset_to_zero(dut):
    """Reset clears the OSR and its shift count."""
    await start(dut)
    assert await now(dut) == (0, 0)


@cocotb.test()
async def test_pull_loads_and_clears_count(dut):
    """PULL loads the FIFO byte and clears the shift count left by earlier OUTs."""
    await start(dut)
    await pull(dut, 0xFF)
    await out(dut, 3)
    assert await now(dut) == (0x1F, 3)
    await pull(dut, 0x3C)
    assert await now(dut) == (0x3C, 0)


@cocotb.test()
async def test_nothing_changes_without_commit(dut):
    """PULL and OUT are ignored on clocks without commit, as between ticks or while stalled."""
    await start(dut)
    await pull(dut, 0xA5)
    await step(dut, commit=0, is_pull=1, txf_data=0x11)
    await step(dut, commit=0, is_out=1, out_bits=4)
    assert await now(dut) == (0xA5, 0)


@cocotb.test()
async def test_uart_tx_lsb_first(dut):
    """pull 0x55 then eight OUT 1s with a right shift send 1, 0, 1, 0, 1, 0, 1, 0."""
    await start(dut, shift_right=1)
    await pull(dut, 0x55)
    bits = [await out(dut, 1) for _ in range(8)]
    assert bits == [1, 0, 1, 0, 1, 0, 1, 0], f"bits sent {bits}"
    assert await now(dut) == (0, 8)


@cocotb.test()
async def test_left_shift_msb_first(dut):
    """With a left shift, OUT 1 sends the MSB first."""
    await start(dut, shift_right=0)
    await pull(dut, 0xA6)
    bits = [await out(dut, 1) for _ in range(8)]
    assert bits == [1, 0, 1, 0, 0, 1, 1, 0], f"bits sent {bits}"
    assert await now(dut) == (0, 8)


@cocotb.test()
async def test_multi_bit_out(dut):
    """OUT n sends n bits right-aligned: the low bits for a right shift, the high for a left."""
    await start(dut)
    for shift_right, expected in ((1, [0b110, 0b010, 0b11]), (0, [0b110, 0b101, 0b10])):
        await reset(dut, shift_right)
        await pull(dut, 0b11010110)
        got = [await out(dut, 3), await out(dut, 3), await out(dut, 2)]
        assert got == expected, f"shift_right={shift_right}: sent {got}, expected {expected}"
        assert await now(dut) == (0, 8)


@cocotb.test()
async def test_full_byte_out(dut):
    """OUT 8 sends the whole byte in one go in either direction."""
    await start(dut)
    for shift_right in (1, 0):
        await reset(dut, shift_right)
        await pull(dut, 0x9E)
        assert await out(dut, 8) == 0x9E
        assert await now(dut) == (0, 8)


@cocotb.test()
async def test_count_saturates_at_eight(dut):
    """Shifting past an empty OSR keeps the count at 8 and sends zeros."""
    await start(dut)
    await pull(dut, 0xFF)
    await out(dut, 5)
    await out(dut, 5)
    assert await now(dut) == (0, 8)
    assert await out(dut, 1) == 0
    assert await now(dut) == (0, 8)


@cocotb.test()
async def test_other_instructions_leave_osr(dut):
    """A commit with neither flag, as for JMP, SET, or PUSH, never shifts or loads the OSR."""
    await start(dut)
    await pull(dut, 0x81)
    await step(dut, commit=1, is_out=0, is_pull=0, out_bits=4, txf_data=0x42)
    assert await now(dut) == (0x81, 0)


@cocotb.test()
async def test_random_against_reference(dut):
    """Random PULL, OUT, and other commits match the reference in both shift directions."""
    rng = random.Random(0x0512)
    await start(dut)
    for shift_right in (1, 0):
        await reset(dut, shift_right)
        osr, count = 0, 0
        for cycle in range(5000):
            # The decoder raises at most one flag, so the stimulus never raises both
            kind = rng.choice(("out", "out", "pull", "other"))
            inputs = {
                "commit": int(rng.random() < 0.6),
                "is_out": int(kind == "out"),
                "is_pull": int(kind == "pull"),
                "out_bits": rng.randrange(1, 9),
                "txf_data": rng.randrange(256),
            }
            got_osr, got_count, got_out = await step(dut, **inputs)
            assert (got_osr, got_count) == (osr, count), (
                f"shift_right={shift_right} cycle {cycle}: (osr, count) = "
                f"{(got_osr, got_count)}, expected {(osr, count)}"
            )
            want_out = shifted_out(osr, inputs["out_bits"], shift_right)
            assert got_out == want_out, (
                f"shift_right={shift_right} cycle {cycle}: out_data {got_out:#04x}, "
                f"expected {want_out:#04x}"
            )
            osr, count = reference(osr, count, shift_right=shift_right, **inputs)
