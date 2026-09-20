# Programmable Protocol Emulator ASIC

An open-source entry for [Jane Street's protocol emulator ASIC competition](https://blog.janestreet.com/protocol-emulator-asic-competition/).

The goal is a small, deterministic processor specialized for timed pin input/output. Protocol behavior will be supplied as firmware so the same silicon can implement UART, SPI, I2C, and other protocols within its timing and I/O limits.

## Status

Stage 0: repository skeleton. The architecture and instruction set are not frozen. The current RTL is deliberately inert and exists only to validate the toolchain before functional logic is added.

## Repository map

```text
docs/
  info.md              Tiny Tapeout-facing datasheet
  spec/                accepted implementation specifications
firmware/              protocol programs and fixtures (planned)
formal/                formal harnesses and properties (planned)
model/                 cycle-accurate reference model (planned)
src/                   synthesizable RTL
test/                  cocotb simulation tests
info.yaml              Tiny Tapeout metadata and pinout
```

This repository is based on the `cmos5l` branch of the official [Tiny Tapeout IHP Verilog template](https://github.com/TinyTapeout/ttihp-verilog-template).

## Development

The exact local setup instructions are still being validated. The template test can be run from `test/` with:

```sh
python -m pip install -r requirements.txt
make -B
```

See [CLAUDE.md](CLAUDE.md) for repository working conventions and [docs/spec/README.md](docs/spec/README.md) for specification status.

Research and design alternatives live in the separate [`protocol-emulator-research`](https://github.com/pouyahatami/protocol-emulator-research) repository.

## License

Apache-2.0. See [LICENSE](LICENSE).
