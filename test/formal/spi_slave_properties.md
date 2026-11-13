# spi_slave formal properties

- Status: P1 and P2 pass a bounded check of 48 cycles. Covers C1 and C2 are reached. No
  property is proven for every cycle yet.
- Module: [`src/spi_slave.sv`](../../src/spi_slave.sv), with
  [`src/sync_2ff.sv`](../../src/sync_2ff.sv)
- Harness: [`spi_slave_formal.sv`](spi_slave_formal.sv), [`spi_slave.sby`](spi_slave.sby)
- Spec: no specification document yet. The required behavior is taken from the comments in
  `src/spi_slave.sv`.

## Assumptions

None, apart from reset on the first cycle. `sclk`, `cs_n`, `mosi`, `tx_word`, and `tx_load` are
free on every cycle. The `sclk <= clk/16` limit from ADR-003 is not assumed, so P1 and P2 hold
for any pin sequence, including `sclk` toggling on every clock.

## Wrapper signals

Yosys does not resolve a hierarchical reference such as `dut.bit_cnt_q`, so the wrapper keeps its
own copies of the signals the properties need.

| Signal | Definition |
|---|---|
| `f_sclk_rise` | The `sclk` pin through two flip-flops, compared with its value one cycle earlier, and gated by `cs_asserted`. It matches `dut.sclk_rise` on every cycle after the first clock edge. |
| `f_edges_q` | `f_sclk_rise` pulses since `cs_asserted` was last 0 or since the last `word_ready`. Cleared by reset and while `cs_asserted = 0`. |
| `f_partial_q` | Set when `cs_asserted = 0` while `f_edges_q` is between 1 and 15, meaning a word was cut short. Cleared only by reset. |

## Properties

Each property applies after the first clock edge.

| ID | Condition | Required result | Source |
|---|---|---|---|
| P1 | `word_ready` | `f_edges_q == 16`. | `bit_cnt_q` comment: a partial word is discarded when chip select is deasserted |
| P2 | `cs_asserted = 0` on the previous cycle | `miso == 0`. | `tx_shift_q` comment: outside a transfer, `miso` idles at 0 |

P1 states that a word completes only after 16 rising edges counted from a clean start. Edges
counted before chip select was deasserted are cleared from `f_edges_q`, so a partial word
followed by fewer than 16 new edges fails P1. The count also restarts after each `word_ready`, so
P1 checks every word in a transfer, not only the first.

P2 uses the previous cycle because `tx_shift_q` is a register. On the first cycle with
`cs_asserted = 0`, `miso` still shows the old register value, and it reads 0 one cycle later.

## Cover statements

| ID | Cover target | Purpose | Reached |
|---|---|---|---|
| C1 | `f_partial_q && word_ready` | Shows P1 is checked on a word that follows a discarded partial word. | Step 36 |
| C2 | `miso` was 1 on the cycle chip select was deasserted | Shows P2 is checked on a cycle where `miso` must change from 1 to 0. | Step 6 |

Both covers ignore the first cycle. Before the first reset edge, the registers hold arbitrary
values, and a cover reached there does not show a real sequence.

## Proof mode and depth

The job uses `bmc` with a depth of 48 cycles, not `prove`. In k-induction, the solver may start
from any state, including one where `f_edges_q` and `dut.bit_cnt_q` disagree. The wrapper cannot
state that the two counts agree without reading `bit_cnt_q`, so the induction step fails even
though the design is correct.

The shortest trace that reaches C1 has 36 steps: reset, the synchronizer delay, one partial
edge, chip select deasserted and asserted again, and 16 edges. The depth of 48 leaves margin
above that trace. A pass says nothing about cycles after step 48.

## Checking that the assertions can fail

Each assertion was run against a copy of `spi_slave.sv` with one rule removed on purpose, as
described in `how-to-verify.md` on the `add-formal-verification` branch:

| Change to the copy | Result |
|---|---|
| Remove the `!cs_asserted` clear of `bit_cnt_q` | P1 fails at step 34. |
| Remove the `!cs_asserted` clear of `tx_shift_q` | P2 fails at step 3. |

## Planned properties

| ID | Required result | Note |
|---|---|---|
| P3 | `f_edges_q == 16` implies `word_ready`: no word is missed. | The converse of P1. |
| P4 | `rx_word` equals the last 16 `mosi` bits sampled on rising edges, MSB first. | Needs a wrapper copy of the `mosi` synchronizer and a 16-bit shift register. |
| P5 | After `tx_load`, `miso` gives `tx_word` MSB first on falling edges 1 to 15. | Includes the rule that the 16th falling edge does not shift. |
| P6 | `!cs_asserted` on the previous cycle implies `bit_cnt_q == 0`. | Reads an internal register, so it needs a way to reach it from the harness. P1 checks its effect at the ports. |

## Running the job

From `test/formal` in WSL:

```sh
source ~/oss-cad-suite/environment
sby -f spi_slave.sby
```

The `bmc` and `cover` tasks write `spi_slave_bmc/` and `spi_slave_cover/`. Each must end with
`DONE (PASS, rc=0)`.

Result on 2026-11-13 with Yosys 0.70+360: `spi_slave_bmc` passed to depth 48, and
`spi_slave_cover` reached C1 at step 36 and C2 at step 6.
