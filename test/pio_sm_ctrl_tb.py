# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_ctrl against the transition table in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20

DISABLED, EXEC, STALL, DELAY = 0b00, 0b01, 0b10, 0b11
STATE_NAMES = {DISABLED: "DISABLED", EXEC: "EXEC", STALL: "STALL", DELAY: "DELAY"}

STROBES = ("commit", "pc_advance", "sideset_en", "delay_load", "delay_dec")
NONE = frozenset()
EXECUTE = frozenset({"commit", "pc_advance", "sideset_en"})


def reference(state, enable, tick, stall, delay_val, delay_last):
    """Return (next state, asserted strobes) from the spec's transition table."""
    if not enable:
        return DISABLED, NONE
    if state == DISABLED:
        return EXEC, NONE
    if not tick:
        return state, NONE
    if state in (EXEC, STALL):
        if stall:
            return STALL, frozenset({"sideset_en"})
        if delay_val == 0:
            return EXEC, EXECUTE
        return DELAY, EXECUTE | {"delay_load"}
    return (EXEC if delay_last else DELAY), frozenset({"delay_dec"})


async def start(dut):
    """Start the clock and hold reset for two edges, leaving the FSM in DISABLED."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.tick.value = 0
    dut.stall.value = 0
    dut.delay_val.value = 0
    dut.delay_last.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def step(dut, enable=1, tick=0, stall=0, delay_val=0, delay_last=0):
    """Drive one cycle's inputs away from the clock edge and sample the Mealy outputs.

    Returns the state during this cycle and the set of asserted strobes. The following call
    observes the state after the rising edge in between.
    """
    await FallingEdge(dut.clk)
    dut.enable.value = enable
    dut.tick.value = tick
    dut.stall.value = stall
    dut.delay_val.value = delay_val
    dut.delay_last.value = delay_last
    await ReadOnly()
    state = int(dut.state.value)
    strobes = frozenset(name for name in STROBES if int(getattr(dut, name).value))
    assert int(dut.stalled.value) == (state == STALL), "stalled must equal state == STALL"
    assert int(dut.active.value) == (state != DISABLED), "active must equal state != DISABLED"
    return state, strobes


async def expect(dut, state, strobes, **inputs):
    got_state, got_strobes = await step(dut, **inputs)
    assert got_state == state, (
        f"inputs {inputs}: expected state {STATE_NAMES[state]}, got {STATE_NAMES[got_state]}"
    )
    assert got_strobes == strobes, (
        f"inputs {inputs} in {STATE_NAMES[state]}: expected {sorted(strobes)}, "
        f"got {sorted(got_strobes)}"
    )


async def enter_exec(dut):
    """Leave DISABLED. The tick in the DISABLED cycle must be ignored."""
    await expect(dut, DISABLED, NONE, enable=1, tick=1)
    await expect(dut, EXEC, NONE, enable=1, tick=0)


@cocotb.test()
async def test_reset_and_disabled(dut):
    """Reset lands in DISABLED, which emits no strobes and stays put while enable is low."""
    await start(dut)
    for _ in range(3):
        await expect(dut, DISABLED, NONE, enable=0, tick=1, stall=1, delay_val=7)
    await expect(dut, DISABLED, NONE, enable=1, tick=1, delay_val=7)
    await expect(dut, EXEC, NONE)


@cocotb.test()
async def test_no_tick_holds(dut):
    """Without a tick, every enabled state holds and emits no strobes."""
    await start(dut)
    await enter_exec(dut)
    await expect(dut, EXEC, NONE, tick=0, stall=1, delay_val=3)
    await expect(dut, EXEC, {"sideset_en"}, tick=1, stall=1)
    await expect(dut, STALL, NONE, tick=0, stall=1)
    await expect(dut, STALL, NONE, tick=0, stall=0)
    await expect(dut, STALL, EXECUTE | {"delay_load"}, tick=1, delay_val=2)
    await expect(dut, DELAY, NONE, tick=0, delay_last=1)
    await expect(dut, DELAY, NONE, tick=0)


@cocotb.test()
async def test_exec_without_delay(dut):
    """An unstalled instruction with no delay commits and stays in EXEC."""
    await start(dut)
    await enter_exec(dut)
    for _ in range(3):
        await expect(dut, EXEC, EXECUTE, tick=1)
    await expect(dut, EXEC, NONE)


@cocotb.test()
async def test_stall_then_release(dut):
    """A stall applies side-set on every tick, then the instruction commits once it clears."""
    await start(dut)
    await enter_exec(dut)
    await expect(dut, EXEC, {"sideset_en"}, tick=1, stall=1, delay_val=7)
    await expect(dut, STALL, {"sideset_en"}, tick=1, stall=1, delay_val=7)
    await expect(dut, STALL, NONE, tick=0, stall=0)
    await expect(dut, STALL, EXECUTE, tick=1, stall=0, delay_val=0)
    await expect(dut, EXEC, NONE)


@cocotb.test()
async def test_delay_sequence(dut):
    """A delay loads, decrements once per tick, and returns to EXEC on the last tick."""
    await start(dut)
    await enter_exec(dut)
    await expect(dut, EXEC, EXECUTE | {"delay_load"}, tick=1, delay_val=3)
    await expect(dut, DELAY, {"delay_dec"}, tick=1)
    await expect(dut, DELAY, NONE, tick=0)
    await expect(dut, DELAY, {"delay_dec"}, tick=1)
    await expect(dut, DELAY, {"delay_dec"}, tick=1, delay_last=1)
    await expect(dut, EXEC, NONE)


@cocotb.test()
async def test_delay_ignores_stall_and_delay_val(dut):
    """DELAY reads only delay_last, so stall and delay_val have no effect there."""
    await start(dut)
    await enter_exec(dut)
    await expect(dut, EXEC, EXECUTE | {"delay_load"}, tick=1, delay_val=31)
    await expect(dut, DELAY, {"delay_dec"}, tick=1, stall=1, delay_val=31)
    await expect(dut, DELAY, {"delay_dec"}, tick=1, stall=1, delay_val=0, delay_last=1)
    await expect(dut, EXEC, NONE)


@cocotb.test()
async def test_disable_from_every_state(dut):
    """Dropping enable reaches DISABLED on the next clock from any state, even with a tick."""
    await start(dut)
    await enter_exec(dut)
    await expect(dut, EXEC, NONE, enable=0, tick=1)
    await expect(dut, DISABLED, NONE, enable=0)

    await enter_exec(dut)
    await expect(dut, EXEC, {"sideset_en"}, tick=1, stall=1)
    await expect(dut, STALL, NONE, enable=0, tick=1, stall=1)
    await expect(dut, DISABLED, NONE, enable=0)

    await enter_exec(dut)
    await expect(dut, EXEC, EXECUTE | {"delay_load"}, tick=1, delay_val=5)
    await expect(dut, DELAY, NONE, enable=0, tick=1, delay_last=1)
    await expect(dut, DISABLED, NONE, enable=1, tick=1)
    await expect(dut, EXEC, NONE)


@cocotb.test()
async def test_random_against_reference(dut):
    """Constrained-random inputs must match the transition table on every cycle."""
    rng = random.Random(0x5EED)
    await start(dut)

    state = DISABLED
    for cycle in range(5000):
        inputs = {
            "enable": int(rng.random() < 0.95),
            "tick": int(rng.random() < 0.5),
            "stall": int(rng.random() < 0.3),
            "delay_val": 0 if rng.random() < 0.5 else rng.randrange(1, 32),
            "delay_last": int(rng.random() < 0.3),
        }
        want_next, want_strobes = reference(state, **inputs)
        got_state, got_strobes = await step(dut, **inputs)
        assert got_state == state, f"cycle {cycle}: state {got_state}, expected {state}"
        assert got_strobes == want_strobes, (
            f"cycle {cycle} in {STATE_NAMES[state]} with {inputs}: "
            f"expected {sorted(want_strobes)}, got {sorted(got_strobes)}"
        )
        state = want_next
