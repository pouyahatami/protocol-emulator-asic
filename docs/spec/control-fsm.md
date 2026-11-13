# SM module and control FSM

- Status: Accepted.
- Written: 2026-10-24. Accepted: 2026-10-25.
- Scope: one SM, the subset needed for UART TX.
- Related: the UART TX program, SM requirements, ADR-001 (SM count), and the RP2040 PIO note in
  [`protocol-emulator-research`](https://github.com/pouyahatami/protocol-emulator-research).
  The SM module and control FSM diagrams live there too.
- RTL: [`src/pio/pio_sm_ctrl.sv`](../../src/pio/pio_sm_ctrl.sv) implements the control FSM,
  [`src/pio/pio_sm_clkdiv.sv`](../../src/pio/pio_sm_clkdiv.sv) the clock divider,
  [`src/pio/pio_sm_pc.sv`](../../src/pio/pio_sm_pc.sv) the PC and `next_pc`,
  [`src/pio/pio_sm_decode.sv`](../../src/pio/pio_sm_decode.sv) the decoder,
  [`src/pio/pio_sm_delay.sv`](../../src/pio/pio_sm_delay.sv) the delay counter,
  [`src/pio/pio_sm_scratch.sv`](../../src/pio/pio_sm_scratch.sv) the X and Y registers,
  [`src/pio/pio_sm_osr.sv`](../../src/pio/pio_sm_osr.sv) the OSR,
  [`src/pio/pio_sm_pins.sv`](../../src/pio/pio_sm_pins.sv) the pin outputs, and
  [`src/pio/pio_sm.sv`](../../src/pio/pio_sm.sv) the SM wrapper.

Raspberry Pi does not publish PIO's internal FSM. This design reconstructs the behavior the
datasheet describes: one instruction per tick, stalls, delays, side-set, and wrap.

## Conventions

- One clock domain. Every register updates on the rising edge of `clk`.
- Signals are active high, except `rst_n`.
- **Registered** means the signal is a flop output and is stable for the whole cycle.
  **Combinational** means it is computed from registers and inputs within the same cycle.
- Configuration inputs must not change while `enable = 1`. Behavior is undefined if they do.
- A **tick** is one SM step. With `clkdiv = 54`, one tick happens every 54 clocks.

## SM module

The SM module (`pio_sm`) contains the clock divider, decoder, stall check, control FSM, delay
counter, PC logic, and datapath. The instruction memory, FIFOs, and pin mux sit outside the
module and connect through its ports.

### Ports: clock, reset, control

| Port | Dir | Width | Type | Meaning |
|---|---|---|---|---|
| `clk` | in | 1 | Clock | System clock, 50 MHz. |
| `rst_n` | in | 1 | Level, active low | Reset. Already synchronized at the top level. While 0, every register takes its reset value. |
| `enable` | in | 1 | Level | 1 = run, 0 = stop. Takes effect on the next clock, not the next tick. |

### Ports: configuration

All static while `enable = 1`.

| Port | Dir | Width | Range | Meaning |
|---|---|---|---|---|
| `clkdiv` | in | 16 | 0–65535 | Clocks per tick. 0 and 1 both mean a tick every clock. |
| `wrap_top` | in | 5 | 0–31 | After the instruction at this address, PC goes to `wrap_bottom` unless a jump is taken. |
| `wrap_bottom` | in | 5 | 0–31 | Wrap target. |
| `sideset_count` | in | 3 | 0–5 | Number of side-set pins. |
| `sideset_opt` | in | 1 | 0–1 | 1 = side-set is optional. The top bit of the delay/side field then says whether this instruction uses it. |
| `sideset_base` | in | 5 | 0–23 | First side-set pin. Side-set pin i is `sideset_base + i`. |
| `out_base` | in | 5 | 0–23 | First OUT pin. |
| `out_count` | in | 4 | 0–8 | Number of OUT pins. |
| `shift_right` | in | 1 | 0–1 | 1 = OSR shifts right, so `OUT` sends the LSB first. |

`sideset_count + sideset_opt` must be at most 5.

### Ports: instruction memory

| Port | Dir | Width | Type | Meaning |
|---|---|---|---|---|
| `imem_addr` | out | 5 | Registered (= PC) | Address of the current instruction. |
| `imem_data` | in | 16 | Combinational | Instruction at `imem_addr`, valid in the same cycle. |

> **Open issue: fetch with synchronous SRAM.** This interface assumes `imem_data` is valid in
> the same cycle as `imem_addr`. The SRAM in
> [ASIC PR #1](https://github.com/pouyahatami/protocol-emulator-asic/pull/1) returns data one
> clock later. At `clkdiv >= 2` this is harmless, because the new instruction is valid before
> the next tick. At `clkdiv <= 1`, each tick would execute the previous instruction. Options,
> undecided: (1) address the SRAM with `pc_advance ? next_pc : pc`, which adds no latency but
> must meet 20 ns from SRAM clock-to-Q to address setup; (2) require `clkdiv >= 2`.

### Ports: TX FIFO

| Port | Dir | Width | Type | Meaning |
|---|---|---|---|---|
| `txf_data` | in | 8 | From the FIFO | Oldest byte in the FIFO. Valid only when `txf_empty = 0`. |
| `txf_empty` | in | 1 | From the FIFO | 1 = nothing to send. |
| `txf_pop` | out | 1 | Combinational, one-cycle pulse | Remove the oldest byte at this clock edge. `txf_pop = commit && is_pull`. |

### Ports: pins and status

| Port | Dir | Width | Type | Meaning |
|---|---|---|---|---|
| `pins_in` | in | 24 | Synchronized | Pin levels after the top level's 2-flop synchronizers, so 2 clocks old. Unused by UART TX. |
| `pins_out` | out | 24 | Registered | Value this SM wants on each pin. Reset: all 1, so UART TX idles high. |
| `pins_oe` | out | 24 | Registered | 1 = this SM drives the pin. Reset: all 0. Only matters on the 8 bidirectional pins. |
| `stalled` | out | 1 | From state register | 1 while the FSM is in STALL. |
| `pc` | out | 5 | Registered | Current PC, for the host and tests. Same as `imem_addr`. |

The pin buses cover all 24 Tiny Tapeout pins. The top-level pin mux decides which SM drives
each pin. RX ports (`rxf_data`, `rxf_push`, `rxf_full`) come with UART RX.

### Internal signals

**Clock divider**

| Signal | Width | Type | Meaning |
|---|---|---|---|
| `div_cnt` | 16 | Register | Counts clocks within a tick. Held at 0 while `enable = 0` or `active = 0`. |
| `tick` | 1 | Combinational | `enable && active && (clkdiv <= 1 \|\| div_cnt == clkdiv - 1)`. `div_cnt` returns to 0 on a tick. |

`active` comes from the control FSM and is 0 only in DISABLED, so the divider starts counting
on the first clock in EXEC. The first tick therefore falls on the `max(clkdiv, 1)`-th clock
in EXEC, for every value of `clkdiv`.

**Decoder.** Combinational from `imem_data`.

| Signal | Width | Bits | Meaning |
|---|---|---|---|
| `op` | 3 | `[15:13]` | Opcode: `000` JMP, `011` OUT, `100` PUSH/PULL, `111` SET. |
| `ds_field` | 5 | `[12:8]` | Delay/side-set field. |
| `args` | 8 | `[7:0]` | Opcode-specific arguments. |
| `side_en` | 1 | From `ds_field` | This instruction drives side-set. `ds_field[4]` if `sideset_opt`, else `sideset_count > 0`. |
| `side_val` | 0–5 | From `ds_field` | Side-set value: the `sideset_count` bits below the opt bit. |
| `delay_val` | 0–5 | From `ds_field` | The low `5 − sideset_count − sideset_opt` bits. |
| `jmp_cond` | 3 | `args[7:5]` | `000` always, `010` X-- (jump if X ≠ 0). |
| `jmp_addr` | 5 | `args[4:0]` | Jump target. |
| `set_dest` | 3 | `args[7:5]` | `001` X, `010` Y, `000` pins. |
| `set_data` | 5 | `args[4:0]` | Immediate value. |
| `out_dest` | 3 | `args[7:5]` | `000` pins. |
| `out_bits` | 5 | `args[4:0]` | Bits to shift out, 1–8. Larger values are undecided. |
| `is_pull` | 1 | `op == 100 && args[7]` | Instruction is `PULL`. |
| `block` | 1 | `args[5]` | Blocking `PULL`. Non-blocking is not in v0. |

With UART TX settings (`sideset_opt = 1`, `sideset_count = 1`): `ds_field[4]` is `side_en`,
`ds_field[3]` is `side_val`, and `ds_field[2:0]` is `delay_val`.

**Stall check, delay counter, PC**

| Signal | Width | Type | Meaning |
|---|---|---|---|
| `stall` | 1 | Combinational | `is_pull && block && txf_empty` for UART TX. |
| `delay_cnt` | 5 | Register | Delay ticks left. Reset 0. |
| `delay_last` | 1 | Combinational | `delay_cnt == 1`. |
| `pc` | 5 | Register | Reset 0. ← `next_pc` when `pc_advance = 1`, else holds. |
| `jump_taken` | 1 | Combinational | `op == JMP` and the condition holds, tested on X before decrementing. |
| `next_pc` | 5 | Combinational | `jmp_addr` if `jump_taken`. Else `wrap_bottom` if `pc == wrap_top`. Else `pc + 1`. |

**Datapath registers.** Written only when `commit = 1`, except side-set.

| Register | Width | Reset | Written by |
|---|---|---|---|
| `osr` | 8 | 0 | `PULL`: ← `txf_data`. `OUT`, any destination: shifted by `out_bits` in the `shift_right` direction, filling with zeros. |
| `osr_count` | 4 | 0 | `PULL`: ← 0. `OUT`: += `out_bits`, saturating at 8. |
| `x` | 8 | 0 | `SET X`: ← `set_data`. `JMP X--`: ← `x − 1`, every time it commits. |
| `y` | 8 | 0 | `SET Y`. Unused by UART TX. |
| `pins_out` | 24 | All 1 | `OUT PINS`: pin `out_base + i` ← `out_data[i]`. Side-set: pin `sideset_base + i` ← `side_val[i]` when `sideset_en && side_en`. Side-set wins if both hit one pin. |

`out_data` is the `out_bits` bits an `OUT` shifts out, taken from the OSR before the shift and
right-aligned: the low bits when `shift_right = 1`, the high bits when `shift_right = 0`. This
matches RP2040, where a left shift sends the MSB first.

Pin rules, following RP2040:

- `OUT PINS` always writes `out_count` pins. `out_data` is 0 above `out_bits`, so pins past
  `out_bits` are driven low.
- Pin numbers `out_base + i` and `sideset_base + i` wrap modulo 32. Pins 24 to 31 do not exist,
  so writes to them are dropped.
- Side-set needs only `sideset_en && side_en`, not `commit`, so it also applies on stalled ticks.
- `pins_oe` stays 0, because no v0 instruction writes pin directions.
- `SET PINS` is not supported yet. It needs its own base and count configuration, which this
  spec does not define.

## Control FSM

A Mealy machine: outputs depend on the current state and inputs in the same cycle, and
registers update on the next rising edge.

The two `enable` transitions act on the next clock. Every other transition needs `tick = 1`.
Without a tick, the FSM and all registers hold.

### States

| State | Encoding | Meaning |
|---|---|---|
| DISABLED | `2'b00` | Reset state. PC, registers, and pins hold. |
| EXEC | `2'b01` | Executing the instruction at PC. |
| STALL | `2'b10` | Waiting for a stall condition to clear. PC held. |
| DELAY | `2'b11` | Idling after an instruction. PC already points at the next one. |

`state` is a 2-bit register with reset DISABLED. EXEC and STALL have identical transitions and
outputs, and STALL exists only to drive `stalled`. In RTL they can merge into one state plus a
flag.

### Inputs

| Signal | Width | From | Type | Meaning |
|---|---|---|---|---|
| `enable` | 1 | Host control register | Level | 1 = run. 0 forces DISABLED on the next clock, from any state. |
| `tick` | 1 | Clock divider | Combinational, one-cycle pulse | The SM may take one step this cycle. |
| `stall` | 1 | Stall check | Combinational | The instruction at PC can't complete this tick. Only read in EXEC and STALL. |
| `delay_val` | 5 | Decoder | Combinational | Delay ticks to add after this instruction. 0 = none. Only read in EXEC and STALL. |
| `delay_last` | 1 | Delay counter | Combinational | This is the last delay tick. Only read in DELAY. |

`side_en` goes from the decoder straight to the pin logic, gated by `sideset_en`. The FSM
doesn't read it.

Terms added to `stall` later:

| Term | Needed by |
|---|---|
| `op == WAIT && !wait_cond` | UART RX |
| `op == PUSH && block && rxf_full` | UART RX |
| `op == OUT && autopull && osr_empty && txf_empty` | Autopull, if adopted |

### Outputs

The five strobes are combinational, last one cycle, and are 0 unless `tick = 1`. `stalled` and
`active` decode the state register and are not gated by `tick`.

| Signal | Width | To | Meaning |
|---|---|---|---|
| `commit` | 1 | Datapath, FIFO | The instruction executes at this edge: OSR, X, Y, and pins written, FIFO popped for `PULL`. |
| `pc_advance` | 1 | PC register | PC ← `next_pc` at this edge. |
| `sideset_en` | 1 | Pin output | Side-set may be applied at this edge, if the instruction has it (`side_en`). Also 1 while stalled. |
| `delay_load` | 1 | Delay counter | `delay_cnt` ← `delay_val`. |
| `delay_dec` | 1 | Delay counter | `delay_cnt` ← `delay_cnt − 1`. |
| `stalled` | 1 | Port `stalled` | `state == STALL`. |
| `active` | 1 | Clock divider | `state != DISABLED`. Gates the divider, so no tick is generated in DISABLED. |

### Transitions

Rows are in priority order. The first match wins.

| From | Condition | To | Outputs |
|---|---|---|---|
| any | `!enable` | DISABLED | none |
| DISABLED | `enable` | EXEC | none |
| any | `!tick` | same | none |
| EXEC or STALL | `stall` | STALL | `sideset_en` |
| EXEC or STALL | `!stall && delay_val == 0` | EXEC | `commit`, `pc_advance`, `sideset_en` |
| EXEC or STALL | `!stall && delay_val > 0` | DELAY | `commit`, `pc_advance`, `sideset_en`, `delay_load` |
| DELAY | `!delay_last` | DELAY | `delay_dec` |
| DELAY | `delay_last` | EXEC | `delay_dec` |

## Decisions

These all affect the golden trace.

1. **PC advances on commit, not when the delay ends.** No register is needed for a pending jump
   target. During a delay, PC already shows the next instruction.
2. **Disabling during a delay drops the rest of the delay.** Re-enable starts in EXEC at the
   current PC. Resuming the delay would need the counter preserved and a flag.
3. **Host forced instruction or start-PC register.** Undecided. A forced instruction adds one
   input path into EXEC.
4. **`enable` acts on the next clock, not the next tick.** The divider is held in DISABLED, so
   the FSM would otherwise never get a tick to leave it. The divider starts counting on the first
   clock in EXEC, and the first instruction executes on the `max(clkdiv, 1)`-th clock in EXEC.
5. **All `pins_out` reset to 1.** Simplest choice that keeps UART idle high. SPI and I2C programs
   set their own levels on the first tick.
