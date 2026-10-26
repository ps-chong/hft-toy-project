# ONNX Runtime 1.20.1 links absl::demangle_rust, which first appears in the
# 20240722 LTS; meta-oe scarthgap ships 20240116. This upgrade is vendored
# from meta-arago (https://git.yoctoproject.org/meta-arago), branch scarthgap,
# commit dd1b7f9b85c093931f3eed954d28eb6f52e271c1,
# meta-arago-extras/recipes-devtools/abseil-cpp/abseil-cpp-arago.inc (MIT),
# with its patches; meta-arago applies it to the same protobuf 4.25 stack.
# It is applied unconditionally here rather than for DISTRO "arago".

FILESEXTRAPATHS:prepend := "${THISDIR}/abseil-cpp:"

PV = "20240722.0"

SRCREV = "4447c7562e3bc702ade25105912dce503f0c4010"
BRANCH = "lts_2024_07_22"

SRC_URI:remove = "\
    file://abseil-ppc-fixes.patch \
    file://0004-PR-1644-unscaledcycleclock-remove-RISC-V-support.patch \
    file://0001-PR-1739-container-internal-Explicitly-include-cstdin.patch \
"

SRC_URI += "\
    file://0004-abseil-ppc-fixes.patch \
    file://0005-Don-t-match-Wnon-virtual-dtor-in-the-flags-are-neede.patch \
"
