SUMMARY = "SWUpdate bundle for the ZCU102 HFT A/B image"
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

do_swuimage:prepend() {
    if [ "${HFT_SWUPDATE_SIGNING}" = "1" ]; then
        test -r "${HFT_SWUPDATE_PRIVATE_KEY}" || bbfatal "missing SWUpdate private key"
        test -r "${HFT_SWUPDATE_CERTIFICATE}" || bbfatal "missing SWUpdate certificate"
    fi
}
