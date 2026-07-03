"""시크릿 마스킹."""

from __future__ import annotations


def mask(value: str | None) -> str:
    if value is None or len(value) < 8:
        return "***"
    return value[:3] + "***"
