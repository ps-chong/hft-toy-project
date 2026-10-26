"""Textual status dashboard for the local HFT control socket."""

from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path
from typing import Any, cast

from textual.app import App, ComposeResult
from textual.widgets import Footer, Header, Static


async def request_status(socket_path: Path) -> dict[str, Any]:
    reader, writer = await asyncio.open_unix_connection(socket_path)
    try:
        writer.write(b'{"command":"status"}\n')
        await writer.drain()
        response = await asyncio.wait_for(reader.readline(), timeout=1.0)
        return cast(dict[str, Any], json.loads(response))
    finally:
        writer.close()
        await writer.wait_closed()


def render_status(response: dict[str, Any]) -> str:
    """Text for one status reply: operator state, then order-flow counters."""
    state = response.get("state", {})
    counters = response.get("counters", {})

    def micros(name: str) -> str:
        value = counters.get(name)
        return "n/a" if value is None else f"{value / 1000:.1f} us"

    return "\n".join(
        (
            "Daemon: connected",
            f"Armed: {state.get('armed', False)}",
            f"Killed: {state.get('killed', True)}",
            f"Risk revision: {state.get('revision', 'unknown')}",
            f"Strategy: {state.get('strategy_id', 'unknown')}",
            f"Max quantity: {state.get('max_quantity', 'unknown')}",
            f"Price collar: {state.get('price_floor', 'unknown')} - "
            f"{state.get('price_ceiling', 'unknown')}",
            "",
            f"Intents received / sent / blocked: {counters.get('intents_received', 0)} / "
            f"{counters.get('intents_sent', 0)} / {counters.get('intents_blocked', 0)}",
            f"Exchange accepted / rejected: {counters.get('accepted', 0)} / "
            f"{counters.get('rejected', 0)}",
            f"Intent to ack p50 / p99: {micros('intent_to_ack_p50_ns')} / "
            f"{micros('intent_to_ack_p99_ns')}",
            f"Journal records dropped: {counters.get('journal_dropped', 0)}",
        )
    )


class HftDashboard(App[None]):
    CSS = """
    #status { padding: 1 2; height: 100%; }
    .healthy { color: green; }
    .failed { color: red; }
    """

    def __init__(self, socket_path: Path) -> None:
        super().__init__()
        self.socket_path = socket_path

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("Connecting to hftd…", id="status", classes="failed")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "MYD-CZU5EV-V2 HFT"
        self.set_interval(1.0, self.refresh_status)

    async def refresh_status(self) -> None:
        widget = self.query_one("#status", Static)
        try:
            response = await request_status(self.socket_path)
            widget.update(render_status(response))
            widget.set_classes("healthy" if response.get("ok") else "failed")
        except (ConnectionError, FileNotFoundError, TimeoutError, json.JSONDecodeError) as error:
            widget.update(f"Daemon: disconnected\n{error}")
            widget.set_classes("failed")


def main() -> None:  # pragma: no cover - CLI glue
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, default=Path("/run/hftd/control.sock"))
    args = parser.parse_args()
    HftDashboard(args.socket).run()


if __name__ == "__main__":
    main()
