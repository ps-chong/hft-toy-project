# Safety and operating boundary

This repository is an educational trading-system reference. It is not approved
for live orders, production risk, exchange certification, or investment use.

## Safe defaults

- The default endpoint is the bundled simulator.
- Trading starts killed and requires an explicit local arm operation.
- A link loss, IPv4/UDP validation error, MAC frame error, sequence gap,
  malformed packet, order-book or ring overflow, stale configuration,
  watchdog expiry, ABI mismatch, or R5 restart latches the kill switch.
- Kill switches are fault-dominant and sticky in every layer: a fault that
  coincides with a clear wins, the PL needs a new commit with
  `clear_faults` while no fault is present, and the R5 needs a configuration
  revision newer than the one in force when it tripped.
- The first market event after a feed gap carries a `feed_gap` flag, so the
  R5 latches its own kill even if the PL's latch were bypassed.
- A database, journal, UI, or analytics failure cannot block or re-enable the
  trading path.
- Credentials, private update keys, board addresses, and live venue endpoints
  are never stored in the repository or image defaults.
- No workflow deploys to a board. SWUpdate output is an artifact only.

## Independent risk checks

PL performs a cheap first gate. R5 is authoritative for symbol enablement,
quantity, price collar, rate, open-order count, duplicate suppression, and
global kill. A53 refuses to transmit an intent with a stale ABI/risk revision.

## Deferred verification

Without a MYD-CZU5EV-V2, actual interrupt latency, cache coherency,
transceiver/link and PCIe behavior, remoteproc startup, placed-and-routed
timing closure (only out-of-context synthesis timing is checked), U-Boot
rollback, and power-loss recovery are unverified. Reports must label
host/simulator numbers as functional baselines rather than hardware latency.
