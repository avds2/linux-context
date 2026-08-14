#!/usr/bin/env python3
"""Binary-safe structured staging for linux-context.

Collectors are shell programs and never hand-build JSON. Bash variables cannot
contain NUL, so NUL-delimited fixed-arity records provide a small, fast,
unambiguous bridge from shell acquisition to Python-owned JSON serialization.
"""
from __future__ import annotations

import math
from pathlib import Path
from typing import Any, Iterable

SCHEMAS: dict[str, tuple[tuple[str, str], ...]] = {
    "facts": (("key","str"),("value","typed"),("value_type","str"),("source","str"),("observation_type","str"),("confidence","float"),("collector","str")),
    "entities": (("id","str"),("entity_type","str"),("label","str"),("source","str"),("observation_type","str"),("confidence","float"),("collector","str")),
    "entity_attrs": (("id","str"),("key","str"),("value","typed"),("value_type","str"),("source","str"),("observation_type","str"),("confidence","float"),("collector","str")),
    "relations": (("from","str"),("predicate","str"),("to","str"),("source","str"),("observation_type","str"),("confidence","float"),("collector","str")),
    "artifacts": (("id","str"),("collector","str"),("label","str"),("kind","str"),("path","str"),("source","str"),("exit_code","int"),("accepted","bool"),("timed_out","bool"),("truncated","bool"),("timeout_seconds","int"),("max_bytes","int"),("captured_bytes","int"),("duration_ms","int"),("priority","int"),("omitted_reason","str"),("omitted_bytes","int")),
    "probes": (("label","str"),("source","str"),("exit_code","int"),("accepted","bool"),("timed_out","bool"),("truncated","bool"),("captured_bytes","int"),("duration_ms","int")),
}

_VALUE_TYPES = {"string", "number", "boolean", "null"}
_TRUE = {"1", "true", "yes", "on"}
_FALSE = {"0", "false", "no", "off"}


def _decode(raw: bytes) -> str:
    return raw.decode("utf-8", errors="replace")


def _bool(text: str) -> bool:
    normalized = text.strip().lower()
    if normalized in _TRUE:
        return True
    if normalized in _FALSE:
        return False
    raise ValueError(f"invalid boolean field: {text!r}")


def _int(text: str) -> int:
    try:
        return int(text)
    except ValueError as exc:
        raise ValueError(f"invalid integer field: {text!r}") from exc


def _float(text: str) -> float:
    try:
        value = float(text)
    except ValueError as exc:
        raise ValueError(f"invalid float field: {text!r}") from exc
    if not math.isfinite(value):
        raise ValueError(f"non-finite float field: {text!r}")
    return value


def _typed(text: str, value_type: str) -> Any:
    if value_type not in _VALUE_TYPES:
        raise ValueError(f"unsupported value_type: {value_type!r}")
    if value_type == "string":
        return text
    if value_type == "number":
        if any(c in text.lower() for c in (".", "e")):
            return _float(text)
        return _int(text)
    if value_type == "boolean":
        return _bool(text)
    if value_type == "null":
        if text != "null":
            raise ValueError(f"null value_type requires literal 'null', got {text!r}")
        return None
    raise AssertionError(value_type)


def read_records(path: Path, kind: str) -> list[dict[str, Any]]:
    try:
        schema = SCHEMAS[kind]
    except KeyError as exc:
        raise ValueError(f"unknown record kind: {kind}") from exc
    if not path.exists() or path.stat().st_size == 0:
        return []
    data = path.read_bytes()
    if not data.endswith(b"\0"):
        raise ValueError(f"{path}: truncated structured staging record (missing NUL terminator)")
    fields = data[:-1].split(b"\0")
    width = len(schema)
    if len(fields) % width:
        raise ValueError(f"{path}: malformed structured staging stream: {len(fields)} fields is not a multiple of {width}")
    out: list[dict[str, Any]] = []
    for offset in range(0, len(fields), width):
        strings = [_decode(x) for x in fields[offset:offset + width]]
        row: dict[str, Any] = {}
        for (name, typ), text in zip(schema, strings):
            if typ in {"str", "typed"}:
                row[name] = text
            elif typ == "bool":
                row[name] = _bool(text)
            elif typ == "int":
                row[name] = _int(text)
            elif typ == "float":
                row[name] = _float(text)
            else:
                raise ValueError(f"unsupported schema primitive: {typ}")
        if "value" in row and "value_type" in row:
            row["value"] = _typed(str(row["value"]), str(row["value_type"]))
        if "confidence" in row and not 0.0 <= float(row["confidence"]) <= 1.0:
            raise ValueError(f"{path}: confidence outside [0,1]: {row['confidence']!r}")
        out.append(row)
    return out


def _encode_field(value: Any, typ: str, row: dict[str, Any]) -> bytes:
    if typ == "bool":
        if not isinstance(value, bool):
            value = _bool(str(value))
        text = "1" if value else "0"
    elif typ == "typed":
        if value is None:
            text = "null"
        elif isinstance(value, bool):
            text = "true" if value else "false"
        else:
            text = str(value)
    else:
        text = "" if value is None else str(value)
    if "\x00" in text:
        raise ValueError("NUL is not permitted inside a staging field")
    return text.encode("utf-8", errors="replace")


def write_records(path: Path, kind: str, rows: Iterable[dict[str, Any]]) -> None:
    try:
        schema = SCHEMAS[kind]
    except KeyError as exc:
        raise ValueError(f"unknown record kind: {kind}") from exc
    parts: list[bytes] = []
    for row in rows:
        # Validate through the same parser semantics before encoding test/compiler fixtures.
        if "confidence" in row:
            confidence = _float(str(row["confidence"]))
            if not 0.0 <= confidence <= 1.0:
                raise ValueError(f"confidence outside [0,1]: {confidence!r}")
        if "value_type" in row:
            value_type = str(row["value_type"])
            if value_type not in _VALUE_TYPES:
                raise ValueError(f"unsupported value_type: {value_type!r}")
        for name, typ in schema:
            if name in row:
                value = row[name]
            elif typ == "bool":
                value = False
            elif typ in {"int", "float"}:
                value = 0
            else:
                value = ""
            parts.append(_encode_field(value, typ, row))
    path.write_bytes(b"\0".join(parts) + (b"\0" if parts else b""))
