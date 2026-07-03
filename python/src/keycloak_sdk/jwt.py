"""자체 강화 JWT 검증 (joserfc). python-keycloak의 decode_token에 의존하지 않는다.

joserfc의 `jwt.decode(..., algorithms=[...])`는 서명·알고리즘 핀닝을 수행한다
(`none`/미서명/미허용 알고리즘 토큰을 거부). 그러나 exp/nbf/iss/aud 클레임 검증은
호출자 책임이므로, 이 모듈이 issuer 정확일치·audience 포함검사·exp/nbf(+클록 스큐)를
수동으로 강제한다.
"""
from __future__ import annotations

import time
from typing import Any

from joserfc import jwt as _jwt
from joserfc.jwk import KeySet

from .exceptions import TokenSignatureError, TokenValidationError
from .tokens import ValidatedToken


class JwtValidator:
    """joserfc 기반 자체 강화 JWT 검증기.

    - 서명 검증 + 알고리즘 핀닝: `allowed_algs`에 없는 알고리즘(`none` 포함)·미서명
      토큰은 joserfc가 디코드 단계에서 거부한다.
    - issuer: 정확 일치(exact match).
    - audience: 포함 검사(containment) — `aud` 클레임이 문자열이면 `==`, 리스트면
      멤버십(`in`)으로 판단한다(다중 audience를 갖는 실제 Keycloak 토큰 대응).
    - exp: 필수 클레임. `now - clock_skew >= exp`이면 만료로 간주.
    - nbf: 선택 클레임. `now + clock_skew < nbf`이면 아직 유효하지 않음으로 간주.
    - 서명/알고리즘/키(kid) 결정 실패는 `TokenSignatureError`(`TokenValidationError`의
      하위 타입)로, 클레임(issuer/audience/exp/nbf) 실패는 평범한 `TokenValidationError`
      로 래핑되어 전파된다 — 호출자가 "JWKS 재조회로 복구 가능한 실패"와 "재조회해도
      소용없는 실패"를 구분할 수 있게 하기 위함이다.
    """

    def __init__(
        self,
        issuer: str,
        audience: str,
        allowed_algs: tuple[str, ...] = ("RS256",),
        clock_skew: float = 30.0,
    ) -> None:
        if not allowed_algs:
            # joserfc는 algorithms=[]/None이면 권장 알고리즘 집합(HS256 포함)으로
            # 폴백한다 — 빈 튜플을 허용하면 알고리즘 혼동 방어가 조용히 무력화된다.
            raise ValueError("allowed_algs must be non-empty")
        self._issuer = issuer
        self._audience = audience
        self._algs: list[str] = list(allowed_algs)
        self._skew = clock_skew

    def validate(self, token: str, key_set: KeySet) -> ValidatedToken:
        try:
            decoded = _jwt.decode(token, key_set, algorithms=self._algs)
        except Exception as exc:  # joserfc.errors.* (서명 불일치, 알고리즘 거부, kid 미해결 등)를 포괄
            raise TokenSignatureError("JWT signature/algorithm validation failed") from exc

        claims: dict[str, Any] = dict(decoded.claims)
        try:
            self._check_claims(claims)
        except TokenValidationError:
            raise
        except Exception as exc:  # 잘못된 타입의 클레임(예: exp/nbf가 숫자가 아님)이
            # float() 변환 등에서 raw ValueError/TypeError를 던지는 것을 방지한다.
            raise TokenValidationError("Malformed claim value") from exc

        aud = claims.get("aud")
        audiences: tuple[str, ...] = tuple(aud) if isinstance(aud, list) else ((aud,) if aud else ())

        return ValidatedToken(
            subject=claims.get("sub"),
            issuer=claims.get("iss"),
            audience=audiences,
            expires_at=claims.get("exp"),
            issued_at=claims.get("iat"),
            claims=claims,
        )

    def _check_claims(self, claims: dict[str, Any]) -> None:
        now = time.time()

        if claims.get("iss") != self._issuer:
            raise TokenValidationError("Issuer mismatch")

        aud = claims.get("aud")
        contained = (aud == self._audience) or (isinstance(aud, list) and self._audience in aud)
        if not contained:
            raise TokenValidationError("Audience not contained")

        exp = claims.get("exp")
        if exp is None:
            raise TokenValidationError("Missing exp claim")
        if now - self._skew >= float(exp):
            raise TokenValidationError("Token expired")

        nbf = claims.get("nbf")
        if nbf is not None and now + self._skew < float(nbf):
            raise TokenValidationError("Token not yet valid")
