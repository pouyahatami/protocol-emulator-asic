## How it works

This project will implement a firmware-programmable engine for deterministic pin input/output. The architecture and instruction set are currently under evaluation.

The checked-in design contains no protocol logic. It instantiates the two instruction memories, `i_imem0` and `i_imem1`, and exposes them through a temporary pin-level access port. Each memory is one IHP `RM_IHPSG13_1P_64x16_c2` macro: a single-port static RAM of 64 words of 16 bits with a synchronous read. The memory contents are not reset, so a word is undefined until it has been written.

One access is sampled on every rising clock edge while `ena` and `rst_n` are both high:

| Pin | Function |
|---|---|
| `ui_in[5:0]` | Word address. |
| `ui_in[6]` | Memory select: 0 addresses `i_imem0`, 1 addresses `i_imem1`. |
| `ui_in[7]` | Access type: 1 writes a word, 0 reads a word. |
| `uio_in[7:0]` | Write access: upper byte of the word. Read access: bit 0 selects the byte presented on `uo_out` (0 lower, 1 upper). |
| `uo_out[7:0]` | Selected byte of the word read at the preceding rising clock edge. |

A word is written in two clocks. The lower byte is the value `uio_in` carried at the rising clock edge before the write access, and the upper byte is the value it carries at the edge that samples the write access. Read data appears on `uo_out` after the rising clock edge that samples the read access, and `uo_out` is zero after an edge that sampled a write access.

The reset is synchronous and active low. While `rst_n` is low no access reaches either memory and `uo_out` returns to zero on the next rising clock edge. While `ena` is low no access reaches either memory and `uo_out` holds its value. The bidirectional bus is an input at all times, because no protocol owns it yet: `uio_oe` is held low and `uio_out` is tied low.

The access port is deliberate scaffolding rather than intended behavior. Synthesis removes a memory whose outputs reach no pin, and LibreLane's disconnected-pin checker aborts the GDS build when an input pin is unconnected, so the port connects every input pin and both memory outputs with the least logic. Expect it to be replaced in full once the Stage-1 host interface is accepted; nothing here should be read as a committed pin assignment.

## How to test

No functional protocol test is available at this stage. Run the cocotb tests in `test/` with `make test`. They cover reset clearing the outputs, every word of both memories reading back the value written to it, a write access presenting zero, the bidirectional bus staying released, and a deselected design holding its outputs and leaving both memories unwritten.

## External hardware

None is required for the memory access port. Requirements for later protocol demonstrations have not yet been selected.
