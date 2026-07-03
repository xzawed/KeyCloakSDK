"""OIDC 엔드포인트."""
from __future__ import annotations

from dataclasses import dataclass

from .config import KeycloakConfig


@dataclass(frozen=True)
class OidcEndpoints:
    issuer: str
    authorization: str
    token: str
    introspection: str
    end_session: str
    jwks: str

    @staticmethod
    def for_realm(config: KeycloakConfig) -> OidcEndpoints:
        base = config.server_url.rstrip("/") + "/realms/" + config.realm
        oc = base + "/protocol/openid-connect"
        return OidcEndpoints(issuer=base, authorization=oc + "/auth", token=oc + "/token",
                             introspection=oc + "/token/introspect", end_session=oc + "/logout",
                             jwks=oc + "/certs")
