"""Extract Mermaid blocks from architecture Markdown and render SVG files."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

MERMAID_BLOCK = re.compile(r"```mermaid\n(.*?)\n```", re.DOTALL)


def extract(source_dir: Path, output_dir: Path) -> list[Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    generated: list[Path] = []
    expected: set[Path] = set()
    for markdown in sorted(source_dir.glob("*.md")):
        for index, diagram in enumerate(
            MERMAID_BLOCK.findall(markdown.read_text(encoding="utf-8")),
            1,
        ):
            output = output_dir / f"{markdown.stem}-{index}.mmd"
            output.write_text(diagram.strip() + "\n", encoding="utf-8")
            generated.append(output)
            expected.add(output)
    for stale in output_dir.glob("*.mmd"):
        if stale not in expected:
            stale.unlink()
    return generated


CHROME_CANDIDATES = (
    "/usr/bin/google-chrome-stable",
    "/usr/bin/google-chrome",
    "/usr/bin/chromium-browser",
    "/usr/bin/chromium",
)


def resolve_puppeteer_config(path: Path | None) -> Path | None:
    config: dict[str, object] = {}
    if path is not None and path.exists():
        config = json.loads(path.read_text(encoding="utf-8"))
    for candidate in CHROME_CANDIDATES:
        if Path(candidate).exists():
            config.setdefault("executablePath", candidate)
            break
    if not config:
        return path
    destination = Path(tempfile.gettempdir()) / "hft-mermaid-puppeteer.json"
    destination.write_text(json.dumps(config), encoding="utf-8")
    return destination


def render(
    diagrams: list[Path],
    output_dir: Path,
    command: str,
    puppeteer_config: Path | None = None,
) -> None:
    executable = shutil.which(command)
    if executable is None:
        raise RuntimeError(f"{command!r} is not installed")
    extra: list[str] = []
    if puppeteer_config is not None:
        extra.extend(["--puppeteerConfigFile", str(puppeteer_config)])
    for diagram in diagrams:
        subprocess.run(
            [
                executable,
                "--input",
                str(diagram),
                "--output",
                str(output_dir / f"{diagram.stem}.svg"),
                "--backgroundColor",
                "transparent",
                *extra,
            ],
            check=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=Path("docs/architecture"))
    parser.add_argument(
        "--output", type=Path, default=Path("docs/architecture/diagrams")
    )
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--command", default="mmdc")
    parser.add_argument(
        "--puppeteer-config",
        type=Path,
        default=Path(__file__).with_name("mermaid-puppeteer.json"),
    )
    args = parser.parse_args()

    diagrams = extract(args.source, args.output)
    if args.render:
        render(
            diagrams,
            args.output,
            args.command,
            resolve_puppeteer_config(args.puppeteer_config),
        )
    print(f"processed {len(diagrams)} Mermaid diagrams")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
