"""Build a deterministic SWUpdate `newc` archive without shell pipelines."""

from __future__ import annotations

import argparse
import hashlib
import os
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Entry:
    name: str
    data: bytes
    mode: int = 0o100644


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def align4(size: int) -> int:
    return (-size) % 4


def newc(entries: list[Entry]) -> bytes:
    output = bytearray()
    for inode, entry in enumerate([*entries, Entry("TRAILER!!!", b"")], start=1):
        name = entry.name.encode() + b"\0"
        fields = (
            inode,
            entry.mode,
            0,
            0,
            1,
            0,
            len(entry.data),
            0,
            0,
            0,
            0,
            len(name),
            0,
        )
        output.extend(b"070701")
        output.extend("".join(f"{field:08x}" for field in fields).encode())
        output.extend(name)
        output.extend(b"\0" * align4(110 + len(name)))
        output.extend(entry.data)
        output.extend(b"\0" * align4(len(entry.data)))
    return bytes(output)


def sign_description(description: bytes, key: Path, certificate: Path) -> bytes:
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "sw-description"
        signature = Path(directory) / "sw-description.sig"
        source.write_bytes(description)
        subprocess.run(
            [
                "openssl",
                "cms",
                "-sign",
                "-binary",
                "-in",
                str(source),
                "-signer",
                str(certificate),
                "-inkey",
                str(key),
                "-outform",
                "DER",
                "-out",
                str(signature),
                "-nosmimecap",
                "-nocerts",
                "-noattr",
            ],
            check=True,
        )
        return signature.read_bytes()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--description", type=Path, required=True)
    parser.add_argument("--rootfs", type=Path, required=True)
    parser.add_argument("--boot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--key", type=Path)
    parser.add_argument("--certificate", type=Path)
    args = parser.parse_args()

    if bool(args.key) != bool(args.certificate):
        parser.error("--key and --certificate must be supplied together")

    description = args.description.read_text(encoding="utf-8")
    description = description.replace("@ROOTFS_SHA256@", sha256(args.rootfs))
    description = description.replace("@BOOT_SHA256@", sha256(args.boot))
    description_bytes = description.encode()

    entries = [Entry("sw-description", description_bytes)]
    if args.key and args.certificate:
        entries.append(
            Entry(
                "sw-description.sig",
                sign_description(description_bytes, args.key, args.certificate),
            )
        )
    entries.extend(
        (
            Entry("hft-image-hft-myd-czu5ev-v2.ext4.gz", args.rootfs.read_bytes()),
            Entry("boot-a.vfat", args.boot.read_bytes()),
            Entry("boot-b.vfat", args.boot.read_bytes()),
        )
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_bytes(newc(entries))
    os.replace(temporary, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
