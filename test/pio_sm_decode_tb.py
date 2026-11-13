# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Unit tests for pio_sm_decode against the decoder table in docs/spec/control-fsm.md."""

import random

import cocotb
from cocotb.triggers import Timer

SETTLE_NS = 1

# Every legal side-set configuration: sideset_count + sideset_opt <= 5
CONFIGS = [(count, opt) for opt in (0, 1) for count in range(6) if count + opt <= 5]

FLAGS = ("is_jmp", "is_out", "is_pull", "is_set")
FIELDS = FLAGS + (
    "side_en", "side_val", "delay_val", "jmp_cond", "jmp_addr",
    "set_dest", "set_data", "out_dest", "out_bits", "block", "unsup_instr",
)


def reference(instr, sideset_count, sideset_opt):
    """Decode one instruction the way the spec describes, field by field."""
    op = instr >> 13
    ds_field = (instr >> 8) & 0x1F
    args = instr & 0xFF
    delay_bits = 5 - sideset_count - sideset_opt
    return {
        "is_jmp": int(op == 0b000),
        "is_out": int(op == 0b011),
        "is_pull": int(op == 0b100 and bool(args & 0x80)),
        "is_set": int(op == 0b111),
        "side_en": (ds_field >> 4) if sideset_opt else int(sideset_count > 0),
        "side_val": (ds_field >> delay_bits) & ((1 << sideset_count) - 1),
        "delay_val": ds_field & ((1 << delay_bits) - 1),
        "jmp_cond": args >> 5,
        "jmp_addr": args & 0x1F,
        "set_dest": args >> 5,
        "set_data": args & 0x1F,
        "out_dest": args >> 5,
        "out_bits": args & 0x1F,
        "block": int(op == 0b100 and bool(args & 0x20)),
        "unsup_instr": int(not v0_legal(op, args)),
    }


def v0_legal(op, args):
    """The v0 subset from the spec's unsupported-instruction table."""
    field_a, field_b = args >> 5, args & 0x1F
    if op == 0b000:
        return field_a in (0b000, 0b010)
    if op == 0b011:
        return field_a == 0b000 and 1 <= field_b <= 8
    if op == 0b100:
        return field_a == 0b101 and field_b == 0
    if op == 0b111:
        return field_a in (0b001, 0b010)
    return False


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
        0x9FA0: {"is_pull": 1, "side_en": 1, "side_val": 1, "delay_val": 7, "block": 1},
        0xF727: {"is_set": 1, "side_en": 1, "side_val": 0, "delay_val": 7,
                 "set_dest": 0b001, "set_data": 7},
        0x6001: {"is_out": 1, "side_en": 0, "delay_val": 0,
                 "out_dest": 0b000, "out_bits": 1},
        0x0642: {"is_jmp": 1, "side_en": 0, "delay_val": 6,
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
async def test_one_flag_per_opcode(dut):
    """Each v0 opcode raises only its own flag, and every other opcode raises none."""
    own_flag = {0b000: "is_jmp", 0b011: "is_out", 0b100: "is_pull", 0b111: "is_set"}
    for op in range(8):
        got = await decode(dut, (op << 13) | 0x80, 0, 0)
        raised = [name for name in FLAGS if got[name]]
        want = [own_flag[op]] if op in own_flag else []
        assert raised == want, f"opcode {op:03b}: flags {raised}, expected {want}"


@cocotb.test()
async def test_unsupported_instructions(dut):
    """Every encoding outside the v0 subset raises unsup_instr, and the UART TX words do not."""
    illegal = {
        "wait": 0x2000, "in": 0x4001, "mov": 0xA000, "irq": 0xC000,
        "push": 0x8020, "pull_noblock": 0x8080, "pull_ifempty": 0x80E0,
        "pull_reserved_bits": 0x80A1,
        "jmp_not_x": 0x0020, "jmp_y_dec": 0x0080,
        "set_pins": 0xE001, "set_pindirs": 0xE081,
        "out_x": 0x6021, "out_pins_0": 0x6000, "out_pins_9": 0x6009,
    }
    for instr in illegal.values():
        await check(dut, instr, 1, 1, {"unsup_instr": 1})
    for instr in (0x9FA0, 0xF727, 0x6001, 0x0642, 0x0002, 0xF041, 0x6008):
        await check(dut, instr, 1, 1, {"unsup_instr": 0})


@cocotb.test()
async def test_exhaustive_legality(dut):
    """unsup_instr matches the reference for all 65536 instruction words."""
    for instr in range(1 << 16):
        dut.instr.value = instr
        await Timer(SETTLE_NS, unit="ns")
        want = 1 - v0_legal(instr >> 13, instr & 0xFF)
        assert int(dut.unsup_instr.value) == want, f"instr={instr:#06x}"


@cocotb.test()
async def test_pull_versus_push(dut):
    """is_pull needs the PUSH/PULL opcode and args[7]. block needs that opcode and args[5]."""
    await check(dut, 0x80A0, 0, 0, {"is_pull": 1, "block": 1})
    await check(dut, 0x8080, 0, 0, {"is_pull": 1, "block": 0})
    await check(dut, 0x8020, 0, 0, {"is_pull": 0, "block": 1})
    # set x, 7 has args[5] set but is not PUSH/PULL
    await check(dut, 0xE027, 0, 0, {"is_set": 1, "block": 0})
    for op in (0b000, 0b011, 0b111):
        await check(dut, (op << 13) | 0x80, 0, 0, {"is_pull": 0})


@cocotb.test()
async def test_random_against_reference(dut):
    """Random instruction words under random legal configurations match the reference."""
    rng = random.Random(0xDEC0)
    for _ in range(20000):
        sideset_count, sideset_opt = rng.choice(CONFIGS)
        await check(dut, rng.randrange(1 << 16), sideset_count, sideset_opt)
