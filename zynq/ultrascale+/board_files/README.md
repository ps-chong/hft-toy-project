# MYD-CZU5EV-V2 Vivado board data

This repository carries a minimal, part-level board definition for the
MYIR MYD-CZU5EV-V2:

- Device: `XCZU5EV-2SFVC784`
- Vivado part: `xczu5ev-sfvc784-2-e`
- PL transceiver bank: Bank 224
- Source: [MYC-CZU3EG/4EV/5EV-V2 Pinouts Description, V1.1][pinout]

[pinout]: https://www.myirtech.com/download/ZU3EG/MYC-CZU3EG_Pinouts.pdf

The pinout is public, but it is not a replacement for MYIR's product-disk
Vivado project. In particular, it does not contain verified DDR timing,
PS MIO configuration, boot-device settings, or the physical mapping from
GTH lane numbers to the four labelled SFP+ cages. Those details must be
verified from vendor data or on hardware before enabling an integrated
PS/XSA or bitstream build.

The batch build prepends this directory to Vivado's `board.repoPaths`.
It also selects the FPGA part explicitly, so out-of-context synthesis does
not depend on installing board files globally.
