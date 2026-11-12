# pio_sm_ctrl formal properties

- Status: P4 proven by k-induction. P1 to P3 are planned and not yet in the harness.
- Module: [`src/pio/pio_sm_ctrl.sv`](../../src/pio/pio_sm_ctrl.sv)
- Harness: [`pio_sm_ctrl_formal.sv`](pio_sm_ctrl_formal.sv), [`pio_sm_ctrl.sby`](pio_sm_ctrl.sby)
- Spec: [`docs/spec/control-fsm.md`](../../docs/spec/control-fsm.md), "Transitions"

Each property applies on a clock edge where `rst_n = 1`, unless its row says otherwise.
`state_next` is the value `state` takes at that edge.

| ID | Condition | Required result | Spec row |
|---|---|---|---|
| P1 | `!enable` | `state_next == DISABLED`, from every state. | any, `!enable` |
| P2 | `enable && !tick && state != DISABLED` | `state_next == state`. | any, `!tick` |
| P3 | Every clock | `sideset_en == (enable && tick && (state == EXEC \|\| state == STALL))`. Draft, not yet reviewed. | EXEC or STALL rows, Outputs |
| P4 | Every cycle, in every state, including reset | `!(delay_load && delay_dec)`. | EXEC or STALL to DELAY, DELAY rows |

P2 excludes DISABLED because DISABLED moves to EXEC when `enable = 1` without waiting for a
tick. The divider generates no tick while the FSM is in DISABLED.

P4 is the driver side of an interface rule. [`pio_sm_delay`](pio_sm_delay_properties.md)
assumes the same rule as A1, so the counter's checks rely on this proof. `delay_load` is only
asserted in the EXEC or STALL branch and `delay_dec` only in the DELAY branch, so the property
holds for every value of the state register, not only for reachable states.

| ID | Cover target | Purpose |
|---|---|---|
| C1 | `delay_load` | Shows P4 is checked on cycles where `delay_load = 1`. |
| C2 | `delay_dec` | Shows P4 is checked on cycles where `delay_dec = 1`. |

Run from `test/formal` in WSL, as described in [how-to-verify.md](how-to-verify.md):

```sh
sby -f pio_sm_ctrl.sby
```

Result on 2026-11-11: `pio_sm_ctrl_prove` passed basecase and induction, and
`pio_sm_ctrl_cover` reached C1 and C2.

## pio_sm_clkdiv

These properties belong to [`src/pio/pio_sm_clkdiv.sv`](../../src/pio/pio_sm_clkdiv.sv), which
generates the `tick` that P2 depends on. Spec section: "Clock divider".

| ID | Condition | Required result | Spec reference |
|---|---|---|---|
| D1 | `tick` | `enable == 1` and `active == 1`. | `tick` definition |
| D2 | `enable && active` stays 1, and `clkdiv` stays constant | No run of `max(clkdiv, 1)` consecutive clocks passes without a tick. | `tick` definition, Decision 4 |

D2 needs either k-induction or an assumption that limits `clkdiv`. A bounded check of depth 20,
as in the OSR harness, cannot reach a tick period of up to 65535 clocks.
