# Protocol and order flow

## Canonical contracts

Files under `protocol/schema` are JSON-compatible YAML. The generator hashes all
schemas and emits VHDL constants, C++ constants/readers, Rust constants, the PL
register table, and binary vectors. CI regenerates into memory and fails on
drift. All multi-byte venue and UDP telemetry fields are big-endian; the
internal 64-byte IPC records are little-endian because both PS processors are
configured that way.

## Market-data sequence

```mermaid
sequenceDiagram
    participant Sim as ITCH simulator
    participant UDP as eth_ipv4_udp_rx
    participant Mold as moldudp64_rx
    participant Itch as itch_decoder
    participant Book as PL order book
    participant Risk as risk_guard and kill latch
    participant R5 as R5 Disruptor stages
    Sim->>UDP: 10G Ethernet frame, 64 bits per beat
    UDP->>UDP: Check MAC, IPv4 checksum, fragment, lengths, IP, port
    UDP->>Mold: UDP payload beats
    Mold->>Mold: Duplicate / in order / gap against the expected sequence
    alt malformed packet
        Mold-->>Risk: malformed: latch kill, expected sequence unchanged
    else gap
        Mold-->>Risk: gap: latch kill
        Mold->>Itch: messages, first event flagged feed_gap
    else in order
        Mold->>Itch: messages with implicit sequence numbers
    end
    Itch->>Book: normalized event
    Itch->>Risk: normalized event
    Risk->>R5: adds only while armed, lifecycle events always
    R5->>R5: feed_gap flag latches the R5 kill switch
```

Supported ITCH messages are Add, Add with MPID, Execute, Execute with Price,
Cancel, Delete, Replace, Trade, Cross Trade, System Event, and Stock Directory.
Add (`A`, `F`), Execute (`E`, `C`), Cancel, Delete, Replace and Trade are
normalized into events, identically in the RTL and in the Rust software
model; System Event, Stock Directory and Cross Trade are validated and
skipped. Unknown well-framed types increment a counter; truncation or a
declared-length mismatch is fatal to synchronized trading.

## Order-entry sequence

```mermaid
sequenceDiagram
    participant R5 as R5 order state
    participant RP as RPMsg
    participant GW as Rust OUCH actor
    participant TCP as SoupBinTCP
    participant Sim as Exchange simulator
    R5->>RP: Approved OrderIntent
    RP->>GW: Version and ABI validation
    GW->>TCP: Unsequenced Data packet
    TCP->>Sim: Enter, Replace, or Cancel
    Sim-->>TCP: Accepted, Replaced, Canceled, Executed, or Rejected
    TCP-->>GW: Sequenced Data packet
    GW->>GW: Reconcile token and sequence
    GW-->>RP: Lifecycle event
    GW--)GW: Nonblocking persistence copy
```

SoupBinTCP owns login, heartbeat, timeout, and reconnect state. OUCH owns order
semantics. TCP/session behavior is therefore outside the deterministic
tick-to-intent domain.

## Recovery invariants

1. A feed gap immediately marks book state stale and kills new entries.
2. Cancels and reconciliation can continue while new entries are killed.
3. Recovery replays missing feed messages into a shadow state.
4. A versioned configuration snapshot is picked up only at a safe point
   between R5 pipeline batches.
5. Re-arming is explicit; receiving a good packet never clears a kill latch.
