# Debugging guide

## Generated contract mismatch

Run `python3 protocol/generator/generate.py --check`. If stale, regenerate and
review all language diffs together. Never edit generated output directly.

## FPGA simulation

List VUnit cases with `zynq/ultrascale+/sim/run.py --list`. Re-run one case by its full
name and add `--gtkwave-fmt ghw` when a waveform is needed. Inspect gap,
malformed, overflow, and killed pulses before debugging downstream behavior.

## R5

Use the host demo and GoogleTest first. Target map/size output shows accidental
runtime growth. CIB/fmt logs are copied through a bounded low-priority channel;
absence of debug logs does not imply the trading executor stopped. Stack
high-water marks and ring counters are the primary target indicators.

## A53

```bash
journalctl -u hft-remoteproc -u hftd --since today
hftctl status
hft-regdump --json
ss -tnp | grep 9001
```

An RPMsg ABI error requires coordinated PL/R5/A53 artifacts, not a daemon
restart. A database outage should increase dropped persistence diagnostics while
order forwarding remains responsive.

## SWUpdate

Validate the `.swu` hash and inspect `sw-description` before installation.
Never copy a private signing key onto the target. Current CI verifies archive
construction only; U-Boot rollback diagnostics are unavailable until hardware.
