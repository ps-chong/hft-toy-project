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
            state = response.get("state", {})
            widget.update(
                "\n".join(
                    (
                        "Daemon: connected",
                        f"Armed: {state.get('armed', False)}",
                        f"Killed: {state.get('killed', True)}",
                        f"Risk revision: {state.get('revision', 'unknown')}",
                        f"Max quantity: {state.get('max_quantity', 'unknown')}",
                        f"Price collar: {state.get('price_floor', 'unknown')} - "
                        f"{state.get('price_ceiling', 'unknown')}",
                    )
                )
            )
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
