"""JwtValidator 보안 회귀 테스트.

joserfc로 서명·클레임을 실제로 만들어 검증기에 통과시킨다(비-공허 테스트).
Java SDK의 JwtValidator가 2회의 보안 수정 루프를 거쳐 수렴한 스위트를 그대로 이식한다:
서명/알고리즘 핀닝(none·미서명 거부), issuer 정확일치, audience 포함검사(다중값 대응),
exp/nbf(+클록 스큐), RSA-공개키를 HMAC 비밀키로 재사용하는 고전적 알고리즘 혼동 공격 방어.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import time

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import KeySet, RSAKey

from keycloak_sdk._internal.jwt import JWT_MAX_BYTES, JwtValidator
from keycloak_sdk.exceptions import TokenKeyError, TokenSignatureError, TokenValidationError
from tests.unit.conftest import hs_token

ISSUER = "https://kc.example.com/realms/r"


def _rsa_key() -> RSAKey:
    return RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})


def _sign(key: RSAKey, claims: dict) -> str:
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def test_valid_single_aud_token_accepted():
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": ISSUER,
            "aud": "app",
            "sub": "user-1",
            "iat": int(time.time()),
            "exp": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    result = validator.validate(tok, KeySet([key]))

    assert result.issuer == ISSUER
    assert result.subject == "user-1"
    assert "app" in result.audience


def test_valid_multi_aud_containing_expected_accepted():
    """실제 Keycloak client-credentials 토큰은 aud가 다중값이다 — 포함검사여야 한다."""
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": ISSUER,
            "aud": ["app", "realm-management"],
            "exp": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    result = validator.validate(tok, KeySet([key]))

    assert result.issuer == ISSUER
    assert set(result.audience) == {"app", "realm-management"}


def test_audience_not_containing_expected_rejected():
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": ISSUER,
            "aud": ["someone-else"],
            "exp": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_none_alg_unsigned_token_rejected():
    """alg=none 헤더의 미서명 토큰. 서명 검증 이전에 알고리즘 핀닝으로 거부돼야 한다."""
    key = _rsa_key()
    validator = JwtValidator(issuer=ISSUER, audience="app")
    none_token = "eyJhbGciOiJub25lIn0.eyJpc3MiOiJpc3MifQ."

    with pytest.raises(TokenValidationError):
        validator.validate(none_token, KeySet([key]))


def test_plain_jwt_with_valid_claims_still_rejected_for_being_unsigned():
    """클레임(issuer/audience/exp)이 전부 유효해도 서명이 없으면 반드시 거부된다.

    비-공허성 확인: claim 검증을 통과할 토큰을 일부러 만들어, 서명 부재만으로
    거부되는지를 직접 증명한다(claim 검증 실패로 우연히 통과하는 게 아님).
    """
    import base64
    import json

    header = base64.urlsafe_b64encode(json.dumps({"alg": "none"}).encode()).rstrip(b"=")
    payload = base64.urlsafe_b64encode(
        json.dumps(
            {
                "iss": ISSUER,
                "aud": "app",
                "exp": int(time.time()) + 60,
            }
        ).encode()
    ).rstrip(b"=")
    plain_jwt = header.decode() + "." + payload.decode() + "."

    validator = JwtValidator(issuer=ISSUER, audience="app")
    with pytest.raises(TokenValidationError):
        validator.validate(plain_jwt, KeySet([_rsa_key()]))


def test_expired_token_rejected():
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": ISSUER,
            "aud": "app",
            "exp": int(time.time()) - 1000,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app", clock_skew=5.0)

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_configured_clock_skew_boundary():
    """Configured clock_skew=30 is actually applied — not ignored, not a far-past default.

    Far-past expiry (e.g. now-1000) rejects under any reasonable skew and does not
    prove wiring. The pair below does: exp=now-10 must PASS (20s margin inside the
    30s window) and exp=now-60 must raise TokenValidationError (30s margin past it).
    If skew were 0 (unwired) the first half fails; if a large library default were
    used instead of 30 the second half fails.
    """
    key = _rsa_key()
    now = int(time.time())
    skew = 30.0
    validator = JwtValidator(issuer=ISSUER, audience="app", clock_skew=skew)

    within = _sign(
        key,
        {"iss": ISSUER, "aud": "app", "exp": now - 10},
    )
    result = validator.validate(within, KeySet([key]))
    assert result.issuer == ISSUER

    beyond = _sign(
        key,
        {"iss": ISSUER, "aud": "app", "exp": now - 60},
    )
    with pytest.raises(TokenValidationError):
        validator.validate(beyond, KeySet([key]))


def test_wrong_issuer_rejected():
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": "https://evil.example.com/realms/r",
            "aud": "app",
            "exp": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_not_yet_valid_nbf_rejected():
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": ISSUER,
            "aud": "app",
            "exp": int(time.time()) + 120,
            "nbf": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app", clock_skew=5.0)

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_hs256_token_signed_with_rsa_public_key_bytes_rejected_when_pinned_to_rs256():
    """고전적 alg-confusion 공격 회귀 테스트.

    검증기는 RS256에만 핀고정돼 있고, 신뢰하는 것은 RSA 공개키뿐이다. 공격자가
    그 RSA 공개키 바이트(PEM/X.509 인코딩)를 그대로 HMAC 비밀키로 재사용해 HS256으로
    서명한 토큰을 제시한다("naive" 검증기가 공개키를 대칭키로 오용하는 경우를 노림).
    클레임은 모두 유효하지만 alg가 허용 집합(RS256)에 없으므로 반드시 거부된다.
    """
    rsa_key = _rsa_key()
    public_key_bytes = rsa_key.as_pem(private=False)
    assert len(public_key_bytes) >= 32  # HS256에 유효한 길이의 "비밀키" 후보

    # joserfc 1.7.7+는 비대칭 공개키를 oct 키로 import하는 것을 거부하지만, 공격자는
    # 그 검사에 묶이지 않으므로 위조 토큰은 표준 라이브러리로 만든다.
    header = {"typ": "JWT", "alg": "HS256"}
    claims = {"iss": ISSUER, "aud": "app", "exp": int(time.time()) + 60}
    header_segment = _b64url(json.dumps(header, separators=(",", ":")).encode())
    claims_segment = _b64url(json.dumps(claims, separators=(",", ":")).encode())
    signing_input = f"{header_segment}.{claims_segment}"
    signature = hmac.new(public_key_bytes, signing_input.encode("ascii"), hashlib.sha256).digest()
    signature_segment = _b64url(signature)
    hs256_token = f"{signing_input}.{signature_segment}"

    # 검증기의 키셋에는 RSA 공개키만 있다 — HS256으로는 애초에 검증 불가능할뿐더러
    # allowed_algs=("RS256",)로 알고리즘 자체가 거부되어야 한다.
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError):
        validator.validate(hs256_token, KeySet([rsa_key]))


def test_missing_exp_claim_rejected():
    key = _rsa_key()
    tok = _sign(key, {"iss": ISSUER, "aud": "app"})
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_malformed_exp_raises_token_validation_error():
    """exp가 숫자가 아니면 float() 변환이 raw ValueError를 던지지 않고
    TokenValidationError로 래핑되어야 한다."""
    key = _rsa_key()
    tok = _sign(key, {"iss": ISSUER, "aud": "app", "exp": "soon"})
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_signature_failure_raises_token_signature_error_subtype():
    """서명/키 결정 실패(예: 검증기 키셋에 없는 kid로 서명됨)는 `TokenSignatureError`
    (`TokenValidationError`의 하위 타입)를 던져야 한다 — `AuthClient`가 이 타입만
    근거로 JWKS 재조회 여부를 판단한다(FIX I.2)."""
    key = _rsa_key()
    unknown_key = _rsa_key()  # 검증기의 KeySet에는 없는 키로 서명 → kid 미해결/서명 실패
    tok = _sign(
        unknown_key,
        {
            "iss": ISSUER,
            "aud": "app",
            "exp": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenSignatureError):
        validator.validate(tok, KeySet([key]))


def test_claim_failure_is_not_a_token_signature_error():
    """클레임 실패(예: audience 불일치)는 `TokenValidationError`이지만
    `TokenSignatureError`는 아니어야 한다 — 그래야 `AuthClient`가 클레임 실패에
    대해서는 불필요한 JWKS 재조회를 건너뛸 수 있다(FIX I.2)."""
    key = _rsa_key()
    tok = _sign(
        key,
        {
            "iss": ISSUER,
            "aud": ["someone-else"],
            "exp": int(time.time()) + 60,
        },
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError) as excinfo:
        validator.validate(tok, KeySet([key]))
    assert not isinstance(excinfo.value, TokenSignatureError)


def test_empty_allowed_algs_rejected_at_construction():
    """allowed_algs=()이면 joserfc가 권장 알고리즘 집합(HS256 포함)으로 폴백해
    알고리즘 혼동 방어가 무력화되므로, 생성 시점에 즉시 거부돼야 한다."""
    with pytest.raises(ValueError):
        JwtValidator(issuer=ISSUER, audience="app", allowed_algs=())


def test_unresolved_kid_raises_token_key_error_not_plain_signature_error():
    """토큰의 kid가 현재 JWKS에 없으면(키 회전 시나리오) `TokenKeyError`를 던진다 —
    `AuthClient`는 이 타입에 한해서만 JWKS를 재조회한다. 단순 서명 위조
    (`TokenSignatureError`, kid는 해석되나 서명 불일치)와 구분되어야 미인증 DoS
    증폭(위조 토큰마다 certs() 재조회)을 막을 수 있다."""
    signing_key = RSAKey.generate_key(2048, {"kid": "rotated-kid", "use": "sig"})
    cached_key = RSAKey.generate_key(2048, {"kid": "cached-kid", "use": "sig"})
    tok = jjwt.encode(
        {"alg": "RS256", "kid": "rotated-kid"},
        {"iss": ISSUER, "aud": "app", "exp": int(time.time()) + 60},
        signing_key,
    )
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenKeyError):
        validator.validate(tok, KeySet([cached_key]))
    # TokenKeyError는 TokenSignatureError의 하위 타입이라 기존 소비자와 호환된다
    assert issubclass(TokenKeyError, TokenSignatureError)


def test_validated_token_claims_are_read_only():
    """ValidatedToken.claims는 읽기전용(MappingProxyType) — 소비자가 내부 클레임 dict를
    변이할 수 없다(Java ValidatedToken.getClaims()의 unmodifiableMap과 동형)."""
    key = _rsa_key()
    tok = _sign(key, {"iss": ISSUER, "aud": "app", "sub": "u", "exp": int(time.time()) + 60})
    validator = JwtValidator(issuer=ISSUER, audience="app")

    result = validator.validate(tok, KeySet([key]))

    assert result.claims["sub"] == "u"
    with pytest.raises(TypeError):
        result.claims["sub"] = "attacker"  # 읽기전용 — 변이 시도는 TypeError


# --- 받는 토큰의 길이 상한(inbound-token-cap) — 디코드보다 먼저 거부한다 ----------------


def test_a_token_over_the_cap_is_rejected_before_it_is_decoded():
    """T1 — 상한 + 1 길이의 쓰레기. 디코드가 먼저 돌면 서명/알고리즘 실패로 나와 `exceeds` 를 말하지
    않는다(순서까지 고정한다). 서명 실패 하위 타입이 아니어야 파사드가 JWKS 를 재조회하지 않는다."""
    over = "a" * (JWT_MAX_BYTES - 1) + ".."
    assert len(over) == JWT_MAX_BYTES + 1

    with pytest.raises(TokenValidationError, match="exceeds 256000 bytes") as refused:
        JwtValidator(issuer=ISSUER, audience="app").validate(over, KeySet([_rsa_key()]))
    assert type(refused.value) is TokenValidationError


def test_a_token_at_the_cap_is_left_to_the_decoder():
    """T2 — 상한 길이의 쓰레기는 상한이 아니라 디코더가 거부한다(`>` 이지 `>=` 가 아니다)."""
    at_cap = "a" * (JWT_MAX_BYTES - 2) + ".."
    assert len(at_cap) == JWT_MAX_BYTES

    with pytest.raises(TokenSignatureError) as refused:
        JwtValidator(issuer=ISSUER, audience="app").validate(at_cap, KeySet([_rsa_key()]))
    assert "exceeds" not in str(refused.value)


def _padded_token(key: RSAKey, length: int) -> str:
    """`pad` 클레임을 덧대 길이가 [length - 8, length] 인 진짜 서명 토큰(역할이 많은 사용자)."""
    claims = {"iss": ISSUER, "aud": "app", "sub": "user-1", "exp": int(time.time()) + 60}
    n = (length - len(_sign(key, claims))) * 3 // 4
    token = _sign(key, {**claims, "pad": "a" * n})
    while len(token) > length:
        n -= 1
        token = _sign(key, {**claims, "pad": "a" * n})
    assert len(token) > length - 8
    return token


@pytest.mark.parametrize(
    "length",
    [
        pytest.param(65_459, id="longest bearer Keycloak 26.6 accepts by default"),
        pytest.param(JWT_MAX_BYTES, id="the cap"),
    ],
)
def test_a_signed_token_up_to_the_cap_still_validates(length):
    """T3 — 상한은 정상 토큰을 거부하지 않는다. ⚠️ 상한 쪽은 joserfc 의 페이로드 조각 상한
    (기본 128,000 B)을 올린 것까지 잰다 — 올리기 전에는 이 토큰이 `ExceededSizeError` 였다(실측)."""
    key = _rsa_key()
    token = _padded_token(key, length)

    result = JwtValidator(issuer=ISSUER, audience="app").validate(token, KeySet([key]))

    assert result.subject == "user-1"


def test_the_cap_measures_str_and_bytes_and_leaves_other_values_to_the_decoder():
    """상한은 `str`·`bytes` 를 잰다(joserfc 는 둘 다 받는다). 다른 값은 지금처럼 디코더가 SDK 오류로
    거부한다 — `len()` 의 raw `TypeError` 가 공개 API 로 새지 않는다."""
    validator = JwtValidator(issuer=ISSUER, audience="app")
    over = b"a" * (JWT_MAX_BYTES - 1) + b".."

    with pytest.raises(TokenValidationError, match="exceeds 256000 bytes"):
        validator.validate(over, KeySet([_rsa_key()]))  # type: ignore[arg-type]
    with pytest.raises(TokenSignatureError):
        validator.validate(None, KeySet([_rsa_key()]))  # type: ignore[arg-type]


# --- HS(대칭) 서명은 허용돼도 키를 찾기 전에 거부한다(hs-refusal-rests-on-libraries) ----------

_RS_AND_HS = ("RS256", "HS256", "HS384", "HS512")
_PIN_REFUSAL = "JWT signature/algorithm validation failed"  # joserfc 가 거부할 때의 지금 문구


class _CountingKeySet(KeySet):
    """joserfc 가 키셋에서 키를 찾는 두 길(`get_by_kid` · `pick_random_key`)을 센다."""

    lookups = 0

    def get_by_kid(self, kid=None, parameters=None):
        self.lookups += 1
        return super().get_by_kid(kid, parameters)

    def pick_random_key(self, algorithm=None, parameters=None):
        self.lookups += 1
        return super().pick_random_key(algorithm, parameters)


@pytest.mark.parametrize("alg", ["HS256", "HS384", "HS512"])
def test_hs_is_refused_before_any_key_lookup_even_when_allowed(alg):
    """⚠️ HS(대칭) 서명은 설정이 허용해도 **키를 찾기 전에** 거부한다(등록부
    hs-refusal-rests-on-libraries) — 검증 키는 JWKS(공개 문서)에서만 오므로 HMAC 비밀이 될 수
    있는 것은 공개된 값뿐이다. kid 는 키셋에 있는 RSA 키를 가리킨다. 허용 목록 밖의 HS 는 지금의
    길과 문구(joserfc 의 핀)에 남는다. 파사드의 JWKS 요청 수는 `test_auth.py` · `aio/test_auth.py`
    가 잰다."""
    rsa_key = _rsa_key()
    forged = hs_token(os.urandom(64), ISSUER, "app", "k1", alg=alg)
    validator = JwtValidator(issuer=ISSUER, audience="app", allowed_algs=_RS_AND_HS)
    key_set = _CountingKeySet([rsa_key])

    with pytest.raises(TokenSignatureError) as refused:
        validator.validate(forged, key_set)

    want = f"algorithm not allowed: {alg} (a JWKS holds public keys only)"
    assert (str(refused.value), refused.value.__cause__, key_set.lookups) == (want, None, 0)
    # 허용 목록 밖이면 지금의 문구 그대로다.
    with pytest.raises(TokenSignatureError) as pinned:
        JwtValidator(issuer=ISSUER, audience="app").validate(forged, KeySet([rsa_key]))
    assert str(pinned.value) == _PIN_REFUSAL
    # 대조 — 같은 검증기 · 같은 키셋이 그 RSA 키로 서명한 RS256 토큰은 통과시키고, 그때 키를 찾는다.
    claims = {"iss": ISSUER, "aud": "app", "sub": "user-1", "exp": int(time.time()) + 60}
    assert validator.validate(_sign(rsa_key, claims), key_set).subject == "user-1"
    assert key_set.lookups == 1


def test_an_unreadable_header_is_left_to_the_decoder():
    """헤더를 읽을 수 없으면(base64 · JSON 이 아니다 · 객체가 아니다 · alg 가 문자열이 아니다) HS
    거부는 판정하지 않는다 — 지금처럼 joserfc 가 거부한다."""
    validator = JwtValidator(issuer=ISSUER, audience="app", allowed_algs=_RS_AND_HS)
    key_set = KeySet([_rsa_key()])
    for header in ("!!!", _b64url(b"[]"), _b64url(json.dumps({"alg": 1}).encode())):
        with pytest.raises(TokenSignatureError) as refused:
            validator.validate(f"{header}.e30.c2ln", key_set)
        assert str(refused.value) == _PIN_REFUSAL


def test_a_header_nested_past_the_recursion_limit_ends_in_an_sdk_error():
    """머리의 JSON 이 파서의 재귀 한도를 넘게 겹쳐 있어도(`[` 5 만 겹) HS 거부가 머리를 읽다
    날것의 `RecursionError` 를 내보내지 않는다 — 읽을 수 없는 머리이므로 판정하지 않고 지금의
    길(joserfc)에 맡겨, SDK 오류로 끝난다."""
    validator = JwtValidator(issuer=ISSUER, audience="app", allowed_algs=_RS_AND_HS)
    depth = 50_000
    header = _b64url(('{"alg":"HS256","x":' + "[" * depth + "]" * depth + "}").encode())

    with pytest.raises(TokenValidationError):
        validator.validate(f"{header}.e30.c2ln", KeySet([_rsa_key()]))


def test_an_hs_token_over_the_cap_is_refused_by_the_cap_before_the_hs_refusal():
    """길이 상한이 HS 거부보다 먼저다 — 허용된 HS256 이어도 상한을 넘은 토큰은 상한의 문구(평범한
    `TokenValidationError`)로, 키를 찾기 전에 거부된다. 머리는 읽을 수 있어 HS 거부가 상한보다
    앞이면 그 문구가 나온다. 파사드의 같은 칸은 `test_auth.py` · `aio/test_auth.py` 다."""
    validator = JwtValidator(issuer=ISSUER, audience="app", allowed_algs=_RS_AND_HS)
    key_set = _CountingKeySet([_rsa_key()])
    over = hs_token(os.urandom(64), ISSUER, "app", "k1", pad="x" * (JWT_MAX_BYTES * 3 // 4))
    assert len(over) > JWT_MAX_BYTES

    with pytest.raises(TokenValidationError) as refused:
        validator.validate(over, key_set)

    assert (type(refused.value), str(refused.value), key_set.lookups) == (
        TokenValidationError,
        f"token exceeds {JWT_MAX_BYTES} bytes",
        0,
    )
