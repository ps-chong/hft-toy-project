# Build guide

## Host prerequisites

Use the checked-in containers for reproducibility (`containers/host/Dockerfile`
is the image CI, the demo and `scripts/ci/local.sh` all use). A native
Ubuntu 24.04 setup needs CMake/Ninja, Clang 19, GCC 14 as the default
`gcc`/`g++`/`gcov`, Python 3.12, GHDL, NVC 1.23, Rust 1.97.1, and the cross
compilers. The step-by-step guides are in [docs/workflow](workflow/README.md).

## Programmable-logic simulation

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
cmake --preset host-clang-debug          # ASan + UBSan
cmake --build --preset host-clang-debug
ctest --preset host-clang-debug

cmake --preset host-clang-tsan           # ThreadSanitizer
cmake --build --preset host-clang-tsan
ctest --preset host-clang-tsan

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

Vivado 2026.1 is the Windows installation in `C:\AMDDesignTools\2026.1`.
From a clone in WSL, `scripts/linux/` drives it through WSL interop: each
script mirrors the sources into `C:\hft-vivado`, runs the Vivado tools there,
and copies the results back under `build/`.

```bash
scripts/linux/verify-tools.sh
python3 scripts/linux/split-vivado-license.py      # once, if the license also holds ALVEO
scripts/linux/build-fpga.sh --profile sim-dma --goal impl
scripts/linux/build-fpga.sh --profile sfp10g --goal impl
scripts/linux/xsim.sh                              # the VUnit benches on the Vivado simulator
scripts/linux/clean-fpga.sh                        # drop build/vivado, build/xsim and the C: copy
```

From a Windows checkout, the PowerShell wrappers run the synthesis directly:

```powershell
.\scripts\windows\verify-tools.ps1
.\scripts\windows\split-vivado-license.ps1        # once, if the license also holds ALVEO
.\scripts\windows\build-fpga.ps1 -Profile sim-dma -License "$env:APPDATA\XilinxLicense-BASIC"
.\scripts\windows\build-fpga.ps1 -Profile sfp10g -License "$env:APPDATA\XilinxLicense-BASIC"
```

`--goal synth` (the default) stops after out-of-context synthesis;
`--goal impl`, which CI runs, also places and routes out of context. Each run fails on
negative setup or hold slack, on Critical CDC findings and, for `impl`, on
negative routed slack or nets with routing errors;
`build/vivado/<profile>/gates.txt` records the values. `xsim.sh` writes
`build/xsim/xsim-junit.xml`.

Both profiles target `xczu5ev-sfvc784-2-e`; `sfp10g` additionally checks for
the AMD Ethernet subsystem. The repo-local MYIR board repository is registered
by Tcl. Bitstream/XSA generation is intentionally rejected until DDR/PS and
physical SFP mapping are validated.

## Target NVMe provisioning

After a verified image boots, persistent storage remains an explicit operator
action:

```console
hft-provision-nvme /dev/nvme0n1 --yes
systemctl start data.mount hft-data-prepare.service
```

This erases the selected NVMe device. It is never called from image install,
boot, or SWUpdate.
