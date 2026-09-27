FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append:hft-zcu102 = " file://hft-zcu102.dtsi"
EXTRA_DT_INCLUDE_FILES:append:hft-zcu102 = " hft-zcu102.dtsi"
