SUMMARY = "Load and supervise HFT R5 firmware through remoteproc"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = "file://hft-remoteproc.service file://start-r5.sh"

RDEPENDS:${PN} += "bash hft-r5-firmware"
SYSTEMD_SERVICE:${PN} = "hft-remoteproc.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${WORKDIR}/start-r5.sh ${D}${bindir}/hft-start-r5
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/hft-remoteproc.service \
        ${D}${systemd_system_unitdir}/hft-remoteproc.service
}
