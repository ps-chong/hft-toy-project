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

`HFT_SRCREV` must be set to an immutable commit in release builds. The default
`AUTOREV` exists only so a developer can build the current `develop` branch.
Release signing additionally requires the external variables documented in
`deploy/swupdate/keys/README.md`.

## ONNX Runtime

`recipes-ml/` vendors the hermetic `onnx` 1.16.1 and `onnxruntime` 1.20.1
recipes from meta-arago Scarthgap (commit `dd1b7f9`, provenance in each recipe
header). meta-arago-extras itself is not a layer here because it depends on
the TI BSP layers. Every bundled dependency is fetched through `SRC_URI` and
CMake runs fully disconnected, so `DL_DIR` mirrors and the source-inclusive
SPDX cover it; the recipe's `LICENSE` lists each bundled component.

`HFT_ENABLE_ONNX ?= "1"` (kas `local_conf_header`) pulls in
`packagegroup-hft-ml`: `onnxruntime`, `python3-onnxruntime`, and
`hft-onnx-smoke`, whose `do_smoke_test` task runs the aarch64 binary under QEMU
user mode at build time. The SDK gains `onnxruntime-dev`. Set it to `0` to
leave ONNX out. See [docs/acceleration.md](../docs/acceleration.md) for the
policy.

`hft-image` sets `IMAGE_ROOTFS_MAXSIZE` to 1400 MiB, below the 1536 MiB A/B
rootfs slot, so an image that would not fit fails at build time rather than
at SWUpdate install.

```bash
kas shell yocto/kas/myd-czu5ev-v2.yml -c 'bitbake onnxruntime hft-onnx-smoke'
```

## Deferred hardware checks

The current layer encodes the reserved memory and remoteproc contract, but the
R5 node labels and PL address map must be compared with the XSA/SDT exported by
the local Vivado 2026.1 build before flashing an image. No board deployment is
part of current CI.
