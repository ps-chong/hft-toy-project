#!/usr/bin/env python3
from __future__ import annotations

import os
import subprocess
from pathlib import Path

from vunit import VUnit


ROOT = Path(__file__).resolve().parents[2]
ENABLE_COVERAGE = os.environ.get("HFT_VHDL_COVERAGE", "0") == "1"
vu = VUnit.from_argv()
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
    lib.set_compile_option("enable_coverage", True)
    lib.set_sim_option("enable_coverage", True)
    lib.set_sim_option("nvc.elab_flags", ["--cover=branch,statement,functional"])


def post_run(results: object) -> None:
    if not ENABLE_COVERAGE:
        return
    coverage_dir = ROOT / "coverage-reports" / "vhdl"
    coverage_dir.mkdir(parents=True, exist_ok=True)
    results.merge_coverage(file_name=str(coverage_dir / "coverage_data"))
    if vu.get_simulator_name() == "nvc":
        subprocess.run(
            [
                "nvc",
                "--cover-report",
                str(coverage_dir / "coverage_data.ncdb"),
                "-o",
                str(coverage_dir / "html"),
            ],
            check=True,
        )


vu.main(post_run=post_run)
