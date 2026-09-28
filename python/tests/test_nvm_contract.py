from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_emmc_ab_layout_fits_four_gigabyte_device() -> None:
    wks = (
        ROOT / "yocto" / "wic" / "hft-myd-czu5ev-v2-ab.wks.in"
    ).read_text(encoding="utf-8")
    sizes = [int(value) for value in re.findall(r"--size\s+(\d+)", wks)]
    assert sizes == [128, 128, 1536, 1536]
    assert sum(sizes) <= 3584
    assert "--label hft_data" not in wks


def test_nvme_mount_is_labelled_and_never_formats_automatically() -> None:
    files = ROOT / "yocto" / "recipes-support" / "nvme" / "files"
    mount = (files / "data.mount").read_text(encoding="utf-8")
    prepare = (files / "hft-data-prepare.service").read_text(encoding="utf-8")
    assert "What=/dev/disk/by-partlabel/hft_data" in mount
    assert "Where=/data" in mount
    assert "Requires=data.mount" in prepare
    assert "mkfs" not in mount + prepare


def test_nvme_provisioning_requires_explicit_device_and_confirmation() -> None:
    script = (
        ROOT
        / "yocto"
        / "recipes-support"
        / "nvme"
        / "files"
        / "hft-provision-nvme"
    )
    subprocess.run(["sh", "-n", str(script)], check=True)
    result = subprocess.run(
        ["sh", str(script)], check=False, capture_output=True, text=True
    )
    assert result.returncode == 2
    assert "/dev/nvmeXnY --yes" in result.stderr


def test_kernel_enables_zynqmp_pcie_and_nvme() -> None:
    config = (
        ROOT
        / "yocto"
        / "recipes-kernel"
        / "linux"
        / "files"
        / "hft-nvme.cfg"
    ).read_text(encoding="utf-8")
    assert "CONFIG_PCIE_XILINX_NWL=y" in config
    assert "CONFIG_BLK_DEV_NVME=y" in config
    assert "CONFIG_EXT4_FS=y" in config
