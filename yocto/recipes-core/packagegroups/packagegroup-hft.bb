SUMMARY = "ZCU102 HFT application package group"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    hftd \
    hftctl \
    hft-r5-firmware \
    hft-remoteproc \
    hft-update-health \
    libmetal \
    open-amp \
    python3-core \
    python3-json \
    systemd-analyze \
"
