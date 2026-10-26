SUMMARY = "ONNX Runtime smoke test for the MYD-CZU5EV-V2 image"
DESCRIPTION = "Runs one inference of a tiny model (y = 2x + 1) through the \
ONNX Runtime C++ API. The do_smoke_test task runs the aarch64 binary at build \
time under QEMU user mode, so the target library is proven to load and infer \
without hardware. Deliberately not part of hft-update-health: ONNX is \
noncritical and must never trigger an A/B rollback."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://hft-onnx-smoke.cpp \
    file://smoke.onnx \
    file://make_model.py \
"

S = "${WORKDIR}"

DEPENDS = "onnxruntime"

inherit pkgconfig qemu

do_compile() {
    ${CXX} ${CXXFLAGS} ${LDFLAGS} -std=c++17 -Wall -Wextra \
        $(pkg-config --cflags libonnxruntime) \
        ${S}/hft-onnx-smoke.cpp -o ${B}/hft-onnx-smoke \
        $(pkg-config --libs libonnxruntime)
}

# Run the target binary against the recipe sysroot with qemu-user.
do_smoke_test() {
    ${@qemu_run_binary(d, '${RECIPE_SYSROOT}', '${B}/hft-onnx-smoke')} ${S}/smoke.onnx
}
do_smoke_test[depends] += "qemu-native:do_populate_sysroot"
addtask smoke_test after do_compile before do_install

python () {
    if not bb.utils.contains('MACHINE_FEATURES', 'qemu-usermode', True, False, d):
        d.setVarFlag('do_smoke_test', 'noexec', '1')
}

do_install() {
    install -d ${D}${bindir} ${D}${datadir}/hft/onnx
    install -m 0755 ${B}/hft-onnx-smoke ${D}${bindir}/hft-onnx-smoke
    install -m 0644 ${S}/smoke.onnx ${D}${datadir}/hft/onnx/smoke.onnx
}

FILES:${PN} = "${bindir}/hft-onnx-smoke ${datadir}/hft/onnx"
RDEPENDS:${PN} = "onnxruntime"
