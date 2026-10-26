from __future__ import annotations

from pathlib import Path

import pytest

from hft_tools.replay_compare import compare, main

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = (ROOT / "protocol" / "vectors" / "replay_expected.bin").read_bytes()


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
