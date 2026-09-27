from __future__ import annotations

import argparse
import asyncio
import json
import socket
import struct
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest
from textual.widgets import Static

from hft_tools.dashboard import HftDashboard, request_status
from hft_tools.exchange_sim import ExchangeSimulator, parse_endpoint
from hft_tools.journal_export import export_journal, parse_records
from hft_tools.latency_report import read_samples, render_html, summarize
from hft_tools.pcap_replay import load_frames, replay, rewrite_sequence
from hft_tools.protocol import SoupPacket, encode_itch_add, encode_mold, fixed_ascii
from hft_tools.regdump import RegisterMap, decode_registers, load_schema


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
    with pytest.raises(ValueError):
        SoupPacket(b"U", b"x" * 0xFFFF).encode()

    async def invalid_read() -> None:
        reader = asyncio.StreamReader()
        reader.feed_data(b"\0\0")
        reader.feed_eof()
        with pytest.raises(ValueError):
            await SoupPacket.read(reader)

    asyncio.run(invalid_read())


def test_exchange_simulator_gap_and_malformed_injection() -> None:
    simulator = ExchangeSimulator(
        itch_target=("127.0.0.1", 9000),
        ouch_bind=("127.0.0.1", 0),
        gap_every=2,
        malformed_every=4,
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

        writer.write(SoupPacket(b"R").encode())
        await writer.drain()
        assert (await SoupPacket.read(reader)).packet_type == b"H"

        writer.write(SoupPacket(b"U", b"bad").encode())
        await writer.drain()
        assert (await SoupPacket.read(reader)).payload == b"Jmalformed"

        for request_type, response_type in ((b"U", b"U"), (b"X", b"C")):
            writer.write(
                SoupPacket(
                    b"U",
                    request_type + (42).to_bytes(4, "big") + b"rest",
                ).encode()
            )
            await writer.drain()
            assert (await SoupPacket.read(reader)).payload[:1] == response_type

        writer.write(SoupPacket(b"?", b"unknown").encode())
        await writer.drain()
        assert (await SoupPacket.read(reader)).packet_type == b"J"
        writer.write(SoupPacket(b"O").encode())
        await writer.drain()
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
    with pytest.raises(ValueError):
        decode_registers(b"\0", schema)

    image_file = tmp_path / "registers.bin"
    image_file.write_bytes(image)
    with RegisterMap(image_file, len(image)) as registers:
        assert registers.read_u32(0) == 0x48544654


def test_udp_replay_sends_all_frames() -> None:
    frame = encode_mold("TESTSESS01", 1, [b"A"])
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as receiver:
        receiver.bind(("127.0.0.1", 0))
        receiver.settimeout(1)
        target = receiver.getsockname()
        assert replay([frame], target, packets_per_second=100_000, repeat=2) == 2
        assert receiver.recv(2048) == frame
        assert receiver.recv(2048) == frame
    with pytest.raises(ValueError):
        replay([frame], target, packets_per_second=0, repeat=1)


def test_latency_and_journal_reports(tmp_path: Path) -> None:
    samples = tmp_path / "samples.jsonl"
    samples.write_text(
        "\n".join(json.dumps({"tick_to_intent_ns": value}) for value in [10, 20, 30, 40]),
        encoding="utf-8",
    )
    values = read_samples(samples)
    summary = summarize(values["tick_to_intent_ns"])
    assert summary.samples == 4
    assert summary.p50_ns == 30
    assert "functional baselines" in render_html({"tick": summary})
    assert summarize([]).samples == 0

    invalid = tmp_path / "invalid.jsonl"
    invalid.write_text('{"tick_to_intent_ns": -1}\n', encoding="utf-8")
    with pytest.raises(ValueError):
        read_samples(invalid)

    payload = "\n".join(
        (
            json.dumps({"SESSION_ID": "one", "MESSAGE": "accepted"}),
            json.dumps({"SESSION_ID": "two", "MESSAGE": "rejected"}),
        )
    )
    assert parse_records(payload, "one") == [{"SESSION_ID": "one", "MESSAGE": "accepted"}]


def test_journal_export_uses_structured_records(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    payload = json.dumps({"SESSION_ID": "one", "MESSAGE": "accepted"}) + "\n"

    def fake_run(*_args: object, **_kwargs: object) -> SimpleNamespace:
        return SimpleNamespace(stdout=payload)

    monkeypatch.setattr(subprocess, "run", fake_run)
    output = tmp_path / "journal.jsonl"
    assert export_journal(output, session="one") == 1
    assert "accepted" in output.read_text(encoding="utf-8")


def test_dashboard_connected_and_disconnected_states(tmp_path: Path) -> None:
    async def scenario() -> None:
        socket_path = tmp_path / "control.sock"

        async def handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            await reader.readline()
            writer.write(
                b'{"ok":true,"state":{"armed":true,"killed":false,'
                b'"revision":2,"max_quantity":10,"price_floor":1,'
                b'"price_ceiling":100}}\n'
            )
            await writer.drain()
            writer.close()

        server = await asyncio.start_unix_server(handler, socket_path)
        response = await request_status(socket_path)
        assert response["state"]["revision"] == 2

        app = HftDashboard(socket_path)
        async with app.run_test() as pilot:
            await app.refresh_status()
            widget = app.query_one("#status", Static)
            assert "Daemon: connected" in str(widget.renderable)
            await pilot.pause()
        server.close()
        await server.wait_closed()

        disconnected = HftDashboard(tmp_path / "missing.sock")
        async with disconnected.run_test():
            await disconnected.refresh_status()
            widget = disconnected.query_one("#status", Static)
            assert "disconnected" in str(widget.renderable)

    asyncio.run(scenario())


def test_endpoint_parser_rejects_invalid_value() -> None:
    assert parse_endpoint("127.0.0.1:9000") == ("127.0.0.1", 9000)
    with pytest.raises(argparse.ArgumentTypeError):
        parse_endpoint("missing-port")
