SUMMARY = "SWUpdate bundle for the MYD-CZU5EV-V2 HFT A/B image"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit swupdate

FILESEXTRAPATHS:prepend := "${LAYERDIR}/../deploy/swupdate:"
SRC_URI = "file://sw-description"

SWUPDATE_IMAGES = "hft-image"
SWUPDATE_IMAGES_FSTYPES[hft-image] = ".ext4.gz"

HFT_SWUPDATE_SIGNING ?= "0"
SWUPDATE_SIGNING = "${@'CMS' if d.getVar('HFT_SWUPDATE_SIGNING') == '1' else ''}"
SWUPDATE_PRIVATE_KEY = "${HFT_SWUPDATE_PRIVATE_KEY}"
SWUPDATE_CERTIFICATE = "${HFT_SWUPDATE_CERTIFICATE}"

python do_swuimage:prepend() {
    if d.getVar("HFT_SWUPDATE_SIGNING") == "1":
        import os

        private_key = d.getVar("HFT_SWUPDATE_PRIVATE_KEY")
        certificate = d.getVar("HFT_SWUPDATE_CERTIFICATE")
        if not private_key or not os.path.isfile(private_key):
            bb.fatal("missing SWUpdate private key")
        if not certificate or not os.path.isfile(certificate):
            bb.fatal("missing SWUpdate certificate")
}
