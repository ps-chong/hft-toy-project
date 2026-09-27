"""Small endian-explicit helpers shared by simulator and replay tools."""

from __future__ import annotations

import asyncio
import struct
from dataclasses import dataclass

MOLD_HEADER = struct.Struct(">10sQH")
SOUP_LENGTH = struct.Struct(">H")


def fixed_ascii(value: str, length: int) -> bytes:
    encoded = value.encode("ascii")
    if len(encoded) > length:
        raise ValueError(f"{value!r} exceeds {length} bytes")
    return encoded.ljust(length, b" ")


def encode_itch_add(
    *,
    timestamp_ns: int,
    order_reference: int,
    side: str,
    quantity: int,
    symbol: str,
    price: int,
) -> bytes:
    if side not in {"B", "S"}:
        raise ValueError("side must be B or S")
    if not 0 <= timestamp_ns < 1 << 48:
        raise ValueError("timestamp must fit 48 bits")
    return b"".join(
        (
            b"A",
            struct.pack(">HH", 1, 1),
            timestamp_ns.to_bytes(6, "big"),
            struct.pack(">Q", order_reference),
            side.encode("ascii"),
            struct.pack(">I", quantity),
            fixed_ascii(symbol, 8),
            struct.pack(">I", price),
        )
    )


def encode_itch_cancel(
    *,
    timestamp_ns: int,
    order_reference: int,
    canceled_quantity: int,
) -> bytes:
    return b"".join(
        (
            b"X",
            struct.pack(">HH", 1, 2),
            timestamp_ns.to_bytes(6, "big"),
            struct.pack(">Q", order_reference),
            struct.pack(">I", canceled_quantity),
        )
    )


def encode_mold(session: str, sequence: int, messages: list[bytes]) -> bytes:
    if len(messages) >= 0xFFFF:
        raise ValueError("too many MoldUDP64 messages")
    body = b"".join(struct.pack(">H", len(message)) + message for message in messages)
    return MOLD_HEADER.pack(fixed_ascii(session, 10), sequence, len(messages)) + body


@dataclass(frozen=True)
class SoupPacket:
    packet_type: bytes
    payload: bytes = b""

    def encode(self) -> bytes:
        if len(self.packet_type) != 1:
            raise ValueError("SoupBinTCP packet type must be one byte")
        length = len(self.payload) + 1
        if length > 0xFFFF:
            raise ValueError("SoupBinTCP packet is too large")
        return SOUP_LENGTH.pack(length) + self.packet_type + self.payload

    @classmethod
    async def read(cls, reader: asyncio.StreamReader) -> SoupPacket:
        length = SOUP_LENGTH.unpack(await reader.readexactly(2))[0]
        if length == 0:
            raise ValueError("zero-length SoupBinTCP packet")
        body = await reader.readexactly(length)
        return cls(body[:1], body[1:])


async def write_soup(writer: asyncio.StreamWriter, packet: SoupPacket) -> None:
    writer.write(packet.encode())
    await writer.drain()
