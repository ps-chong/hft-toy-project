# Build and CI architecture

## Build topology

```mermaid
flowchart LR
    Source["develop branch"] --> FPGA["FPGA: VSG, VUnit on GHDL and NVC"]
    Source --> R5Host["R5: ASan/UBSan, TSAN, clang-tidy, coverage"]
    Source --> R5Cross["R5: Arm GNU cross-link"]
    Source --> Rust["A53: clippy, tests, loom, aarch64"]
    Source --> Quality["Python, docs, figure drift"]
    Source --> Demo["Demo smoke (Docker Compose)"]
    Source --> SWU["SWUpdate contract"]
    Source -.->|"runner online"| Vivado["Vivado OOC synthesis,<br/>implementation, xsim<br/>self-hosted WSL"]
    Source --> Yocto["Yocto image (manual and weekly)"]
    FPGA --> Reports["JUnit, coverage, demo and Vivado reports"]
    R5Host --> Reports
    R5Cross --> Reports
    Rust --> Reports
    Demo --> Reports
    Vivado --> Reports
```

Every hosted workflow also runs locally, in the same container image, with
`scripts/ci/local.sh` (see [docs/workflow/07-ci.md](../workflow/07-ci.md)).

## Local programmable-logic build

The source belongs in the WSL file system (`~/hft-toy-project`); Vivado is
the Windows installation at `C:\AMDDesignTools\2026.1\Vivado`. The scripts in
`scripts/linux/` drive it through WSL interop: `common.sh` mirrors the
sources into a per-checkout directory under `C:\hft-vivado` (Windows Vivado
needs native paths), runs the `.bat` launchers from there with `cmd.exe`,
passes `XILINXD_LICENSE_FILE` through `WSLENV`, and stops the Windows
processes if a run is cancelled. `verify-tools.sh` checks the version.
`build-fpga.sh` invokes one Tcl entry point, copies the reports back under
`build/vivado/<profile>`, and never opens the hardware manager. The Tcl flow
registers `zynq/ultrascale+/board_files`, targets `xczu5ev-sfvc784-2-e`, reads
the RTL from `rtl/sources.f` (the simulation's list), and fails on negative
setup or hold slack or a Critical CDC finding; the `impl` goal then places
and routes out of context, with the clock ports driven from BUFGCE sites
(`HD.CLK_SRC`), and fails on negative routed slack or any net with routing
errors. `gates.txt` records the values. `xsim.sh` runs the VUnit benches on
the Vivado simulator (see [fpga.md](fpga.md)).

A Windows checkout uses `scripts/windows/` instead: `verify-tools.ps1` and
`build-fpga.ps1` run the same Tcl natively.

Vivado 2026.1 licenses by tier and exposes only the starting tier's devices.
The free BASIC tier covers the XCZU5EV. If the license file also holds the
ALVEO tier, `split-vivado-license.py` (or `.ps1`) writes a BASIC-only copy,
and `build-fpga.sh --license <dir>` (`build-fpga.ps1 -License <dir>`) or
`HFT_VIVADO_LICENSE` selects it.

## Vivado in GitHub Actions

`.github/workflows/vivado.yml` runs the same builds on a self-hosted Linux
runner in WSL labelled `vivado`: out-of-context implementation of the two
profiles one after the other, and the benches on xsim. It never runs for
pull requests, checks out without persisted credentials, and uploads the
reports and JUnit results. `scripts/linux/runner.sh` installs the runner
under `~/ghr` as the current user and starts and stops it on demand. Until
the runner is registered and the repository variable `HFT_VIVADO_RUNNER` is
`online`, the jobs are skipped instead of queueing.

## C++ build matrix

- Clang 19 debug with ASan/UBSan, and a ThreadSanitizer preset.
- GCC 14 coverage with gcovr HTML/Cobertura.
- Arm GNU 13.3.Rel1 C++23 cross-link with exceptions/RTTI disabled.
- CIB and `fmt` enabled in the target lane.
- A host C++26 reference lane is defined for a GCC 16 environment; target code
  remains C++23.

Clang 19 is the minimum: with libstdc++, `std::expected` needs the
`__cpp_concepts` level Clang 18 does not report. Dependencies are immutable
CMake FetchContent revisions or release archives; the target toolchain archive
is checksum-verified.

## Rust build matrix

Rust 1.97.1/Edition 2024 runs fmt, Clippy (`-D warnings`, which makes
`missing_docs` an error), unit/property tests, mockall actor tests, an
end-to-end daemon test, `loom` model checks, SQL migration validation,
cargo-audit/deny, llvm-cov, and an `aarch64-unknown-linux-gnu` release build.
Cargo.lock is committed.

## Programmable-logic verification

GHDL and the pinned NVC 1.23.0 both run the full VUnit suite; NVC also
collects statement, branch, and functional coverage. The Vivado runner runs
the same benches on xsim. VSG checks synthesizable RTL and testbenches.

## Workflow boundary

Pushes to `develop` trigger the FPGA, R5, A53, quality and demo workflows,
and Vivado when its runner is online. Yocto runs on demand and weekly because
of its resource footprint. No job includes JTAG, a board hostname, hardware
credentials, or remote SWUpdate installation.
