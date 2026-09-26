from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_generated_contracts_are_current() -> None:
    subprocess.run(
        [sys.executable, "protocol/generator/generate.py", "--check"],
        cwd=ROOT,
        check=True,
    )


def test_vector_manifest_references_existing_files() -> None:
    vector_dir = ROOT / "protocol" / "vectors"
    manifest = json.loads((vector_dir / "manifest.json").read_text(encoding="utf-8"))

    assert len(manifest["schema_sha256"]) == 64
    for vector in manifest["vectors"]:
        payload = vector_dir / vector["file"]
        assert payload.is_file()
        assert payload.stat().st_size >= 20
