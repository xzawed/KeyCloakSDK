"""토큰 값 타입."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from ._internal.secrets import mask


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
        expires_in = data.get("expires_in")
        expires_at = issued_at + float(expires_in) if expires_in is not None else None
        return TokenSet(
            access_token=data["access_token"],
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
    claims: dict[str, Any] = field(default_factory=dict)


@dataclass(frozen=True)
class IntrospectionResult:
    active: bool
    username: str | None
    client_id: str | None
