"""Decode the generated PL register map through Linux UIO or an image file."""

from __future__ import annotations

import argparse
import json
import mmap
import os
import struct
from pathlib import Path
from types import TracebackType
from typing import Any, Self, cast


class RegisterMap:
    """RAII owner for a read-only memory mapping."""

    def __init__(self, device: Path, span: int) -> None:
        self._descriptor = os.open(device, os.O_RDONLY | os.O_CLOEXEC)
        try:
            self._mapping = mmap.mmap(
                self._descriptor,
                span,
                access=mmap.ACCESS_READ,
            )
        except BaseException:
            os.close(self._descriptor)
            raise

    def __enter__(self) -> Self:
        return self

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        self._mapping.close()
        os.close(self._descriptor)

    def read_u32(self, offset: int) -> int:
        return int(struct.unpack_from("<I", self._mapping, offset)[0])


def load_schema(path: Path) -> dict[str, Any]:
    return cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))


def decode_registers(image: bytes, schema: dict[str, Any]) -> dict[str, int]:
    values: dict[str, int] = {}
    for register in schema["registers"]:
        offset = int(register["offset"], 16)
        if offset + 4 > len(image):
            raise ValueError(f"{register['name']} is outside the supplied image")
        values[register["name"]] = struct.unpack_from("<I", image, offset)[0]
    return values


def build_parser() -> argparse.ArgumentParser:  # pragma: no cover - CLI glue
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", type=Path, default=Path("/dev/uio0"))
    parser.add_argument("--schema", type=Path, default=Path("protocol/schema/registers.yaml"))
    parser.add_argument("--json", action="store_true")
    return parser


def main() -> None:  # pragma: no cover - CLI glue
    args = build_parser().parse_args()
    schema = load_schema(args.schema)
    span = int(schema["span"], 16)
    with RegisterMap(args.device, span) as registers:
        values = {
            register["name"]: registers.read_u32(int(register["offset"], 16))
            for register in schema["registers"]
        }
    if args.json:
        print(json.dumps(values, indent=2, sort_keys=True))
    else:
        for name, value in values.items():
            print(f"{name:24} 0x{value:08x} ({value})")


if __name__ == "__main__":
    main()
