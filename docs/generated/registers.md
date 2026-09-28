# Generated PL register map

Schema SHA-256: `b467d912ddcf2b7d7ab2351d1354c236773f6ccfb6a16af5ffeff283ca808fcf`

Base address: `0xA0000000`; span: `0x00010000`.

| Name | Offset | Access | Reset | Description |
| --- | ---: | :---: | ---: | --- |
| `BUILD_ID` | `0x0000` | ro | `0x48544654` | ASCII HFTT |
| `ABI_VERSION` | `0x0004` | ro | `1` |  |
| `CONTROL` | `0x0008` | rw | `1` |  |
| `STATUS` | `0x000C` | ro | `0` |  |
| `EXPECTED_SEQUENCE_LO` | `0x0010` | ro | `0` |  |
| `EXPECTED_SEQUENCE_HI` | `0x0014` | ro | `0` |  |
| `PACKET_COUNT_LO` | `0x0018` | ro | `0` |  |
| `PACKET_COUNT_HI` | `0x001C` | ro | `0` |  |
| `DROP_COUNT` | `0x0020` | ro | `0` |  |
| `MALFORMED_COUNT` | `0x0024` | ro | `0` |  |
| `GAP_COUNT` | `0x0028` | ro | `0` |  |
| `RISK_MAX_QTY` | `0x0040` | rw | `1000` |  |
| `RISK_PRICE_FLOOR` | `0x0048` | rw | `1` |  |
| `RISK_PRICE_CEILING` | `0x0050` | rw | `1000000000` |  |
