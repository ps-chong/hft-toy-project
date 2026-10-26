"""Render the README and workflow figures from checked-in data.

    python scripts/render_figures.py              # deterministic figures
    python scripts/render_figures.py --dashboard  # also the dashboard screenshot

Deterministic figures (CI re-renders them and fails on any difference):
  docs/figures/latency-histogram.svg  from docs/figures/data/demo-r5-latency.jsonl
  docs/figures/ingress-waveform.svg   from docs/figures/ingress-waveform.json (WaveDrom)

The dashboard screenshot (docs/figures/dashboard.svg) depends on the Textual
version, so it is regenerated on request only.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIGURES = ROOT / "docs" / "figures"
sys.path.insert(0, str(ROOT / "python" / "src"))

from hft_tools.latency_report import read_samples, summarize

# Histogram geometry (SVG user units).
WIDTH, HEIGHT = 720, 320
LEFT, RIGHT, TOP, BOTTOM = 60, 20, 56, 50
BIN_US = 2
FIRST_US, LAST_US = 10, 70


def latency_histogram(samples: list[int]) -> str:
    """SVG bar chart of tick-to-intent latency with p50/p99 markers."""
    summary = summarize(samples)
    edges = list(range(FIRST_US, LAST_US + BIN_US, BIN_US))
    counts = [0] * len(edges)  # the last bin collects everything above LAST_US
    for value in samples:
        micros = value / 1000
        index = min(max(int((micros - FIRST_US) // BIN_US), 0), len(edges) - 1)
        counts[index] += 1
    plot_w, plot_h = WIDTH - LEFT - RIGHT, HEIGHT - TOP - BOTTOM
    bar_w = plot_w / len(edges)
    peak = max(counts) or 1

    def x_of(micros: float) -> float:
        return LEFT + (micros - FIRST_US) / BIN_US * bar_w

    parts = [
        (
            f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{HEIGHT}" '
            f'viewBox="0 0 {WIDTH} {HEIGHT}" font-family="sans-serif" font-size="12">'
        ),
        f'<rect width="{WIDTH}" height="{HEIGHT}" fill="white"/>',
        (
            f'<text x="{WIDTH / 2}" y="22" text-anchor="middle" font-size="15">'
            f"R5 tick-to-intent latency, host model ({summary.samples} samples)</text>"
        ),
    ]
    for index, count in enumerate(counts):
        height = count / peak * plot_h
        x = LEFT + index * bar_w
        parts.append(
            f'<rect x="{x + 1:.1f}" y="{TOP + plot_h - height:.1f}" width="{bar_w - 2:.1f}" '
            f'height="{height:.1f}" fill="#4878a8"/>'
        )
    axis_y = TOP + plot_h
    parts.append(
        f'<line x1="{LEFT}" y1="{axis_y}" x2="{WIDTH - RIGHT}" y2="{axis_y}" stroke="black"/>'
    )
    parts.append(
        f'<line x1="{LEFT}" y1="{TOP}" x2="{LEFT}" y2="{axis_y}" stroke="black"/>'
    )
    for micros in range(FIRST_US, LAST_US + 1, 10):
        x = x_of(micros)
        label = f"{micros}" if micros < LAST_US else f"{micros}+"
        parts.append(
            f'<line x1="{x:.1f}" y1="{axis_y}" x2="{x:.1f}" y2="{axis_y + 5}" stroke="black"/>'
        )
        parts.append(
            f'<text x="{x:.1f}" y="{axis_y + 18}" text-anchor="middle">{label}</text>'
        )
    parts.append(
        f'<text x="{LEFT + plot_w / 2}" y="{HEIGHT - 12}" text-anchor="middle">'
        "microseconds from event intake to intent publish</text>"
    )
    parts.append(
        f'<text x="16" y="{TOP + plot_h / 2}" text-anchor="middle" '
        f'transform="rotate(-90 16 {TOP + plot_h / 2})">samples</text>'
    )
    for name, value, colour in (
        ("p50", summary.p50_ns, "#c0392b"),
        ("p99", summary.p99_ns, "#8e44ad"),
    ):
        x = x_of(min(value / 1000, LAST_US))
        parts.append(
            f'<line x1="{x:.1f}" y1="{TOP}" x2="{x:.1f}" y2="{axis_y}" stroke="{colour}" '
            'stroke-dasharray="4 3"/>'
        )
        parts.append(
            f'<text x="{x:.1f}" y="{TOP - 8}" text-anchor="middle" fill="{colour}">'
            f"{name} {value / 1000:.1f} us</text>"
        )
    parts.append("</svg>")
    return "\n".join(parts) + "\n"


def waveform(spec_path: Path) -> str:
    import wavedrom

    drawing = wavedrom.render(spec_path.read_text(encoding="utf-8"))
    return str(drawing.tostring()) + "\n"


SAMPLE_STATUS = {
    "ok": True,
    "state": {
        "armed": True,
        "killed": False,
        "revision": 4,
        "strategy_id": 0,
        "max_quantity": 1000,
        "price_floor": 1,
        "price_ceiling": 1_000_000_000,
    },
    "counters": {
        "intents_received": 312,
        "intents_sent": 312,
        "intents_blocked": 0,
        "accepted": 312,
        "rejected": 0,
        "intent_to_ack_p50_ns": 195_455,
        "intent_to_ack_p99_ns": 435_967,
        "journal_dropped": 0,
    },
}


async def dashboard(path: Path) -> None:
    from hft_tools.dashboard import HftDashboard, render_status
    from textual.widgets import Static

    app = HftDashboard(Path("/nonexistent/control.sock"))
    async with app.run_test(size=(78, 22)) as pilot:
        widget = app.query_one("#status", Static)
        widget.update(render_status(SAMPLE_STATUS))
        widget.set_classes("healthy")
        await pilot.pause()
        app.save_screenshot(filename=path.name, path=str(path.parent))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--dashboard", action="store_true", help="also render dashboard.svg"
    )
    args = parser.parse_args()
    FIGURES.mkdir(parents=True, exist_ok=True)

    samples = read_samples(FIGURES / "data" / "demo-r5-latency.jsonl")[
        "tick_to_intent_ns"
    ]
    (FIGURES / "latency-histogram.svg").write_text(
        latency_histogram(samples), encoding="utf-8"
    )
    (FIGURES / "ingress-waveform.svg").write_text(
        waveform(FIGURES / "ingress-waveform.json"), encoding="utf-8"
    )
    rendered = ["latency-histogram.svg", "ingress-waveform.svg"]
    if args.dashboard:
        asyncio.run(dashboard(FIGURES / "dashboard.svg"))
        rendered.append("dashboard.svg")
    print(json.dumps({"rendered": rendered}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
