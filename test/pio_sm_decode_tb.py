# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_decode against the decoder table in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.triggers import Timer

SETTLE_NS = 1

# Every legal side-set configuration: sideset_count + sideset_opt <= 5
CONFIGS = [(count, opt) for opt in (0, 1) for count in range(6) if count + opt <= 5]

FIELDS = (
    "op", "side_en", "side_val", "delay_val", "jmp_cond", "jmp_addr",
    "set_dest", "set_data", "out_dest", "out_bits", "is_pull", "block",
)


def reference(instr, sideset_count, sideset_opt):
    """Decode one instruction the way the spec describes, field by field."""
    op = instr >> 13
    ds_field = (instr >> 8) & 0x1F
    args = instr & 0xFF
    delay_bits = 5 - sideset_count - sideset_opt
    return {
        "op": op,
        "side_en": (ds_field >> 4) if sideset_opt else int(sideset_count > 0),
        "side_val": (ds_field >> delay_bits) & ((1 << sideset_count) - 1),
        "delay_val": ds_field & ((1 << delay_bits) - 1),
        "jmp_cond": args >> 5,
        "jmp_addr": args & 0x1F,
        "set_dest": args >> 5,
        "set_data": args & 0x1F,
        "out_dest": args >> 5,
        "out_bits": args & 0x1F,
        "is_pull": int(op == 0b100 and bool(args & 0x80)),
        "block": (args >> 5) & 1,
    }


async def decode(dut, instr, sideset_count, sideset_opt):
    dut.instr.value = instr
    dut.sideset_count.value = sideset_count
    dut.sideset_opt.value = sideset_opt
    await Timer(SETTLE_NS, unit="ns")
    return {name: int(getattr(dut, name).value) for name in FIELDS}


async def check(dut, instr, sideset_count, sideset_opt, expected=None):
    got = await decode(dut, instr, sideset_count, sideset_opt)
    want = reference(instr, sideset_count, sideset_opt)
    if expected is not None:
        assert {name: want[name] for name in expected} == expected, (
            f"reference disagrees with the hand-decoded fields for {instr:#06x}"
        )
    mismatches = {name: (got[name], want[name]) for name in FIELDS if got[name] != want[name]}
    assert not mismatches, (
        f"instr={instr:#06x} count={sideset_count} opt={sideset_opt}: "
        f"(got, expected) {mismatches}"
    )


@cocotb.test()
async def test_uart_tx_program(dut):
    """The four UART TX words decode to the fields in uart-tx.md with .side_set 1 opt."""
    program = {
        0x9FA0: {"op": 0b100, "side_en": 1, "side_val": 1, "delay_val": 7,
                 "is_pull": 1, "block": 1},
        0xF727: {"op": 0b111, "side_en": 1, "side_val": 0, "delay_val": 7,
                 "set_dest": 0b001, "set_data": 7},
        0x6001: {"op": 0b011, "side_en": 0, "delay_val": 0,
                 "out_dest": 0b000, "out_bits": 1},
        0x0642: {"op": 0b000, "side_en": 0, "delay_val": 6,
                 "jmp_cond": 0b010, "jmp_addr": 2},
    }
    for instr, expected in program.items():
        await check(dut, instr, sideset_count=1, sideset_opt=1, expected=expected)


@cocotb.test()
async def test_delay_side_split_exhaustive(dut):
    """Every delay/side-set field value splits correctly under every legal configuration."""
    for sideset_count, sideset_opt in CONFIGS:
        for ds_field in range(32):
            await check(dut, ds_field << 8, sideset_count, sideset_opt)


@cocotb.test()
async def test_split_examples(dut):
    """Hand-checked splits at the edges of the configuration range."""
    # No side-set: all 5 bits are delay and side-set is never enabled
    await check(dut, 0x1F00, 0, 0, {"side_en": 0, "side_val": 0, "delay_val": 31})
    # Five mandatory side-set bits: no delay left
    await check(dut, 0x1500, 5, 0, {"side_en": 1, "side_val": 0b10101, "delay_val": 0})
    # Four optional side-set bits with the enable bit clear
    await check(dut, 0x0F00, 4, 1, {"side_en": 0, "side_val": 0b1111, "delay_val": 0})
    # Two mandatory side-set bits above three delay bits
    await check(dut, 0x1300, 2, 0, {"side_en": 1, "side_val": 0b10, "delay_val": 0b011})


@cocotb.test()
async def test_pull_versus_push(dut):
    """is_pull needs both the PUSH/PULL opcode and args[7]. block is args[5] for both."""
    await check(dut, 0x80A0, 0, 0, {"is_pull": 1, "block": 1})
    await check(dut, 0x8080, 0, 0, {"is_pull": 1, "block": 0})
    await check(dut, 0x8020, 0, 0, {"is_pull": 0, "block": 1})
    for op in (0b000, 0b011, 0b111):
        await check(dut, (op << 13) | 0x80, 0, 0, {"is_pull": 0})


@cocotb.test()
async def test_random_against_reference(dut):
    """Random instruction words under random legal configurations match the reference."""
    rng = random.Random(0xDEC0)
    for _ in range(20000):
        sideset_count, sideset_opt = rng.choice(CONFIGS)
        await check(dut, rng.randrange(1 << 16), sideset_count, sideset_opt)
