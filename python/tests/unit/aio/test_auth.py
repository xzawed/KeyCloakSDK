"""AsyncAuthClient 단위 테스트. python-keycloak `KeycloakOpenID`를 AsyncMock으로 주입한다.

`aio/auth.py`는 네트워크 경계라 커버리지 게이트(G3)에서 제외되지만(pyproject omit), 이
스위트는 커버리지가 아니라 매핑·PKCE·에러 변환·JWKS 배선 "행동"을 증명하기 위한 것이다.
sync `tests/unit/test_auth.py`와 동형(same coverage) — python-keycloak `a_*` 메서드만 다르다.
"""

from __future__ import annotations

import asyncio
import os
import time
from unittest.mock import AsyncMock, MagicMock
from urllib.parse import parse_qs, urlparse

import pytest
from joserfc import jwt as jjwt
from joserfc.errors import UnsupportedAlgorithmError
from joserfc.jwk import ECKey, RSAKey
from keycloak.exceptions import KeycloakAuthenticationError, KeycloakGetError

from keycloak_sdk._internal.backoff import JwksFailureBackoff
from keycloak_sdk._internal.jwt import JWT_MAX_BYTES
from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.auth import AuthorizationUrl
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import (
    KeycloakAuthError,
    KeycloakTransportError,
    TokenKeyError,
    TokenSignatureError,
    TokenValidationError,
)
from keycloak_sdk.oidc import OidcEndpoints
from keycloak_sdk.tokens import IntrospectionResult, TokenSet, ValidatedToken
from tests.unit.conftest import OCT_SHAPES, UNREADABLE_JWKS, b64u, hs_token


class _FakeClock:
    """백오프 창을 결정적으로 넘기기 위한 시계 — sleep 하지 않는다."""

    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


def _config(**overrides: object) -> KeycloakConfig:
    defaults: dict[str, object] = {
        "server_url": "https://kc.example.com",
        "realm": "r",
        "client_id": "app",
        "client_secret": "s3cret",
    }
    defaults.update(overrides)
    return KeycloakConfig(**defaults)  # type: ignore[arg-type]


def _client(openid: MagicMock, config: KeycloakConfig | None = None) -> AsyncAuthClient:
    cfg = config or _config()
    return AsyncAuthClient(cfg, OidcEndpoints.for_realm(cfg), openid=openid)


# --- client_credentials_token -----------------------------------------------------


async def test_client_credentials_maps_tokenset():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={"access_token": "a", "expires_in": 300, "token_type": "Bearer"}
    )
    ts = await _client(openid).client_credentials_token()
    assert isinstance(ts, TokenSet)
    assert ts.access_token == "a"
    openid.a_token.assert_awaited_once()


async def test_client_credentials_passes_scopes():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={"access_token": "a", "expires_in": 300, "token_type": "Bearer"}
    )
    config = _config(scopes=("openid", "profile"))
    await _client(openid, config=config).client_credentials_token()

    openid.a_token.assert_awaited_once_with(grant_type="client_credentials", scope="openid profile")


# --- _awrap exception translation --------------------------------------------------


async def test_awrap_translates_auth_error():
    openid = MagicMock()
    openid.a_token = AsyncMock(side_effect=KeycloakAuthenticationError("bad", response_code=401))
    with pytest.raises(KeycloakAuthError):
        await _client(openid).client_credentials_token()


async def test_awrap_translates_error_without_response_code_to_transport_error():
    openid = MagicMock()
    openid.a_token = AsyncMock(side_effect=KeycloakGetError(error_message="conn reset"))
    with pytest.raises(KeycloakTransportError):
        await _client(openid).client_credentials_token()


async def test_awrap_reraises_an_sdk_exception_unchanged():
    """`keycloak_sdk` 예외는 python-keycloak 실패가 아니다 — 같은 객체를 변환 없이 다시 던진다
    (sync `_wrap` 동형)."""
    client = _client(MagicMock())
    original = KeycloakTransportError("already ours")

    async def boom() -> None:
        raise original

    with pytest.raises(KeycloakTransportError) as excinfo:
        await client._awrap(boom())

    assert excinfo.value is original


async def test_awrap_reraises_a_runtime_error_from_the_awaitable_unchanged():
    """awaitable 이 던진 `RuntimeError`(우리 버그)는 `KeycloakError` 도 아니고 python-keycloak
    프레임을 지나지도 않는다 — 같은 객체 그대로 전파된다."""
    client = _client(MagicMock())
    original = RuntimeError("bug in the awaitable")

    async def boom() -> None:
        raise original

    with pytest.raises(RuntimeError) as excinfo:
        await client._awrap(boom())

    assert excinfo.value is original


async def test_refetch_done_keeps_a_newer_fetch():
    """끝난 옛 fetch 의 콜백은 그 사이 갈아 끼운 더 새로운 fetch 를 현재 조회로 남긴다."""
    client = _client(MagicMock())

    async def finish() -> None:
        await asyncio.sleep(0)

    async def wait_forever() -> None:
        await asyncio.Event().wait()

    old = asyncio.ensure_future(finish())
    await old
    newer = asyncio.ensure_future(wait_forever())
    client._jwks_fetch = newer

    client._refetch_done(old)

    assert client._jwks_fetch is newer
    newer.cancel()
    with pytest.raises(asyncio.CancelledError):
        await newer


async def test_refetch_done_clears_a_cancelled_fetch_without_raising():
    """취소된 현재 fetch 는 `.exception()` 을 부르지 않는다 — 그 호출은 `CancelledError` 다.
    슬롯만 비우고 그대로 돌아온다."""
    client = _client(MagicMock())

    async def wait_forever() -> None:
        await asyncio.Event().wait()

    fetch = asyncio.ensure_future(wait_forever())
    client._jwks_fetch = fetch
    fetch.cancel()
    with pytest.raises(asyncio.CancelledError):
        await fetch
    assert fetch.cancelled()
    assert client._jwks_fetch is fetch

    client._refetch_done(fetch)

    assert client._jwks_fetch is None


# --- authorization_url (sync — no network) -----------------------------------------


def test_authorization_url_is_sync_and_builds_directly_from_endpoints():
    openid = MagicMock()
    config = _config(scopes=("openid", "profile"))
    client = _client(openid, config=config)
    openid.reset_mock()  # 생성은 세션의 어댑터 표를 읽는다(재시도 끄기) — 재는 것은 조립이다

    result = client.authorization_url("https://app.example.com/callback")

    assert isinstance(result, AuthorizationUrl)
    assert result.code_verifier and result.state and result.nonce
    assert len(result.code_verifier) >= 43  # RFC 7636 minimum length

    parsed = urlparse(result.url)
    endpoints = OidcEndpoints.for_realm(config)
    assert result.url.startswith(endpoints.authorization)
    qs = parse_qs(parsed.query)
    assert qs["response_type"] == ["code"]
    assert qs["client_id"] == ["app"]
    assert qs["redirect_uri"] == ["https://app.example.com/callback"]
    assert qs["scope"] == ["openid profile"]
    assert qs["state"] == [result.state]
    assert qs["code_challenge_method"] == ["S256"]
    assert "code_challenge" in qs

    # authorization_url must not touch the network — openid mock untouched.
    openid.assert_not_called()
    assert not openid.mock_calls


def test_authorization_url_generates_distinct_verifiers_per_call():
    openid = MagicMock()
    client = _client(openid)

    first = client.authorization_url("https://app/cb")
    second = client.authorization_url("https://app/cb")

    assert first.code_verifier != second.code_verifier
    assert first.state != second.state
    assert first.nonce != second.nonce


# --- exchange_code / refresh / logout / introspect ---------------------------------


