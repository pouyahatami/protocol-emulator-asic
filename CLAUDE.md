# CLAUDE.md

Guidance for work in this repository.

## Goal

Build an open-source, programmable protocol-emulation ASIC for the Jane Street competition. UART, SPI, and I2C are firmware demonstrations, not separate fixed-function peripherals.

## Current phase

This project is at the skeleton and requirements stage. No ISA, engine count, register width, memory implementation, pin map, or stretch protocol is final unless it appears in an accepted specification and is enforced by tests.

## Sources of truth

Use this order when information conflicts:

1. Official competition rules and the checked-out Tiny Tapeout template.
2. Executable RTL, tests, formal properties, and build configuration here.
3. Accepted specifications under `docs/spec/`.
4. Accepted decision records in the research repository.
5. Old notes, estimates, and proposals.

Do not silently resolve a conflict. Update or flag the lower-priority source.

## Confirmed constraints

- Target IHP 130 nm CMOS5L through Tiny Tapeout.
- Use a 6x4 tile allocation unless the competition rules change.
- Keep the project open source.
- Submission deadline: 2027-01-18.
- Demonstrate UART, SPI, and I2C in firmware.
- Preserve the official Tiny Tapeout interface and required submission files.

The organizers' approximate cell count is planning guidance only. Area, timing, and routability are measured properties.

## Engineering rules

- Make the smallest change that establishes testable behavior.
- Add or update tests with behavioral changes.
- Run simulation before committing RTL.
- Run synthesis early and after changes likely to affect area or timing.
- Run place-and-route at architectural milestones.
- Specify instruction timing, stalls, reset state, FIFO behavior, and pin direction precisely.
- Keep generated build products out of version control unless the template requires them.
- Use reproducible scripts and pinned dependencies where practical.
- Never present an estimate as a tool result or silicon result.

## Verification expectations

Grow verification in layers: directed simulation, protocol conformance, differential checking against a cycle-accurate model, constrained-random testing, formal properties, gate-level simulation, and physical checks.

A feature is incomplete until its timing and failure behavior are tested.

## Repository boundary

Implementation material belongs here. Literature notes, competing ideas, rough calculations, and unresolved decisions belong in `pouyahatami/protocol-emulator-research`. Required Tiny Tapeout documentation such as `docs/info.md` remains here.

## Immediate priorities

1. Verify the unchanged skeleton through CI and the physical flow.
2. Define representative UART, SPI, and I2C workloads.
3. Accept the architecture and minimal ISA through decision records.
4. Add specifications under `docs/spec/` before substantial RTL.
