SUMMARY = "MYD-CZU5EV-V2 HFT A/B demonstration image"
LICENSE = "MIT"

inherit core-image

IMAGE_FEATURES += "ssh-server-openssh read-only-rootfs"

IMAGE_INSTALL:append = " \
    packagegroup-hft \
    kernel-modules \
    openssh-sftp-server \
    postgresql \
    postgresql-client \
    swupdate \
    swupdate-www \
"

IMAGE_FSTYPES += "tar.zst ext4 wic wic.bmap"
WKS_SEARCH_PATH:append = ":${LAYERDIR}/wic"

VOLATILE_LOG_DIR = "no"
ROOTFS_POSTPROCESS_COMMAND += "hft_prepare_persistent_paths; "

hft_prepare_persistent_paths() {
    install -d ${IMAGE_ROOTFS}/data/postgresql
    install -d ${IMAGE_ROOTFS}/data/hft
    install -d ${IMAGE_ROOTFS}/var/lib
    ln -snf /data/postgresql ${IMAGE_ROOTFS}/var/lib/postgresql
}
