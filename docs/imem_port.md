# imem_port

`src/imem_port.sv` joins the two `RM_IHPSG13_1P_64x16_c2` instruction SRAMs, `i_imem0` and `i_imem1`, into one 128-word by 16-bit memory with a single access port. The bootloader drives the port with `ADDR_WIDTH = 7`. The instruction fetcher will share the port later, through an owner multiplexer in front of it.

The IHP library has no 128x16 macro; the next size is 256x16.

## Address map

| `addr[6]` | Words | Macro |
|---|---|---|
| 0 | 0 to 63 | `i_imem0` |
| 1 | 64 to 127 | `i_imem1` |

`addr[5:0]` is the word address inside the selected macro. A burst that runs past word 63 continues in `i_imem1`, and a burst past word 127 wraps to word 0.

## Signals

| Port | Direction | Width | Function |
|---|---|---|---|
| `clk` | in | 1 | Clock, shared with both macros |
| `rst_n` | in | 1 | Synchronous active-low reset; clears the read bank register |
| `men`, `wen`, `ren` | in | 1 each | Memory enable, write enable, and read enable, with the same meaning as the macro pins |
| `addr` | in | 7 | Word address |
| `din` | in | 16 | Write data |
| `dout` | out | 16 | Read data |
| `mem0_men`, `mem1_men` | out | 1 each | Memory enable of `i_imem0` and `i_imem1`. At most one is high: `men & ~addr[6]` and `men & addr[6]` |
| `mem_wen`, `mem_ren` | out | 1 each | Write and read enable, connected to both macros |
| `mem_addr` | out | 6 | `addr[5:0]`, connected to both macros |
| `mem_din` | out | 16 | `din`, connected to both macros |
| `mem0_dout`, `mem1_dout` | in | 16 each | Read data from `i_imem0` and `i_imem1` |

The write enable, read enable, address, and write data are shared. A macro whose memory enable is low ignores them.

## Timing

The decode from `addr` to the macro inputs is combinational, so an access is sampled at the same rising edge as with a single macro.

The read latency is one clock cycle, the same as a single macro. Each macro registers its output: after the rising edge that samples a read, `A_DOUT` holds the word read and keeps it until the next read of that macro.

`dout` is selected by `read_bank_q`, a copy of `addr[6]` registered at each rising edge that samples a read (`men` and `ren` high). `read_bank_q` does not change on a write or an idle cycle, so `dout` keeps showing the last word read. Updating it on every access would be wrong: a write to the other macro would switch `dout` to that macro's old output.

## Reset

Reset clears `read_bank_q`, so `dout` shows `i_imem0`'s output. The macro contents and outputs are not reset. Each word is undefined until written, and `dout` is undefined until the first read.

## Verification

`test/imem_port/imem_port_tb.sv` checks the decode, back-to-back reads that alternate between the macros, and `dout` holding through writes and idle cycles. `test/bootloader/bootloader_tb.sv` runs the bootloader through `imem_port`, including a burst across word 63 and word 64. Run each from its folder with `vsim -do run.do`.
