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

# ext4.gz and bootvfat.gz are the rootfs and boot-slot artifacts the SWUpdate
# bundle (deploy/swupdate/sw-description) installs.
IMAGE_FSTYPES += "tar.zst ext4 ext4.gz bootvfat.gz wic wic.bmap"
WKS_SEARCH_PATH:append = ":${LAYERDIR}/wic"

# bootvfat: the IMAGE_BOOT_FILES that wic's bootimg-partition writes into
# boot_a/boot_b, as a standalone FAT image the size of one boot slot. Entries
# use wic's "source[;destination]" form; globs are not supported.
IMAGE_TYPES += "bootvfat"
HFT_BOOT_SLOT_KIB = "131072"
do_image_bootvfat[depends] += " \
    dosfstools-native:do_populate_sysroot \
    mtools-native:do_populate_sysroot \
    virtual/kernel:do_deploy \
    u-boot-xlnx-scr:do_deploy \
"
IMAGE_CMD:bootvfat() {
    out="${IMGDEPLOYDIR}/${IMAGE_NAME}.bootvfat"
    rm -f "$out"
    mkfs.vfat -n BOOT -C "$out" ${HFT_BOOT_SLOT_KIB}
    boot_files='${IMAGE_BOOT_FILES}'
    for entry in $boot_files; do
        src="${entry%%;*}"
        dst="${entry#*;}"
        [ "$dst" = "$entry" ] && dst="$(basename "$src")"
        [ -f "${DEPLOY_DIR_IMAGE}/$src" ] || bbfatal "IMAGE_BOOT_FILES entry $src is not in ${DEPLOY_DIR_IMAGE}"
        MTOOLS_SKIP_CHECK=1 mcopy -o -i "$out" "${DEPLOY_DIR_IMAGE}/$src" "::/$dst"
    done
}

# Each A/B rootfs slot is 1536 MiB (wic/hft-myd-czu5ev-v2-ab.wks.in). An image
# that would not fit fails here at build time, not at SWUpdate install.
IMAGE_ROOTFS_MAXSIZE = "1433600"

# The SDK can build C++ and Rust ONNX Runtime consumers.
TOOLCHAIN_TARGET_TASK:append = "${@' onnxruntime-dev' if d.getVar('HFT_ENABLE_ONNX') == '1' else ''}"

VOLATILE_LOG_DIR = "no"
ROOTFS_POSTPROCESS_COMMAND += "hft_prepare_persistent_paths; "

hft_prepare_persistent_paths() {
    install -d ${IMAGE_ROOTFS}/data/postgresql
    install -d ${IMAGE_ROOTFS}/data/hft
    install -d ${IMAGE_ROOTFS}/var/lib
    ln -snf /data/postgresql ${IMAGE_ROOTFS}/var/lib/postgresql
}
