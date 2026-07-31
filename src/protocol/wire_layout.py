"""Load `generated/wire_layout.json` and build `struct` format strings matching Zig `readWire` layout (LE)."""

from __future__ import annotations

import json
import struct
from pathlib import Path
from typing import Any, Mapping

_DEFAULT_MANIFEST = Path(__file__).resolve().parent / "generated" / "wire_layout.json"


def load_manifest(path: Path | None = None) -> dict[str, Any]:
    manifest_path = path or _DEFAULT_MANIFEST
    with manifest_path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _schema_to_fmt(schema: Mapping[str, Any]) -> str:
    kind = schema["kind"]
    if kind == "int":
        bits = int(schema["bits"])
        signed = bool(schema["signed"])
        if bits == 8:
            return "b" if signed else "B"
        if bits == 16:
            return "h" if signed else "H"
        if bits == 32:
            return "i" if signed else "I"
        if bits == 64:
            return "q" if signed else "Q"
        raise ValueError(f"unsupported int width: {bits}")
    if kind == "float":
        bits = int(schema["bits"])
        if bits == 32:
            return "f"
        if bits == 64:
            return "d"
        raise ValueError(f"unsupported float width: {bits}")
    if kind == "array":
        el = _schema_to_fmt(schema["element"])
        return el * int(schema["len"])
    if kind == "struct":
        return "".join(_schema_to_fmt(f["schema"]) for f in schema["fields"])
    if kind == "void":
        return ""
    raise ValueError(f"unsupported schema kind: {kind}")


def struct_format_for_schema_name(manifest: Mapping[str, Any], name: str) -> str:
    """Little-endian, no inter-field padding (matches Zig `readWire` / `writeWire`)."""
    try:
        schema = manifest["schemas"][name]
    except KeyError as e:
        raise KeyError(f"unknown schema {name!r}") from e
    return "<" + _schema_to_fmt(schema)


def wire_size_constant(manifest: Mapping[str, Any], key: str) -> int:
    return int(manifest["constants"][key])


def _self_check(manifest: dict[str, Any]) -> None:
    for name, const_key in (
        ("State", "wire_size_State"),
        ("ScanEntry", "wire_size_ScanEntry"),
        ("AuraEntry", "wire_size_AuraEntry"),
        ("CooldownEntry", "wire_size_CooldownEntry"),
        ("SpellRangeEntry", "wire_size_SpellRangeEntry"),
        ("TalentPoints", "wire_size_TalentPoints"),
    ):
        fmt = struct_format_for_schema_name(manifest, name)
        expected = wire_size_constant(manifest, const_key)
        actual = struct.calcsize(fmt)
        if actual != expected:
            raise SystemExit(
                f"wire_layout self-check failed: {name} calcsize={actual} manifest={expected}"
            )


if __name__ == "__main__":
    _self_check(load_manifest())
    print("wire_layout: self-check ok")
