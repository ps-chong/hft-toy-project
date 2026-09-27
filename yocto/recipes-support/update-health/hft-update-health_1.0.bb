SUMMARY = "Confirm healthy SWUpdate A/B boot"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = "file://hft-update-health.service file://hft-update-health.sh"

RDEPENDS:${PN} += "bash libubootenv-bin postgresql-client hftd"
SYSTEMD_SERVICE:${PN} = "hft-update-health.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/hft-update-health.sh \
        ${D}${bindir}/hft-update-health
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/hft-update-health.service \
        ${D}${systemd_system_unitdir}/hft-update-health.service
}
