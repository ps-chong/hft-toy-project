"""Create JSON and HTML latency summaries from newline-delimited samples."""

from __future__ import annotations

import argparse
import html
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class Summary:
    samples: int
    minimum_ns: int
    p50_ns: int
    p99_ns: int
    p999_ns: int
    maximum_ns: int


def percentile(sorted_values: list[int], quantile: float) -> int:
    if not sorted_values:
        return 0
    index = round((len(sorted_values) - 1) * quantile)
    return sorted_values[index]


def summarize(values: list[int]) -> Summary:
    ordered = sorted(values)
    if not ordered:
        return Summary(0, 0, 0, 0, 0, 0)
    return Summary(
        samples=len(ordered),
        minimum_ns=ordered[0],
        p50_ns=percentile(ordered, 0.5),
        p99_ns=percentile(ordered, 0.99),
        p999_ns=percentile(ordered, 0.999),
        maximum_ns=ordered[-1],
    )


def read_samples(path: Path) -> dict[str, list[int]]:
    domains: dict[str, list[int]] = {}
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        record: dict[str, Any] = json.loads(line)
        for name, value in record.items():
            if name.endswith("_ns"):
                if not isinstance(value, int) or value < 0:
                    raise ValueError(f"{path}:{line_number}: {name} is not a duration")
                domains.setdefault(name, []).append(value)
    return domains


def render_html(summaries: dict[str, Summary]) -> str:
    rows = "\n".join(
        "<tr>"
        f"<td>{html.escape(name)}</td>"
        f"<td>{summary.samples}</td>"
        f"<td>{summary.minimum_ns}</td>"
        f"<td>{summary.p50_ns}</td>"
        f"<td>{summary.p99_ns}</td>"
        f"<td>{summary.p999_ns}</td>"
        f"<td>{summary.maximum_ns}</td>"
        "</tr>"
        for name, summary in sorted(summaries.items())
    )
    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>HFT latency</title>
<style>body{{font:16px system-ui;margin:2rem}}table{{border-collapse:collapse}}
th,td{{border:1px solid #888;padding:.5rem;text-align:right}}th:first-child,
td:first-child{{text-align:left}}</style></head><body>
<h1>HFT latency summary</h1>
<p>Host values are functional baselines, not ZCU102 measurements.</p>
<table><thead><tr><th>Domain</th><th>N</th><th>Min</th><th>p50</th>
<th>p99</th><th>p99.9</th><th>Max</th></tr></thead><tbody>{rows}</tbody></table>
</body></html>
"""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path, default=Path("latency-report"))
    return parser


def main() -> None:
    args = build_parser().parse_args()
    summaries = {name: summarize(values) for name, values in read_samples(args.input).items()}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.with_suffix(".json").write_text(
        json.dumps(
            {name: asdict(summary) for name, summary in summaries.items()},
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    args.output.with_suffix(".html").write_text(
        render_html(summaries),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
