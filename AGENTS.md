# Instructions for coding agents

Read this file before changing the repository.

## Project

This repository implements a firmware-programmable protocol-emulator ASIC for the Jane Street competition. The target is Tiny Tapeout's IHP 130 nm CMOS5L flow with a 6x4 tile allocation.

The project is in Stage 0. The architecture and ISA are not final. UART, SPI, and I2C are required demonstration workloads, not fixed-function blocks.

## Source priority

When information conflicts, use this order:

1. Official competition rules and the checked-out Tiny Tapeout template.
2. RTL, tests, formal properties, and build configuration in this repository.
3. Accepted specifications under `docs/spec/`.
4. Accepted decision records in the research repository.
5. Proposals, estimates, and old notes.

Flag conflicts and update the lower-priority source.

## Non-negotiable rules

- Do not change the top-level module name or port list without an explicit interface decision and matching updates to `info.yaml`, the testbench, and documentation.
- Do not treat a research proposal as an accepted requirement.
- Preserve unrelated worktree changes.
- Change only files needed for the task.
- Add or update tests with behavioral changes.
- Specify cycle timing, stalls, reset behavior, FIFO boundaries, and pin direction for externally visible behavior.
- Never present an estimate as a synthesis, timing, formal, FPGA, or silicon result.
- Do not commit generated build products unless the Tiny Tapeout template requires them.

## RTL style

- Keep synthesizable design files under `src/`, as required by the template.
- Use `default_nettype none` and restore `default_nettype wire` at the end of compilation units.
- Use explicit widths and avoid implicit nets.
- Keep clocked and combinational logic clearly separated.
- Use nonblocking assignments in sequential logic.
- Give comments full sentences and explain intent or constraints, not obvious syntax.
- Prefer lines at or below 100 characters.
- Use LF line endings and end every text file with a newline.

## Verification

Run the smallest relevant test first, then the complete available regression. Verification is expected to grow through directed simulation, protocol conformance, differential model checking, constrained-random testing, formal properties, gate-level simulation, and physical checks.

A feature is incomplete until intended timing and failure behavior are tested.

## Repository boundary

Implementation and required submission documents belong here. Literature notes, alternatives, calculations, and unresolved decisions belong in [`pouyahatami/protocol-emulator-research`](https://github.com/pouyahatami/protocol-emulator-research).

## Current commands

From the repository root:

```sh
make test
make clean
```

Replace or extend these commands only when the new flow is checked into the repository and verified.
