# pio_sm_delay formal properties

- Status: Assumption A1 and covers C1 and C2 in the harness. No assertions yet.
- Module: [`src/pio/pio_sm_delay.sv`](../../src/pio/pio_sm_delay.sv)
- Harness: [`pio_sm_delay_formal.sv`](pio_sm_delay_formal.sv), [`pio_sm_delay.sby`](pio_sm_delay.sby)
- Spec: [`docs/spec/control-fsm.md`](../../docs/spec/control-fsm.md), "Stall check, delay
  counter, PC" and "Outputs"

## Assumptions

An assumption limits the free inputs to values the real driver can produce. Each assumption
must be proven as an assertion in the driver's harness.

| ID | Assumption | Proven by |
|---|---|---|
| A1 | `!(delay_load && delay_dec)` on every cycle. | [`pio_sm_ctrl` P4](pio_sm_ctrl_properties.md) |

The counter gives `delay_load` priority over `delay_dec` in its `if / else if` order. A1 states
that the priority is never used, so the counter's behavior is defined only for one strobe at a
time.

## Planned assumption

The module header also states that the control FSM only decrements while `delay_cnt >= 1`. A
decrement at 0 would wrap the count to 31 and keep `delay_last = 0` for 31 more ticks.

| ID | Assumption | Proof needed |
|---|---|---|
| A2 | `!delay_dec \|\| delay_cnt != 0` | An assertion in a `pio_sm` harness, which sees both the FSM state and the count. Not yet written. |

A2 cannot be proven in `pio_sm_ctrl` alone, because that module does not see `delay_cnt`.

## Cover statements

| ID | Cover target | Purpose |
|---|---|---|
| C1 | A load of `delay_val = 1` gives `delay_last = 1` on the next cycle. | Shows A1 still allows loads. |
| C2 | A decrement gives `delay_last = 1` on the next cycle. | Shows A1 still allows a load followed by decrements. |

The covers read only module ports. A hierarchical reference such as `dut.delay_cnt` is not
resolved by Yosys and becomes an undriven wire, which the solver may set to any value.

Run from `test/formal` in WSL, as described in [how-to-verify.md](how-to-verify.md):

```sh
sby -f pio_sm_delay.sby
```

Result on 2026-11-11: `pio_sm_delay_cover` reached C1 and C2.
