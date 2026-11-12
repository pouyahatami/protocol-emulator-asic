# How to verify a module with formal properties

This document describes how a formal property is written, where it is placed, and how it is run
in this repository. The worked example is the rule that `delay_load` and `delay_dec` are never
asserted together.

## Formal checking compared with simulation

A simulation test drives one chosen input sequence and checks the outputs. A formal tool treats
every unconstrained input as free: on each cycle it may take any value. The solver searches all
input sequences for one that breaks a property. A pass is a statement about every sequence, not
only the ones a testbench drives.

## Statement types

| Statement | Meaning to the solver | Failure means |
|---|---|---|
| `assert (p)` | `p` must hold on every reachable cycle. The solver searches for a counterexample. | The design can violate `p`. The solver writes a trace. |
| `assume (p)` | Only consider input sequences where `p` holds. | Not applicable. An assumption removes cases. It is never checked. |
| `cover (p)` | Find at least one trace that reaches `p`. | `p` is unreachable. The assumptions may be too strict. |

An assumption is a claim about the environment that the solver accepts without proof. A wrong
assumption can hide a real bug, so every assumption needs a matching proof elsewhere.

## Assert at the driver, assume at the receiver

An interface rule between two modules involves a driver, which produces the signals, and a
receiver, which depends on them.

The usual pattern is to assert at the driver and assume at the receiver. Start with the `assert`
in the driver, because that is the claim to prove. For the delay strobes, the driver is
`pio_sm_ctrl.sv` and the receiver is `pio_sm_delay.sv`.

1. **Assert at the driver.** The `pio_sm_ctrl` harness asserts `!(delay_load && delay_dec)` as
   P4. The solver proves the FSM never produces both strobes.
2. **Assume at the receiver.** The `pio_sm_delay` harness assumes the same expression as A1.
   The solver checks the counter only for inputs the FSM can produce.
3. **Link the two in the documentation.** The receiver's assumption table names the driver
   property that proves it. An assumption without a linked proof is an open item.

Only add the assumption after the driver's assertion passes. If the assertion fails, the
assumption describes inputs the real driver does not respect.

## Files for one module

Each harness lives in `test/formal`. The RTL under `src/` is not changed.

| File | Contents |
|---|---|
| `<module>_formal.sv` | Wrapper module. Instantiates the module, leaves its inputs free, and holds the `assume`, `assert`, and `cover` statements. |
| `<module>.sby` | SymbiYosys job file. Lists the tasks, source files, engine, and depth. |
| `<module>_properties.md` | Table of properties, assumptions, and covers, each with an ID and a spec reference. |

## Writing the wrapper

1. Declare every input of the module as an input of the wrapper. The solver drives the wrapper's
   inputs freely.
2. Add `initial assume (!rst_n);` so the first cycle is a reset cycle.
3. Write combinational properties in `always @(*)`. Write properties that compare cycles in
   `always @(posedge clk)` with `$past()`, gated by an `f_past_valid` register that is 0 on the
   first cycle.
4. Add one `cover` for each case the assertions depend on. A property that is never exercised
   passes without checking anything.
5. Use only ports and wrapper signals in properties. Yosys does not resolve a hierarchical
   reference such as `dut.delay_cnt`. It creates an undriven wire, which the solver may set to
   any value, and the log shows a warning that the identifier is implicitly declared.

## Proof modes

| Mode | Result | Limit |
|---|---|---|
| `bmc` | No counterexample within `depth` cycles from reset. | Says nothing about cycles after `depth`. |
| `prove` | k-induction. A pass holds for every cycle. | Induction may fail on an unreachable state. Add a helper assertion that excludes it. |
| `cover` | A trace reaching each `cover`. | Only shows reachability. |

Use `prove` when the property can be proven by induction, and `bmc` when a pass within a fixed
depth is enough.

## Running a job

SymbiYosys and Yosys are installed with OSS CAD Suite in WSL. From a WSL shell:

```sh
source ~/oss-cad-suite/environment
cd /mnt/c/Projects/protocol-emulator/protocol-emulator-asic/test/formal
sby -f pio_sm_ctrl.sby
```

Each task writes a directory named `<module>_<task>`. The last lines of the log give the result:

- `DONE (PASS, rc=0)` means every assertion held, or every cover was reached.
- `DONE (FAIL, rc=2)` means an assertion failed or a cover was not reached. The counterexample
  is in `<module>_<task>/engine_0/trace.vcd`. Open it in GTKWave.
- Read every `Warning` line. A warning about an implicit or undriven wire usually means a
  property reads a signal the solver does not see.

## Checking that an assertion can fail

A passing assertion is only useful if it would fail on a broken design. To check this, copy the
module, break the rule on purpose (for example, also assert `delay_dec` in the EXEC branch),
point the `.sby` file at the copy, and run it. The `prove` task must fail and produce a trace.
Then restore the original file reference.
