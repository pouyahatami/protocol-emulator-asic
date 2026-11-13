# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"Unit tests for pio_sm_delay against the delay counter in docs/spec/control-fsm.md."

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20


def reference(delay_cnt, delay_load, delay_dec, delay_val):
    """Return the count after one clock edge."""
    if delay_load:
        return delay_val
    if delay_dec:
        return (delay_cnt - 1) & 0x1F
    return delay_cnt


async def start(dut):
    """Start the clock and hold reset for two edges."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.delay_load.value = 0
    dut.delay_dec.value = 0
    dut.delay_val.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def step(dut, delay_load=0, delay_dec=0, delay_val=0):
    """Drive one cycle's inputs away from the clock edge and return (delay_cnt, delay_last)."""
    await FallingEdge(dut.clk)
    dut.delay_load.value = delay_load
    dut.delay_dec.value = delay_dec
    dut.delay_val.value = delay_val
    await ReadOnly()
    delay_cnt = int(dut.delay_cnt.value)
    delay_last = int(dut.delay_last.value)
    assert delay_last == (delay_cnt == 1), f"delay_last={delay_last} with delay_cnt={delay_cnt}"
    return delay_cnt, delay_last


@cocotb.test()
async def test_reset_to_zero(dut):
    """Reset clears the count, so delay_last is low."""
    await start(dut)
    assert await step(dut) == (0, 0)


@cocotb.test()
async def test_holds_without_strobes(dut):
    """Without a strobe the count holds, whatever delay_val says."""
    await start(dut)
    await step(dut, delay_load=1, delay_val=9)
    for value in (0, 31, 5):
        assert await step(dut, delay_val=value) == (9, 0)


@cocotb.test()
async def test_every_delay_takes_that_many_ticks(dut):
    """Loading n and decrementing until delay_last takes exactly n DELAY ticks, for n = 1..31.

    This is how the control FSM uses the counter: it leaves DELAY on the tick where
    delay_last is high, and decrements on that tick too
    """
    await start(dut)
    for n in range(1, 32):
        await step(dut, delay_load=1, delay_val=n)
        ticks = 0
        while True:
            delay_cnt, delay_last = await step(dut, delay_dec=1)
            ticks += 1
            assert delay_cnt == n - ticks + 1, f"n={n} tick {ticks}: count {delay_cnt}"
            if delay_last:
                break
            assert ticks < n, f"n={n}: delay_last never rose"
        assert ticks == n, f"delay {n} took {ticks} ticks"
        assert await step(dut) == (0, 0), f"n={n}: count must end at 0"


@cocotb.test()
async def test_stalled_between_ticks(dut):
    """The count only moves on a strobe, so idle clocks between ticks change nothing."""
    await start(dut)
    await step(dut, delay_load=1, delay_val=2)
    for _ in range(5):
        assert await step(dut) == (2, 0)
    await step(dut, delay_dec=1)
    for _ in range(5):
        assert await step(dut) == (1, 1)


@cocotb.test()
async def test_load_overwrites_stale_count(dut):
    """A load replaces whatever is left, as after a disable that dropped part of a delay."""
    await start(dut)
    await step(dut, delay_load=1, delay_val=7)
    await step(dut, delay_dec=1)
    await step(dut, delay_load=1, delay_val=1)
    assert await step(dut) == (1, 1)


@cocotb.test()
async def test_random_against_reference(dut):
    """Random strobe sequences, never both at once, match the reference every cycle."""
    rng = random.Random(0xDE1A)
    await start(dut)
    delay_cnt = 0
    for cycle in range(10000):
        roll = rng.random()
        inputs = {
            "delay_load": int(roll < 0.2),
            "delay_dec": int(0.2 <= roll < 0.6 and delay_cnt >= 1),
            "delay_val": rng.randrange(32),
        }
        got, _ = await step(dut, **inputs)
        assert got == delay_cnt, f"cycle {cycle}: count {got}, expected {delay_cnt}"
        delay_cnt = reference(delay_cnt, **inputs)
