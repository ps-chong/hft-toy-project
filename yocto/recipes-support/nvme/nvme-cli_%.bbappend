# Upstream's first-boot postinst writes a per-host NVMe-over-Fabrics host NQN
# and host ID into /etc. hft-image has a read-only rootfs, where first-boot
# configuration cannot run (do_rootfs fails), and it uses only local PCIe
# NVMe, so the identifiers are not needed; baking them into the image would
# give every board the same ones.
python () {
    d.delVar('pkg_postinst_ontarget:' + d.getVar('PN'))
}