async def test_exchange_code_maps_response_and_delegates_pkce_args():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={
            "access_token": "acc2",
            "refresh_token": "ref2",
            "id_token": "id2",
            "token_type": "Bearer",
            "scope": "openid profile",
            "expires_in": 60,
        }
    )
    client = _client(openid)

    result = await client.exchange_code("auth-code", "https://app/cb", "verifier-xyz")

    openid.a_token.assert_awaited_once_with(
        grant_type="authorization_code",
        code="auth-code",
        redirect_uri="https://app/cb",
        code_verifier="verifier-xyz",
    )
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc2"
    assert result.id_token == "id2"


async def test_exchange_code_wraps_auth_error():
    openid = MagicMock()
    openid.a_token = AsyncMock(
        side_effect=KeycloakAuthenticationError(
            error_message='{"error": "invalid_grant"}',
            response_code=400,
            response_body=b'{"error": "invalid_grant"}',
        )
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError):
        await client.exchange_code("bad-code", "https://app/cb", "verifier")


def _exchange_openid_with_id_token(key: RSAKey, id_token: str | None, ajwks) -> MagicMock:
    openid = MagicMock()
    response: dict[str, object] = {"access_token": "acc", "token_type": "Bearer", "expires_in": 60}
    if id_token is not None:
        response["id_token"] = id_token
    openid.a_token = AsyncMock(return_value=response)
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    return openid


async def test_exchange_code_validates_id_token_and_accepts_matching_nonce(ajwks):
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce", typ="ID"
    )
    client = _client(_exchange_openid_with_id_token(key, id_token, ajwks), config=config)

    result = await client.exchange_code("code", "https://app/cb", "verifier", nonce="server-nonce")

    assert result.access_token == "acc"


async def test_exchange_code_rejects_mismatched_nonce(ajwks):
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce", typ="ID"
    )
    client = _client(_exchange_openid_with_id_token(key, id_token, ajwks), config=config)

    with pytest.raises(KeycloakAuthError, match="nonce"):
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="attacker-nonce")


async def test_exchange_code_rejects_missing_id_token_when_nonce_expected(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    client = _client(_exchange_openid_with_id_token(key, id_token=None, ajwks=ajwks))

    with pytest.raises(KeycloakAuthError, match="id_token"):
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="server-nonce")


async def test_exchange_code_rejects_a_forged_rs256_id_token_whose_nonce_matches(ajwks):
    """sync 동형 — 서명만 틀린 RS256 id_token 은 실서버로 만들 수 없어 여기서 증명한다."""
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    forger = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})  # kid 만 같다
    forged = _signed_token(
        forger, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce", typ="ID"
    )
    client = _client(_exchange_openid_with_id_token(key, forged, ajwks), config=config)

    with pytest.raises(KeycloakAuthError, match="invalid id_token") as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="server-nonce")
    assert type(refused.value.__cause__) is TokenSignatureError


# --- id_token 의 aud 는 client_id 로 잰다 — `expected_audience` 는 access 전용이다(sync 동형) ---

_API = "some-api"


def _override_setup(ajwks) -> tuple[AsyncAuthClient, MagicMock, RSAKey, OidcEndpoints]:
    """`expected_audience` 를 리소스 서버로 재정의한 클라이언트. 토큰 응답은 `_answer` 가 싣는다."""
    config = _config(expected_audience=_API)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    openid = MagicMock()
    return _client(openid, config=config), openid, key, OidcEndpoints.for_realm(config)


def _answer(openid: MagicMock, id_token: str, access: str = "acc") -> None:
    openid.a_token = AsyncMock(
        return_value={
            "access_token": access,
            "id_token": id_token,
            "token_type": "Bearer",
            "expires_in": 60,
        }
    )


@pytest.mark.parametrize("aud", ["app", ["app", _API], [_API, "app"]])
async def test_exchange_code_checks_the_id_token_aud_against_the_client_id_under_an_override(
    ajwks, aud
):
    """A1 — 재정의가 있어도 `aud` 에 client_id 가 있는 id_token 의 교환은 통과한다. azp 는
    Keycloak 의 id_token 처럼 client_id 다 — aud 가 여럿이면 OIDC Core §3.1.3.7 ④ 가 그것을
    요구한다(sync 동형)."""
    client, openid, key, endpoints = _override_setup(ajwks)
    claims = {"nonce": "n", "azp": "app", "typ": "ID"}
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience=aud, **claims))

    tokens = await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    assert tokens.id_token


@pytest.mark.parametrize("aud", [_API, [_API], [_API, "other"]])
async def test_exchange_code_refuses_an_id_token_without_the_client_id_even_if_aud_is_the_override(
    ajwks, aud
):
    """A2 — `aud` 가 재정의 값뿐인 id_token 은 거부다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience=aud, nonce="n", typ="ID"))

    with pytest.raises(KeycloakAuthError, match="invalid id_token") as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    assert type(refused.value.__cause__) is TokenValidationError
    assert str(refused.value.__cause__) == "Audience not contained"


async def test_validate_keeps_the_override_for_access_tokens_after_an_exchange(ajwks):
    """A3 — access 검증은 재정의를 계속 쓴다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    id_token = _signed_token(key, issuer=endpoints.issuer, audience="app", nonce="n", typ="ID")
    access = _signed_token(key, issuer=endpoints.issuer, audience=_API)
    _answer(openid, id_token, access)

    tokens = await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    assert _API in (await client.validate(tokens.access_token)).audience
    with pytest.raises(TokenValidationError, match="Audience not contained"):
        await client.validate(id_token)


def _id_claims(endpoints: OidcEndpoints, **changes: object) -> dict[str, object]:
    """Keycloak 의 id_token 모양(typ `ID`) — `changes` 가 덮고, 값이 None 인 클레임은 뺀다."""
    claims: dict[str, object] = {
        "iss": endpoints.issuer,
        "aud": "app",
        "sub": "user-1",
        "exp": int(time.time()) + 60,
        "nonce": "n",
        "typ": "ID",
    }
    claims.update(changes)
    return {k: v for k, v in claims.items() if v is not None}


