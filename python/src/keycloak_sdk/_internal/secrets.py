"""시크릿 마스킹."""

from __future__ import annotations


def mask(value: str | None) -> str:
    # 완전 불투명 마스크: 접두 노출 없이 값의 존재 여부만 표시한다(있으면 "***",
    # 없으면 ""). 접두 3글자 노출은 보안 이득이 없고 짧은 시크릿에서 비율 유출이
    # 크므로 제거했다(Java Secrets.mask와 동형).
    return "***" if value else ""
