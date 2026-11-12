"""자체 강화 JWT 검증 (joserfc). python-keycloak의 decode_token에 의존하지 않는다.

joserfc의 `jwt.decode(..., algorithms=[...])`는 서명·알고리즘 핀닝을 수행한다
(`none`/미서명/미허용 알고리즘 토큰을 거부). 그러나 exp/nbf/iss/aud 클레임 검증은
호출자 책임이므로, 이 모듈이 issuer 정확일치·audience 포함검사·exp/nbf(+클록 스큐)를
수동으로 강제한다.
"""

from __future__ import annotations

import time
from collections.abc import Collection
from typing import Any

from joserfc import jwt as _jwt
from joserfc.errors import InvalidKeyIdError, MissingKeyError
from joserfc.jwk import KeySet
from joserfc.jws import JWSRegistry
from joserfc.util import json_b64decode

from ..exceptions import TokenKeyError, TokenSignatureError, TokenValidationError
from ..tokens import ValidatedToken

#: 받는 토큰의 길이 상한(아홉 언어 공통). Microsoft.IdentityModel 의
#: `DefaultMaximumTokenSizeInBytes` 와 같은 수이고, Keycloak 26.6 기본값이 받는 가장 긴
#: Bearer(65,459 B)의 약 3.9 배라 서버가 낸 토큰은 거부하지 않는다.
JWT_MAX_BYTES = 256_000


def check_token_size(token: str) -> None:
    """상한을 넘는 토큰을 **어떤 일보다 먼저** 거부한다 — 나누기·디코드·JWKS 적재보다 앞이다.

    joserfc 도 조각마다 상한을 두지만(헤더 512 · 페이로드 128,000 · 서명 1,024 B) 그 전에
    토큰 전체를 `bytes` 로 옮기고 나눈다. 그리고 파사드는 그보다 먼저 JWKS 를 적재하므로,
    콜드 캐시에서는 쓰레기 토큰 하나가 IdP 요청 하나였다. 그래서 파사드(`_validate_for`)와
    `JwtValidator.validate` 가 둘 다 맨 앞에서 이것을 부른다.

    `str`·`bytes` 가 아닌 값은 재지 않는다 — 지금처럼 디코더가 SDK 오류로 거부한다
    (`len()` 의 raw `TypeError` 로 바꾸지 않는다).
    """
    # 단위는 `len()` — `str` 은 코드 포인트, `bytes` 는 바이트. 진짜 JWT 는 ASCII 라 둘이 같다.
    if isinstance(token, (str, bytes)) and len(token) > JWT_MAX_BYTES:
        raise TokenValidationError(f"token exceeds {JWT_MAX_BYTES} bytes")


def refuse_hs_algorithm(token: str, allowed_algs: Collection[str]) -> None:
    """⚠️ 허용 목록에 든 HS(대칭) 알고리즘을 **키를 찾기 전에** 거부한다(등록부
    hs-refusal-rests-on-libraries).

    검증 키는 realm JWKS(공개 문서)에서만 오므로 HMAC 비밀이 될 수 있는 것은 공개된 값뿐이다.
    설정 핀은 joserfc 가 디코드 안에서 — 파사드가 JWKS 를 적재한 **뒤**에 — 걸고, 그때까지 이 거부는
    oct 를 버리는 키 적재(`jwks_keys.py`)와 joserfc 의 키 종류 · alg 결합에 기대 있었다. 그래서 헤더
    alg 를 여기서 직접 본다. 허용 목록 밖의 alg 와 읽을 수 없는 헤더는 판정하지 않는다 — 지금처럼
    joserfc 가 거부한다. `check_token_size` 처럼 파사드(`_validate_for`, JWKS 적재 앞)와
    `JwtValidator.validate` 가 둘 다 부른다.
    """
    alg = _header_alg(token)
    if isinstance(alg, str) and alg in allowed_algs and alg.startswith("HS"):
        raise TokenSignatureError(f"algorithm not allowed: {alg} (a JWKS holds public keys only)")


def _header_alg(token: str | bytes) -> object:
    """보호 헤더의 `alg` 값 — joserfc 와 같은 디코더로 읽는다. 읽을 수 없으면 None."""
    try:
        raw = token.encode() if isinstance(token, str) else token
        return json_b64decode(raw.partition(b".")[0]).get("alg")
    except Exception:  # 기형 헤더 · 문자열이 아닌 토큰 — 판정은 지금의 길(joserfc)에 맡긴다
        return None


class JwtValidator:
    """joserfc 기반 자체 강화 JWT 검증기.

    - 길이: `JWT_MAX_BYTES` 를 넘으면 디코드 전에 평범한 `TokenValidationError` 다
      (서명 실패 하위 타입이 아니라 JWKS 재조회를 부르지 않는다).
    - 서명 검증 + 알고리즘 핀닝: `allowed_algs`에 없는 알고리즘(`none` 포함)·미서명
      토큰은 joserfc가 디코드 단계에서 거부한다. 허용된 HS 는 그보다 앞, 키를 찾기 전에
      거부한다(`refuse_hs_algorithm`).
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
        # ⚠️ 레지스트리를 넘기면 joserfc 는 `algorithms=` 를 보지 않는다 — 핀은 레지스트리가 든다.
        self._registry = JWSRegistry(algorithms=self._algs)
        # joserfc 의 페이로드 조각 상한(기본 128,000 B)을 위 상한으로 올린다. 그대로 두면 상한 안의
        # 진짜 서명 토큰(실측: 255,993 자 · 페이로드 조각 255,598 B)이 `ExceededSizeError` 로
        # 거부돼, 상한까지 받는 다른 여덟 언어와 받는 토큰이 갈린다. 조각은 토큰보다 길 수
        # 없으니 길이 상한은 `check_token_size` 하나다.
        self._registry.max_payload_length = JWT_MAX_BYTES

    def validate(self, token: str, key_set: KeySet) -> ValidatedToken:
        check_token_size(token)
        refuse_hs_algorithm(token, self._algs)
        try:
            decoded = _jwt.decode(token, key_set, registry=self._registry)
        except (InvalidKeyIdError, MissingKeyError) as exc:
            # 현재 JWKS로 서명 키(kid)를 해석 불가 — 키 회전 가능성(재조회 가치 있음).
            # 서명 위조(BadSignatureError)와 구분해, 위조 토큰이 certs() 재조회를
            # 유발하는 미인증 DoS 증폭을 막는다.
            raise TokenKeyError("JWT signing key (kid) not found in JWKS") from exc
        except Exception as exc:
            # 서명 불일치·알고리즘 거부·미서명 등 — 재조회해도 소용없는 실패
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
        if isinstance(aud, list):
            audiences: tuple[str, ...] = tuple(aud)
        else:
            audiences = (aud,) if aud else ()

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