@pytest.mark.parametrize(
    ("changes", "nonce", "cause", "reason"),
    [
        (
            {"iss": "https://evil.example.com/realms/r"},
            "n",
            TokenValidationError,
            "Issuer mismatch",
        ),
        ({"exp": None}, "n", TokenValidationError, "Missing exp claim"),
        ({"exp": -60}, "n", TokenValidationError, "Token expired"),  # 스큐(30초) 밖
        ({"nbf": 60}, "n", TokenValidationError, "Token not yet valid"),  # 스큐 밖
        ({}, "other", None, "unexpected nonce"),
    ],
)
async def test_exchange_code_keeps_iss_exp_skew_and_nonce_checks_under_an_override(
    ajwks, changes, nonce, cause, reason
):
    """A4 — 재정의 아래에서도 aud 만 바뀐다. iss·exp·스큐·nonce 대조는 그대로다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    now = int(time.time())
    timed = {k: now + v for k, v in changes.items() if k in ("exp", "nbf") and v is not None}
    claims = _id_claims(endpoints, **{**changes, **timed})
    _answer(openid, jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key))

    with pytest.raises(KeycloakAuthError) as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce=nonce)
    if cause is None:
        assert str(refused.value) == f"authorization code exchange failed: {reason}"
    else:
        assert str(refused.value) == "authorization code exchange failed: invalid id_token"
        assert type(refused.value.__cause__) is cause
        assert str(refused.value.__cause__) == reason


async def test_exchange_code_keeps_the_clock_skew_under_an_override(ajwks):
    """A4 대조군 — 스큐 안(10초 전 만료)의 id_token 은 통과한다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    claims = _id_claims(endpoints, exp=int(time.time()) - 10)
    _answer(openid, jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key))

    assert (await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")).id_token


async def test_exchange_code_keeps_the_algorithm_pin_under_an_override(ajwks):
    """A4 — 알고리즘 핀(기본 RS256)도 그대로다: ES256 id_token 은 서명 단계에서 거부된다."""
    config = _config(expected_audience=_API)
    endpoints = OidcEndpoints.for_realm(config)
    key = ECKey.generate_key("P-256", {"kid": "k1", "use": "sig"})
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    openid = MagicMock()
    _answer(openid, jjwt.encode({"alg": "ES256", "kid": key.kid}, _id_claims(endpoints), key))
    client = _client(openid, config=config)

    with pytest.raises(KeycloakAuthError, match="invalid id_token") as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    assert type(refused.value.__cause__) is TokenSignatureError


async def test_exchange_and_validate_share_one_jwks_store(ajwks):
    """A5 — 교환 뒤 access 검증은 JWKS 를 다시 가져오지 않는다.

    대조군: 두 번째 저장소는 가져온다 — 이 카운터가 두 번째 저장소를 볼 수 있다는 증거다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    access = _signed_token(key, issuer=endpoints.issuer, audience=_API)
    id_token = _signed_token(key, issuer=endpoints.issuer, audience="app", nonce="n", typ="ID")
    _answer(openid, id_token, access)

    await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    assert ajwks.call_count == 1
    assert client._jwks_keys.fresh() is not None  # 교환이 채운 것이 **이** 저장소다
    await client.validate(access)
    assert ajwks.call_count == 1

    second_store = _client(MagicMock(), config=_config(expected_audience=_API))
    await second_store.validate(access)
    assert ajwks.call_count == 2


async def test_exchange_and_validate_share_one_forced_refetch_window(ajwks):
    """A5 — 교환의 미해결 kid 가 연 30초 창을 `validate()` 가 이어받는다."""
    client, openid, _, endpoints = _override_setup(ajwks)
    stranger = RSAKey.generate_key(2048, {"kid": "x1", "use": "sig"})
    other = RSAKey.generate_key(2048, {"kid": "x2", "use": "sig"})
    claims = {"nonce": "n", "typ": "ID"}
    _answer(openid, _signed_token(stranger, issuer=endpoints.issuer, audience="app", **claims))

    with pytest.raises(KeycloakAuthError, match="invalid id_token"):
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    assert ajwks.call_count == 2  # 최초 로드 + 강제 재조회 1

    with pytest.raises(TokenKeyError):
        await client.validate(_signed_token(other, issuer=endpoints.issuer, audience=_API))
    assert ajwks.call_count == 2


async def test_exchange_and_validate_share_one_cold_cache_backoff(ajwks):
    """A5 — 콜드 캐시 + IdP 장애의 백오프도 하나다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    client._jwks_backoff = JwksFailureBackoff(clock=_FakeClock(), jitter=lambda: 1.0)
    ajwks.side_effect = KeycloakTransportError("idp down")
    id_token = _signed_token(key, issuer=endpoints.issuer, audience="app", nonce="n", typ="ID")
    _answer(openid, id_token)

    with pytest.raises(KeycloakTransportError, match="idp down"):
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    with pytest.raises(KeycloakTransportError, match="backing off"):
        await client.validate(_signed_token(key, issuer=endpoints.issuer, audience=_API))
    assert ajwks.call_count == 1


# --- typ · azp — 두 경로가 갈리는 두 검사(파사드 배선, sync 동형) ------------------------
# (A) `validate()` 는 Keycloak 의 access 아닌 토큰(typ ID · Refresh · Offline · Logout ·
# Serialized-ID)을 거부한다. (B) nonce 교환의 id_token 은 OIDC Core §3.1.3.7 ④⑤ 를
# 지킨다. 어느 검사도 다른 경로에 걸리지 않는다. 검증기 칸은 `tests/unit/test_jwt.py` 다.

_NO_AZP = object()  # azp 클레임 자체가 없다
#: typ 클레임 자체가 없다 — `_signed_token` 이 그 클레임을 뺀다(None 은 JSON null 로 남는다).
_NO_TYP = object()
_AZP_MISMATCH = "Authorized party (azp) mismatch"
_AZP_MISSING = "Missing azp claim for multiple audiences"


def _exchange_setup(ajwks) -> tuple[AsyncAuthClient, MagicMock, RSAKey, OidcEndpoints]:
    """재정의 없는 교환 클라이언트(client_id `app`). 토큰 응답은 `_answer` 가 싣는다."""
    config = _config()
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    openid = MagicMock()
    return _client(openid, config=config), openid, key, OidcEndpoints.for_realm(config)


def _azp(azp: object) -> dict[str, object]:
    return {} if azp is _NO_AZP else {"azp": azp}


@pytest.mark.parametrize("typ", ["ID", "Logout", "Refresh"])
async def test_validate_refuses_a_keycloak_token_that_is_not_an_access_token(ajwks, typ):
    """(A) — id_token · 백채널 로그아웃 토큰 · refresh 토큰이 `validate()` 를 통과하지
    못한다. 클레임 실패라 JWKS 를 다시 가져오지 않는다."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(key, issuer=endpoints.issuer, audience="app", typ=typ)

    with pytest.raises(TokenValidationError) as refused:
        await client.validate(token)

    assert type(refused.value) is TokenValidationError
    assert str(refused.value) == f"Token is not an access token (typ {typ})"
    assert ajwks.call_count == 1


@pytest.mark.parametrize("typ", ["Bearer", "bearer", "DPoP", "dpop"])
async def test_validate_accepts_an_access_token_typ(ajwks, typ):
    """(A) 허용 목록 — typ 가 ASCII 대소문자를 무시하고 `Bearer` · `DPoP` 면 통과한다(sync 동형)."""
    client, key, endpoints = _validate_client(_config(), ajwks)

    result = await client.validate(
        _signed_token(key, issuer=endpoints.issuer, audience="app", typ=typ)
    )

    assert (result.subject, result.claims["typ"]) == ("user-1", typ)


_NOT_ACCESS = "Token is not an access token (typ is not Bearer or DPoP)"


@pytest.mark.parametrize(
    "typ",
    [
        pytest.param(_NO_TYP, id="absent"),
        pytest.param("at+jwt", id="at+jwt"),
        pytest.param("CANARY-TYP-7c2e", id="token-chosen string"),
        pytest.param(1, id="number"),
        pytest.param(None, id="null"),
        pytest.param(["Bearer"], id="array"),
    ],
)
async def test_validate_refuses_a_token_not_typed_bearer_or_dpop(ajwks, typ):
    """(A) — 허용 목록 밖은 상수 문구로 거부한다(sync 동형)."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(key, issuer=endpoints.issuer, audience="app", typ=typ)

    with pytest.raises(TokenValidationError) as refused:
        await client.validate(token)

    assert type(refused.value) is TokenValidationError
    assert str(refused.value) == _NOT_ACCESS
    assert ajwks.call_count == 1


async def test_validate_refuses_a_jarm_authorization_response(ajwks):
    """JARM 인가 응답 모양(typ 없음 · aud = client_id · code · state) — sync 동형."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    claims = {"iss": endpoints.issuer, "aud": "app", "exp": int(time.time()) + 60, "code": "c0de"}
    jarm = jjwt.encode({"alg": "RS256", "kid": key.kid}, {**claims, "state": "s1"}, key)

    with pytest.raises(TokenValidationError) as refused:
        await client.validate(jarm)

    assert str(refused.value) == _NOT_ACCESS


async def test_validate_does_not_judge_azp(ajwks):
    """(B) 는 access 경로에 걸리지 않는다 — aud 가 여럿이고 azp 가 없거나 남인 access
    토큰도 통과한다."""
    client, key, endpoints = _validate_client(_config(), ajwks)

    for azp in (_NO_AZP, "frontend"):
        token = _signed_token(key, issuer=endpoints.issuer, audience=["app", "x"], **_azp(azp))
        assert (await client.validate(token)).subject == "user-1"


async def test_exchange_code_accepts_an_id_token_whose_typ_is_id(ajwks):
    """(A) 는 교환의 id_token 경로에 걸리지 않는다 — Keycloak 의 id_token 은 typ 가 `ID` 다."""
    client, openid, key, endpoints = _exchange_setup(ajwks)
    claims = {"nonce": "n", "typ": "ID", "azp": "app"}
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience="app", **claims))

    tokens = await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    assert tokens.id_token


@pytest.mark.parametrize(
    ("aud", "azp"),
    [
        pytest.param("app", _NO_AZP, id="single aud, no azp"),
        pytest.param(["app", "other"], "app", id="several auds, azp is the client"),
    ],
)
async def test_exchange_code_accepts_an_id_token_whose_azp_names_the_client(ajwks, aud, azp):
    """(B) 통과 칸 — aud 가 하나면 azp 는 없어도 되고, aud 가 여럿이면 azp 가 client_id 다."""
    client, openid, key, endpoints = _exchange_setup(ajwks)
    claims = {"nonce": "n", "typ": "ID", **_azp(azp)}
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience=aud, **claims))

    tokens = await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    assert tokens.id_token


@pytest.mark.parametrize(
    ("aud", "azp", "reason"),
    [
        pytest.param("app", "evil", _AZP_MISMATCH, id="single aud, foreign azp"),
        pytest.param(["app", "evil"], _NO_AZP, _AZP_MISSING, id="several auds, no azp"),
        pytest.param(["app", "evil"], "evil", _AZP_MISMATCH, id="several auds, foreign azp"),
    ],
)
async def test_exchange_code_refuses_an_id_token_whose_azp_breaks_oidc_core(
    ajwks, aud, azp, reason
):
    """(B) — 실패는 다른 id_token 실패와 같은 모양이다(`invalid id_token`, 원인이 이유를 말한다)."""
    client, openid, key, endpoints = _exchange_setup(ajwks)
    claims = {"nonce": "n", "typ": "ID", **_azp(azp)}
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience=aud, **claims))

    with pytest.raises(KeycloakAuthError) as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    assert str(refused.value) == "authorization code exchange failed: invalid id_token"
    assert type(refused.value.__cause__) is TokenValidationError
    assert str(refused.value.__cause__) == reason


async def test_exchange_code_checks_azp_against_the_client_id_under_an_override(ajwks):
    """(B) 의 기준은 `expected_audience` 가 아니라 client_id 다 — 재정의 값을 azp 로 단
    id_token 은 거부다."""
    client, openid, key, endpoints = _override_setup(ajwks)
    aud = ["app", _API]
    for_client = {"nonce": "n", "typ": "ID", "azp": "app"}
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience=aud, **for_client))
    assert (await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")).id_token

    for_api = {**for_client, "azp": _API}
    _answer(openid, _signed_token(key, issuer=endpoints.issuer, audience=aud, **for_api))
    with pytest.raises(KeycloakAuthError, match="invalid id_token") as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    assert str(refused.value.__cause__) == _AZP_MISMATCH


# --- validate_id_token — 공개 id_token 검증(sync 동형) ------------------------------------------
# 교환이 nonce 를 대조하기 전에 돌리는 그 검사다(같은 내부 함수). 실패는 `validate()` 와 같은
# `TokenValidationError` 다. 칸의 근거는 sync `tests/unit/test_auth.py` 의 같은 이름 시험이다.

_NOT_ID_TOKEN = 'Token is not an id_token (typ is not "ID")'


async def test_validate_id_token_accepts_a_keycloak_id_token_and_returns_its_claims(ajwks):
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(
        key, issuer=endpoints.issuer, audience="app", azp="app", typ="ID", nonce="n"
    )

    result = await client.validate_id_token(token)

    assert result.subject == "user-1"
    assert result.issuer == endpoints.issuer
    assert result.audience == ("app",)
    assert {k: result.claims[k] for k in ("typ", "azp", "nonce")} == {
        "typ": "ID",
        "azp": "app",
        "nonce": "n",
    }


async def test_validate_id_token_refuses_an_access_token_issued_to_the_client(ajwks):
    """이 규칙이 닫는 틈 — aud ∋ client_id · azp = client_id 인 액세스 토큰(typ `Bearer`)."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(
        key, issuer=endpoints.issuer, audience=["app", "account"], azp="app", typ="Bearer"
    )
    assert (await client.validate(token)).audience == ("app", "account")

    with pytest.raises(TokenValidationError) as refused:
        await client.validate_id_token(token)

    assert type(refused.value) is TokenValidationError
    assert str(refused.value) == _NOT_ID_TOKEN


