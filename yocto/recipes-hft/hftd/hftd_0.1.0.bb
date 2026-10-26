SUMMARY = "Rust control, OUCH gateway, and analytics services"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=996a749c2ba3c05ef939ef023101056d"

# meta-rust-bin's cargo_bin (Rust 1.97.1): poky's cargo class carries Rust
# 1.75, which cannot build this edition-2024 workspace.
inherit cargo_bin systemd useradd

SRC_URI = "${HFT_REPOSITORY} \
           file://hftd.service \
           file://hftd.tmpfiles \
"
SRCREV = "${HFT_SRCREV}"
S = "${WORKDIR}/git"

# cargo downloads crates during compilation; Cargo.lock pins every version.
do_compile[network] = "1"
EXTRA_CARGO_FLAGS = "--locked --package hftd --package hftctl"

# cc-rs compiles build-host C code (ring, pulled into sqlx's compile-time
# macros) with HOST_CC and falls back to the target CC without it; cargo_bin
# exports the native wrappers only as BUILD_CC/BUILD_CXX.
do_compile:prepend() {
    export HOST_CC="${WRAPPER_DIR}/cc-native-wrapper.sh"
    export HOST_CXX="${WRAPPER_DIR}/cxx-native-wrapper.sh"
}

SYSTEMD_SERVICE:${PN} = "hftd.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system hft"
USERADD_PARAM:${PN} = "--system --home /data/hft --no-create-home \
                       --gid hft --shell /sbin/nologin hft"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${CARGO_BINDIR}/hftd ${D}${bindir}/hftd
    install -m 0755 ${CARGO_BINDIR}/hftctl ${D}${bindir}/hftctl

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/hftd.service \
        ${D}${systemd_system_unitdir}/hftd.service
    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/hftd.tmpfiles \
        ${D}${libdir}/tmpfiles.d/hftd.conf
}

FILES:${PN} += "${libdir}/tmpfiles.d/hftd.conf"
