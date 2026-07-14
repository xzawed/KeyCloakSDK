"""불변 설정."""

from __future__ import annotations

from dataclasses import dataclass

from ._internal.secrets import mask
from .exceptions import KeycloakConfigError


@dataclass(frozen=True)
class KeycloakConfig:
    server_url: str
    realm: str
    client_id: str
    client_secret: str | None = None
    scopes: tuple[str, ...] = ("openid",)
    read_timeout: float = 30.0
    clock_skew: float = 30.0
    # JWT 서명 검증 시 허용할 알고리즘(핀). 기본 RS256이나 ES256/PS256 서명 realm을 위해
    # 설정 가능하게 노출한다 — 하드코딩하면 그런 realm의 정상 토큰이 전부 거부된다.
    signature_algorithms: tuple[str, ...] = ("RS256",)

    def __post_init__(self) -> None:
        for name in ("server_url", "realm", "client_id"):
            v = getattr(self, name)
            if not v or not str(v).strip():
                raise KeycloakConfigError(f"Missing required config: {name}")
        if not self.signature_algorithms:
            # 빈 집합은 joserfc가 권장 기본(HS256 포함)으로 폴백해 알고리즘 혼동 방어를 무력화한다.
            raise KeycloakConfigError("signature_algorithms must be non-empty")

    def __repr__(self) -> str:
        return (
            f"KeycloakConfig(server_url={self.server_url!r}, realm={self.realm!r}, "
            f"client_id={self.client_id!r}, client_secret={mask(self.client_secret)!r}, "
            f"scopes={self.scopes!r})"
        )
