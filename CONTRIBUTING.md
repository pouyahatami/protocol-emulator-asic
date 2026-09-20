# Contributing

Thanks for helping build the protocol-emulator ASIC.

## Before starting

1. Read [AGENTS.md](AGENTS.md) and the accepted specifications under `docs/spec/`.
2. Check the [research repository](https://github.com/pouyahatami/protocol-emulator-research) for relevant decisions.
3. Open or claim an issue before substantial work so parallel changes do not collide.
4. Use a short-lived branch from `main`.

## Where work belongs

- RTL and the Tiny Tapeout wrapper: `src/`
- Cocotb and simulation support: `test/`
- Accepted implementation behavior: `docs/spec/`
- Required Tiny Tapeout datasheet: `docs/info.md`
- Research, alternatives, calculations, and decision records: the research repository

## Pull requests

Keep pull requests focused and explain:

- what behavior changed;
- why it changed;
- how it was verified;
- any area, timing, interface, or compatibility impact;
- which issue, specification, or decision record it implements.

Do not mix formatting or unrelated refactors with functional changes.

## Checks

Run the available regression before requesting review:

```sh
make test
```

For RTL changes, include the relevant simulator output. Once synthesis and formal targets are added, their required commands will be listed here and in the pull-request template.

## Commit messages

Use an imperative summary of roughly 72 characters or fewer. Add context in the body when the reason is not obvious. Keep commits reviewable and avoid checking in generated artifacts.

## Design decisions

Changes to the ISA, top-level interface, engine count, memory organization, host interface, or pin ownership require an accepted architecture decision record before implementation.
