# ZCU102 HFT reference design

An educational end-to-end trading reference for the AMD Zynq UltraScale+
MPSoC ZCU102:

- VHDL-2008 market-data pipeline for MoldUDP64 and an ITCH 5.0 subset.
- FreeRTOS/C++23 cooperative execution and risk control on Cortex-R5.
- Rust async SoupBinTCP/OUCH gateway, observability, and PostgreSQL analytics on
  Cortex-A53 Yocto Linux.
- Shared generated contracts, deterministic simulators, per-layer tests and
  coverage, signed SWUpdate A/B artifacts, and reproducible CI environments.

The project is fail-closed and simulator-only by default. It is not a
production trading system and no workflow deploys to hardware.

## Repository and local paths

The canonical branch is `develop` at
<https://github.com/ps-chong/hft-toy-project>. The expected Windows checkout is:

```powershell
git clone --branch develop https://github.com/ps-chong/hft-toy-project `
  C:\Users\121679\hft-toy-project
Set-Location C:\Users\121679\hft-toy-project
```

Vivado is invoked only through the checked-in batch wrapper and is expected at
`C:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat`:

```powershell
.\scripts\windows\verify-tools.ps1
.\scripts\windows\build-fpga.ps1 -Profile sim-dma
```

GitHub Actions performs open-source FPGA simulation, R5 host tests and
cross-compilation, and A53 Rust tests/cross-compilation. Vivado synthesis stays
local because no Windows self-hosted runner was selected.

## Generate contracts

Schemas are JSON-compatible YAML so generation has no bootstrap dependency:

```bash
python3 protocol/generator/generate.py
python3 protocol/generator/generate.py --check
```

The command emits matching C++, Rust, and VHDL constants, register
documentation, and binary golden vectors.

## Build and test

The supported host flow uses CMake/Ninja:

```bash
cmake --preset host-clang-debug
cmake --build --preset host-clang-debug
ctest --preset host-clang-debug
```

Rust and Python commands:

```bash
cargo test --workspace
python3 -m pytest python/tests
```

See [docs/architecture/overview.md](docs/architecture/overview.md) for the
system design, [docs/coding-standards.md](docs/coding-standards.md) for
library/ownership rules, and [docs/safety.md](docs/safety.md) for operating
limits.