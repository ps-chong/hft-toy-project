from __future__ import annotations

import argparse
import asyncio
import json
import struct
from pathlib import Path

import pytest

from hft_tools.exchange_sim import ExchangeSimulator, parse_endpoint
from hft_tools.journal_export import parse_records
from hft_tools.latency_report import read_samples, render_html, summarize
from hft_tools.pcap_replay import load_frames, rewrite_sequence
from hft_tools.protocol import SoupPacket, encode_itch_add, encode_mold, fixed_ascii
from hft_tools.regdump import decode_registers, load_schema


def test_protocol_helpers_validate_and_encode() -> None:
    assert fixed_ascii("ACME", 8) == b"ACME    "
    with pytest.raises(ValueError):
        fixed_ascii("TOO-LONG", 3)
    with pytest.raises(ValueError):
        encode_itch_add(
            timestamp_ns=1,
            order_reference=1,
            side="?",
            quantity=1,
            symbol="ACME",
            price=1,
        )

    message = encode_itch_add(
        timestamp_ns=123_456,
        order_reference=1,
        side="B",
        quantity=100,
        symbol="ACME",
        price=1_234_500,
    )
    packet = encode_mold("TESTSESS01", 7, [message])
    assert len(message) == 36
    assert packet[10:18] == (7).to_bytes(8, "big")
    assert packet[18:20] == b"\0\1"


def test_soup_packet_validation() -> None:
    assert SoupPacket(b"H").encode() == b"\0\1H"
    with pytest.raises(ValueError):
        SoupPacket(b"TOO").encode()


def test_exchange_simulator_gap_and_malformed_injection() -> None:
    simulator = ExchangeSimulator(
        itch_target=("127.0.0.1", 9000),
        ouch_bind=("127.0.0.1", 0),
        gap_every=2,
        malformed_every=3,
    )
    first = simulator.next_feed_packet()
    second = simulator.next_feed_packet()
    third = simulator.next_feed_packet()
    assert int.from_bytes(first[10:18], "big") == 1
    assert int.from_bytes(second[10:18], "big") == 2
    assert int.from_bytes(third[10:18], "big") == 4
    assert len(third) == len(first) - 1


def test_exchange_soup_login_and_order() -> None:
    async def scenario() -> None:
        simulator = ExchangeSimulator(
            itch_target=("127.0.0.1", 9000),
            ouch_bind=("127.0.0.1", 0),
        )
        server = await asyncio.start_server(simulator.handle_ouch, "127.0.0.1", 0)
        address = server.sockets[0].getsockname()
        reader, writer = await asyncio.open_connection(address[0], address[1])
        writer.write(SoupPacket(b"L", b"credentials").encode())
        await writer.drain()
        assert (await SoupPacket.read(reader)).packet_type == b"A"

        payload = b"O" + (42).to_bytes(4, "big") + b"rest"
        writer.write(SoupPacket(b"U", payload).encode())
        await writer.drain()
        accepted = await SoupPacket.read(reader)
        assert accepted.packet_type == b"S"
        assert accepted.payload == b"A" + (42).to_bytes(4, "big")
        writer.close()
        await writer.wait_closed()
        server.close()
        await server.wait_closed()

    asyncio.run(scenario())


def test_replay_and_register_helpers(tmp_path: Path) -> None:
    frame = encode_mold("TESTSESS01", 1, [b"A"])
    capture = tmp_path / "frame.bin"
    capture.write_bytes(frame)
    assert load_frames([capture]) == [frame]
    assert int.from_bytes(rewrite_sequence(frame, 99)[10:18], "big") == 99

    schema = load_schema(Path("protocol/schema/registers.yaml"))
    image = bytearray(int(schema["span"], 16))
    struct.pack_into("<I", image, 0, 0x48544654)
    values = decode_registers(bytes(image), schema)
    assert values["BUILD_ID"] == 0x48544654


def test_latency_and_journal_reports(tmp_path: Path) -> None:
    samples = tmp_path / "samples.jsonl"
    samples.write_text(
        "\n".join(
            json.dumps({"tick_to_intent_ns": value}) for value in [10, 20, 30, 40]
        ),
        encoding="utf-8",
    )
    values = read_samples(samples)
    summary = summarize(values["tick_to_intent_ns"])
    assert summary.samples == 4
    assert summary.p50_ns == 30
    assert "functional baselines" in render_html({"tick": summary})

    payload = "\n".join(
        (
            json.dumps({"SESSION_ID": "one", "MESSAGE": "accepted"}),
            json.dumps({"SESSION_ID": "two", "MESSAGE": "rejected"}),
        )
    )
    assert parse_records(payload, "one") == [
        {"SESSION_ID": "one", "MESSAGE": "accepted"}
    ]


def test_endpoint_parser_rejects_invalid_value() -> None:
    assert parse_endpoint("127.0.0.1:9000") == ("127.0.0.1", 9000)
    with pytest.raises(argparse.ArgumentTypeError):
        parse_endpoint("missing-port")
