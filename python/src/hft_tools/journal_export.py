"""Export structured hftd journal records for one session."""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path
from typing import Any


def parse_records(payload: str, session: str | None = None) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line in payload.splitlines():
        if not line:
            continue
        record: dict[str, Any] = json.loads(line)
        if session is None or record.get("SESSION_ID") == session:
            records.append(record)
    return records


def export_journal(
    output: Path,
    *,
    session: str | None = None,
    since: str = "today",
) -> int:
    result = subprocess.run(
        [
            "journalctl",
            "--unit=hftd.service",
            "--output=json",
            f"--since={since}",
            "--no-pager",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    records = parse_records(result.stdout, session)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        "".join(json.dumps(record, sort_keys=True) + "\n" for record in records),
        encoding="utf-8",
    )
    return len(records)


def main() -> None:  # pragma: no cover - CLI glue
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--session")
    parser.add_argument("--since", default="today")
    args = parser.parse_args()
    count = export_journal(args.output, session=args.session, since=args.since)
    print(f"exported {count} journal records")


if __name__ == "__main__":
    main()
