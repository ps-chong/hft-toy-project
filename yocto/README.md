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

## Deferred hardware checks

The current layer encodes the reserved memory and remoteproc contract, but the
R5 node labels and PL address map must be compared with the XSA/SDT exported by
the local Vivado 2026.1 build before flashing an image. No board deployment is
part of current CI.
