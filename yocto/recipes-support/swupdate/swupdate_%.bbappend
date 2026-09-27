FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:hft-zcu102 = " file://hft-swupdate.cfg file://swupdate.cfg"

PACKAGECONFIG:append:hft-zcu102 = " uboot lua mongoose"

do_install:append:hft-zcu102() {
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/swupdate.cfg ${D}${sysconfdir}/swupdate.cfg
    install -d ${D}${sysconfdir}/swupdate
    if [ -n "${HFT_SWUPDATE_PUBLIC_CERT}" ] &&
       [ -r "${HFT_SWUPDATE_PUBLIC_CERT}" ]; then
        install -m 0644 ${HFT_SWUPDATE_PUBLIC_CERT} \
            ${D}${sysconfdir}/swupdate/signing-cert.pem
    fi
}
