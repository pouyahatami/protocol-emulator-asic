# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_clkdiv against the clock divider in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20

# 54 is the UART TX setting for 115200 baud from 50 MHz
PERIODS = (0, 1, 2, 3, 7, 54)


def reference(div_cnt, enable, active, clkdiv):
    """Return (tick, next div_cnt) for one cycle of the spec's divider."""
    if not (enable and active):
        return 0, 0
    if clkdiv <= 1 or div_cnt == clkdiv - 1:
        return 1, 0
    return 0, (div_cnt + 1) & 0xFFFF


async def start(dut, clkdiv=0):
    """Start the clock and hold reset for two edges, leaving the divider stopped."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.active.value = 0
    dut.clkdiv.value = clkdiv
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def step(dut, enable=1, active=1, clkdiv=None):
    """Drive one cycle's inputs away from the clock edge and return (tick, div_cnt)."""
    await FallingEdge(dut.clk)
    dut.enable.value = enable
    dut.active.value = active
    if clkdiv is not None:
        dut.clkdiv.value = clkdiv
    await ReadOnly()
    return int(dut.tick.value), int(dut.div_cnt.value)


async def tick_cycles(dut, cycles):
    """Run enabled and active for a number of cycles and return the indices that ticked."""
    ticked = []
    for cycle in range(cycles):
        tick, _ = await step(dut)
        if tick:
            ticked.append(cycle)
    return ticked


def expected_ticks(clkdiv, cycles):
    """Ticks fall on cycles period - 1, 2 * period - 1, ... counted from the first active cycle."""
    period = max(clkdiv, 1)
    return list(range(period - 1, cycles, period))


@cocotb.test()
async def test_reset_holds_tick_low(dut):
    """After reset, tick stays low and the count stays at 0 while stopped."""
    await start(dut, clkdiv=0)
    for enable, active in ((0, 0), (0, 1), (1, 0)):
        for _ in range(3):
            tick, div_cnt = await step(dut, enable=enable, active=active)
            assert tick == 0, f"enable={enable} active={active} must not tick"
            assert div_cnt == 0, f"enable={enable} active={active} must hold the count at 0"


@cocotb.test()
async def test_tick_period(dut):
    """Each clkdiv gives one single-cycle tick every max(clkdiv, 1) clocks, first one included."""
    await start(dut)
    for clkdiv in PERIODS:
        await step(dut, enable=0, active=0, clkdiv=clkdiv)
        cycles = 4 * max(clkdiv, 1)
        got = await tick_cycles(dut, cycles)
        assert got == expected_ticks(clkdiv, cycles), (
            f"clkdiv={clkdiv}: ticks at {got}, expected {expected_ticks(clkdiv, cycles)}"
        )


@cocotb.test()
async def test_maximum_period(dut):
    """The largest clkdiv counts the full 16-bit range without wrapping early."""
    await start(dut, clkdiv=0xFFFF)
    cycles = 2 * 0xFFFF
    got = await tick_cycles(dut, cycles)
    assert got == expected_ticks(0xFFFF, cycles), f"ticks at {got}"


@cocotb.test()
async def test_stop_restarts_full_period(dut):
    """Dropping enable or active mid-period clears the count, so the next period is full length."""
    await start(dut, clkdiv=5)
    for stop in ({"enable": 0, "active": 1}, {"enable": 1, "active": 0}):
        got = await tick_cycles(dut, 3)
        assert got == [], f"no tick expected in the first 3 of 5 cycles, got {got}"
        tick, _ = await step(dut, **stop)
        assert tick == 0, f"{stop} must suppress the tick"
        _, div_cnt = await step(dut, **stop)
        assert div_cnt == 0, f"{stop} must clear the count on the next clock"
        got = await tick_cycles(dut, 10)
        assert got == [4, 9], f"after {stop}, ticks at {got}, expected [4, 9]"
        await step(dut, enable=0, active=0)


@cocotb.test()
async def test_stop_on_tick_cycle(dut):
    """Stopping in the cycle where a tick would fire suppresses it and restarts cleanly."""
    await start(dut, clkdiv=3)
    got = await tick_cycles(dut, 2)
    assert got == []
    tick, div_cnt = await step(dut, enable=0)
    assert (tick, div_cnt) == (0, 2), f"expected no tick at count 2, got {tick}, {div_cnt}"
    got = await tick_cycles(dut, 6)
    assert got == [2, 5], f"ticks at {got}, expected [2, 5]"


@cocotb.test()
async def test_random_against_reference(dut):
    """Random enable and active sequences match the reference every cycle.

    clkdiv changes only while enable is low, as the spec requires.
    """
    rng = random.Random(0xC10C)
    await start(dut)

    div_cnt = 0
    clkdiv = 0
    for cycle in range(20000):
        enable = int(rng.random() < 0.97)
        active = int(rng.random() < 0.98)
        new_clkdiv = None
        if not enable and rng.random() < 0.5:
            new_clkdiv = rng.choice(PERIODS + (rng.randrange(0, 40),))
            clkdiv = new_clkdiv
        want_tick, want_next = reference(div_cnt, enable, active, clkdiv)
        got_tick, got_cnt = await step(dut, enable=enable, active=active, clkdiv=new_clkdiv)
        assert got_cnt == div_cnt, f"cycle {cycle}: div_cnt {got_cnt}, expected {div_cnt}"
        assert got_tick == want_tick, (
            f"cycle {cycle}: clkdiv={clkdiv} enable={enable} active={active} "
            f"div_cnt={div_cnt}: tick {got_tick}, expected {want_tick}"
        )
        div_cnt = want_next
