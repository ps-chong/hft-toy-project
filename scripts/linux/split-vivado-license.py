#!/usr/bin/env python3
"""Write a copy of a Vivado 2026.1 license file that keeps only one tier.

Vivado 2026.1 selects a single tier at start-up and exposes only that tier's
devices. A license file holding both ALVEO and BASIC entries can start in
ALVEO, which hides the Zynq UltraScale+ XCZU5EV. FlexLM signs each feature
line separately, so dropping whole INCREMENT/PACKAGE blocks of the other tiers
keeps the remaining entries valid. The source file is never modified.

The defaults are the Windows %APPDATA% locations seen from WSL, which is
where Vivado (a Windows program here) and scripts/linux/common.sh look.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

TIERS = ("BASIC", "CORE", "PRO", "ALVEO")


def windows_appdata() -> Path:
    appdata = subprocess.run(
        ["/mnt/c/Windows/System32/cmd.exe", "/d", "/c", "echo %APPDATA%"],
        cwd="/mnt/c",
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    converted = subprocess.run(
        ["wslpath", "-u", appdata], check=True, capture_output=True, text=True
    ).stdout.strip()
    return Path(converted)


def blocks(lines: list[str]) -> list[list[str]]:
    """Group lines into keyword lines plus their '\\' continuations."""
    grouped: list[list[str]] = []
    current: list[str] = []
    for line in lines:
        current.append(line)
        if not line.rstrip().endswith("\\"):
            grouped.append(current)
            current = []
    if current:
        grouped.append(current)
    return grouped


def keep_tier(lines: list[str], tier: str) -> tuple[list[str], int]:
    kept: list[str] = []
    dropped = 0
    for block in blocks(lines):
        text = "\n".join(block)
        tier_match = re.search(r"License_Tier:([A-Z]+)", text)
        # Tier packages are named Vivado_<Tier>_Package (e.g. Vivado_Alveo_Package).
        package_match = re.search(
            r"^(PACKAGE|INCREMENT)\s+Vivado_([A-Za-z]+)_Package", text, re.MULTILINE
        )
        other_tier = tier_match is not None and tier_match.group(1) != tier
        other_package = package_match is not None and package_match.group(2).upper() != tier
        if other_tier or other_package:
            dropped += 1
            continue
        kept.extend(block)
    return kept, dropped


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--source", type=Path, help="default: %%APPDATA%%/XilinxLicense/Xilinx.lic"
    )
    parser.add_argument("--tier", choices=TIERS, default="BASIC")
    parser.add_argument(
        "--destination", type=Path, help="default: %%APPDATA%%/XilinxLicense-<tier>"
    )
    args = parser.parse_args()

    if args.source is None or args.destination is None:
        appdata = windows_appdata()
        args.source = args.source or appdata / "XilinxLicense" / "Xilinx.lic"
        args.destination = args.destination or appdata / f"XilinxLicense-{args.tier}"
    if not args.source.is_file():
        print(f"License file '{args.source}' was not found.", file=sys.stderr)
        return 1

    lines = args.source.read_text(encoding="ascii", errors="replace").splitlines()
    kept, dropped = keep_tier(lines, args.tier)
    if not any(f"License_Tier:{args.tier}" in line for line in kept):
        print(f"'{args.source}' holds no License_Tier:{args.tier} entries.", file=sys.stderr)
        return 1

    args.destination.mkdir(parents=True, exist_ok=True)
    output = args.destination / "Xilinx.lic"
    # Windows FlexLM reads CRLF files, like the PowerShell version writes.
    output.write_text("\r\n".join(kept) + "\r\n", encoding="ascii", newline="")
    print(f"Wrote {output} ({dropped} block(s) of other tiers removed).")
    print(f"Use it with: HFT_VIVADO_LICENSE='{args.destination}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