@pytest.mark.parametrize(
    "extra",
    [
        pytest.param({"typ": _NO_TYP}, id="absent"),
        pytest.param({"typ": "bearer"}, id="lowercase bearer"),
        pytest.param({"typ": 1}, id="number"),
        pytest.param({"typ": None}, id="null"),
        pytest.param({"typ": ["ID"]}, id="array"),
        pytest.param({"typ": "CANARY-TYP-0f3a"}, id="token-chosen string"),
    ],
)
async def test_validate_id_token_refuses_any_typ_but_id(ajwks, extra):
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(key, issuer=endpoints.issuer, audience="app", azp="app", **extra)

    with pytest.raises(TokenValidationError) as refused:
        await client.validate_id_token(token)

    assert type(refused.value) is TokenValidationError
    assert str(refused.value) == _NOT_ID_TOKEN
    assert ajwks.call_count == 1


async def test_validate_id_token_refuses_a_back_channel_logout_token(ajwks):
    client, key, endpoints = _validate_client(_config(), ajwks)
    events = {"http://schemas.openid.net/event/backchannel-logout": {}}
    token = _signed_token(
        key, issuer=endpoints.issuer, audience="app", typ="Logout", sid="s-1", events=events
    )

    with pytest.raises(TokenValidationError) as refused:
        await client.validate_id_token(token)

    assert str(refused.value) == _NOT_ID_TOKEN


async def test_validate_id_token_holds_aud_to_the_client_id_under_an_override(ajwks):
    client, key, endpoints = _validate_client(_config(expected_audience=_API), ajwks)

    with pytest.raises(TokenValidationError) as refused:
        await client.validate_id_token(
            _signed_token(key, issuer=endpoints.issuer, audience=_API, typ="ID")
        )
    assert str(refused.value) == "Audience not contained"

    accepted = await client.validate_id_token(
        _signed_token(key, issuer=endpoints.issuer, audience="app", typ="ID")
    )
    assert accepted.audience == ("app",)


async def test_validate_id_token_shares_one_jwks_store_with_validate_and_the_exchange(ajwks):
    client, openid, key, endpoints = _exchange_setup(ajwks)
    id_token = _signed_token(key, issuer=endpoints.issuer, audience="app", nonce="n", typ="ID")

    await client.validate_id_token(id_token)
    assert ajwks.call_count == 1
    await client.validate(_signed_token(key, issuer=endpoints.issuer, audience="app"))
    _answer(openid, id_token)
    await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")
    await client.validate_id_token(id_token)
    assert ajwks.call_count == 1

    second_store = _client(MagicMock(), config=_config())
    await second_store.validate_id_token(id_token)
    assert ajwks.call_count == 2


