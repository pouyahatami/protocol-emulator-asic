# SPDX-FileCopyrightText: 2026 Bruce Liu
# SPDX-License-Identifier: Apache-2.0

"""Integration tests for pio_sm against the UART TX program and the 0x55 golden trace."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

CLOCK_PERIOD_NS = 20

# Official RP2040 UART TX, hand-encoded in uart-tx.md
UART_TX = {
    0: 0x9FA0,  # pull side 1 [7]
    1: 0xF727,  # set x, 7 side 0 [7]
    2: 0x6001,  # out pins, 1
    3: 0x0642,  # jmp x-- 2 [6]
}

EXEC, STALL, DELAY = 0b01, 0b10, 0b11
TX_PIN = 0


def tx_bit(dut):
    return (int(dut.pins_out.value) >> TX_PIN) & 1


def bits_lsb_first(byte):
    return [(byte >> i) & 1 for i in range(8)]


class TxFifo:
    """Host-side FIFO. A byte written here is visible to PULL on the next tick."""

    def __init__(self):
        self.q = []

    def push(self, byte):
        self.q.append(byte & 0xFF)


async def drive_imem(dut):
    """Return the instruction at PC in the same cycle, as a flop memory would."""
    while True:
        await FallingEdge(dut.clk)
        addr = int(dut.imem_addr.value)
        dut.imem_data.value = UART_TX.get(addr, 0)


async def drive_fifo(dut, fifo):
    """Drive the FIFO ports and pop on the edge where txf_pop is high."""
    while True:
        await FallingEdge(dut.clk)
        if fifo.q:
            dut.txf_data.value = fifo.q[0]
            dut.txf_empty.value = 0
        else:
            dut.txf_data.value = 0
            dut.txf_empty.value = 1
        await ReadOnly()
        popping = int(dut.txf_pop.value) and bool(fifo.q)
        await RisingEdge(dut.clk)
        if popping:
            fifo.q.pop(0)


async def start(dut, clkdiv=1):
    """Reset, apply the UART TX configuration, and start the memory and FIFO drivers."""
    fifo = TxFifo()
    cocotb.start_soon(Clock(dut.clk, CLOCK_PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    dut.enable.value = 0
    dut.clkdiv.value = clkdiv
    dut.wrap_top.value = 3
    dut.wrap_bottom.value = 0
    dut.sideset_count.value = 1
    dut.sideset_opt.value = 1
    dut.sideset_base.value = TX_PIN
    dut.out_base.value = TX_PIN
    dut.out_count.value = 1
    dut.shift_right.value = 1
    dut.imem_data.value = UART_TX[0]
    dut.txf_data.value = 0
    dut.txf_empty.value = 1
    dut.pins_in.value = 0
    await ClockCycles(dut.clk, 2)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1
    cocotb.start_soon(drive_imem(dut))
    cocotb.start_soon(drive_fifo(dut, fifo))
    return fifo


async def enable(dut):
    await FallingEdge(dut.clk)
    dut.enable.value = 1


async def disable(dut):
    await FallingEdge(dut.clk)
    dut.enable.value = 0


async def next_tick(dut):
    """Advance to the next cycle where tick is high, and return (state, pc, stalled)."""
    while True:
        await FallingEdge(dut.clk)
        if int(dut.u_clkdiv.tick.value):
            return (
                int(dut.u_ctrl.state.value),
                int(dut.pc.value),
                int(dut.stalled.value),
            )


async def after_tick(dut):
    """Finish the current tick and return the TX pin after the edge."""
    await RisingEdge(dut.clk)
    await ReadOnly()
    return tx_bit(dut)


def golden_trace(byte):
    """(state, pc, tx_after) for each tick of one UART byte, FIFO empty afterwards.

    State and PC are sampled during the tick. TX is the pin after that tick's edge
    """
    rows = [(EXEC, 0, 1)]
    rows += [(DELAY, 1, 1)] * 7
    rows += [(EXEC, 1, 0)]
    rows += [(DELAY, 2, 0)] * 7
    for k, bit in enumerate(bits_lsb_first(byte)):
        rows.append((EXEC, 2, bit))
        rows.append((EXEC, 3, bit))
        next_pc = 2 if k < 7 else 0
        rows += [(DELAY, next_pc, bit)] * 6
    rows.append((EXEC, 0, 1))
    return rows


@cocotb.test()
async def test_reset_idle_high(dut):
    """After reset the TX pin is high, the PC is 0, and no pin is driven."""
    await start(dut)
    await FallingEdge(dut.clk)
    await ReadOnly()
    assert tx_bit(dut) == 1
    assert int(dut.pc.value) == 0
    assert int(dut.stalled.value) == 0
    assert int(dut.pins_oe.value) == 0


@cocotb.test()
async def test_empty_fifo_stalls_high(dut):
    """Enable with an empty FIFO: PULL stalls, the PC stays at 0, and TX stays high."""
    await start(dut, clkdiv=2)
    await enable(dut)
    state, pc, stalled = await next_tick(dut)
    assert (state, pc, stalled) == (EXEC, 0, 0)
    assert await after_tick(dut) == 1
    for _ in range(5):
        state, pc, stalled = await next_tick(dut)
        assert (state, pc, stalled) == (STALL, 0, 1)
        assert await after_tick(dut) == 1
        assert int(dut.txf_pop.value) == 0


@cocotb.test()
async def test_one_byte_0x55_trace(dut):
    """Every tick of 0x55 matches the golden trace in uart-tx.md, then PULL stalls."""
    fifo = await start(dut, clkdiv=1)
    fifo.push(0x55)
    await enable(dut)

    for tick, (want_state, want_pc, want_tx) in enumerate(golden_trace(0x55)):
        state, pc, _ = await next_tick(dut)
        assert (state, pc) == (want_state, want_pc), (
            f"tick {tick}: state/pc {(state, pc)}, expected {(want_state, want_pc)}"
        )
        assert await after_tick(dut) == want_tx, f"tick {tick}: TX {tx_bit(dut)}, expected {want_tx}"

    state, pc, stalled = await next_tick(dut)
    assert (state, pc, stalled) == (STALL, 0, 1)
    assert await after_tick(dut) == 1


@cocotb.test()
async def test_patterns(dut):
    """0x00, 0xFF, and 0xA5 each produce start, eight LSB-first data bits, and stop."""
    fifo = await start(dut, clkdiv=1)
    await enable(dut)
    for byte in (0x00, 0xFF, 0xA5):
        fifo.push(byte)
        # Omit the following PULL, whose state is EXEC or STALL depending on the next push
        for tick, (want_state, want_pc, want_tx) in enumerate(golden_trace(byte)[:-1]):
            state, pc, _ = await next_tick(dut)
            assert (state, pc) == (want_state, want_pc), f"{byte:#04x} tick {tick}"
            assert await after_tick(dut) == want_tx, f"{byte:#04x} tick {tick}: TX"


@cocotb.test()
async def test_back_to_back_stop_bit(dut):
    """Two queued bytes: the second PULL is the stop bit, exactly 8 ticks, no extra gap."""
    fifo = await start(dut, clkdiv=1)
    fifo.push(0x00)
    fifo.push(0xFF)
    await enable(dut)

    for _ in golden_trace(0x00)[:-1]:
        await next_tick(dut)
        await after_tick(dut)

    # The next 8 ticks are pull side 1 [7] for the second byte: TX stays high
    for tick in range(8):
        state, pc, _ = await next_tick(dut)
        want_state = EXEC if tick == 0 else DELAY
        want_pc = 0 if tick == 0 else 1
        assert (state, pc) == (want_state, want_pc), f"stop tick {tick}"
        assert await after_tick(dut) == 1

    state, _, _ = await next_tick(dut)
    assert state == EXEC
    assert await after_tick(dut) == 0, "start bit of the second byte"


@cocotb.test()
async def test_bit_timing_clkdiv_54(dut):
    """At clkdiv = 54 each UART bit lasts exactly 432 system clocks."""
    fifo = await start(dut, clkdiv=54)
    fifo.push(0x55)
    await enable(dut)

    levels = []
    # First tick through the stop bit of the empty-FIFO PULL that follows the byte
    for _ in range(81):
        await next_tick(dut)
        levels.append(await after_tick(dut))

    runs = []
    value = levels[0]
    length = 1
    for bit in levels[1:]:
        if bit == value:
            length += 1
        else:
            runs.append((value, length))
            value, length = bit, 1
    runs.append((value, length))

    want = [(1, 8), (0, 8)] + [(b, 8) for b in bits_lsb_first(0x55)] + [(1, 1)]
    assert runs == want, f"tick runs {runs}, expected {want}"


@cocotb.test()
async def test_disable_holds_and_drops_delay(dut):
    """Disable mid-delay holds pins and PC. Re-enable starts EXEC at that PC, delay dropped."""
    fifo = await start(dut, clkdiv=2)
    fifo.push(0x55)
    await enable(dut)

    # Run through pull and into the start-bit delay, where PC already shows the OUT
    while True:
        state, pc, _ = await next_tick(dut)
        tx = await after_tick(dut)
        if state == DELAY and pc == 2:
            break

    await disable(dut)
    await ClockCycles(dut.clk, 5)
    await FallingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.pc.value) == 2
    assert tx_bit(dut) == tx
    assert int(dut.u_ctrl.state.value) == 0
    assert int(dut.u_clkdiv.tick.value) == 0

    await enable(dut)
    state, pc, _ = await next_tick(dut)
    assert (state, pc) == (EXEC, 2), "re-enable must execute the instruction left in the PC"
    assert await after_tick(dut) == 1, "first data bit of 0x55, with the rest of the start bit dropped"
