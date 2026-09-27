"""SDK 오류의 **프레임 로컬**이 토큰을 들고 나가지 않는다 — id_token·JWKS·`validate()` 경로.

⚠️ 메시지·원인 사슬 정화(`test_token_response_leaks.py`)는 로컬을 보지 않는다. Sentry Python 은
기본값으로 traceback 이 닿는 모든 프레임의 로컬을 `repr` 로 모으고,
`TracebackException(capture_locals=True)` 가 같은 것을 찍는다. 예전에는 거부된 교환의
`err.__traceback__.tb_next.tb_frame.f_locals['response']['refresh_token']` 이 raw refresh
token 이었고, id_token 거부는 `JwtValidator`·joserfc 프레임이 원문 JWT 를 쥔 채 사슬
(`__cause__`)로 닿았다.

HTTP 실패·형식이 틀린 응답 경로(여섯 호출과 적대적 변형의 곱)는 `test_token_response_leaks.py` 의
`locals` 렌더가 잰다. 여기는 그 하네스가 닿지 못하는 자리 — **서명된** id_token 이 거부되는 교환,
교환 도중의 JWKS 장애, `validate()` 실패 — 를 sync·aio 둘 다 잰다.
"""

from __future__ import annotations

import time
import traceback
from collections.abc import Awaitable, Callable
from typing import Any
from unittest.mock import AsyncMock, MagicMock

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey
from keycloak import KeycloakOpenID

from keycloak_sdk.aio.auth import AsyncAuthClient
from keycloak_sdk.auth import AuthClient
from keycloak_sdk.config import KeycloakConfig
from keycloak_sdk.exceptions import (
    KeycloakAuthError,
    KeycloakTransportError,
    TokenKeyError,
    TokenSignatureError,
    TokenValidationError,
)
from keycloak_sdk.oidc import OidcEndpoints

SECRET = "CS8d2k-client-secret-canary"
CODE = "CD3f7h-auth-code-canary"
VERIFIER = "PV6j1l-pkce-verifier-canary-0123456789abcdef"
ACCESS = "AT5n9p-access-canary"
REFRESH = "RT2r4t-refresh-canary"
NONCE = "server-nonce"

_CONFIG = KeycloakConfig(
    server_url="https://kc.example.com", realm="r", client_id="app", client_secret=SECRET
)
_ENDPOINTS = OidcEndpoints.for_realm(_CONFIG)
_KEY = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})
_FORGER = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig"})  # JWKS 의 k1 과 kid 만 같다
_STRANGER = RSAKey.generate_key(2048, {"kid": "not-in-jwks", "use": "sig"})


def _jwt(key: RSAKey, **changes: object) -> str:
    claims: dict[str, object] = {
        "iss": _ENDPOINTS.issuer,
        "aud": "app",
        "sub": "user-1",
        "exp": int(time.time()) + 60,
        "nonce": NONCE,
    }
    claims.update(changes)
    return jjwt.encode({"alg": "RS256", "kid": key.kid}, claims, key)


def _secrets(id_token: str) -> dict[str, str]:
    """찾을 값 — JWT 는 통째로와 **payload·서명 조각 따로**(joserfc 프레임은 조각을 쥔다)."""
    _, payload, signature = id_token.split(".")
    return {
        "client_secret": SECRET,
        "code": CODE,
        "code_verifier": VERIFIER,
        "access_token": ACCESS,
        "refresh_token": REFRESH,
        "id_token": id_token,
        "id_token payload": payload,
        "id_token signature": signature,
    }


def _render(err: BaseException) -> str:
    """오류 수집기가 모으는 것 — 사슬(`__cause__`·`__context__`)까지, 프레임마다 로컬을 찍는다."""
    return "".join(traceback.TracebackException.from_exception(err, capture_locals=True).format())


def _leaked(err: BaseException, secrets: dict[str, str]) -> list[str]:
    rendered = _render(err)
    return [name for name, value in secrets.items() if value in rendered]


def _response(id_token: str) -> dict[str, object]:
    return {
        "access_token": ACCESS,
        "refresh_token": REFRESH,
        "id_token": id_token,
        "token_type": "Bearer",
        "expires_in": 60,
    }


# --- 경우 — (id_token, JWKS 응답 또는 예외, 기대 오류 타입, 원인 타입) ------------------------

_Case = tuple[str, object, type[BaseException], type[BaseException] | None]
_JWKS = {"keys": [_KEY.as_dict(private=False)]}

