#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COVER_SPEC = "branch,statement,functional"
ENABLE_COVERAGE = os.environ.get("HFT_VHDL_COVERAGE", "0") == "1"


def coverage_databases(output_root: Path) -> list[Path]:
    databases = sorted(path for path in output_root.rglob("*.ncdb") if path.is_file())
    if not databases:
        databases = sorted(path for path in output_root.rglob("*.covdb") if path.is_file())
    return databases


def export_nvc_coverage(databases: list[Path], dest: Path) -> None:
    if not databases:
        raise RuntimeError("NVC produced no coverage databases")

    dest.mkdir(parents=True, exist_ok=True)
    merged = dest / "coverage_data.ncdb"
    if len(databases) == 1:
        merged.write_bytes(databases[0].read_bytes())
    else:
        subprocess.run(
            ["nvc", "--cover-merge", "-o", str(merged), *[str(path) for path in databases]],
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


def configure_suite():
    from vunit import VUnit

    vu = VUnit.from_argv(compile_builtins=False)
    vu.add_vhdl_builtins()
    vu.add_osvvm()

    lib = vu.add_library("hft")
    lib.add_source_file(ROOT / "protocol/generated/vhdl/hft_protocol_pkg.vhd")
    for source in (
        "hft_types_pkg.vhd",
        "moldudp64_decoder.vhd",
        "itch_decoder.vhd",
        "order_book.vhd",
        "risk_guard.vhd",
        "signal_engine.vhd",
        "hft_pipeline.vhd",
        "zcu102_hft_top.vhd",
    ):
        lib.add_source_file(ROOT / "fpga/rtl" / source)
    lib.add_source_files(ROOT / "fpga/tb" / "tb_*.vhd")

    if ENABLE_COVERAGE:
        cover_flags = [f"--cover={COVER_SPEC}"]
        lib.set_compile_option("nvc.a_flags", cover_flags)
        lib.set_sim_option("nvc.elab_flags", cover_flags)
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
            coverage_databases(output_root),
            ROOT / "coverage-reports" / "vhdl",
        )

    vu.main(post_run=post_run)


if __name__ == "__main__":
    main()
