"""불변 설정."""
from __future__ import annotations
from dataclasses import dataclass, field
from ._internal.secrets import mask
from .exceptions import KeycloakConfigError

@dataclass(frozen=True)
class KeycloakConfig:
    server_url: str
    realm: str
    client_id: str
    client_secret: str | None = None
    scopes: tuple[str, ...] = ("openid",)
    connect_timeout: float = 10.0
    read_timeout: float = 30.0
    clock_skew: float = 30.0

    def __post_init__(self) -> None:
        for name in ("server_url", "realm", "client_id"):
            v = getattr(self, name)
            if not v or not str(v).strip():
                raise KeycloakConfigError(f"Missing required config: {name}")

    def __repr__(self) -> str:
        return (f"KeycloakConfig(server_url={self.server_url!r}, realm={self.realm!r}, "
                f"client_id={self.client_id!r}, client_secret={mask(self.client_secret)!r}, "
                f"scopes={self.scopes!r})")
