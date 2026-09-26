"""불변 설정."""

from __future__ import annotations

import math
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
    # 미해결 kid(키 회전)로 인한 JWKS 강제 재조회의 최소 간격(초, 기본 30) — DoS 증폭 상한.
    # 위조 kid를 연속 주입해도 이 간격보다 자주 IdP를 때리지 못한다.
    jwks_min_refetch_seconds: float = 30.0
    # `validate()`가 토큰 `aud`에서 찾을 값. 미지정(None)이면 `client_id`를 기대한다(기존 동작).
    # 기본 realm은 client-credentials 토큰 `aud`에 client_id를 넣지 않으므로(audience 매퍼를
    # 추가해야 들어간다), 리소스 서버처럼 API 이름이 aud인 경우 여기에 그 값을 설정한다.
    expected_audience: str | None = None

    def __post_init__(self) -> None:
        for name in ("server_url", "realm", "client_id"):
            v = getattr(self, name)
            if not v or not str(v).strip():
                raise KeycloakConfigError(f"Missing required config: {name}")
        if not self.signature_algorithms:
            # 빈 집합은 joserfc가 권장 기본(HS256 포함)으로 폴백해 알고리즘 혼동 방어를 무력화한다.
            raise KeycloakConfigError("signature_algorithms must be non-empty")
        # read_timeout이 0 이하·NaN·±inf면 인증 경로는 max(1, round(...))로 1초로 조용히
        # 클램프하고, 어드민 경로는 python-keycloak에 그대로 넘겨 모든 호출이 즉시 실패한다.
        # 음수·비유한 clock_skew도 같다. jwks 간격은 `< 0`만으로는 NaN·+inf가 통과한다.
        # 쓸 수 없는 클라이언트가 에러 없이 생기지 않게 생성 시 거부한다(Ruby·.NET·JVM과 동일).
        if self.jwks_min_refetch_seconds < 0 or not math.isfinite(self.jwks_min_refetch_seconds):
            raise KeycloakConfigError("jwks_min_refetch_seconds must be >= 0")
        if not math.isfinite(self.read_timeout) or self.read_timeout <= 0:
            raise KeycloakConfigError("read_timeout must be > 0")
        if not math.isfinite(self.clock_skew) or self.clock_skew < 0:
            raise KeycloakConfigError("clock_skew must be >= 0")

    def __repr__(self) -> str:
        return (
            f"KeycloakConfig(server_url={self.server_url!r}, realm={self.realm!r}, "
            f"client_id={self.client_id!r}, client_secret={mask(self.client_secret)!r}, "
            f"scopes={self.scopes!r})"
        )
