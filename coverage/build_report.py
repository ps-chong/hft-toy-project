"""Merge per-layer coverage summaries into a static HTML landing page."""

from __future__ import annotations

import argparse
import html
import json
import xml.etree.ElementTree as ET
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True)
class Summary:
    layer: str
    lines_covered: int
    lines_valid: int
    branches_covered: int
    branches_valid: int
    source: str

    @property
    def line_rate(self) -> float:
        return ratio(self.lines_covered, self.lines_valid)

    @property
    def branch_rate(self) -> float:
        return ratio(self.branches_covered, self.branches_valid)


def ratio(covered: int, valid: int) -> float:
    return 100.0 if valid == 0 else covered * 100.0 / valid


def read_cobertura(path: Path) -> Summary:
    root = ET.parse(path).getroot()
    return Summary(
        layer=path.parent.name,
        lines_covered=int(root.attrib.get("lines-covered", 0)),
        lines_valid=int(root.attrib.get("lines-valid", 0)),
        branches_covered=int(root.attrib.get("branches-covered", 0)),
        branches_valid=int(root.attrib.get("branches-valid", 0)),
        source=str(path),
    )


def render(summaries: list[Summary]) -> str:
    rows = "\n".join(
        "<tr>"
        f"<td>{html.escape(item.layer)}</td>"
        f"<td>{item.line_rate:.1f}% ({item.lines_covered}/{item.lines_valid})</td>"
        f"<td>{item.branch_rate:.1f}% "
        f"({item.branches_covered}/{item.branches_valid})</td>"
        f"<td><code>{html.escape(item.source)}</code></td>"
        "</tr>"
        for item in summaries
    )
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>MYD-CZU5EV-V2 HFT coverage</title>
  <style>
    body {{ font: 16px system-ui; margin: 2rem; max-width: 80rem; }}
    table {{ border-collapse: collapse; width: 100%; }}
    th, td {{ border: 1px solid #888; padding: .5rem; text-align: left; }}
  </style>
</head>
<body>
  <h1>MYD-CZU5EV-V2 HFT coverage</h1>
  <p>Generated from handwritten-code Cobertura reports. Vendor and generated
  code exclusions are documented by each layer.</p>
  <table>
    <thead><tr><th>Layer</th><th>Lines</th><th>Branches</th><th>Source</th></tr></thead>
    <tbody>{rows}</tbody>
  </table>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="+", type=Path)
    parser.add_argument(
        "--output", type=Path, default=Path("coverage-reports/index.html")
    )
    args = parser.parse_args()

    summaries = [read_cobertura(report) for report in args.reports]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(summaries), encoding="utf-8")
    args.output.with_suffix(".json").write_text(
        json.dumps([asdict(summary) for summary in summaries], indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
