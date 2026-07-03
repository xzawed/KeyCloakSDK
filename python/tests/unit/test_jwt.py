"""JwtValidator 보안 회귀 테스트.

joserfc로 서명·클레임을 실제로 만들어 검증기에 통과시킨다(비-공허 테스트).
Java SDK의 JwtValidator가 2회의 보안 수정 루프를 거쳐 수렴한 스위트를 그대로 이식한다:
서명/알고리즘 핀닝(none·미서명 거부), issuer 정확일치, audience 포함검사(다중값 대응),
exp/nbf(+클록 스큐), RSA-공개키를 HMAC 비밀키로 재사용하는 고전적 알고리즘 혼동 공격 방어.
"""
from __future__ import annotations

import time

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import KeySet, OctKey, RSAKey

from keycloak_sdk.exceptions import TokenValidationError
from keycloak_sdk.jwt import JwtValidator

ISSUER = "https://kc.example.com/realms/r"


def _rsa_key() -> RSAKey:
    return RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})


def _sign(key: RSAKey, claims: dict) -> str:
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


def test_valid_single_aud_token_accepted():
    key = _rsa_key()
    tok = _sign(key, {
        "iss": ISSUER,
        "aud": "app",
        "sub": "user-1",
        "iat": int(time.time()),
        "exp": int(time.time()) + 60,
    })
    validator = JwtValidator(issuer=ISSUER, audience="app")

    result = validator.validate(tok, KeySet([key]))

    assert result.issuer == ISSUER
    assert result.subject == "user-1"
    assert "app" in result.audience


def test_valid_multi_aud_containing_expected_accepted():
    """실제 Keycloak client-credentials 토큰은 aud가 다중값이다 — 포함검사여야 한다."""
    key = _rsa_key()
    tok = _sign(key, {
        "iss": ISSUER,
        "aud": ["app", "realm-management"],
        "exp": int(time.time()) + 60,
    })
    validator = JwtValidator(issuer=ISSUER, audience="app")

    result = validator.validate(tok, KeySet([key]))

    assert result.issuer == ISSUER
    assert set(result.audience) == {"app", "realm-management"}


def test_audience_not_containing_expected_rejected():
    key = _rsa_key()
    tok = _sign(key, {
        "iss": ISSUER,
        "aud": ["someone-else"],
        "exp": int(time.time()) + 60,
    })
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
    payload = base64.urlsafe_b64encode(json.dumps({
        "iss": ISSUER, "aud": "app", "exp": int(time.time()) + 60,
    }).encode()).rstrip(b"=")
    plain_jwt = header.decode() + "." + payload.decode() + "."

    validator = JwtValidator(issuer=ISSUER, audience="app")
    with pytest.raises(TokenValidationError):
        validator.validate(plain_jwt, KeySet([_rsa_key()]))


def test_expired_token_rejected():
    key = _rsa_key()
    tok = _sign(key, {
        "iss": ISSUER,
        "aud": "app",
        "exp": int(time.time()) - 1000,
    })
    validator = JwtValidator(issuer=ISSUER, audience="app", clock_skew=5.0)

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_wrong_issuer_rejected():
    key = _rsa_key()
    tok = _sign(key, {
        "iss": "https://evil.example.com/realms/r",
        "aud": "app",
        "exp": int(time.time()) + 60,
    })
    validator = JwtValidator(issuer=ISSUER, audience="app")

    with pytest.raises(TokenValidationError):
        validator.validate(tok, KeySet([key]))


def test_not_yet_valid_nbf_rejected():
    key = _rsa_key()
    tok = _sign(key, {
        "iss": ISSUER,
        "aud": "app",
        "exp": int(time.time()) + 120,
        "nbf": int(time.time()) + 60,
    })
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

    hmac_key = OctKey.import_key(public_key_bytes)
    hs256_token = jjwt.encode(
        {"alg": "HS256"},
        {"iss": ISSUER, "aud": "app", "exp": int(time.time()) + 60},
        hmac_key,
    )

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
