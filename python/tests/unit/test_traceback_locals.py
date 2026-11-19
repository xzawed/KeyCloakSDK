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

import builtins
import importlib
import json
import time
import traceback
from collections.abc import Awaitable, Callable
from typing import Any, NoReturn
from unittest.mock import AsyncMock, MagicMock

import httpx
import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import RSAKey
from keycloak import KeycloakOpenID

from keycloak_sdk._internal.frames import ascrub_frames, scrub_frames
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
    """Keycloak 의 id_token 모양(typ `ID`) — 아니면 「nonce mismatch」 칸이 nonce 대조에 닿기 전에
    종류 검사에서 거부돼, 토큰 응답이 살아 있는 교환 프레임을 재지 않는다."""
    claims: dict[str, object] = {
        "iss": _ENDPOINTS.issuer,
        "aud": "app",
        "sub": "user-1",
        "exp": int(time.time()) + 60,
        "nonce": NONCE,
        "typ": "ID",
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


def test_failed_validate_id_token_keeps_the_token_out_of_frame_locals(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """공개 `validate_id_token()` 의 인자도 로컬이다 — 서명은 유효하고 aud 만 다른 id_token."""
    token = _jwt(_KEY, aud="other")
    client, _ = _sync_client(monkeypatch, token, _JWKS)
    sealed = _Sealed(token)

    err = _catch(lambda: client.validate_id_token(sealed.value))

    _assert_shape(err, TokenValidationError, None)
    assert str(err) == "Audience not contained"
    assert not _leaked(err, _secrets(token))


async def test_failed_validate_id_token_keeps_the_token_out_of_frame_locals_aio(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    token = _jwt(_KEY, aud="other")
    client, _ = _aio_client(monkeypatch, token, _JWKS)
    sealed = _Sealed(token)

    err = await _acatch(lambda: client.validate_id_token(sealed.value))

    _assert_shape(err, TokenValidationError, None)
    assert str(err) == "Audience not contained"
    assert not _leaked(err, _secrets(token))


# --- 인가 URL 조립·생성자 — Grok 레그가 찾고 실측으로 확인한 두 자리 ---------------------------


def _unencodable(*args: object, **kwargs: object) -> str:
    """조립(`urlencode`)이 던진다 — verifier 는 이미 `authorization_url` 프레임의 로컬이다.

    ⚠️ 예전에는 `str()` 이 던지는 redirect_uri 로 같은 실패를 냈다. 이제 그 `str()` 은 redirect_uri
    검사(`_internal/redirect_uri.py`)가 PKCE 생성 **앞**에서 부르므로, 그 값으로는 이 테스트가 잴
    로컬이 생기지 않는다(실측: `@scrub_frames` 를 뗀 변이에서도 초록이었다). 그래서 조립 자체를
    실패시킨다."""
    raise ValueError("unencodable query")


_PKCE = ("PV9x2c-generated-verifier-canary-0123456789ab", "challenge")


@pytest.mark.parametrize("facade", ["sync", "aio"])
def test_failed_authorization_url_keeps_the_verifier_out_of_frame_locals(
    monkeypatch: pytest.MonkeyPatch, facade: str
) -> None:
    """예전에는 `authorization_url` 프레임의 `code_verifier` 로컬이 찍혔다(실측)."""
    module = "keycloak_sdk.auth" if facade == "sync" else "keycloak_sdk.aio.auth"
    monkeypatch.setattr(f"{module}._generate_pkce_pair", lambda: _PKCE)
    monkeypatch.setattr(f"{module}.urlencode", _unencodable)
    if facade == "sync":
        client: AuthClient | AsyncAuthClient = _sync_client(monkeypatch, _jwt(_KEY), _JWKS)[0]
    else:
        client = _aio_client(monkeypatch, _jwt(_KEY), _JWKS)[0]

    err = _catch(lambda: client.authorization_url("https://app/cb"))

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


# --- 예외 그룹의 구성원 — 등록부 `python-scrub-frames-skips-exception-groups` ------------------

#: 3.11 부터는 내장이고, 3.10 에서는 anyio 가 쓰는 백포트(`exceptiongroup` — 3.10 에서는 anyio 와
#: pytest 가 끌어온다)다. 3.10 도 건너뛰지 않는다 — 아래 실측 경로의 그룹이 3.10 에서는 그 백포트다.
_GROUP: Any = (
    getattr(builtins, "BaseExceptionGroup", None)
    or importlib.import_module("exceptiongroup").BaseExceptionGroup
)
#: 구성원을 던진 프레임이 쥔 로컬의 값 — 오류 수집기가 찍는 그것.
_HELD = "GM4w8z-group-member-local-canary"


def _raise_holding(exc: BaseException) -> NoReturn:
    client_secret = _HELD  # noqa: F841 — 수집기가 찍는 로컬
    raise exc


def _raised(exc: BaseException) -> BaseException:
    """`exc` 를 던지고 잡는다 — traceback 은 이 프레임과, 비밀 이름의 로컬을 쥔 `_raise_holding`."""
    try:
        _raise_holding(exc)
    except BaseException as caught:
        return caught
    raise AssertionError("not raised")


def _reached(err: BaseException) -> list[tuple[str, BaseException]]:
    """닿는 노드마다 (경로, 노드) — 원인 · 문맥(숨긴 것도) · 그룹의 구성원을 따라 노드마다 한 번.
    시험 자신의 걸음이다 — SDK 의 걸음으로 재면 SDK 를 SDK 로 잰다."""
    seen: set[int] = set()
    reached: list[tuple[str, BaseException]] = []
    todo: list[tuple[str, BaseException | None]] = [("err", err)]
    while todo:
        path, node = todo.pop(0)
        if node is None or id(node) in seen:
            continue
        seen.add(id(node))
        reached.append((path, node))
        todo += [(f"{path}.__cause__", node.__cause__), (f"{path}.__context__", node.__context__)]
        if isinstance(node, _GROUP):
            todo += [(f"{path}.exceptions[{i}]", m) for i, m in enumerate(node.exceptions)]
    return reached


def _shape(err: BaseException) -> list[tuple[str, int, type[BaseException], str]]:
    """객체 · 타입 · 메시지 · 사슬 모양 — 경로마다."""
    return [(path, id(node), type(node), str(node)) for path, node in _reached(err)]


def _kept(err: BaseException) -> list[str]:
    """맨 위가 아닌데 아직 traceback 을 쥔 노드의 경로."""
    return [path for path, node in _reached(err)[1:] if node.__traceback__ is not None]


@scrub_frames
def _sync_raises(err: BaseException) -> None:
    raise err


@ascrub_frames
async def _aio_raises(err: BaseException) -> None:
    raise err


async def _through(facade: str, err: BaseException) -> BaseException:
    """`err` 를 데코레이터(sync · aio)를 지나 던지고 여기서 잡는다."""
    try:
        if facade == "sync":
            _sync_raises(err)
        else:
            await _aio_raises(err)
    except BaseException as caught:
        return caught
    raise AssertionError("not raised")


@pytest.mark.parametrize("facade", ["sync", "aio"])
async def test_the_members_of_a_reached_group_lose_their_tracebacks(facade: str) -> None:
    """원인으로 단 그룹 — 중첩된 그룹, 구성원의 사슬, 두 그룹에 든 구성원, `BaseException` 구성원.
    예전에는 사슬만 뗐다: 그룹의 구성원은 비밀 이름의 로컬을 쥔 프레임째 수집기에 닿았다."""
    member_cause = _raised(TypeError("member cause"))
    member = _raised(OSError("member"))
    member.__cause__ = member_cause
    shared = _raised(KeyboardInterrupt())
    inner = _raised(_GROUP("inner", [member, shared]))
    outer = _raised(_GROUP("outer", [inner, shared]))
    top = RuntimeError("top")
    top.__cause__ = outer
    before = _shape(top)
    assert len(before) == 6 and len(_kept(top)) == 5, "전제 — 구성원과 그 사슬이 traceback 을 쥔다"
    assert _HELD in _render(top), "전제 — 이 렌더가 프레임 로컬을 찍는다"

    err = await _through(facade, top)

    assert err is top
    assert _shape(err) == before, "객체 · 타입 · 메시지 · 사슬 모양은 그대로다"
    assert _kept(err) == []
    assert [f.f_code.co_name for f, _ in traceback.walk_tb(err.__traceback__)] == [
        "_through",
        "wrapper",
    ]
    assert _HELD not in _render(err)


@pytest.mark.parametrize("facade", ["sync", "aio"])
async def test_the_walk_ends_on_cycles_through_a_group(facade: str) -> None:
    """구성원의 원인이 자기를 담은 그룹이고 문맥이 자기 자신이다 — 걸음은 끝나고, 순환 위의
    구성원도 traceback 을 잃는다."""
    member = _raised(OSError("member"))
    group = _raised(_GROUP("group", [member]))
    member.__cause__ = group
    member.__context__ = member
    top = RuntimeError("top")
    top.__context__ = group
    before = _shape(top)

    err = await _through(facade, top)

    assert err is top
    assert _shape(err) == before
    assert _kept(err) == []


def _refused_on_every_address(request: httpx.Request) -> NoReturn:
    """실측한 모양 — 호스트가 주소 여럿으로 풀리고(`localhost` → ::1 · 127.0.0.1) 모두 연결을
    거부했다. anyio 가 시도마다의 오류를 그룹으로 묶어 `OSError("All connection attempts failed")`
    의 원인으로 달고, httpcore 의 풀이 그 위의 오류를 `from None` 으로 다시 던져 그룹은 숨긴
    `__context__` 너머로만 닿는다. 구성원은 비밀 이름의 로컬을 쥔 프레임에서 던져졌다."""
    refused = [_raised(ConnectionRefusedError(111, "Connection refused")) for _ in range(2)]
    try:
        raise OSError("All connection attempts failed") from _GROUP(
            "multiple connection attempts failed", refused
        )
    except OSError:
        raise httpx.ConnectError("All connection attempts failed", request=request) from None


async def _over_failing_jwks() -> tuple[AsyncAuthClient, list[str]]:
    """진짜 `KeycloakOpenID` 의 httpx 클라이언트를 목 전송으로 바꾼 aio 클라이언트 — 토큰
    엔드포인트는 토큰 응답을 주고, JWKS 조회는 위 모양으로 실패한다."""
    hits: list[str] = []

    def answer(request: httpx.Request) -> httpx.Response:
        hits.append(f"{request.method} {request.url.path}")
        if request.method == "POST":
            # 스트림으로 준다 — `json=` 은 httpx 가 미리 읽어, SDK 의 원문 읽기(`token_cap`)가
            # `StreamConsumed` 로 실패한다.
            body = json.dumps(_response(_jwt(_KEY))).encode()
            return httpx.Response(
                200, headers={"Content-Type": "application/json"}, stream=httpx.ByteStream(body)
            )
        _refused_on_every_address(request)

    openid = KeycloakOpenID(
        server_url=_CONFIG.server_url,
        realm_name=_CONFIG.realm,
        client_id=_CONFIG.client_id,
        client_secret_key=SECRET,
        timeout=5,
    )
    created = openid.connection.async_s
    openid.connection.async_s = httpx.AsyncClient(transport=httpx.MockTransport(answer))
    await created.aclose()
    return AsyncAuthClient(_CONFIG, _ENDPOINTS, openid=openid), hits


_JWKS_LANES: dict[str, Callable[[AsyncAuthClient], Awaitable[object]]] = {
    "validate": lambda c: c.validate(_jwt(_KEY)),
    "validate_id_token": lambda c: c.validate_id_token(_jwt(_KEY)),
    "exchange_code": lambda c: c.exchange_code(CODE, "https://app/cb", VERIFIER, nonce=NONCE),
}


@pytest.mark.usefixtures("fast_tls")
@pytest.mark.parametrize("lane", list(_JWKS_LANES))
async def test_the_group_behind_a_failed_aio_jwks_fetch_loses_its_tracebacks(lane: str) -> None:
    """실제 경로 — aio JWKS 조회의 전송 실패는 원인으로 남고(`afetch_jwks`) 그 너머에 그룹이 있다.
    sync 는 urllib3 가 주소를 차례로 시도해 마지막 오류 하나만 남긴다(그룹 없음 — 실측).
    ⚠️ `TracebackException` 은 숨긴 문맥을 따라가지 않아 렌더로는 못 잰다 — traceback 을 쥔
    노드를 직접 센다."""
    client, hits = await _over_failing_jwks()
    try:
        err = await _acatch(lambda: _JWKS_LANES[lane](client))
    finally:
        await client.aclose()

    assert hits[-1] == f"GET {httpx.URL(_ENDPOINTS.jwks).path}"
    assert (type(err), str(err)) == (
        KeycloakTransportError,
        "JWKS fetch failed: All connection attempts failed",
    )
    groups = [path for path, node in _reached(err) if isinstance(node, _GROUP)]
    assert groups == ["err.__cause__.__context__.__cause__"], "전제 — 숨긴 문맥 너머의 그룹"
    assert _kept(err) == []
