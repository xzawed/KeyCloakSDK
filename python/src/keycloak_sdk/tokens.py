"""토큰 값 타입."""

from __future__ import annotations

import math
from collections.abc import Mapping
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Any

from ._internal.secrets import mask
from .exceptions import KeycloakAuthError


@dataclass(frozen=True)
class TokenSet:
    access_token: str
    refresh_token: str | None
    id_token: str | None
    token_type: str
    scope: str | None
    expires_at: float | None

    def is_expired(self, now: float, skew: float) -> bool:
        if self.expires_at is None:
            return True
        return now + skew >= self.expires_at

    def __repr__(self) -> str:
        return (
            f"TokenSet(token_type={self.token_type!r}, scope={self.scope!r}, "
            f"access_token={mask(self.access_token)!r}, "
            f"refresh_token={mask(self.refresh_token)!r}, expires_at={self.expires_at!r})"
        )

    @staticmethod
    def from_response(data: dict[str, Any], issued_at: float) -> TokenSet:
        # ⚠️ **존재 검사는 타입 검사가 아니다.** 예전에는 `data["access_token"]` 이라
        # 숫자·객체가 그대로 들어왔고(타입 힌트는 `str`), 소비자는 그것을 Bearer 로 실어
        # 보내 매번 401 을 받았다. 키가 없으면 raw `KeyError` 가 새서 `keycloak_sdk.
        # exceptions` 를 잡는 소비자가 **아무것도 잡지 못했다**(§4). 나머지 필드도 같다 —
        # `expires_in` 이 숫자가 아니면 raw `ValueError`/`TypeError` 가 샜고, 앞의 것은 **값을
        # 인용한다**. 객체 모양 `token_type` 은 `repr` 이 그대로 찍었다(실측 2026-09-26).
        # ⚠️ 거부 메시지에는 필드 이름만 싣는다 — 형식이 틀린 응답은 그 자리에 토큰을 실어 온다.
        access_token = data.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise KeycloakAuthError("token response has no usable access_token")
        return TokenSet(
            access_token=access_token,
            refresh_token=_optional_str(data, "refresh_token"),
            id_token=_optional_str(data, "id_token"),
            token_type=_optional_str(data, "token_type") or "Bearer",
            scope=_optional_str(data, "scope"),
            expires_at=_expires_at(data.get("expires_in"), issued_at),
        )


def _optional_str(data: dict[str, Any], name: str, what: str = "token response") -> str | None:
    value = data.get(name)
    if value is None or isinstance(value, str):
        return value
    raise KeycloakAuthError(f"{what} has an invalid {name}")


def _expires_at(expires_in: Any, issued_at: float) -> float | None:
    if expires_in is None:
        return None
    try:
        seconds = float(expires_in)  # 숫자 문자열("300")도 받는다 — 예전과 같다
    except (TypeError, ValueError):
        seconds = math.nan
    # ⚠️ 거부는 `except` **밖**이다 — 안에서 던지면 값을 인용한 `ValueError` 가 `__context__` 로
    # 매달려 `logging.exception` 이 찍는다. 무한대·NaN 도 거부한다(`is_expired` 가 영원히 거짓).
    if not math.isfinite(seconds):
        raise KeycloakAuthError("token response has an invalid expires_in")
    return issued_at + seconds


@dataclass(frozen=True)
class ValidatedToken:
    subject: str | None
    issuer: str | None
    audience: tuple[str, ...]
    expires_at: float | None
    issued_at: float | None
    claims: Mapping[str, Any] = field(default_factory=dict)

    def __post_init__(self) -> None:
        # frozen dataclass가 claims 필드 자체 재바인딩은 막지만 dict 내부 변이는 막지
        # 못한다 — 읽기전용 MappingProxyType으로 감싸 소비자의 내부 변이를 차단한다
        # (Java ValidatedToken.getClaims()의 unmodifiableMap과 동형).
        object.__setattr__(self, "claims", MappingProxyType(dict(self.claims)))


@dataclass(frozen=True)
class IntrospectionResult:
    active: bool
    username: str | None
    client_id: str | None


def _introspection_result(data: dict[str, Any]) -> IntrospectionResult:
    """introspect 응답 → `IntrospectionResult`. sync·aio 미러가 같이 쓴다(RFC 7662).

    ⚠️ `active` 는 JSON boolean 만 받는다 — 예전 `bool(...)` 은 문자열 `"false"` 를 **활성**으로
    읽었다(fail-open, 실측 2026-09-26). 없거나 null 이면 비활성이다(예전과 같다). `username`·
    `client_id` 는 str|None 이다 — 객체 모양은 기본 dataclass repr 이 그 안의 토큰을 찍었다(Grok
    레그가 찾음). 거부 메시지에는 필드 이름만 싣는다."""
    what = "introspection response"
    active = data.get("active")
    if active is None:
        active = False
    if not isinstance(active, bool):
        raise KeycloakAuthError(f"{what} has an invalid active")
    return IntrospectionResult(
        active=active,
        username=_optional_str(data, "username", what),
        client_id=_optional_str(data, "client_id", what),
    )