CASES: dict[str, _Case] = {
    # 검증은 통과했고 nonce 만 다르다 — 토큰 응답 전체가 교환 프레임의 로컬에 살아 있다.
    "nonce mismatch": (_jwt(_KEY, nonce="other"), _JWKS, KeycloakAuthError, None),
    # 서명 위조 — 사슬 끝의 joserfc 예외 프레임이 JWT 조각을 쥔다.
    "forged signature": (_jwt(_FORGER), _JWKS, KeycloakAuthError, TokenSignatureError),
    # 클레임 거부 — `JwtValidator` 프레임이 원문 JWT 를 쥔다.
    "foreign audience": (_jwt(_KEY, aud="other"), _JWKS, KeycloakAuthError, TokenValidationError),
    # 미해결 kid — 강제 재조회 후 재시도하는 가지(`TokenKeyError`)를 지난다.
    "unknown kid": (_jwt(_STRANGER), _JWKS, KeycloakAuthError, TokenKeyError),
    # 교환 도중 JWKS 장애 — 오류는 `KeycloakTransportError` 인데 교환 프레임은 토큰을 쥐고 있다.
    # (클래스로 둔다 — 인스턴스를 공유하면 앞 실행의 traceback 이 다음 raise 에 이어 붙는다.)
    "jwks down": (_jwt(_KEY), KeycloakTransportError, KeycloakTransportError, None),
}


def _jwks_mock(answer: object, factory: type[MagicMock]) -> MagicMock:
    if isinstance(answer, type) and issubclass(answer, BaseException):
        return factory(side_effect=answer)  # 호출마다 새 인스턴스
    return factory(return_value=answer)


def _sync_client(
    monkeypatch: pytest.MonkeyPatch, id_token: str, jwks: object
) -> tuple[AuthClient, MagicMock]:
    monkeypatch.setattr("keycloak_sdk.auth.fetch_jwks", _jwks_mock(jwks, MagicMock))
    openid = MagicMock(spec=KeycloakOpenID)
    openid.token.return_value = _response(id_token)
    return AuthClient(_CONFIG, _ENDPOINTS, openid=openid), openid


def _aio_client(
    monkeypatch: pytest.MonkeyPatch, id_token: str, jwks: object
) -> tuple[AsyncAuthClient, MagicMock]:
    monkeypatch.setattr("keycloak_sdk.aio.auth.afetch_jwks", _jwks_mock(jwks, AsyncMock))
    openid = MagicMock()
    openid.a_token = AsyncMock(return_value=_response(id_token))
    return AsyncAuthClient(_CONFIG, _ENDPOINTS, openid=openid), openid


class _Sealed:
    """토큰을 쥐되 `repr` 로 드러내지 않는다 — 호출을 싼 람다의 자유 변수도 프레임 로컬로 찍힌다."""

    def __init__(self, value: str) -> None:
        self.value = value

    def __repr__(self) -> str:
        return "<sealed>"


def _catch(call: Callable[[], object]) -> BaseException:
    """호출을 **여기서** 잡는다 — traceback 의 첫 프레임 로컬은 `call`(람다) 뿐이다."""
    try:
        call()
    except Exception as exc:
        return exc
    raise AssertionError("the call did not fail")


async def _acatch(call: Callable[[], Awaitable[Any]]) -> BaseException:
    try:
        await call()
    except Exception as exc:
        return exc
    raise AssertionError("the call did not fail")


def _assert_shape(err: BaseException, kind: type[BaseException], cause: type[BaseException] | None):
    """전제 — 정말 그 경로로 실패했다(아니면 누출 검사는 없는 오류를 찾으며 통과한다)."""
    assert type(err) is kind, f"{type(err).__name__}: {err}"
    if cause is not None:
        assert type(err.__cause__) is cause, repr(err.__cause__)


@pytest.mark.parametrize("case", list(CASES))
def test_rejected_exchange_keeps_tokens_out_of_frame_locals(
    monkeypatch: pytest.MonkeyPatch, case: str
) -> None:
    id_token, jwks, kind, cause = CASES[case]
    client, _ = _sync_client(monkeypatch, id_token, jwks)

    err = _catch(lambda: client.exchange_code(CODE, "https://app/cb", VERIFIER, nonce=NONCE))

    _assert_shape(err, kind, cause)
    assert not _leaked(err, _secrets(id_token))


@pytest.mark.parametrize("case", list(CASES))
async def test_rejected_exchange_keeps_tokens_out_of_frame_locals_aio(
    monkeypatch: pytest.MonkeyPatch, case: str
) -> None:
    id_token, jwks, kind, cause = CASES[case]
    client, _ = _aio_client(monkeypatch, id_token, jwks)

    err = await _acatch(lambda: client.exchange_code(CODE, "https://app/cb", VERIFIER, nonce=NONCE))

    _assert_shape(err, kind, cause)
    assert not _leaked(err, _secrets(id_token))


