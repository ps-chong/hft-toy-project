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
    participant UDP as Ethernet IPv4 UDP validator
    participant Mold as MoldUDP64 decoder
    participant Itch as ITCH decoder
    participant Book as Bounded PL book
    participant Ring as PL-to-R5 ring
    participant Exec as R5 executor
    Sim->>UDP: 10G Ethernet frame
    UDP->>UDP: Check MAC, IPv4 checksum, fragment, lengths, IP, port
    UDP->>Mold: Validated UDP payload
    Mold->>Mold: Check session, sequence, count, lengths
    alt sequence gap or malformed payload
        Mold-->>Exec: Stale/fault notification
        Exec->>Exec: Latch kill switch
    else valid packet
        loop each message
            Mold->>Itch: Message bytes and implicit sequence
            Itch->>Book: Normalized fixed-size event
            Itch->>Ring: Normalized fixed-size event
        end
        Ring->>Exec: Doorbell after release publication
    end
```

Supported ITCH messages are Add, Add with MPID, Execute, Execute with Price,
Cancel, Delete, Replace, Trade, Cross Trade, System Event, and Stock Directory.
The first hardware slice fully normalizes Add/Cancel/Delete and safely
classifies the remaining types. Unsupported well-framed types increment a
counter; truncation or a declared-length mismatch is fatal to synchronized
trading.

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
4. A versioned snapshot is swapped only at an R5 executor safe point.
5. Re-arming is explicit; receiving a good packet never clears a kill latch.
