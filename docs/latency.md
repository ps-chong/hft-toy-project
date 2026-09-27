# Latency measurement

Two domains are always reported separately:

- `tick_to_intent_ns`: PL ingress timestamp to R5-approved intent publication.
- `intent_to_ack_ns`: A53 RPMsg receipt to simulated exchange acknowledgement.

Report count, minimum, p50, p99, p99.9, and maximum. Do not average the domains
or label host measurements as ZCU102 values. Capture queue depth, drops, CPU
load, logging level, database state, feed rate, compiler/build ID, and clock
configuration alongside every run.

Use `hft-latency-report samples.jsonl --output artifacts/latency` for host
samples. Hardware measurement should use the PL counter at ingress and another
hardware-visible marker at R5 intent publication. Linux wall clock is suitable
only for the second domain.

Performance changes require identical vectors and configuration. A regression
gate should compare p99 and maximum while also requiring zero market/order ring
drops.
