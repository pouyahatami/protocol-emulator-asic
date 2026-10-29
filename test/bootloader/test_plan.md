# Bootloader test plan

Verification plan for `src/bootloader.sv`. The testbench is `test/bootloader/bootloader_tb.sv`, and it runs in Questa/ModelSim. Run it from `test/bootloader/` with `vsim -do run.do`.

## Goals

The testbench must show that two interfaces are sound:

1. **SPI slave interface.** The bootloader accepts words only while chip select is asserted, decodes commands and loads read data into the slave at the correct time.
2. **SRAM macro interface.** The bootloader drives `RM_IHPSG13_1P_64x16_c2` within the macro's rules and accounts for its one-cycle read latency.

## Approach

### Structure

The testbench wires the bootloader to a simulation model of the real SRAM, and plays the part of the SPI slave itself:

```
 testbench (acts as SPI slave)          bootloader_instance          sram_instance
 cs_asserted, word_ready, rx_word  -->                        --> men, wen, ren, addr, din
 tx_word, tx_load                  <--                        <-- dout
```

- `bootloader_instance` is the design under test.
- `sram_instance` is IHP's behavioural model of the SRAM macro, copied from the PDK into `test/ihp_sram/`. It is compiled with `FUNCTIONAL` defined, which selects the zero-delay variant without timing checks. `A_DLY` is tied high, as the datasheet requires.
- The SRAM model is the memory itself. The testbench never drives the SRAM port; it only observes it.

### Timing convention

- The clock period is 20 ns (50 MHz).
- Inputs change on the falling edge (`@(negedge clk)`), half a cycle away from the rising edge that samples them.
- The monitor checks outputs at the rising edge. The bootloader and the SRAM model update their registers with nonblocking assignments, so the monitor sees the values that edge samples.

### Stimulus tasks

| Task | Function |
|---|---|
| `reset` | Holds `rst_n` low for two edges, clears the counters, enables the monitor |
| `send_word` | Presents one word as a one-cycle `word_ready` pulse, followed by `CYCLES_BETWEEN_WORDS` idle cycles |
| `write_burst` | Sends `OPCODE_WRITE`, the address, then the data words; updates `expected_mem` and checks that each data word caused one SRAM write |
| `read_burst` | Sends `OPCODE_READ`, the address, then one dummy word per word read; the monitor checks each received word |

Tests that need a non-standard transfer, such as an unknown opcode, drive `cs_asserted` and call `send_word` directly.

Bursts wrap at the end of the SRAM, for example addresses 62, 63, 0, 1. The testbench models this with `% DEPTH` wherever it computes an address.

### Monitor and checks

A monitor runs at every rising edge after reset and checks these rules:

| Rule | Interface |
|---|---|
| `sram_men`, `sram_wen`, `sram_ren` and `tx_load` are never X | SRAM, SPI |
| `sram_wen` or `sram_ren` is never high while `sram_men` is low | SRAM |
| `sram_wen` and `sram_ren` are never high in the same access | SRAM |

It also counts SRAM writes (`write_count`) and `tx_load` pulses (`tx_count`). During a read burst, it compares each word the host receives with `expected_mem`, a reference copy of what the SRAM should hold.

Write addresses are not checked as they happen. A write to the wrong address shows up as wrong data when it is read back.

### Read model

SPI is full duplex: the slave can only send a word while the host clocks one in. A read burst of N words therefore takes N dummy words from the host.

The word loaded in `READ_FIRST` is shifted out during the first dummy word, and each `word_ready` in `READ_STREAM` loads the next word. The word loaded by the last `word_ready` is never shifted out, so the bootloader performs N + 1 loads and the host receives the first N. That last word can come from an address that was never written and read as X; the testbench ignores it.

### Pass criterion

Each failed check increments `errors` and reports `$error`. At the end, the testbench prints `PASS: all bootloader tests passed` or `FAIL: <n> error(s)`. A 1 ms watchdog stops a hung simulation with `$fatal`.

## Test cases

### Implemented

| ID | Test | Stimulus | Expected result | Interface |
|---|---|---|---|---|
| T1 | `test_write_then_read_burst` | Write 8 random words at address 5, then read 8 words from address 5 | 8 SRAM writes; the read returns the written data | Both |
| T2 | `test_length_one_bursts` | Write one word at address 17, then read one word | One write; the read returns that word | Both |
| T3 | `test_address_wraps_at_end_of_sram` | Write 4 words at address 62, read them back, then read 2 words from address 0 | The read returns the data; addresses 0 and 1 hold the third and fourth words | SRAM |
| T4 | `test_unknown_opcode_is_ignored` | Send `0x1234`, then words that look like a write command | No SRAM write and no `tx_load`; the next transfer is decoded normally | SPI |
| T5 | `test_chip_select_ends_transfer` | (a) Deassert chip select after the address, then start a new write. (b) Send a word while chip select is deasserted | (a) The new transfer starts from a new opcode. (b) That word is never written | SPI |

To confirm the tests detect faults, two faults were added to copies of the bootloader: `READ_ADDRESS` using `addr_q` instead of `rx_word`, and `WRITE_DATA` incrementing the address by 2. The testbench reported errors for both.

### Planned

