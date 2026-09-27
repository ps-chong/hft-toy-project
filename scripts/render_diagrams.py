#!/usr/bin/env python3
"""Extract Mermaid blocks from architecture Markdown and render SVG files."""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
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


def render(diagrams: list[Path], output_dir: Path, command: str) -> None:
    executable = shutil.which(command)
    if executable is None:
        raise RuntimeError(f"{command!r} is not installed")
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
            ],
            check=True,
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source", type=Path, default=Path("docs/architecture")
    )
    parser.add_argument(
        "--output", type=Path, default=Path("docs/architecture/diagrams")
    )
    parser.add_argument("--render", action="store_true")
    parser.add_argument("--command", default="mmdc")
    args = parser.parse_args()

    diagrams = extract(args.source, args.output)
    if args.render:
        render(diagrams, args.output, args.command)
    print(f"processed {len(diagrams)} Mermaid diagrams")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
