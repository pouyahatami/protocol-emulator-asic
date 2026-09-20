## How it works

This project will implement a firmware-programmable engine for deterministic pin input/output. The architecture and instruction set are currently under evaluation.

The checked-in Stage-0 design is intentionally inert: all dedicated outputs are low and all bidirectional pins are released. It exists to validate the IHP CMOS5L Tiny Tapeout build flow before functional logic is added.

## How to test

No functional protocol test is available at this stage. Run the cocotb test in `test/` to confirm that the skeleton never drives the bidirectional pins and keeps all outputs low.

## External hardware

None is required for the Stage-0 skeleton. Requirements for later protocol demonstrations have not yet been selected.
