SUMMARY = "SWUpdate bundle for the MYD-CZU5EV-V2 HFT A/B image"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit swupdate

FILESEXTRAPATHS:prepend := "${THISDIR}/../../../deploy/swupdate:"
SRC_URI = "file://sw-description"

# The payload names in sw-description are these deploy link names
# (hft-image-hft-myd-czu5ev-v2.rootfs.<type>).
SWUPDATE_IMAGES = "hft-image"
SWUPDATE_IMAGES_FSTYPES[hft-image] = ".rootfs.ext4.gz .rootfs.bootvfat.gz"
SWUPDATE_IMAGES_NOAPPEND_MACHINE[hft-image] = "0"
# Orders do_swuimage after hft-image:do_image_complete.
IMAGE_DEPENDS = "hft-image"

# swupdate-common.bbclass fails the build when signing is on and the key or
# certificate is missing.
HFT_SWUPDATE_SIGNING ?= "0"
SWUPDATE_SIGNING = "${@'CMS' if d.getVar('HFT_SWUPDATE_SIGNING') == '1' else ''}"
SWUPDATE_CMS_KEY = "${HFT_SWUPDATE_PRIVATE_KEY}"
SWUPDATE_CMS_CERT = "${HFT_SWUPDATE_CERTIFICATE}"
