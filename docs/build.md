# Build guide

## Host prerequisites

Use the checked-in containers for reproducibility. A native Ubuntu 24.04 setup
needs CMake/Ninja, Clang 18, GCC 14+, Python 3.12, GHDL, Rust 1.97.1, and the
cross compilers. The root README contains the shortest commands.

## FPGA simulation

```bash
python3 -m venv .venv
.venv/bin/pip install -e 'python[dev]'
VUNIT_SIMULATOR=ghdl .venv/bin/python 'zynq/ultrascale+/sim/run.py'
.venv/bin/vsg -c 'zynq/ultrascale+/vsg.yaml' \
  -f 'zynq/ultrascale+/rtl/'*.vhd 'zynq/ultrascale+/tb/'*.vhd
```

Set `VUNIT_SIMULATOR=nvc HFT_VHDL_COVERAGE=1` for NVC coverage. CI installs
the NVC 1.23.0 Ubuntu 24.04 package from the upstream GitHub release.

## R5 host and target

```bash
cmake --preset host-clang-debug
cmake --build --preset host-clang-debug
ctest --preset host-clang-debug

export ARM_GNU_TOOLCHAIN_ROOT=/opt/arm-gnu-toolchain
cmake --preset r5-release
cmake --build --preset r5-release
```

The latter links `hft_r5_firmware.elf`. The AMD BSP build additionally defines
`HFT_WITH_XILINX_FREERTOS` and supplies platform hooks.

## A53 Rust

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace --all-targets
cargo build --workspace --release --target aarch64-unknown-linux-gnu
```

## Yocto and SWUpdate

```bash
docker build -t hft-yocto -f containers/yocto/Dockerfile .
docker run --rm -v "$PWD:/workspace" hft-yocto \
  kas shell yocto/kas/myd-czu5ev-v2.yml -c 'bitbake-layers show-layers'
```

Full `kas build` creates image artifacts only. Do not flash them without
completing the deferred hardware checks.

## Local Vivado

```powershell
Set-Location C:\Users\121679\hft-toy-project
.\scripts\windows\verify-tools.ps1
.\scripts\windows\build-fpga.ps1 -Profile sim-dma
```

The current goal is out-of-context synthesis; board bitstream integration is
intentionally rejected until hardware is available.
