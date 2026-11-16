# pio_sm_ctrl formal properties

- Status: P1 to P19 proven by k-induction. Together they cover every row of the transition
  table, for both the next state and the outputs.
- Module: [`src/pio/pio_sm_ctrl.sv`](../../src/pio/pio_sm_ctrl.sv)
- Harness: [`pio_sm_ctrl_formal.sv`](pio_sm_ctrl_formal.sv), [`pio_sm_ctrl.sby`](pio_sm_ctrl.sby)
- Spec: [`docs/spec/control-fsm.md`](../../docs/spec/control-fsm.md), "Transitions" and
  "Outputs"

The harness reads the state only through `stalled`, `active`, and `on_instr`, which decode all
four states: DISABLED is `!active`, EXEC is `on_instr && !stalled`, STALL is `stalled`, and
DELAY is `active && !on_instr`. The properties therefore check the module at its ports.

The properties are concurrent SVA, read by the yosys-slang plugin. The open-source flow has no
`|->` or `|=>`, so each "if A then B" is written `!A || B`, and a next-cycle check compares the
current cycle with `$past`.

## Assumptions

| ID | Assumption | Reason |
|---|---|---|
| A1 | `rst_n = 0` on the first cycle. | Power-up starts in reset. |

## Next state

Each property applies to a clock edge, and its result is the state after that edge. A tick
means `enable && tick` in EXEC, STALL, or DELAY.

| ID | Condition on the previous cycle | Required state | Spec row |
|---|---|---|---|
| P5 | `!rst_n` | DISABLED | Reset |
| P1 | `rst_n && !enable` | DISABLED | any, `!enable` |
| P6 | `rst_n && enable`, in DISABLED | EXEC | DISABLED, `enable` |
| P2 | `rst_n && enable && !tick`, not in DISABLED | Unchanged | any, `!tick` |
| P7 | A tick in DELAY with `!delay_last` | DELAY | DELAY, `!delay_last` |
| P8 | A tick in DELAY with `delay_last` | EXEC | DELAY, `delay_last` |
| P9 | A tick in EXEC or STALL with `unsup_instr` | EXEC | EXEC or STALL, `unsup_instr` |
| P10 | A tick in EXEC or STALL with `stall`, and no `unsup_instr` | STALL | EXEC or STALL, `stall` |
| P11 | A commit with `delay_val == 0` | EXEC | EXEC or STALL, `delay_val == 0` |
| P12 | A commit with `delay_val > 0` | DELAY | EXEC or STALL, `delay_val > 0` |

P2 excludes DISABLED because DISABLED moves to EXEC when `enable = 1` without waiting for a
tick. The divider generates no tick while the FSM is in DISABLED.

## Outputs

These hold on every cycle. The rows are in the spec's priority order: no tick or DISABLED,
then DELAY, then `unsup_instr`, then `stall`, then commit.

| ID | Condition | Required outputs | Spec row |
|---|---|---|---|
| P15 | `!enable`, `!tick`, or DISABLED | No strobe | any, `!enable` and `!tick` |
| P16 | A tick in DELAY | `delay_dec` only | DELAY rows |
| P17 | A tick in EXEC or STALL with `unsup_instr` | No strobe | EXEC or STALL, `unsup_instr` |
| P18 | A tick in EXEC or STALL with `stall` | `sideset_en` only | EXEC or STALL, `stall` |
| P19 | A commit | `commit`, `pc_advance`, `sideset_en`, and `delay_load` exactly when `delay_val > 0` | EXEC or STALL, `!stall` rows |
| P3 | Every cycle | `sideset_en == (enable && tick && (EXEC or STALL) && !unsup_instr)` | Outputs, Decision 6 |
| P4 | Every cycle, in every state, including reset | `!(delay_load && delay_dec)` | EXEC or STALL to DELAY, DELAY rows |
| P13 | Every cycle | `stalled` implies `on_instr` | States |
| P14 | Every cycle | `on_instr` implies `active` | States |

P4 is the driver side of an interface rule. [`pio_sm_delay`](pio_sm_delay_properties.md)
assumes the same rule as A1, so the counter's checks rely on this proof. P4 has no reset guard,
so it holds for every value of the state register, not only for reachable states.

P3 follows from P15 to P19. It stays as its own row because it states the side-set rule in one
place, and Decision 6 says an unsupported instruction does not side-set.

## Cover statements

| ID | Cover target | Purpose |
|---|---|---|
| C1 | `delay_load` | Shows P4 is checked on cycles where `delay_load = 1`. |
| C2 | `delay_dec` | Shows P4 is checked on cycles where `delay_dec = 1`. |
| C3 | STALL held for two cycles | Shows P10 and P18 are exercised. |
| C4 | A commit from STALL | Shows a stall can clear. |
| C5 | DELAY held for two cycles | Shows P7 is exercised. |
| C6 | EXEC after DELAY | Shows P8 is exercised. |
| C7 | EXEC held by an unsupported instruction | Shows P9 and P17 are exercised. |
| C8 | DISABLED after DELAY | Shows P1 acts from DELAY. |
| C9 | DISABLED after STALL | Shows P1 acts from STALL. |

Run from `test/formal`, as described in [how-to-verify.md](how-to-verify.md):

```sh
sby -f pio_sm_ctrl.sby
```

Result on 2026-11-16: `pio_sm_ctrl_prove` passed basecase and induction, and
`pio_sm_ctrl_cover` reached C1 to C9. Ten copies of the module, each with one rule broken by
hand, all failed `pio_sm_ctrl_prove`, each on the property for the broken rule.

## pio_sm_clkdiv

These properties belong to [`src/pio/pio_sm_clkdiv.sv`](../../src/pio/pio_sm_clkdiv.sv), which
generates the `tick` that P2 depends on. Spec section: "Clock divider".

| ID | Condition | Required result | Spec reference |
|---|---|---|---|
| D1 | `tick` | `enable == 1` and `active == 1`. | `tick` definition |
| D2 | `enable && active` stays 1, and `clkdiv` stays constant | No run of `max(clkdiv, 1)` consecutive clocks passes without a tick. | `tick` definition, Decision 4 |

D2 needs either k-induction or an assumption that limits `clkdiv`. A bounded check of depth 20,
as in the OSR harness, cannot reach a tick period of up to 65535 clocks.
