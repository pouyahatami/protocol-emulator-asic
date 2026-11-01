# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_pins against the pins_out row in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly

CLOCK_PERIOD_NS = 20

NUM_PINS = 24
ALL_HIGH = (1 << NUM_PINS) - 1
OP_JMP, OP_OUT, OP_SET = 0b000, 0b011, 0b111
DEST_PINS, DEST_X = 0b000, 0b001

CONFIG = ("out_base", "out_count", "sideset_base", "sideset_count")
STROBES = ("commit", "op", "out_dest", "out_data", "sideset_en", "side_en", "side_val")


def write_field(pins, base, count, data):
    """Write count bits of data from pin base, wrapping modulo 32 and dropping pins 24 to 31."""
    for i in range(count):
        j = (base + i) % 32
        if j < NUM_PINS:
            pins = (pins & ~(1 << j)) | (((data >> i) & 1) << j)
    return pins


def reference(pins, cfg, commit, op, out_dest, out_data, sideset_en, side_en, side_val):
    """Return pins_out after one clock edge. Side-set is written last so it wins."""
    if commit and op == OP_OUT and out_dest == DEST_PINS:
        pins = write_field(pins, cfg["out_base"], cfg["out_count"], out_data)
    if sideset_en and side_en:
        pins = write_field(pins, cfg["sideset_base"], cfg["sideset_count"], side_val)
    return pins


async def start(dut, **cfg):
    """Start the clock, then reset with the given pin configuration."""
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    await reset(dut, **cfg)


async def reset(dut, out_base=0, out_count=1, sideset_base=0, sideset_count=1):
    """Hold reset for two edges with the given pin configuration."""
    await FallingEdge(dut.clk)
    dut.rst_n.value = 0
    dut.out_base.value = out_base
    dut.out_count.value = out_count
    dut.sideset_base.value = sideset_base
    dut.sideset_count.value = sideset_count
    for name in STROBES:
        getattr(dut, name).value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1


async def step(dut, commit=0, op=OP_JMP, out_dest=DEST_PINS, out_data=0,
               sideset_en=0, side_en=0, side_val=0):
    """Drive one cycle's inputs away from the clock edge and return pins_out during that cycle."""
    await FallingEdge(dut.clk)
    dut.commit.value = commit
    dut.op.value = op
    dut.out_dest.value = out_dest
    dut.out_data.value = out_data
    dut.sideset_en.value = sideset_en
    dut.side_en.value = side_en
    dut.side_val.value = side_val
    await ReadOnly()
    assert int(dut.pins_oe.value) == 0, "no v0 instruction may drive a pin direction"
    return int(dut.pins_out.value)


async def now(dut):
    return await step(dut)


async def out_pins(dut, data):
    await step(dut, commit=1, op=OP_OUT, out_dest=DEST_PINS, out_data=data)


async def side(dut, value, commit=0):
    await step(dut, commit=commit, op=OP_JMP, sideset_en=1, side_en=1, side_val=value)


def pins_with(changes):
    """All pins high except the given {pin: level} changes."""
    pins = ALL_HIGH
    for pin, level in changes.items():
        pins = (pins & ~(1 << pin)) | (level << pin)
    return pins


@cocotb.test()
async def test_reset_all_high_and_released(dut):
    """Reset drives every pin_out high and releases every pin."""
    await start(dut)
    assert await now(dut) == ALL_HIGH


@cocotb.test()
async def test_holds_without_strobes(dut):
    """Without commit or sideset_en, nothing changes even with data on the inputs."""
    await start(dut, out_base=0, out_count=8, sideset_base=8, sideset_count=5)
    await step(dut, commit=0, op=OP_OUT, out_data=0x00, side_en=1, side_val=0)
    await step(dut, commit=0, op=OP_OUT, out_data=0x00, sideset_en=0, side_en=1)
    assert await now(dut) == ALL_HIGH


@cocotb.test()
async def test_out_pins_window(dut):
    """OUT PINS writes out_count pins from out_base, bit i to pin out_base + i, and no others."""
    await start(dut, out_base=10, out_count=4)
    await out_pins(dut, 0b0110)
    assert await now(dut) == pins_with({10: 0, 11: 1, 12: 1, 13: 0})


@cocotb.test()
async def test_out_count_beyond_out_bits_drives_zero(dut):
    """A 1-bit OUT into a 3-pin window drives the two pins above it low."""
    await start(dut, out_base=4, out_count=3)
    await out_pins(dut, 0b1)
    assert await now(dut) == pins_with({4: 1, 5: 0, 6: 0})


