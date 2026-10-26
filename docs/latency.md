# Latency measurement

Two domains are always reported separately:

- `tick_to_intent_ns`: PL ingress timestamp to R5-approved intent publication.
- `intent_to_ack_ns`: A53 RPMsg receipt to simulated exchange acknowledgement.

Report count, minimum, p50, p99, p99.9, and maximum. Do not average the domains
or label host measurements as MYD-CZU5EV-V2 values. Capture queue depth, drops,
CPU load, logging level, NVMe/database state, SFP link state, feed rate,
compiler/build ID, and clock configuration alongside every run.

## What is measured today

| Segment | Value | Source |
| --- | --- | --- |
| PL: first frame beat to R5 event port | 17 cycles, 109 ns at 156.25 MHz | RTL simulation, checked in `tb_myd_czu5ev_v2_hft_top` |
| PL: last frame beat to R5 event port | 5 cycles, 32 ns | same |
| PL: event to first telemetry beat | 1 cycle | same |
| R5 model on the host: event intake to intent (p50 / p99) | 18.1 us / 60.2 us | demo, 312 samples |
| A53 on the host: intent to exchange ack (p50 / p99) | 195 us / 436 us | demo, through Docker networking |

The PL numbers are cycle-exact properties of the RTL. The host numbers come
from processes in containers on a Windows workstation and only show that the
software paths work; they say nothing about the R5 or A53 on the board.

![R5 tick-to-intent latency](figures/latency-histogram.svg)

## Tools

Use `hft-latency-report samples.jsonl --output artifacts/latency` for host
samples; the demo writes `demo/out/latency.html`. Hardware measurement should
use the PL ingress cycle counter (carried in every telemetry record as
`ingress_cycles`) and another hardware-visible marker at R5 intent
publication. Linux wall clock is suitable only for the second domain.

Performance changes require identical vectors and configuration. A regression
gate should compare p99 and maximum while also requiring zero market/order ring
drops.
