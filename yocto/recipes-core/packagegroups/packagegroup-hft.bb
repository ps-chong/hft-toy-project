SUMMARY = "MYD-CZU5EV-V2 HFT application package group"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    hftd \
    hftctl \
    hft-r5-firmware \
    hft-remoteproc \
    hft-nvme-data \
    hft-update-health \
    libmetal \
    open-amp \
    nvme-cli \
    python3-core \
    python3-json \
    systemd-analyze \
"
