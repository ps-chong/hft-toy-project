SUMMARY = "Fail-closed NVMe data mount and provisioning tools"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit systemd

SRC_URI = " \
    file://data.mount \
    file://hft-data-prepare.service \
    file://hft-prepare-data \
    file://hft-provision-nvme \
"

RDEPENDS:${PN} = " \
    e2fsprogs-mke2fs \
    gptfdisk \
    parted \
    util-linux-lsblk \
    util-linux-mountpoint \
    util-linux-wipefs \
    udev \
"

SYSTEMD_SERVICE:${PN} = "data.mount hft-data-prepare.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/data.mount \
        ${D}${systemd_system_unitdir}/data.mount
    install -m 0644 ${WORKDIR}/hft-data-prepare.service \
        ${D}${systemd_system_unitdir}/hft-data-prepare.service

    install -d ${D}${libexecdir}
    install -m 0755 ${WORKDIR}/hft-prepare-data \
        ${D}${libexecdir}/hft-prepare-data

    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/hft-provision-nvme \
        ${D}${sbindir}/hft-provision-nvme

    install -d ${D}${sysconfdir}/systemd/system/postgresql.service.d
    cat >${D}${sysconfdir}/systemd/system/postgresql.service.d/10-hft-data.conf <<'EOF'
[Unit]
Requires=hft-data-prepare.service
After=hft-data-prepare.service
EOF
}

FILES:${PN} += " \
    ${systemd_system_unitdir}/data.mount \
    ${systemd_system_unitdir}/hft-data-prepare.service \
    ${libexecdir}/hft-prepare-data \
    ${sysconfdir}/systemd/system/postgresql.service.d/10-hft-data.conf \
"
