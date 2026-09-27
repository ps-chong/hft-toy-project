SUMMARY = "FreeRTOS/C++ cooperative HFT firmware for Cortex-R5-0"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://LICENSE;md5=996a749c2ba3c05ef939ef023101056d"

inherit cmake deploy

SRC_URI = "${HFT_REPOSITORY}"
SRCREV = "${HFT_SRCREV}"
S = "${WORKDIR}/git"
B = "${WORKDIR}/build"

DEPENDS += "freertos10-xilinx libxil xilstandalone xiltimer open-amp libmetal"

OECMAKE_GENERATOR = "Ninja"
EXTRA_OECMAKE += " \
    -DHFT_BUILD_TESTS=OFF \
    -DHFT_ENABLE_BOOST=ON \
    -DHFT_ENABLE_CIB=ON \
    -DHFT_WITH_XILINX_FREERTOS=ON \
"

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware
    install -m 0644 ${B}/r5/hft_r5_firmware.elf \
        ${D}${nonarch_base_libdir}/firmware/hft-r5.elf
}

do_deploy() {
    install -Dm0644 ${B}/r5/hft_r5_firmware.elf \
        ${DEPLOYDIR}/hft-r5.elf
}
addtask deploy after do_compile before do_build

FILES:${PN} = "${nonarch_base_libdir}/firmware/hft-r5.elf"
