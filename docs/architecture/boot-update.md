# Boot and update architecture

## Boot chain

```mermaid
sequenceDiagram
    participant ROM as ZynqMP BootROM
    participant FSBL as FSBL
    participant PMU as PMU firmware
    participant ATF as TF-A
    participant UBoot as U-Boot
    participant Linux as A53 Linux
    participant R5 as R5 FreeRTOS
    ROM->>FSBL: Load authenticated BOOT image
    FSBL->>PMU: Start platform management
    FSBL->>ATF: Hand off A53 execution
    ATF->>UBoot: EL3 handoff
    UBoot->>UBoot: Select A/B slot and increment bootcount
    UBoot->>Linux: Kernel, DTB, rootfs
    Linux->>R5: remoteproc loads hft-r5.elf
    R5-->>Linux: RPMsg endpoint appears
    Linux->>Linux: Start hftd, PostgreSQL, health confirmation
```

## Partition layout

The WIC image has `boot_a`, `boot_b`, `rootfs_a`, `rootfs_b`, and `hft_data`.
The active root is read-only where practical. PostgreSQL, update state, and
operator configuration live on `hft_data` and are not replaced by an OS update.

## SWUpdate transaction

```mermaid
stateDiagram-v2
    [*] --> Verify
    Verify --> Rejected: Signature, hash, hardware, ABI, or schema failure
    Verify --> WriteInactive: Valid bundle
    WriteInactive --> Rejected: Write or flush failure
    WriteInactive --> Pending: Set slot, bootcount zero, upgrade flag
    Pending --> BootCandidate: Reboot
    BootCandidate --> Confirmed: PL, R5, hftd, DB, ABI healthy
    BootCandidate --> Rollback: Timeout, crash, or bootlimit
    Rollback --> [*]
    Confirmed --> [*]
    Rejected --> [*]
```

Bundles contain matching boot artifacts, rootfs, and R5 firmware. CMS/RSA
signatures and SHA-256 hashes are checked before writes. Private keys remain
outside the repository. Bootloader updates are excluded from routine bundles to
preserve recovery.

## Database compatibility

Migrations are expand/contract and a backup is taken before update. The new
schema must remain readable by the previous slot. A bundle declares a schema
range and is rejected before installation if the persistent database is outside
that range.

## Current verification boundary

CI builds and parses bundle contracts and writes synthetic inactive-slot images.
It does not reboot a ZCU102. U-Boot environment persistence, bootcount rollback,
power loss, actual block-device aliases, FPGA build-ID health, and remoteproc
startup remain pending hardware.
