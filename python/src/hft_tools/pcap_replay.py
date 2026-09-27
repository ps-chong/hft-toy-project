"""Replay MoldUDP64 binary captures with deterministic pacing and faults."""

from __future__ import annotations

import argparse
import socket
import time
from collections.abc import Iterable
from pathlib import Path

from .exchange_sim import parse_endpoint


def load_frames(paths: Iterable[Path]) -> list[bytes]:
    frames: list[bytes] = []
    for path in paths:
        payload = path.read_bytes()
        if len(payload) < 20:
            raise ValueError(f"{path} is shorter than a MoldUDP64 header")
        frames.append(payload)
    if not frames:
        raise ValueError("no capture frames supplied")
    return frames


def rewrite_sequence(frame: bytes, sequence: int) -> bytes:
    if len(frame) < 20:
        raise ValueError("truncated MoldUDP64 frame")
    rewritten = bytearray(frame)
    rewritten[10:18] = sequence.to_bytes(8, "big")
    return bytes(rewritten)


def replay(
    frames: Iterable[bytes],
    target: tuple[str, int],
    *,
    packets_per_second: float,
    repeat: int,
    inject_gap_at: int = 0,
) -> int:
    if packets_per_second <= 0:
        raise ValueError("packets_per_second must be positive")
    delay = 1.0 / packets_per_second
    deadline = time.monotonic()
    sent = 0
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
        for _ in range(repeat):
            for frame in frames:
                sent += 1
                if inject_gap_at and sent == inject_gap_at:
                    sequence = int.from_bytes(frame[10:18], "big") + 1
                    frame = rewrite_sequence(frame, sequence)
                udp.sendto(frame, target)
                deadline += delay
                time.sleep(max(0.0, deadline - time.monotonic()))
    return sent


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("captures", nargs="+", type=Path)
    parser.add_argument("--target", type=parse_endpoint, default=("127.0.0.1", 9000))
    parser.add_argument("--pps", type=float, default=1_000.0)
    parser.add_argument("--repeat", type=int, default=1)
    parser.add_argument("--inject-gap-at", type=int, default=0)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    frames = load_frames(args.captures)
    sent = replay(
        frames,
        args.target,
        packets_per_second=args.pps,
        repeat=args.repeat,
        inject_gap_at=args.inject_gap_at,
    )
    print(f"replayed {sent} packets to {args.target[0]}:{args.target[1]}")


if __name__ == "__main__":
    main()
