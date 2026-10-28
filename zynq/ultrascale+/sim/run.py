#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
COVER_SPEC = "branch,statement,functional"
ENABLE_COVERAGE = os.environ.get("HFT_VHDL_COVERAGE", "0") == "1"


def _database_paths(root: Path, pattern: str) -> list[Path]:
    if not root.exists():
        return []
    if root.resolve() in {ROOT.resolve(), Path.cwd().resolve()}:
        paths = list(root.glob(pattern))
        vunit_out = root / "vunit_out"
        if vunit_out.exists():
            paths.extend(vunit_out.rglob(pattern))
        return paths
    return list(root.rglob(pattern))


def coverage_databases(*roots: Path) -> list[Path]:
    found: list[Path] = []
    seen: set[Path] = set()
    for pattern in ("*.ncdb", "*.covdb"):
        for root in roots:
            for path in _database_paths(root, pattern):
                resolved = path.resolve()
                if path.is_file() and resolved not in seen:
                    seen.add(resolved)
                    found.append(path)
        if found:
            return sorted(found)
    return []


def export_nvc_coverage(databases: list[Path], dest: Path) -> None:
    if not databases:
        raise RuntimeError("NVC produced no coverage databases")

    dest.mkdir(parents=True, exist_ok=True)
    merged = dest / "coverage_data.ncdb"
    if len(databases) == 1:
        merged.write_bytes(databases[0].read_bytes())
    else:
        subprocess.run(
            [
                "nvc",
                "--cover-merge",
                "-o",
                str(merged),
                *[str(path) for path in databases],
            ],
            check=True,
        )
    subprocess.run(
        ["nvc", "--cover-report", "-o", str(dest / "html"), str(merged)],
        check=True,
    )
    subprocess.run(
        [
            "nvc",
            "--cover-export",
            "--format=cobertura",
            "-o",
            str(dest / "coverage.xml"),
            str(merged),
        ],
        check=True,
    )


# Compilation order, shared with vivado/tcl/build.tcl.
SOURCE_LIST = ROOT / "zynq/ultrascale+/rtl/sources.f"


def rtl_sources() -> list[Path]:
    lines = SOURCE_LIST.read_text(encoding="utf-8").splitlines()
    return [
        ROOT / line.strip()
        for line in lines
        if line.strip() and not line.startswith("#")
    ]


VECTOR_DIR = ROOT / "protocol/vectors"

# Testbenches that read protocol vectors.
VECTOR_BENCHES = (
    "tb_eth_ipv4_udp_rx",
    "tb_moldudp64_rx",
    "tb_itch_decoder",
    "tb_telemetry_udp_tx",
    "tb_hft_pipeline",
    "tb_myd_czu5ev_v2_hft_top",
)

# (source, destination) clock periods in ps for the CDC stress bench: the
# real ps_clk/axis_clk pair both ways, plus two nearly equal clocks.
CDC_RATIOS = ((10_000, 6_400), (6_400, 10_000), (7_000, 7_100))


# Shared with xsim.py, which runs the same benches on the Vivado simulator.
def bench_generics() -> dict[str, dict[str, str]]:
    """Generics every configuration of a test bench gets."""
    vectors = VECTOR_DIR.as_posix()
    generics = {bench: {"vector_dir": vectors} for bench in VECTOR_BENCHES}

    # The demo points the replay at its own capture and at the events
    # hft-plsim produced from it; CI uses the generated session.
    # Empty string generics cannot be passed on the GHDL command line, so
    # unset paths keep the entity default ("").
    replay = {
        "capture_path": os.environ.get(
            "HFT_REPLAY_CAPTURE", (VECTOR_DIR / "replay_capture.bin").as_posix()
        ),
        "expected_path": os.environ.get(
            "HFT_REPLAY_EXPECTED", (VECTOR_DIR / "replay_expected.bin").as_posix()
        ),
        "events_path": os.environ.get("HFT_REPLAY_OUTPUT", ""),
    }
    generics["tb_replay"] = {name: value for name, value in replay.items() if value}
    return generics


def bench_configs() -> dict[str, dict[str, dict[str, int]]]:
    """Named configurations per test bench; each replaces the default one."""
    return {
        "tb_cdc_snapshot": {
            f"src{source_ps}ps_dst{destination_ps}ps": {
                "src_period_ps": source_ps,
                "dst_period_ps": destination_ps,
            }
            for source_ps, destination_ps in CDC_RATIOS
        }
    }


def configure_suite():
    from vunit import VUnit

    vu = VUnit.from_argv(compile_builtins=False)
    vu.add_vhdl_builtins()
    vu.add_osvvm()

    lib = vu.add_library("hft")
    for source in rtl_sources():
        lib.add_source_file(source)
    lib.add_source_file(ROOT / "zynq/ultrascale+/tb/hft_tb_pkg.vhd")
    lib.add_source_files(ROOT / "zynq/ultrascale+/tb" / "tb_*.vhd")

    for bench, generics in bench_generics().items():
        test_bench = lib.test_bench(bench)
        for name, value in generics.items():
            test_bench.set_generic(name, value)
    for bench, configs in bench_configs().items():
        test_bench = lib.test_bench(bench)
        for name, generics in configs.items():
            test_bench.add_config(name=name, generics=generics)

    if ENABLE_COVERAGE:
        # NVC accepts --cover only on elaborate, not analyse.
        lib.set_sim_option("nvc.elab_flags", [f"--cover={COVER_SPEC}"])
    return vu


def main() -> None:
    vu = configure_suite()

    def post_run(results: object) -> None:
        if not ENABLE_COVERAGE:
            return
        if vu.get_simulator_name() != "nvc":
            raise RuntimeError("HFT_VHDL_COVERAGE=1 requires VUNIT_SIMULATOR=nvc")
        output_root = Path(getattr(results, "_output_path", "vunit_out"))
        export_nvc_coverage(
            coverage_databases(output_root, ROOT, Path.cwd()),
            ROOT / "coverage-reports" / "vhdl",
        )

    vu.main(post_run=post_run)


if __name__ == "__main__":
    main()
