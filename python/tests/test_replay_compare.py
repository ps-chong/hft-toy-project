from __future__ import annotations

import json
import re
import struct
from pathlib import Path

import pytest

from hft_tools.replay_compare import RECORD, RECORD_SIZE, Event, compare, main, records

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = (ROOT / "protocol" / "vectors" / "replay_expected.bin").read_bytes()
SCHEMA = json.loads((ROOT / "protocol" / "schema" / "ipc.yaml").read_text(encoding="utf-8"))
EVENT_FIELDS = SCHEMA["records"]["normalized_event"]["fields"]

# struct format codes that can carry each schema type.
STRUCT_CODES = {"u8": "cB", "u16": "H", "u32": "I", "u64": "Q"}


def test_record_layout_matches_the_schema() -> None:
    """The comparator hand-writes its struct format. It must tile the 64-byte
    record exactly as the normalized_event fields in ipc.yaml do, so a schema
    change cannot leave it decoding the wrong bytes while every byte-for-byte
    comparison still passes."""
    assert SCHEMA["record_size"] == RECORD_SIZE
    assert RECORD.size == RECORD_SIZE
    codes = re.findall(r"\d*[a-zA-Z]", RECORD.format.removeprefix("<"))
    assert RECORD.format.startswith("<"), "little-endian, no padding"
    assert len(codes) == len(EVENT_FIELDS)
    offset = 0
    for code, field in zip(codes, EVENT_FIELDS, strict=True):
        size = struct.calcsize("<" + code)
        assert (field["offset"], field["size"]) == (offset, size), field["name"]
        if field["type"] in STRUCT_CODES:
            assert code in STRUCT_CODES[field["type"]], field["name"]
        else:
            assert code == f"{field['size']}s", field["name"]
        offset += size


def test_decoded_fields_come_from_the_schema_offsets() -> None:
    """Event.decode reads every field at the offset ipc.yaml gives it."""
    offsets = {field["name"]: (field["offset"], field["size"]) for field in EVENT_FIELDS}

    def raw(record: bytes, name: str) -> int:
        start, size = offsets[name]
        return int.from_bytes(record[start : start + size], "little")

    for record in records(EXPECTED):
        event = Event.decode(record)
        assert ord(event.kind) == raw(record, "kind")
        assert ord(event.side) == raw(record, "side")
        assert event.flags == raw(record, "flags")
        assert event.sequence == raw(record, "sequence")
        assert event.order_reference == raw(record, "order_reference")
        assert event.price == raw(record, "price")
        assert event.quantity == raw(record, "quantity")


def test_identical_sessions_match_and_summarize() -> None:
    summary = compare(EXPECTED, EXPECTED)
    assert summary["match"] is True
    assert summary["model_events"] == 9
    assert summary["feed_gap_flags"] == 1
    assert summary["kinds"] == {"A": 3, "D": 1, "E": 2, "U": 1, "X": 2}
    assert summary["sequences"] == [1, 16]


def test_reports_the_first_differing_record(tmp_path: Path) -> None:
    altered = bytearray(EXPECTED)
    altered[64 * 3 + 48] ^= 0x01  # quantity of the fourth event
    summary = compare(EXPECTED, bytes(altered))
    assert summary["match"] is False
    assert summary["first_difference"] == 3
    model_path, rtl_path = tmp_path / "model.bin", tmp_path / "rtl.bin"
    model_path.write_bytes(EXPECTED)
    rtl_path.write_bytes(bytes(altered))
    assert main([str(model_path), str(rtl_path)]) == 1


def test_length_mismatch_and_partial_records() -> None:
    summary = compare(EXPECTED, EXPECTED[:-64])
    assert summary["match"] is False
    assert summary["first_difference"] == 8
    with pytest.raises(ValueError, match="whole number"):
        compare(EXPECTED[:-1], EXPECTED)
