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
        "axis64_to_byte.vhd",
        "udp_ipv4_rx.vhd",
        "telemetry_udp_tx.vhd",
        "myd_czu5ev_v2_hft_top.vhd",
    ):
        lib.add_source_file(ROOT / "zynq/ultrascale+/rtl" / source)
    lib.add_source_files(ROOT / "zynq/ultrascale+/tb" / "tb_*.vhd")

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
