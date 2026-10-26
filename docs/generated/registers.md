# Generated PL register map

Schema SHA-256: `ba4292b7c035e026b044ecdaa3817076ee61f2d6436393b326ce3473a2f309cb`

Base address: `0xA0000000`; span: `0x00010000`; clock domain: `ps_clk`.

Writes to rw registers land in ps_clk shadow registers. Writing 1 to COMMIT.request transfers the whole shadow set to axis_clk through one cdc_snapshot handshake; CONFIG_REVISION increments when axis_clk has applied it. ro counters are sampled into one snapshot, so 64-bit values are never torn.

| Name | Offset | Access | Reset | Description |
| --- | ---: | :---: | ---: | --- |
| `BUILD_ID` | `0x0000` | ro | `0x48544654` | ASCII HFTT |
| `ABI_VERSION` | `0x0004` | ro | `2` |  |
| `CONTROL` | `0x0008` | rw | `2` | Shadowed; takes effect on COMMIT (bits: enable=0, kill=1, clear_faults=2) |
| `STATUS` | `0x000C` | ro | `0` | (bits: link_up=0, stale=1, overflow=2, killed=3, commit_busy=4) |
| `EXPECTED_SEQUENCE_LO` | `0x0010` | ro | `0` |  |
| `EXPECTED_SEQUENCE_HI` | `0x0014` | ro | `0` |  |
| `PACKET_COUNT_LO` | `0x0018` | ro | `0` |  |
| `PACKET_COUNT_HI` | `0x001C` | ro | `0` |  |
| `DROP_COUNT` | `0x0020` | ro | `0` |  |
| `MALFORMED_COUNT` | `0x0024` | ro | `0` |  |
| `GAP_COUNT` | `0x0028` | ro | `0` |  |
| `COMMIT` | `0x002C` | wo | `0` | Write 1 to apply the shadow configuration atomically (bits: request=0) |
| `CONFIG_REVISION` | `0x0030` | ro | `0` | Number of configurations applied in axis_clk |
| `TELEMETRY_DROP_COUNT` | `0x0034` | ro | `0` |  |
| `RISK_MAX_QTY` | `0x0040` | rw | `1000` |  |
| `RISK_PRICE_FLOOR` | `0x0048` | rw | `1` | Low 32 bits |
| `RISK_PRICE_FLOOR_HI` | `0x004C` | rw | `0` |  |
| `RISK_PRICE_CEILING` | `0x0050` | rw | `1000000000` | Low 32 bits |
| `RISK_PRICE_CEILING_HI` | `0x0054` | rw | `0` |  |
| `STOCK_LOCATE` | `0x0058` | rw | `0` | Instrument whose book the PL maintains; 0 tracks none |
| `STRATEGY_SELECT` | `0x005C` | rw | `0` | 0 = spread cross, 1 = imbalance |
| `TOB_ANCHOR_PRICE` | `0x0060` | rw | `0` | Lowest price of the 1024-tick ladder band |
