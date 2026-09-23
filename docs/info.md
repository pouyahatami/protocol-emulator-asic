## How it works

This project will implement a firmware-programmable engine for deterministic pin input/output. The architecture and instruction set are currently under evaluation.

The checked-in design is a Stage-0 placeholder. It carries no protocol logic. On every rising clock edge it samples the two input buses, combines them as `ui_in ^ uio_in`, and presents the result on the dedicated outputs one clock later. The reset is synchronous and active low: while `rst_n` is low the captured value returns to zero on the next rising edge. While `ena` is low the captured value is held rather than updated. The bidirectional bus is an input at all times, because no protocol owns it yet: `uio_oe` is held low and `uio_out` is tied low.

The combining logic is deliberate scaffolding rather than intended behavior. An inert design that tied all outputs low and read none of its inputs was optimised away during synthesis, which left all nineteen input pins unconnected and caused LibreLane's disconnected-pin checker to abort the GDS build. Folding both input buses into one registered value is the cheapest construct that keeps every input pin physically connected and the flow passing. Expect this block to be replaced in full once the Stage-1 datapath and its pin interface are accepted; nothing here should be read as a committed pin assignment.

## How to test

No functional protocol test is available at this stage. Run the cocotb tests in `test/` with `make test`. They cover reset clearing the outputs, each input bus reaching `uo_out` after one clock, the bidirectional bus staying released, and the captured value holding while `ena` is low.

## External hardware

None is required for the Stage-0 placeholder. Requirements for later protocol demonstrations have not yet been selected.