def test_failed_validate_keeps_the_token_out_of_frame_locals(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """`validate()` 의 인자도 로컬이다 — 소비자가 넘긴 bearer 토큰(서명은 유효, aud 만 다르다)."""
    token = _jwt(_KEY, aud="other")
    client, _ = _sync_client(monkeypatch, token, _JWKS)
    sealed = _Sealed(token)  # 람다의 자유 변수로 토큰 원문을 두면 **테스트** 프레임이 찍는다

    err = _catch(lambda: client.validate(sealed.value))

    _assert_shape(err, TokenValidationError, None)
    assert not _leaked(err, _secrets(token))


async def test_failed_validate_keeps_the_token_out_of_frame_locals_aio(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    token = _jwt(_KEY, aud="other")
    client, _ = _aio_client(monkeypatch, token, _JWKS)
    sealed = _Sealed(token)

    err = await _acatch(lambda: client.validate(sealed.value))

    _assert_shape(err, TokenValidationError, None)
    assert not _leaked(err, _secrets(token))


# --- 인가 URL 조립·생성자 — Grok 레그가 찾고 실측으로 확인한 두 자리 ---------------------------


class _Hostile:
    """`str()` 이 실패하는 redirect_uri — `urlencode` 가 조립 도중 던진다(verifier 는 이미 로컬)."""

    def __str__(self) -> str:
        raise ValueError("unprintable redirect_uri")


_PKCE = ("PV9x2c-generated-verifier-canary-0123456789ab", "challenge")


@pytest.mark.parametrize("facade", ["sync", "aio"])
def test_failed_authorization_url_keeps_the_verifier_out_of_frame_locals(
    monkeypatch: pytest.MonkeyPatch, facade: str
) -> None:
    """예전에는 `authorization_url` 프레임의 `code_verifier` 로컬이 찍혔다(실측)."""
    module = "keycloak_sdk.auth" if facade == "sync" else "keycloak_sdk.aio.auth"
    monkeypatch.setattr(f"{module}._generate_pkce_pair", lambda: _PKCE)
    if facade == "sync":
        client: AuthClient | AsyncAuthClient = _sync_client(monkeypatch, _jwt(_KEY), _JWKS)[0]
    else:
        client = _aio_client(monkeypatch, _jwt(_KEY), _JWKS)[0]

    err = _catch(lambda: client.authorization_url(_Hostile()))  # type: ignore[arg-type]

    assert type(err) is ValueError
    assert _PKCE[0] not in _render(err)


class _ExplodingLower:
    """생성 도중 실패하는 하위 클라이언트 — python-keycloak 이 CA 번들을 못 읽을 때의 모양이다
    (실측: `SSL_CERT_FILE` 이 없는 파일이면 `KeycloakOpenID(...)` 가 `FileNotFoundError`, 그 안쪽
    프레임이 `client_secret_key` 를 쥔다). 여기서는 인자를 로컬로 쥔 채 던지는 것만 흉내 낸다."""

    def __init__(self, **kwargs: object) -> None:
        raise FileNotFoundError("CA bundle not found")


@pytest.mark.parametrize(
    ("facade", "lower"),
    [
        ("sync", "keycloak_sdk.auth.KeycloakOpenID"),
        ("aio", "keycloak_sdk.aio.auth.KeycloakOpenID"),
        ("sync admin", "keycloak_sdk.admin.KeycloakAdmin"),
        ("aio admin", "keycloak_sdk.aio.admin.KeycloakAdmin"),
    ],
)
def test_failed_construction_keeps_the_client_secret_out_of_frame_locals(
    monkeypatch: pytest.MonkeyPatch, facade: str, lower: str
) -> None:
    """하위 클라이언트 생성이 실패하면 그 프레임이 `client_secret_key` 를 쥔다 — 떼어져야 한다."""
    from keycloak_sdk.admin import AdminClient
    from keycloak_sdk.aio.admin import AsyncAdminClient

    monkeypatch.setattr(lower, _ExplodingLower)
    build: dict[str, Callable[[], object]] = {
        "sync": lambda: AuthClient(_CONFIG, _ENDPOINTS),
        "aio": lambda: AsyncAuthClient(_CONFIG, _ENDPOINTS),
        "sync admin": lambda: AdminClient(_CONFIG).users,
        "aio admin": lambda: AsyncAdminClient(_CONFIG).users,
    }

    err = _catch(build[facade])

    assert type(err) is FileNotFoundError
    assert SECRET not in _render(err)


def test_the_rendering_still_names_the_failure(monkeypatch: pytest.MonkeyPatch) -> None:
    """대조군 — 떼어 낸 것은 안쪽 프레임뿐이다: 타입·메시지·원인 사슬은 그대로 찍힌다.

    그리고 이 렌더가 로컬을 **정말** 찍는다는 증거로, 호출자 프레임의 로컬은 남는다."""
    id_token = _jwt(_FORGER)
    client, _ = _sync_client(monkeypatch, id_token, _JWKS)
    marker = "caller-local-marker"  # noqa: F841 — capture_locals 가 찍어야 하는 호출자 로컬

    try:
        client.exchange_code(CODE, "https://app/cb", VERIFIER, nonce=NONCE)
    except KeycloakAuthError as exc:
        err: BaseException = exc
    rendered = _render(err)

    assert "KeycloakAuthError: authorization code exchange failed: invalid id_token" in rendered
    assert "TokenSignatureError: JWT signature/algorithm validation failed" in rendered
    assert "caller-local-marker" in rendered