@pytest.mark.parametrize(
    "extra",
    [
        pytest.param({"typ": _NO_TYP}, id="absent"),
        pytest.param({"typ": "Bearer"}, id="Bearer"),
        pytest.param({"typ": "Logout"}, id="Logout"),
    ],
)
async def test_exchange_code_refuses_an_id_token_that_is_not_typed_id(ajwks, extra):
    client, openid, key, endpoints = _exchange_setup(ajwks)
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience="app", nonce="n", azp="app", **extra
    )
    _answer(openid, id_token)

    with pytest.raises(KeycloakAuthError) as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    assert str(refused.value) == "authorization code exchange failed: invalid id_token"
    assert type(refused.value.__cause__) is TokenValidationError
    assert str(refused.value.__cause__) == _NOT_ID_TOKEN
    with pytest.raises(TokenValidationError, match="not an id_token"):
        await client.validate_id_token(id_token)


async def test_refresh_maps_response_and_delegates():
    openid = MagicMock()
    openid.a_refresh_token = AsyncMock(
        return_value={
            "access_token": "acc3",
            "refresh_token": "ref3",
            "token_type": "Bearer",
            "scope": "openid",
            "expires_in": 120,
        }
    )
    client = _client(openid)

    result = await client.refresh("old-refresh")

    openid.a_refresh_token.assert_awaited_once_with("old-refresh")
    assert isinstance(result, TokenSet)
    assert result.access_token == "acc3"


async def test_refresh_wraps_transport_error():
    openid = MagicMock()
    openid.a_refresh_token = AsyncMock(side_effect=KeycloakGetError(error_message="conn reset"))
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        await client.refresh("old-refresh")


async def test_logout_delegates_and_returns_none():
    openid = MagicMock()
    openid.a_logout = AsyncMock(return_value={})
    client = _client(openid)

    result = await client.logout("some-refresh")

    openid.a_logout.assert_awaited_once_with("some-refresh")
    assert result is None


async def test_logout_wraps_auth_error():
    openid = MagicMock()
    openid.a_logout = AsyncMock(
        side_effect=KeycloakAuthenticationError(
            error_message="already invalidated", response_code=400
        )
    )
    client = _client(openid)

    with pytest.raises(KeycloakAuthError):
        await client.logout("some-refresh")


async def test_introspect_maps_active_token():
    openid = MagicMock()
    openid.a_introspect = AsyncMock(
        return_value={"active": True, "username": "alice", "client_id": "app"}
    )
    client = _client(openid)

    result = await client.introspect("some-token")

    openid.a_introspect.assert_awaited_once_with("some-token")
    assert result == IntrospectionResult(active=True, username="alice", client_id="app")


async def test_introspect_maps_inactive_token_with_missing_fields():
    openid = MagicMock()
    openid.a_introspect = AsyncMock(return_value={"active": False})
    client = _client(openid)

    result = await client.introspect("expired-token")

    assert result == IntrospectionResult(active=False, username=None, client_id=None)


#: python-keycloak 이 성공으로 받은 응답(2xx)이 OAuth `error` 를 실었다 — sync 동형(등록부
#: auth-2xx-error-code-divergent). B2 는 쓸 수 있어 보이는 토큰 · `active: true` 까지 싣는다.
_SUCCESS_STATUS_OAUTH_ERROR: dict[str, tuple[dict[str, object], dict[str, object]]] = {
    "B1": ({"error": "invalid_grant", "error_description": "d"}, {"error": "invalid_token"}),
    "B2": (
        {
            "error": "invalid_grant",
            "access_token": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl",
            "token_type": "Bearer",
            "expires_in": 300,
        },
        {"error": "invalid_token", "active": True},
    ),
}
_LANE_CALLS = {
    "client_credentials_token": lambda c: c.client_credentials_token(),
    "refresh": lambda c: c.refresh("old-refresh"),
    "exchange_code": lambda c: c.exchange_code("auth-code", "https://app/cb", "verifier-xyz"),
    "introspect": lambda c: c.introspect("some-token"),
}


@pytest.mark.parametrize("body", list(_SUCCESS_STATUS_OAUTH_ERROR))
@pytest.mark.parametrize("lane", list(_LANE_CALLS))
async def test_success_status_oauth_error_fails_like_an_error_status(lane, body):
    """sync 동형 — 4xx 가 그 `error` 를 실었을 때와 같은 오류 · 같은 코드, 본문의 나머지는 쓰지
    않는다. 목은 HTTP 상태를 남기지 않는다 — 메시지는 상태 없이 코드만 싣는다."""
    token, introspection = _SUCCESS_STATUS_OAUTH_ERROR[body]
    openid = MagicMock()
    openid.a_token = AsyncMock(return_value=token)
    openid.a_refresh_token = AsyncMock(return_value=token)
    openid.a_introspect = AsyncMock(return_value=introspection)
    client = _client(openid)

    with pytest.raises(KeycloakAuthError) as excinfo:
        await _LANE_CALLS[lane](client)

    code = "invalid_token" if lane == "introspect" else "invalid_grant"
    assert excinfo.value.error == code
    assert str(excinfo.value) == f"Keycloak request failed ({code})"


# --- validate() — JWKS fetch 로드 후 JwtValidator(sync)에 위임 -------------------------


def _signed_token(
    key: RSAKey, issuer: str, audience: str | list[str], **extra_claims: object
) -> str:
    """realm 키로 서명한다. typ 를 주지 않으면 Keycloak 의 액세스 토큰처럼 `Bearer` 다(sync 동형) —
    id_token 은 `typ="ID"` 를 준다. `typ=_NO_TYP` 은 그 클레임을 뺀다."""
    claims: dict[str, object] = {
        "iss": issuer,
        "aud": audience,
        "sub": "user-1",
        "exp": int(time.time()) + 60,
        "typ": "Bearer",
    }
    claims.update(extra_claims)
    if claims.get("typ") is _NO_TYP:
        del claims["typ"]
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


