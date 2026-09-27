"""Deterministic MoldUDP64 publisher and SoupBinTCP/OUCH exchange simulator."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import socket
from dataclasses import dataclass, field

from .protocol import SoupPacket, encode_itch_add, encode_mold, write_soup


def parse_endpoint(value: str) -> tuple[str, int]:
    host, separator, port = value.rpartition(":")
    if not separator or not host:
        raise argparse.ArgumentTypeError("endpoint must be HOST:PORT")
    try:
        return host, int(port)
    except ValueError as error:
        raise argparse.ArgumentTypeError("port must be numeric") from error


@dataclass
class SimulatorState:
    feed_sequence: int = 1
    next_order_reference: int = 1
    accepted_orders: dict[int, bytes] = field(default_factory=dict)


class ExchangeSimulator:
    def __init__(
        self,
        *,
        itch_target: tuple[str, int],
        ouch_bind: tuple[str, int],
        interval: float = 0.1,
        gap_every: int = 0,
        malformed_every: int = 0,
    ) -> None:
        self.itch_target = itch_target
        self.ouch_bind = ouch_bind
        self.interval = interval
        self.gap_every = gap_every
        self.malformed_every = malformed_every
        self.state = SimulatorState()

    def next_feed_packet(self) -> bytes:
        sequence = self.state.feed_sequence
        reference = self.state.next_order_reference
        self.state.next_order_reference += 1
        message = encode_itch_add(
            timestamp_ns=sequence * 1_000,
            order_reference=reference,
            side="B" if sequence % 2 else "S",
            quantity=100,
            symbol="ACME",
            price=1_234_500 + sequence,
        )
        packet = encode_mold("SIM0000001", sequence, [message])
        self.state.feed_sequence += 1
        if self.gap_every and sequence % self.gap_every == 0:
            self.state.feed_sequence += 1
        if self.malformed_every and sequence % self.malformed_every == 0:
            return packet[:-1]
        return packet

    async def publish_feed(self, stop: asyncio.Event) -> None:
        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(
            asyncio.DatagramProtocol,
            family=socket.AF_INET,
        )
        try:
            while not stop.is_set():
                transport.sendto(self.next_feed_packet(), self.itch_target)
                try:
                    await asyncio.wait_for(stop.wait(), timeout=self.interval)
                except TimeoutError:
                    pass
        finally:
            transport.close()

    async def handle_ouch(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            while True:
                packet = await SoupPacket.read(reader)
                if packet.packet_type == b"L":
                    await write_soup(
                        writer,
                        SoupPacket(b"A", b"SIM0000001" + b"00000000000000000001"),
                    )
                elif packet.packet_type == b"R":
                    await write_soup(writer, SoupPacket(b"H"))
                elif packet.packet_type == b"O":
                    break
                elif packet.packet_type == b"U":
                    await self._handle_ouch_payload(packet.payload, writer)
                else:
                    await write_soup(writer, SoupPacket(b"J", b"unknown packet"))
        except (asyncio.IncompleteReadError, ConnectionResetError):
            pass
        finally:
            writer.close()
            with contextlib.suppress(ConnectionError):
                await writer.wait_closed()

    async def _handle_ouch_payload(
        self, payload: bytes, writer: asyncio.StreamWriter
    ) -> None:
        if len(payload) < 5 or payload[0] not in b"OUX":
            await write_soup(writer, SoupPacket(b"S", b"Jmalformed"))
            return
        user_ref = int.from_bytes(payload[1:5], "big")
        message_type = payload[0]
        if message_type == ord("O"):
            self.state.accepted_orders[user_ref] = payload
            response_type = b"A"
        elif message_type == ord("X"):
            self.state.accepted_orders.pop(user_ref, None)
            response_type = b"C"
        else:
            self.state.accepted_orders[user_ref] = payload
            response_type = b"U"
        await write_soup(
            writer,
            SoupPacket(b"S", response_type + user_ref.to_bytes(4, "big")),
        )

    async def run(self) -> None:
        stop = asyncio.Event()
        publisher = asyncio.create_task(self.publish_feed(stop))
        server = await asyncio.start_server(self.handle_ouch, *self.ouch_bind)
        try:
            async with server:
                await server.serve_forever()
        finally:
            stop.set()
            publisher.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await publisher


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--itch-target", type=parse_endpoint, default=("127.0.0.1", 9000)
    )
    parser.add_argument(
        "--ouch-bind", type=parse_endpoint, default=("127.0.0.1", 9001)
    )
    parser.add_argument("--interval", type=float, default=0.1)
    parser.add_argument("--gap-every", type=int, default=0)
    parser.add_argument("--malformed-every", type=int, default=0)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    simulator = ExchangeSimulator(
        itch_target=args.itch_target,
        ouch_bind=args.ouch_bind,
        interval=args.interval,
        gap_every=args.gap_every,
        malformed_every=args.malformed_every,
    )
    try:
        asyncio.run(simulator.run())
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
