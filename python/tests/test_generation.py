from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def load_render_module():
    spec = importlib.util.spec_from_file_location(
        "hft_render_diagrams", ROOT / "scripts" / "render_diagrams.py"
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_generated_contracts_are_current() -> None:
    subprocess.run(
        [sys.executable, "protocol/generator/generate.py", "--check"],
        cwd=ROOT,
        check=True,
    )


def test_puppeteer_config_uses_system_chrome(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    render = load_render_module()
    chrome = tmp_path / "chrome"
    chrome.write_text("", encoding="utf-8")
    monkeypatch.setattr(render, "CHROME_CANDIDATES", (str(chrome),))
    monkeypatch.setattr(render.tempfile, "gettempdir", lambda: str(tmp_path))
    config = render.resolve_puppeteer_config(ROOT / "scripts" / "mermaid-puppeteer.json")
    assert config is not None
    payload = json.loads(config.read_text(encoding="utf-8"))
    assert payload["executablePath"] == str(chrome)
    assert "--no-sandbox" in payload["args"]


def test_extracted_mermaid_sources_are_current() -> None:
    subprocess.run(
        [sys.executable, "scripts/render_diagrams.py"],
        cwd=ROOT,
        check=True,
    )
    result = subprocess.run(
        ["git", "diff", "--exit-code", "--", "docs/architecture/diagrams"],
        cwd=ROOT,
        check=False,
        capture_output=True,
        text=True,
    )
    dirty = [
        line
        for line in result.stdout.splitlines()
        if line.startswith("diff --git") and line.endswith(".mmd")
    ]
    assert not dirty, result.stdout


def test_vector_manifest_references_existing_files() -> None:
    vector_dir = ROOT / "protocol" / "vectors"
    manifest = json.loads((vector_dir / "manifest.json").read_text(encoding="utf-8"))

    assert len(manifest["schema_sha256"]) == 64
    for vector in manifest["vectors"]:
        payload = vector_dir / vector["file"]
        assert payload.is_file()
        assert payload.stat().st_size >= 20
        ignored = subprocess.run(
            ["git", "check-ignore", "-q", str(payload.relative_to(ROOT))],
            cwd=ROOT,
            check=False,
        )
        assert ignored.returncode == 1
