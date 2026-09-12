"""토큰 값 타입."""

from __future__ import annotations

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
        # exceptions` 를 잡는 소비자가 **아무것도 잡지 못했다**(§4).
        access_token = data.get("access_token")
        if not isinstance(access_token, str) or not access_token:
            raise KeycloakAuthError("token response has no usable access_token")
        expires_in = data.get("expires_in")
        expires_at = issued_at + float(expires_in) if expires_in is not None else None
        return TokenSet(
            access_token=access_token,
            refresh_token=data.get("refresh_token"),
            id_token=data.get("id_token"),
            token_type=data.get("token_type", "Bearer"),
            scope=data.get("scope"),
            expires_at=expires_at,
        )


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