async def test_validate_loads_jwks_and_delegates_to_jwt_validator(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    result = await client.validate(token)

    ajwks.assert_awaited_once()
    assert isinstance(result, ValidatedToken)
    assert result.issuer == endpoints.issuer
    assert result.subject == "user-1"
    assert config.client_id in result.audience


async def test_validate_caches_jwks_across_calls(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    await client.validate(token)
    await client.validate(token)

    assert ajwks.call_count == 1


async def test_validate_concurrent_cold_cache_single_flights_a_certs(ajwks):
    """동시성 하드닝: 콜드 캐시에서 두 `validate()`가 동시에 실행돼도 JWKS fetch는
    한 번만 호출돼야 한다(`asyncio.Lock` 단일화). JWKS fetch side_effect에 진짜
    `await asyncio.sleep(0)` 지점을 둬 실제 컨텍스트 스위치를 강제한다 — 그렇지 않으면
    목이 동기적으로 완료돼 두 번째 호출이 이미 채워진 캐시를 보게 되어(잠금 유무와
    무관하게) 테스트가 아무것도 증명하지 못한다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()

    async def _certs_with_yield(*_args: object, **_kwargs: object) -> dict[str, object]:
        await asyncio.sleep(0)
        return {"keys": [key.as_dict(private=False)]}

    ajwks.side_effect = _certs_with_yield
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    results = await asyncio.gather(client.validate(token), client.validate(token))

    assert ajwks.call_count == 1
    for result in results:
        assert isinstance(result, ValidatedToken)
        assert result.subject == "user-1"


async def test_validate_rejects_token_with_wrong_audience(ajwks):
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        await client.validate(token)


def _validate_client(
    config: KeycloakConfig, ajwks
) -> tuple[AsyncAuthClient, RSAKey, OidcEndpoints]:
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    return _client(openid, config=config), key, OidcEndpoints.for_realm(config)


async def test_validate_defaults_expected_audience_to_client_id(ajwks):
    """`expected_audience` 미지정 시 기대 audience는 client_id다(sync 동형·기존 동작 유지)."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    client_id_token = _signed_token(key, issuer=endpoints.issuer, audience="app")
    api_token = _signed_token(key, issuer=endpoints.issuer, audience="some-api")

    result = await client.validate(client_id_token)

    assert "app" in result.audience
    with pytest.raises(TokenValidationError):
        await client.validate(api_token)


async def test_validate_uses_configured_expected_audience(ajwks):
    """`expected_audience`를 설정하면 client_id 대신 그 값을 `aud`에서 찾는다(sync 동형)."""
    client, key, endpoints = _validate_client(_config(expected_audience="some-api"), ajwks)
    api_token = _signed_token(key, issuer=endpoints.issuer, audience="some-api")
    client_id_token = _signed_token(key, issuer=endpoints.issuer, audience="app")

    result = await client.validate(api_token)

    assert "some-api" in result.audience
    with pytest.raises(TokenValidationError):
        await client.validate(client_id_token)


async def test_validate_refetches_jwks_and_retries_once_on_signature_failure(ajwks):
    """키 회전 시나리오: sync와 동형 — 서명 실패(TokenSignatureError) 시 JWKS fetch를
    한 번 재조회한 뒤 재시도해 성공해야 한다."""
    old_key = RSAKey.generate_key(2048, {"kid": "old-kid", "use": "sig"})
    new_key = RSAKey.generate_key(2048, {"kid": "new-kid", "use": "sig"})
    openid = MagicMock()
    ajwks.side_effect = [
        {"keys": [old_key.as_dict(private=False)]},
        {"keys": [old_key.as_dict(private=False), new_key.as_dict(private=False)]},
    ]
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(new_key, issuer=endpoints.issuer, audience=config.client_id)

    result = await client.validate(token)

    assert isinstance(result, ValidatedToken)
    assert result.subject == "user-1"
    assert ajwks.call_count == 2


async def test_validate_wraps_certs_transport_error(ajwks):
    openid = MagicMock()
    ajwks.side_effect = KeycloakTransportError("conn reset")
    client = _client(openid)

    with pytest.raises(KeycloakTransportError):
        await client.validate("irrelevant-token")


# --- 받는 토큰의 길이 상한 — 콜드 캐시에서도 JWKS 를 가져오기 전에 거부한다(sync 동형) ---------


async def test_validate_rejects_a_token_over_the_cap_without_a_jwks_request(ajwks):
    """T1 — 콜드 캐시의 파사드. 상한 밖 쓰레기 하나가 JWKS 요청을 내지 않는다."""
    client = _client(MagicMock())

    with pytest.raises(TokenValidationError, match="exceeds 256000 bytes"):
        await client.validate("a" * (JWT_MAX_BYTES - 1) + "..")

    ajwks.assert_not_called()
    assert client._jwks_keys.fresh() is None


async def test_validate_lets_a_token_at_the_cap_through_to_the_jwks_load_and_decoder(ajwks):
    """T2 — 상한 길이의 쓰레기는 파사드 문을 지나 JWKS 적재와 디코더에 닿는다(`>=` 가 아니다)."""
    client = _client(MagicMock())

    with pytest.raises(TokenValidationError) as refused:
        await client.validate("a" * (JWT_MAX_BYTES - 2) + "..")

    assert "exceeds" not in str(refused.value)
    assert ajwks.call_count == 1


async def test_exchange_code_rejects_an_id_token_over_the_cap_without_a_jwks_request(ajwks):
    """T1 — 코드 교환의 id_token 경로도 같은 문을 지난다(원인이 상한이고 JWKS 요청 0)."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    over = "a" * (JWT_MAX_BYTES - 1) + ".."
    client = _client(_exchange_openid_with_id_token(key, over, ajwks))

    with pytest.raises(KeycloakAuthError, match="invalid id_token") as refused:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="server-nonce")

    assert type(refused.value.__cause__) is TokenValidationError
    assert str(refused.value.__cause__) == "token exceeds 256000 bytes"
    ajwks.assert_not_called()


# --- 보안: JWKS 강제 재조회 DoS 증폭 방지 + 자원 정리 (감사 후속) -------------------


async def test_signature_forgery_does_not_refetch_jwks(ajwks):
    """서명 위조(kid는 캐시에 있으나 서명 불일치)는 JWKS fetch 재조회를 유발하지 않는다 —
    sync와 동형의 미인증 DoS 증폭 방어."""
    cached_key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    forger_key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    openid = MagicMock()
    ajwks.return_value = {"keys": [cached_key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(openid, config=config)
    token = _signed_token(forger_key, issuer=endpoints.issuer, audience=config.client_id)

    with pytest.raises(TokenValidationError):
        await client.validate(token)

    assert ajwks.call_count == 1


async def test_aclose_closes_underlying_connection():
    """aclose()는 ConnectionManager.aclose()를 호출해 httpx AsyncClient를 닫는다 —
    미해제 시 async 소켓/FD 누수(EMFILE)."""
    openid = MagicMock()
    openid.connection.aclose = AsyncMock()
    client = _client(openid)

    await client.aclose()

    openid.connection.aclose.assert_awaited_once_with()


async def test_malformed_jwks_yields_sdk_error_not_a_raw_library_exception(ajwks):
    """sync 미러와 동일한 계약 — 기형 JWKS는 SDK 오류로 나와야 한다(동형 최소집합 5번).

    두 미러가 갈라지지 않도록 async에도 같은 프로브를 둔다. 고치기 전에는 joserfc가 joserfc
    타입도 아닌 stdlib `binascii.Error`를 던져 `keycloak_sdk.exceptions`를 잡는 소비자가
    아무것도 잡지 못했다(§4 위반).
    """
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)

    openid = MagicMock()
    ajwks.return_value = {
        "keys": [
            {
                "kty": "RSA",
                "kid": "k1",
                "use": "sig",
                "alg": "RS256",
                "n": "!!!not-base64!!!",
                "e": "AQAB",
            }
        ]
    }
    client = _client(openid, config=config)

    with pytest.raises(TokenValidationError):
        await client.validate(token)


async def test_jwks_key_it_cannot_read_is_skipped_not_the_whole_set(ajwks, unreadable_jwk):
    """sync 미러와 같은 계약 — 못 읽는 키 하나가 키셋 전체를 버리면 안 된다(RFC 7517 §5 · 등록부
    jwks-unsupported-key-rejects-set). 못 읽는 키를 **앞**에 둔다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    token = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)
    ajwks.return_value = {"keys": [unreadable_jwk, key.as_dict(private=False)]}
    client = _client(MagicMock(), config=config)

    assert (await client.validate(token)).subject


async def test_jwks_with_only_keys_it_cannot_read_is_refused_and_keeps_the_cached_set(ajwks):
    """sync 미러와 같은 대조 — 쓸 수 있는 키가 없는 키셋은 `TokenValidationError` 이고
    캐시를 덮지 않는다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    good = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)
    unknown = _signed_token(
        RSAKey.generate_key(2048, {"kid": "kZ", "use": "sig"}),
        issuer=endpoints.issuer,
        audience=config.client_id,
    )
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    client = _client(MagicMock(), config=config)
    await client.validate(good)

    ajwks.return_value = {"keys": list(UNREADABLE_JWKS.values())}
    with pytest.raises(TokenValidationError, match="no usable keys"):
        await client.validate(unknown)
    assert ajwks.await_count == 2  # 강제 재조회가 정말 일어났다

    assert (await client.validate(good)).subject  # 신뢰 키 캐시가 그대로다


async def test_empty_jwks_is_refused_and_keeps_the_cached_set(ajwks):
    """sync 미러와 같은 대조 — 200 + `{"keys": []}` 는 `TokenValidationError` 이고
    캐시를 덮지 않는다."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    good = _signed_token(key, issuer=endpoints.issuer, audience=config.client_id)
    unknown = _signed_token(
        RSAKey.generate_key(2048, {"kid": "kZ", "use": "sig"}),
        issuer=endpoints.issuer,
        audience=config.client_id,
    )
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    client = _client(MagicMock(), config=config)
    await client.validate(good)

    ajwks.return_value = {"keys": []}
    with pytest.raises(TokenValidationError, match="no keys"):
        await client.validate(unknown)
    assert ajwks.await_count == 2  # 강제 재조회가 정말 일어났다

    assert (await client.validate(good)).subject  # 신뢰 키 캐시가 그대로다


@pytest.mark.parametrize(("member", "kid"), OCT_SHAPES)
async def test_jwks_oct_key_is_never_a_verification_key(ajwks, member, kid):
    """sync 미러와 같은 계약 — JWKS 의 대칭(`oct`) 키는 검증 키가 아니다(등록부
    jwks-oct-key-usable-with-hs). 같은 키셋의 RSA 토큰은 그대로 통과한다(대조)."""
    secret = os.urandom(32)
    rsa = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config(signature_algorithms=("RS256", "HS256"))
    endpoints = OidcEndpoints.for_realm(config)
    ajwks.return_value = {
        "keys": [{"kty": "oct", "k": b64u(secret), **member}, rsa.as_dict(private=False)]
    }
    client = _client(MagicMock(), config=config)

    with pytest.raises(TokenValidationError):
        await client.validate(hs_token(secret, endpoints.issuer, config.client_id, kid))
    assert (
        await client.validate(
            _signed_token(rsa, issuer=endpoints.issuer, audience=config.client_id)
        )
    ).subject


async def test_jwks_with_only_an_oct_key_has_no_usable_keys(ajwks):
    """sync 미러와 같은 대조 — oct 만 있는 키셋은 쓸 수 있는 키가 없는 키셋이다."""
    rsa = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config(signature_algorithms=("RS256", "HS256"))
    endpoints = OidcEndpoints.for_realm(config)
    ajwks.return_value = {"keys": [{"kty": "oct", "kid": "k1", "k": b64u(os.urandom(32))}]}
    client = _client(MagicMock(), config=config)

    with pytest.raises(TokenValidationError, match="no usable keys"):
        await client.validate(
            _signed_token(rsa, issuer=endpoints.issuer, audience=config.client_id)
        )


@pytest.mark.parametrize("alg", ["HS256", "HS384", "HS512"])
async def test_hs_is_refused_before_the_jwks_is_fetched_even_when_allowed(ajwks, alg):
    """sync 미러와 같은 계약 — HS(대칭) 서명은 설정이 허용해도 JWKS 를 부르기 전에
    거부한다(등록부 hs-refusal-rests-on-libraries). `validate` 와 코드 교환의 id_token 둘 다.
    kid 는 JWKS 의 RSA 키다."""
    rsa = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config(signature_algorithms=("RS256", "HS256", "HS384", "HS512"))
    endpoints = OidcEndpoints.for_realm(config)
    forged = hs_token(os.urandom(64), endpoints.issuer, config.client_id, "k1", alg=alg)
    client = _client(_exchange_openid_with_id_token(rsa, forged, ajwks), config=config)

    with pytest.raises(TokenSignatureError) as refused:
        await client.validate(forged)
    with pytest.raises(KeycloakAuthError) as exchanged:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    want = f"algorithm not allowed: {alg} (a JWKS holds public keys only)"
    cause = exchanged.value.__cause__
    assert (str(refused.value), refused.value.__cause__, ajwks.await_count) == (want, None, 0)
    assert str(exchanged.value) == "authorization code exchange failed: invalid id_token"
    assert (type(cause), str(cause)) == (TokenSignatureError, want)
    # 대조 — 같은 클라이언트가 그 RSA 키로 서명한 RS256 토큰은 통과시키고, 그때 JWKS 를 부른다.
    good = _signed_token(rsa, issuer=endpoints.issuer, audience=config.client_id)
    assert (await client.validate(good)).subject == "user-1"
    assert ajwks.await_count == 1


async def test_an_hs_token_over_the_cap_is_refused_by_the_cap_before_the_hs_refusal(ajwks):
    """sync 미러와 같은 계약 — 길이 상한이 HS 거부보다 먼저다. 상한을 넘은 HS256 토큰은 HS 의
    문구가 아니라 상한의 문구로, JWKS 를 부르기 전에 거부된다. `validate` 와 코드 교환의 id_token
    둘 다."""
    rsa = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config(signature_algorithms=("RS256", "HS256"))
    endpoints = OidcEndpoints.for_realm(config)
    pad = "x" * (JWT_MAX_BYTES * 3 // 4)
    over = hs_token(os.urandom(64), endpoints.issuer, config.client_id, "k1", pad=pad)
    assert len(over) > JWT_MAX_BYTES
    client = _client(_exchange_openid_with_id_token(rsa, over, ajwks), config=config)

    with pytest.raises(TokenValidationError) as refused:
        await client.validate(over)
    with pytest.raises(KeycloakAuthError) as exchanged:
        await client.exchange_code("code", "https://app/cb", "verifier", nonce="n")

    want = f"token exceeds {JWT_MAX_BYTES} bytes"
    cause = exchanged.value.__cause__
    assert (type(refused.value), str(refused.value), ajwks.await_count) == (
        TokenValidationError,
        want,
        0,
    )
    assert (type(cause), str(cause)) == (TokenValidationError, want)


async def test_a_lowercase_hs_alg_the_pin_names_is_left_to_joserfc(ajwks):
    """sync 미러와 같은 계약 — 설정 핀 ("RS256", "hs256") 에서 머리 alg `hs256` 은 「HS」 접두가
    아니므로 지금의 길이다: JWKS 를 적재하고, joserfc 가 그 이름을 모른다고 거부한다."""
    rsa = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    config = _config(signature_algorithms=("RS256", "hs256"))
    endpoints = OidcEndpoints.for_realm(config)
    ajwks.return_value = {"keys": [rsa.as_dict(private=False)]}
    forged = hs_token(os.urandom(64), endpoints.issuer, config.client_id, "k1", alg="hs256")
    client = _client(MagicMock(), config=config)

    with pytest.raises(TokenSignatureError) as refused:
        await client.validate(forged)

    assert (str(refused.value), type(refused.value.__cause__), ajwks.await_count) == (
        "JWT signature/algorithm validation failed",
        UnsupportedAlgorithmError,
        1,
    )


# ⚠️ 콜드 캐시 + IdP 장애 축 — sync 미러와 **대칭으로** 둔다. 이 저장소는 「sync 에만 있는
# 보안 테스트」를 이미 결함 부류로 추적한다(`python-aio-security-test-asymmetry`).
# 상태 기계는 `tests/unit/test_backoff.py` 가 재고, 여기서는 배선만 증명한다.
async def test_cold_cache_failing_idp_collapses_to_one_certs_call(ajwks):
    openid = MagicMock()
    ajwks.side_effect = KeycloakTransportError("idp down")
    client = _client(openid)
    # ⚠️ 멈춘 시계다 — sync 판과 같은 까닭(wall-clock-ordering-in-tests).
    # jitter 는 기본값 그대로다.
    client._jwks_backoff = JwksFailureBackoff(clock=_FakeClock())

    for _ in range(20):
        with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
            await client._load_jwks()

    assert ajwks.call_count == 1, (
        "cold cache + failing IdP: 20 loads must collapse to one outbound request"
    )


# ⚠️ **이 테스트를 지우지 말 것 — 위 단언은 「한 번 실패하면 영원히 차단」으로도 통과한다.**
async def test_backoff_window_expires_and_the_next_load_reaches_the_idp(ajwks):
    openid = MagicMock()
    ajwks.side_effect = KeycloakTransportError("idp down")
    client = _client(openid)
    clock = _FakeClock()
    client._jwks_backoff = JwksFailureBackoff(clock=clock, jitter=lambda: 1.0)

    with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
        await client._load_jwks()
    assert ajwks.call_count == 1

    with pytest.raises(KeycloakTransportError, match="backing off"):
        await client._load_jwks()
    assert ajwks.call_count == 1

    clock.advance(10.0)
    with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
        await client._load_jwks()
    assert ajwks.call_count == 2


# --- 보안 단언 미러 — sync 에만 있던 여덟 -------------------------------------
#
# ⚠️ **두 미러가 갈리면 한쪽만 고쳐지고 나머지는 조용히 남는다.** 아래 여덟은 sync 에만
# 있던 **보안** 단언이다(2026-09-12 대칭 diff). 프로덕션 aio 코드는 이미 이 성질들을
# 갖고 있으므로 이 테스트들은 **행동을 바꾸지 않고 고정**한다 — 그러나 고정되지 않은
# 성질은 다음 리팩터에서 조용히 사라진다. alg 핀닝은 CLAUDE.md 가 교차언어 불변식으로
# 못박은 것인데 aio 에는 단언이 **0** 이었다.


def _es256_setup(config: KeycloakConfig, ajwks) -> tuple[AsyncAuthClient, str]:
    key = ECKey.generate_key("P-256", {"kid": "k1", "use": "sig"})
    endpoints = OidcEndpoints.for_realm(config)
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    client = _client(MagicMock(), config=config)
    token = jjwt.encode(
        {"alg": "ES256", "kid": key.kid},
        {
            "iss": endpoints.issuer,
            "aud": config.client_id,
            "sub": "user-1",
            "exp": int(time.time()) + 60,
            "typ": "Bearer",  # Keycloak 의 액세스 토큰 모양(sync 동형)
        },
        key,
    )
    return client, token


async def test_validate_accepts_token_signed_with_configured_algorithm(ajwks):
    """signature_algorithms 를 ES256 으로 설정한 realm 의 ES256 토큰은 통과한다."""
    client, token = _es256_setup(_config(signature_algorithms=("ES256",)), ajwks)

    result = await client.validate(token)

    assert result.subject == "user-1"


async def test_validate_rejects_algorithm_not_in_configured_set(ajwks):
    """⚠️ **alg 핀닝** — 기본(RS256만)에서 ES256 토큰은 거부된다. 라이브러리 기본값은
    아홉 언어 어디서도 안전하지 않다(CLAUDE.md 교차언어 불변식)."""
    client, token = _es256_setup(_config(), ajwks)

    with pytest.raises(TokenValidationError):
        await client.validate(token)


async def test_validate_does_not_refetch_jwks_on_claim_failure(ajwks):
    """클레임 실패는 서명 실패가 아니므로 재조회를 트리거하지 않는다 — 그렇지 않으면
    무효 토큰 하나마다 IdP 왕복이 생긴다(DoS 증폭)."""
    client, key, endpoints = _validate_client(_config(), ajwks)
    token = _signed_token(key, issuer=endpoints.issuer, audience="someone-else")

    with pytest.raises(TokenValidationError):
        await client.validate(token)

    assert ajwks.call_count == 1


async def test_forced_jwks_refetch_is_rate_limited(ajwks):
    """kid 를 무작위로 바꾼 위조 토큰이 연속 도착해도 강제 재조회는 rate-limit 되어
    JWKS fetch 가 상한(최초 로드 1 + 최초 강제 재조회 1 = 2)을 넘지 않는다."""
    cached_key = RSAKey.generate_key(2048, {"kid": "cached", "use": "sig"})
    ajwks.return_value = {"keys": [cached_key.as_dict(private=False)]}
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    client = _client(MagicMock(), config=config)
    tokens = [
        _signed_token(
            RSAKey.generate_key(2048, {"kid": kid, "use": "sig"}),
            issuer=endpoints.issuer,
            audience=config.client_id,
        )
        for kid in ("x1", "x2")
    ]

    for tok in tokens:
        with pytest.raises(TokenValidationError):
            await client.validate(tok)

    assert ajwks.call_count == 2


async def test_recovered_idp_resets_the_backoff(ajwks):
    """대조군 — 복구 후 성공이 카운터를 되돌린다. 되돌리지 않으면 장수 프로세스가
    상한에 고정된다(`security.md` 규칙 3)."""
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    ajwks.side_effect = [
        KeycloakTransportError("idp down"),
        {"keys": [key.as_dict(private=False)]},
    ]
    client = _client(MagicMock())
    clock = _FakeClock()
    client._jwks_backoff = JwksFailureBackoff(clock=clock, jitter=lambda: 1.0)

    with pytest.raises((KeycloakTransportError, KeycloakAuthError)):
        await client._load_jwks()
    clock.advance(10.0)
    await client._load_jwks()

    assert client._jwks_backoff.failures == 0
    assert client._jwks_backoff.remaining() == 0.0


async def test_exchange_code_skips_id_token_validation_without_nonce(ajwks):
    """nonce 를 주지 않으면 id_token 검증을 건너뛴다 — JWKS 를 부르지 않는 것으로 잰다."""
    config = _config()
    endpoints = OidcEndpoints.for_realm(config)
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
    id_token = _signed_token(
        key, issuer=endpoints.issuer, audience=config.client_id, nonce="server-nonce"
    )
    openid = MagicMock()
    openid.a_token = AsyncMock(
        return_value={
            "access_token": "acc",
            "id_token": id_token,
            "token_type": "Bearer",
            "expires_in": 60,
        }
    )
    ajwks.return_value = {"keys": [key.as_dict(private=False)]}
    client = _client(openid, config=config)

    result = await client.exchange_code("code", "https://app/cb", "verifier")

    assert result.access_token == "acc"
    ajwks.assert_not_called()


def test_authorization_url_repr_masks_verifier():
    """⚠️ **마스킹** — 기본 dataclass repr 은 평문 PKCE verifier 를 로그·트레이스에 흘린다."""
    client = _client(MagicMock())

    result = client.authorization_url("https://app.example.com/callback")

    rendered = repr(result)
    assert result.code_verifier not in rendered
    assert result.url in rendered
    assert result.state in rendered
    assert result.nonce in rendered


def test_authorization_url_percent_encodes_and_resists_param_injection():
    """⚠️ **#442 의 회귀 테스트가 aio 에만 없었다.** 인코딩이 없으면 `redirect_uri` 안의
    `&` 가 별도 파라미터를 **주입**한다(그 결함은 sync 에서 실제로 배포돼 있었다)."""
    client = _client(MagicMock(), config=_config(scopes=("openid",)))

    # 원문 공백은 이제 조립 전에 거부된다(R3 —
    # test_authorization_redirect_uri.py). 그래서 인코딩된 공백 `%20` 을 싣는다 —
    # 왕복 단언이 `%` 자신의 인코딩까지 본다.
    hostile = "https://app.example.com/cb?x=1%20y&z=2"
    result = client.authorization_url(hostile)

    assert " " not in result.url, f"원문 공백이 남았다: {result.url}"
    qs = parse_qs(urlparse(result.url).query)
    assert qs["redirect_uri"] == [hostile]