| ID | Test | Purpose | Interface |
|---|---|---|---|
| P1 | Minimum word spacing (`CYCLES_BETWEEN_WORDS` = 0 and 1) | `READ_FIRST` ignores `word_ready`. Find the minimum spacing the bootloader handles, and confirm the real SPI slave never produces less | SPI |
| P2 | Reset during a burst | `rst_n` low in the middle of a write and of a read; the bootloader returns to IDLE and no write is issued | Both |
| P3 | Chip select deasserted in `READ_FIRST` | The early-termination path that skips the load | SPI |
| P4 | Chip select deasserted in the same cycle as `word_ready` | The boundary case of the `word_valid` qualification | SPI |
| P5 | Full-memory write and read | All 64 addresses, including wrap during a read | SRAM |
| P6 | Back-to-back transfers with one idle cycle, without reset | No state from one transfer leaks into the next | SPI |
| P7 | Read of a word written in the same cycle | Not reachable with this protocol; record as not applicable once confirmed | SRAM |
| P8 | Random command sequences against a reference memory | Broad coverage once the directed tests pass | Both |
| P9 | Address word with upper bits set, such as `0x0045` | Only the low 6 bits are used, so this addresses word 5 | SRAM |
| P10 | FSM state and transition coverage | Show that every state and transition is reached by the tests | Both |

## Formal properties

Candidate properties, to be written as assertions on `bootloader` once a formal flow is set up:

| Property | Meaning |
|---|---|
| `!(sram_wen && sram_ren)` | Never write and read in one access. The macro allows it (write-through), but the bootloader never needs it |
| `(sram_wen \|\| sram_ren) -> sram_men` | A strobe never appears without the memory enable |
| `sram_wen -> (state_q == WRITE_DATA && word_valid)` | Writes happen only for a valid data word in a write burst |
| `sram_ren -> state_q inside {READ_ADDRESS, READ_FIRST, READ_STREAM}` | Reads happen only in a read burst |
| `tx_load -> state_q inside {READ_FIRST, READ_STREAM}` | The slave is loaded only in a read burst |
| `!cs_asserted -> !sram_wen` | No write after chip select is deasserted |

## Questions

- **Should the testbench check that the FSM hits every state as intended?** Not with a check per state. Measure it with FSM coverage instead (P10): Questa's code coverage, if your edition includes it, or `cover` statements in formal.
- **Can the monitor's rules move to formal properties, and can SymbiYosys check them?** The `men`/`wen`/`ren` rules can, and they are listed under formal properties. Once they are assertions in the RTL, they also run in simulation, and the testbench can drop its copies. Open-source Yosys supports immediate `assert` inside `always` blocks; full concurrent SVA needs the commercial Verific front end. The X check stays in simulation, because formal tools do not model X the way a simulator does.
- **Should there be a property that `men` never goes low?** No. `men` is low whenever there is no access, which is intended. The useful property is the reverse: `wen` or `ren` high implies `men` high.
- **Can formal prove that `men` low is a no-op, whatever `wen` and `ren` are?** Not for this design. That is a property of the SRAM macro, which is a black box. The datasheet guarantees it. The bootloader's side is the property that `wen` and `ren` stay low while `men` is low.
- **The SRAM has no initial value, unlike an FPGA. How is it cleared?** The contents are undefined until written. Either the host writes the whole image before the program runs, or a clear command walks all 64 addresses and writes zeros, which takes 64 cycles per memory. The program must never run from an unwritten word.
- **Should every test start with a reset?** Yes for directed tests, so that one failure does not cascade into the rest. P6 covers back-to-back transfers without reset.
- **Should chip select changing in the middle of a transfer be tested?** Deassertion mid-burst is covered by T5, P3 and P4. Chip select changing in the middle of a word is handled by the SPI slave's bit counter, and belongs in the slave's testbench.
- **Should an invalid address be tested?** Every 6-bit address is valid, and the upper 10 bits of the address word are ignored. P9 checks that they are ignored.
- **The design needs two instruction memories. How does the bootloader reach both, or can they act as one 128-word memory?** They can act as one: widen the address to 7 bits and use bit 6 to pick the macro (`men` goes to one or the other, and `dout` is selected by a registered copy of bit 6). Bursts then cross from one macro into the other. A separate opcode per memory also works. The IHP library has no 128x16 macro; the next size is 256x16. The choice is a design decision and should be recorded in the research repository.

## Assumptions and open items

- **SPI slave handshake.** The testbench assumes the real slave pulses `word_ready` for one cycle per received word, and samples `tx_word` in the cycle `tx_load` is high. This must be checked against the SPI slave RTL once it exists. Until then, goal 1 is only partly verified.
- **Questa error vlog-2892.** Questa rejects `input logic` ports under `default_nettype none`. `run.do` suppresses the error for now. Changing the ports to `input wire logic` or `input var logic` needs a decision, because AGENTS.md says to declare ports as `logic`.
- **CI.** This testbench is not run in CI. CI runs only the template cocotb test in `test/`.
- **SRAM model copy.** `test/ihp_sram/` holds copies of the PDK files from `ihp-sg13g2/libs.ref/sg13g2_sram/verilog`. The CMOS5L SRAM folder is a symlink to that folder. Copy them again if the PDK version changes.
