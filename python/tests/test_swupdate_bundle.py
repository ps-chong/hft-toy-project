from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read_newc(archive: bytes) -> dict[str, bytes]:
    entries: dict[str, bytes] = {}
    offset = 0
    while True:
        assert archive[offset : offset + 6] == b"070701"
        header = archive[offset + 6 : offset + 110]
        fields = [int(header[index : index + 8], 16) for index in range(0, 104, 8)]
        file_size = fields[6]
        name_size = fields[11]
        offset += 110
        name = archive[offset : offset + name_size - 1].decode()
        offset += name_size
        offset += (-offset) % 4
        data = archive[offset : offset + file_size]
        offset += file_size
        offset += (-offset) % 4
        if name == "TRAILER!!!":
            return entries
        entries[name] = data


def test_builds_deterministic_unsigned_bundle(tmp_path: Path) -> None:
    rootfs = tmp_path / "rootfs.ext4.gz"
    boot = tmp_path / "boot.vfat"
    output = tmp_path / "hft.swu"
    rootfs.write_bytes(b"rootfs-image")
    boot.write_bytes(b"boot-image")

    subprocess.run(
        [
            sys.executable,
            "deploy/swupdate/build_bundle.py",
            "--description",
            "deploy/swupdate/sw-description",
            "--rootfs",
            str(rootfs),
            "--boot",
            str(boot),
            "--output",
            str(output),
        ],
        cwd=ROOT,
        check=True,
    )

    entries = read_newc(output.read_bytes())
    assert list(entries) == [
        "sw-description",
        "hft-image-hft-zcu102.ext4.gz",
        "boot-a.vfat",
        "boot-b.vfat",
    ]
    description = entries["sw-description"].decode()
    assert hashlib.sha256(rootfs.read_bytes()).hexdigest() in description
    assert hashlib.sha256(boot.read_bytes()).hexdigest() in description
    assert "@ROOTFS_SHA256@" not in description
