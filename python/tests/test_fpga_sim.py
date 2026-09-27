from __future__ import annotations

import importlib.util
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load_run_module():
    spec = importlib.util.spec_from_file_location(
        "hft_fpga_sim_run", ROOT / "fpga" / "sim" / "run.py"
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_coverage_databases_prefer_ncdb(tmp_path: Path) -> None:
    run = load_run_module()
    nested = tmp_path / "nvc" / "libraries" / "hft"
    nested.mkdir(parents=True)
    database = nested / "tb_hft_pipeline.ncdb"
    database.write_bytes(b"ncdb")
    (nested / "stale.covdb").write_bytes(b"old")
    assert run.coverage_databases(tmp_path) == [database]


def test_export_nvc_coverage_copies_single_database(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    run = load_run_module()
    source = tmp_path / "work" / "top.ncdb"
    source.parent.mkdir()
    source.write_bytes(b"coverage")
    dest = tmp_path / "report"
    commands: list[list[str]] = []

    def fake_run(command: list[str], check: bool) -> SimpleNamespace:
        del check
        commands.append(command)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(run.subprocess, "run", fake_run)
    run.export_nvc_coverage([source], dest)
    assert (dest / "coverage_data.ncdb").read_bytes() == b"coverage"
    assert commands[0][:2] == ["nvc", "--cover-report"]
    assert commands[1][:2] == ["nvc", "--cover-export"]


def test_export_nvc_coverage_merges_and_rejects_empty(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    run = load_run_module()
    first = tmp_path / "a.ncdb"
    second = tmp_path / "b.ncdb"
    first.write_bytes(b"a")
    second.write_bytes(b"b")
    dest = tmp_path / "report"
    commands: list[list[str]] = []

    def fake_run(command: list[str], check: bool) -> SimpleNamespace:
        del check
        commands.append(command)
        if command[1] == "--cover-merge":
            Path(command[3]).write_bytes(b"merged")
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(run.subprocess, "run", fake_run)
    run.export_nvc_coverage([first, second], dest)
    assert commands[0][:2] == ["nvc", "--cover-merge"]
    assert (dest / "coverage_data.ncdb").read_bytes() == b"merged"
    with pytest.raises(RuntimeError, match="no coverage databases"):
        run.export_nvc_coverage([], dest)
