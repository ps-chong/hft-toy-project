# MYD-CZU5EV-V2 board integration

## Public hardware contract

The target is MYIR part `MYD-CZU5EV-V2-4E4D-1200-C`, containing an
`XCZU5EV-2SFVC784` MPSoC, 4 GB DDR4, 4 GB eMMC, four PL GTH lanes, and four
PS-GTR lanes. The checked-in Vivado board data is derived from MYIR's public
[MYC-CZU3EG/4EV/5EV-V2 pinout][pinout].

[pinout]: https://www.myirtech.com/download/ZU3EG/MYC-CZU3EG_Pinouts.pdf

| Function | Bank/lane | P/N balls | Project role |
| --- | --- | --- | --- |
| PL GTH TX/RX 0 | 224/0 | W4/W3, Y2/Y1 | 10G UDP ingress cage |
| PL GTH TX/RX 1 | 224/1 | U4/U3, V2/V1 | 10G UDP telemetry cage |
| PL GTH refclk 0 | 224 | Y6/Y5 | Shared 156.25 MHz reference |
| PS-GTR 0 | 505/0 | E25/E26, F27/F28 | PCIe Gen2 x1 NVMe |
| PS-GTR refclk 0 | 505 | F23/F24 | PCIe 100 MHz reference |
| PCIe PERST# | PS MIO31 | H16 | Root-port reset |

The SoC supports wider PCIe, but this carrier pinout routes only PS-GTR lane 0
to PCIe; the design therefore treats the slot as Gen2 x1.

## Vivado support boundary

`zynq/ultrascale+/board_files` is a repo-local board repository. It declares
the exact part and public PL pins. `build.tcl` prepends that path to
`board.repoPaths`, selects `xczu5ev-sfvc784-2-e`, and performs an
out-of-context build without global Vivado installation changes.

The public pinout does not provide:

- DDR4 component timing and calibration values;
- a validated ZynqMP PS/MIO preset;
- complete base-board reset/clock sequencing; or
- the physical cage label corresponding to each numbered GTH lane.

The repository does not invent those values. Bitstream and XSA goals fail with
an explicit diagnostic until vendor data or hardware measurements validate the
missing contract. Physical SFP transmitters remain disabled during that future
bring-up.

## Storage and boot

Boot firmware, two 128 MiB boot partitions, and two 1536 MiB root filesystems
remain on eMMC. PCIe NVMe is data-only and must be provisioned explicitly:

```console
hft-provision-nvme /dev/nvme0n1 --yes
systemctl start data.mount hft-data-prepare.service
```

The tool refuses non-NVMe and mounted devices. It creates a GPT partition and
ext4 filesystem labelled `hft_data`. PostgreSQL and `hftd` require that mount;
absence is a visible degraded state and never triggers formatting.

## Deferred hardware evidence

Before deployment, record the MYIR board revision, PS preset checksum, physical
SFP lane/cage map, recovered 10G clocks, PCIe link width/speed, eMMC device
name, NVMe persistent identifier, remoteproc index, and PL address/interrupt
map. None of those checks are inferred from successful host simulation.
