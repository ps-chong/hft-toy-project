SUMMARY = "Rust control, OUCH gateway, and analytics services"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=996a749c2ba3c05ef939ef023101056d"

inherit cargo systemd useradd

SRC_URI = "${HFT_REPOSITORY} \
           file://hftd.service \
           file://hftd.tmpfiles \
"
SRCREV = "${HFT_SRCREV}"
S = "${WORKDIR}/git"

CARGO_SRC_DIR = ""
CARGO_BUILD_FLAGS += "--workspace --package hftd --package hftctl"

SYSTEMD_SERVICE:${PN} = "hftd.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"
USERADD_PACKAGES = "${PN}"
GROUPADD_PARAM:${PN} = "--system hft"
USERADD_PARAM:${PN} = "--system --home /data/hft --no-create-home \
                       --gid hft --shell /sbin/nologin hft"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/hftd ${D}${bindir}/hftd
    install -m 0755 ${B}/target/${RUST_TARGET_SYS}/release/hftctl ${D}${bindir}/hftctl

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/hftd.service \
        ${D}${systemd_system_unitdir}/hftd.service
    install -d ${D}${libdir}/tmpfiles.d
    install -m 0644 ${WORKDIR}/hftd.tmpfiles \
        ${D}${libdir}/tmpfiles.d/hftd.conf
}

FILES:${PN} += "${libdir}/tmpfiles.d/hftd.conf"