@cocotb.test()
async def test_out_to_other_destinations_leaves_pins(dut):
    """OUT X, and other opcodes whose args look like OUT PINS, never touch the pins."""
    await start(dut, out_base=0, out_count=8)
    await step(dut, commit=1, op=OP_OUT, out_dest=DEST_X, out_data=0)
    for op in (OP_JMP, OP_SET):
        await step(dut, commit=1, op=op, out_dest=DEST_PINS, out_data=0)
    assert await now(dut) == ALL_HIGH


@cocotb.test()
async def test_side_set(dut):
    """Side-set writes sideset_count pins from sideset_base, but only with both enables."""
    await start(dut, sideset_base=20, sideset_count=3)
    await step(dut, sideset_en=1, side_en=0, side_val=0)
    await step(dut, sideset_en=0, side_en=1, side_val=0)
    assert await now(dut) == ALL_HIGH
    await side(dut, 0b010)
    assert await now(dut) == pins_with({20: 0, 21: 1, 22: 0})


@cocotb.test()
async def test_side_set_while_stalled(dut):
    """On a stalled tick side-set applies without commit, so OUT does not."""
    await start(dut, out_base=3, out_count=1, sideset_base=7, sideset_count=1)
    await step(dut, commit=0, op=OP_OUT, out_data=0, sideset_en=1, side_en=1, side_val=0)
    assert await now(dut) == pins_with({7: 0})


@cocotb.test()
async def test_side_set_wins_over_out(dut):
    """When OUT and side-set hit the same pin on one edge, side-set wins and OUT keeps the rest."""
    await start(dut, out_base=0, out_count=4, sideset_base=2, sideset_count=1)
    await step(dut, commit=1, op=OP_OUT, out_data=0b0000, sideset_en=1, side_en=1, side_val=1)
    assert await now(dut) == pins_with({0: 0, 1: 0, 2: 1, 3: 0})


@cocotb.test()
async def test_pin_numbers_wrap_modulo_32(dut):
    """Windows past pin 23 drop the missing pins 24 to 31, and past 31 wrap to pin 0."""
    await start(dut, out_base=22, out_count=4)
    await out_pins(dut, 0b0000)
    assert await now(dut) == pins_with({22: 0, 23: 0})

    await reset(dut, out_base=30, out_count=4)
    await out_pins(dut, 0b0000)
    assert await now(dut) == pins_with({0: 0, 1: 0})


@cocotb.test()
async def test_uart_tx_line(dut):
    """UART TX with OUT and side-set on pin 0: idle high, start bit low, then LSB-first data."""
    await start(dut, out_base=0, out_count=1, sideset_base=0, sideset_count=1)
    line = []
    await side(dut, 1, commit=1)
    line.append((await now(dut)) & 1)
    await side(dut, 0, commit=1)
    line.append((await now(dut)) & 1)
    for bit in (1, 0, 1, 0, 1, 0, 1, 0):
        await out_pins(dut, bit)
        line.append((await now(dut)) & 1)
        await step(dut, commit=1, op=OP_JMP)
        assert (await now(dut)) & 1 == bit, "JMP must not disturb the TX pin"
    assert line == [1, 0, 1, 0, 1, 0, 1, 0, 1, 0], f"TX line {line}"


@cocotb.test()
async def test_random_against_reference(dut):
    """Random OUT and side-set traffic under random legal configurations matches the reference."""
    rng = random.Random(0x9145)
    await start(dut)
    for _ in range(10):
        cfg = {
            "out_base": rng.randrange(32),
            "out_count": rng.randrange(9),
            "sideset_base": rng.randrange(32),
            "sideset_count": rng.randrange(6),
        }
        await reset(dut, **cfg)
        pins = ALL_HIGH
        for cycle in range(1000):
            inputs = {
                "commit": int(rng.random() < 0.5),
                "op": rng.choice((OP_OUT, OP_OUT, OP_JMP, OP_SET)),
                "out_dest": rng.choice((DEST_PINS, DEST_PINS, DEST_X)),
                "out_data": rng.randrange(256),
                "sideset_en": int(rng.random() < 0.5),
                "side_en": int(rng.random() < 0.7),
                "side_val": rng.randrange(1 << cfg["sideset_count"]),
            }
            got = await step(dut, **inputs)
            assert got == pins, f"{cfg} cycle {cycle}: pins {got:#08x}, expected {pins:#08x}"
            pins = reference(pins, cfg, **inputs)
