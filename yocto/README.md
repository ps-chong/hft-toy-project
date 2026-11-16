# Yocto image

The `kas/myd-czu5ev-v2.yml` manifest pins Scarthgap/AMD 2026.1 layers and adds
this directory as `meta-hft`.

```bash
kas checkout yocto/kas/myd-czu5ev-v2.yml
kas shell yocto/kas/myd-czu5ev-v2.yml -c 'bitbake-layers show-layers'
kas build yocto/kas/myd-czu5ev-v2.yml
```

The intended output is an A/B WIC image, SPDX manifest, R5 firmware package,
and SWUpdate bundle. Full image construction requires substantial disk space
and a verified MYIR PS/DDR preset exported as AMD SDT artifacts. The generic
machine is intentionally non-deployable until those artifacts are supplied.
The build does not invoke Vivado and never deploys to a board.

## Release builds

`kas/myd-czu5ev-v2.yml` is the development manifest: `HFT_SRCREV` defaults to
`AUTOREV` (the tip of `develop`), the image carries `debug-tweaks` (an empty
root password) and the SWUpdate web interface, and the bundle is unsigned.
`kas/release.yml` is an overlay for images that may be installed on a board:

```bash
HFT_SRCREV=<40-character commit hash> \
HFT_SWUPDATE_PRIVATE_KEY=/secure/swupdate-signing-key.pem \
HFT_SWUPDATE_CERTIFICATE=/secure/swupdate-signing-cert.pem \
HFT_SWUPDATE_PUBLIC_CERT=/secure/swupdate-signing-cert.pem \
kas build yocto/kas/release.yml
```

It sets `HFT_RELEASE = "1"`, removes `debug-tweaks` and `swupdate-www`, turns on
CMS signing of the bundle, and inherits `classes/hft-release.bbclass`. That
class refuses to parse the configuration, before any task runs, unless
`HFT_SRCREV` is a 40-character commit hash, the three signing variables name
existing files, and `debug-tweaks` is gone. Key handling is described in
`deploy/swupdate/keys/README.md`.

Without `debug-tweaks` the image has no shell login; a site layer has to add
accounts or authorized keys. CI (`yocto.yml`) builds the development manifest.

## ONNX Runtime

`recipes-ml/` vendors the hermetic `onnx` 1.16.1 and `onnxruntime` 1.20.1
recipes from meta-arago Scarthgap (commit `dd1b7f9`, provenance in each recipe
header), together with meta-arago's `abseil-cpp` upgrade to the 20240722 LTS,
which ONNX Runtime 1.20.1 requires. meta-arago-extras itself is not a layer
here because it depends on the TI BSP layers. Every bundled dependency is
fetched through `SRC_URI` and CMake runs fully disconnected, so `DL_DIR`
mirrors and the source-inclusive SPDX cover it; the recipe's `LICENSE` lists
each bundled component.

`HFT_ENABLE_ONNX ?= "1"` (kas `local_conf_header`) pulls in
`packagegroup-hft-ml`: `onnxruntime`, `python3-onnxruntime`, and
`hft-onnx-smoke`, whose `do_smoke_test` task runs the aarch64 binary under QEMU
user mode at build time. The SDK gains `onnxruntime-dev`. Set it to `0` to
leave ONNX out. See [docs/acceleration.md](../docs/acceleration.md) for the
policy.

`hft-image` sets `IMAGE_ROOTFS_MAXSIZE` to 1400 MiB, below the 1536 MiB A/B
rootfs slot, so an image that would not fit fails at build time rather than
at SWUpdate install. The WIC layout pins both boot slots at 128 MiB and both
rootfs slots at 1536 MiB (`--fixed-size`).

## SWUpdate bundle

`hft-image-update` packs the rootfs (`.rootfs.ext4.gz`) and the boot-slot
image (`.rootfs.bootvfat.gz`, the `IMAGE_BOOT_FILES` in a 128 MiB FAT image)
under the shared `deploy/swupdate/sw-description`. SWUpdate installs them into
the inactive `rootfs_<slot>`/`boot_<slot>` partitions.

```bash
kas shell yocto/kas/myd-czu5ev-v2.yml -c 'bitbake onnxruntime hft-onnx-smoke'
```

## Deferred hardware checks

The current layer encodes the reserved memory and remoteproc contract, but the
R5 node labels and PL address map must be compared with the XSA/SDT exported by
the local Vivado 2026.1 build before flashing an image. No board deployment is
part of current CI. Known gaps, recorded so they are not mistaken for working
features:

- **R5 multiconfig.** `HFT_ENABLE_R5_MULTICONFIG = "1"` cannot be enabled yet.
  The standalone layers (`xilinx-freertos`, the R5 machine) live in the
  `meta-xilinx` checkout but are not enabled in the kas manifest, and no
  `hft-myd-czu5ev-v2-cortexr5-0` machine is defined; BitBake's sanity check
  stops with `DISTRO 'xilinx-freertos' not found`. It needs those layers and a
  machine generated from the MYIR SDT/XSA.
- **Remoteproc unit.** `hftd.service` has `Requires=hft-remoteproc.service`,
  but `hft-remoteproc` and `hft-r5-firmware` are part of the image only with
  the R5 multiconfig. A default image therefore has no unit for `hftd` to
  require, and `hftd` does not start there.
- **Firmware size.** The freestanding R5 link is 663,176 bytes (431,520 text,
  4,260 data, 227,396 bss), larger than the 256 KiB `r5_firmware` carve-out.
  The board linker script differs, so measure it at bring-up.
- **`/dev/rpmsg0`.** Nothing here creates the RPMsg character device; it is
  expected from the BSP platform layer. See
  `docs/architecture/ipc-memory.md`.
- **Boot chain and device tree.** U-Boot, TF-A, the FSBL and the PMU firmware
  are not built, nothing reads `boot_slot`, and the `device-tree` recipe is
  skipped, so the boot partition has no `system.dtb`. See
  `docs/architecture/boot-update.md`.
