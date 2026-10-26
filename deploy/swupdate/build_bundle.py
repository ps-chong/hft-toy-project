"""Build a deterministic SWUpdate `newc` archive without shell pipelines.

Host counterpart of the Yocto `hft-image-update` recipe: both read the same
`sw-description`, whose payload names are the Yocto deploy link names and whose
hashes use meta-swupdate's `$swupdate_get_sha256(file)` placeholder.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

ROOTFS_ENTRY = "hft-image-hft-myd-czu5ev-v2.rootfs.ext4.gz"
BOOT_ENTRY = "hft-image-hft-myd-czu5ev-v2.rootfs.bootvfat.gz"
SHA256_PLACEHOLDER = re.compile(r"\$swupdate_get_sha256\(([^)]+)\)")


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


def expand_hashes(description: str, payloads: dict[str, Path]) -> str:
    def digest(match: re.Match[str]) -> str:
        name = match.group(1)
        if name not in payloads:
            raise SystemExit(f"sw-description hashes unknown payload {name}")
        return sha256(payloads[name])

    return SHA256_PLACEHOLDER.sub(digest, description)


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

    payloads = {ROOTFS_ENTRY: args.rootfs, BOOT_ENTRY: args.boot}
    description = expand_hashes(args.description.read_text(encoding="utf-8"), payloads)
    description_bytes = description.encode()

    entries = [Entry("sw-description", description_bytes)]
    if args.key and args.certificate:
        entries.append(
            Entry(
                "sw-description.sig",
                sign_description(description_bytes, args.key, args.certificate),
            )
        )
    entries.extend(Entry(name, path.read_bytes()) for name, path in payloads.items())

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_bytes(newc(entries))
    os.replace(temporary, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
