SUMMARY = "MYD-CZU5EV-V2 HFT application package group"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    hftd \
    hft-nvme-data \
    hft-update-health \
    libmetal \
    open-amp \
    nvme-cli \
    python3-core \
    python3-json \
    systemd-analyze \
"

# The public MYIR pinout cannot generate the standalone R5 BSP. Add the
# firmware/remoteproc packages only after a verified XSA/SDT machine is enabled.
RDEPENDS:${PN}:append:hft-myd-czu5ev-v2 = " \
    ${@'hft-r5-firmware hft-remoteproc' if d.getVar('HFT_ENABLE_R5_MULTICONFIG') == '1' else ''} \
"
