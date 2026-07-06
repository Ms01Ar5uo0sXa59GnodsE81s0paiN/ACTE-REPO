from __future__ import annotations

import json
import os
from typing import Any, Iterable


def _string_value(value: Any) -> str:
    if isinstance(value, str):
        return value.strip()
    return ""


def secret_values(
    raw_value: str,
    *,
    scalar_fields: Iterable[str],
    list_fields: Iterable[str],
) -> tuple[str, ...]:
    value = (raw_value or "").strip()
    if not value:
        return ()
    if not (value.startswith("{") or value.startswith("[")):
        return (value,)
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return (value,)
    return tuple(_walk_secret(parsed, tuple(scalar_fields), tuple(list_fields)))


def _walk_secret(value: Any, scalar_fields: tuple[str, ...], list_fields: tuple[str, ...]) -> list[str]:
    direct = _string_value(value)
    if direct:
        return [direct]
    if isinstance(value, list):
        found: list[str] = []
        for item in value:
            found.extend(_walk_secret(item, scalar_fields, list_fields))
        return found
    if isinstance(value, dict):
        found = []
        for field in scalar_fields:
            direct = _string_value(value.get(field))
            if direct:
                found.append(direct)
        for field in list_fields:
            items = value.get(field)
            if isinstance(items, list):
                for item in items:
                    found.extend(_walk_secret(item, scalar_fields, list_fields))
        return found
    return []


def first_secret_value(
    env_names: Iterable[str],
    *,
    scalar_fields: Iterable[str],
    list_fields: Iterable[str],
) -> str:
    for env_name in env_names:
        for value in secret_values(
            os.environ.get(env_name, ""),
            scalar_fields=scalar_fields,
            list_fields=list_fields,
        ):
            if value:
                return value
    return ""
