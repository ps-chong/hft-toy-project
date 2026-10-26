"""Compare normalized-event files from the software PL model and the RTL.

Both files are sequences of 64-byte ``normalized_event`` records
(protocol/schema/ipc.yaml, little-endian). The demo writes one from
hft-plsim (``--model-out``) and one from the VHDL replay testbench
(``tb_replay``, ``HFT_REPLAY_OUTPUT``) for the same datagram capture.
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

RECORD_SIZE = 64
FEED_GAP = 1 << 0

# abi, kind, side, flags, sequence, timestamp, reference, symbol, price,
# quantity, locate, reserved, new reference.
RECORD = struct.Struct("<HccIQQQ8sQIH2sQ")


@dataclass(frozen=True)
class Event:
    kind: str
    side: str
    flags: int
    sequence: int
    order_reference: int
    price: int
    quantity: int

    @classmethod
    def decode(cls, record: bytes) -> Event:
        fields = RECORD.unpack(record)
        return cls(
            kind=fields[1].decode("ascii", "replace"),
            side=fields[2].decode("ascii", "replace"),
            flags=fields[3],
            sequence=fields[4],
            order_reference=fields[6],
            price=fields[8],
            quantity=fields[9],
        )


def records(data: bytes) -> list[bytes]:
    if len(data) % RECORD_SIZE:
        raise ValueError(f"{len(data)} bytes is not a whole number of {RECORD_SIZE}-byte records")
    return [data[offset : offset + RECORD_SIZE] for offset in range(0, len(data), RECORD_SIZE)]


def compare(model: bytes, rtl: bytes) -> dict[str, object]:
    """Summary of the comparison; ``match`` is true only for identical files."""
    left, right = records(model), records(rtl)
    first_difference = next(
        (index for index, (a, b) in enumerate(zip(left, right, strict=False)) if a != b),
        None,
    )
    if first_difference is None and len(left) != len(right):
        first_difference = min(len(left), len(right))
    events = [Event.decode(record) for record in left]
    summary: dict[str, object] = {
        "match": first_difference is None,
        "model_events": len(left),
        "rtl_events": len(right),
        "kinds": dict(sorted(Counter(event.kind for event in events).items())),
        "feed_gap_flags": sum(1 for event in events if event.flags & FEED_GAP),
    }
    if events:
        summary["sequences"] = [events[0].sequence, events[-1].sequence]
    if first_difference is not None:
        summary["first_difference"] = first_difference
        if first_difference < len(left):
            summary["model"] = Event.decode(left[first_difference]).__dict__
        if first_difference < len(right):
            summary["rtl"] = Event.decode(right[first_difference]).__dict__
    return summary


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model", type=Path, help="hft-plsim --model-out file")
    parser.add_argument("rtl", type=Path, help="tb_replay output file")
    args = parser.parse_args(argv)
    summary = compare(args.model.read_bytes(), args.rtl.read_bytes())
    print(json.dumps(summary, indent=2))
    return 0 if summary["match"] else 1


if __name__ == "__main__":
    sys.exit(main())
