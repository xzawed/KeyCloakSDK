"""바닥 계약(기본 표현이 비밀을 찍지 않는다)을 **도달 가능한 객체 전부**에 건다.

`test_tokens.py`·`test_config.py` 는 손으로 고른 값 타입의 `repr` 을 잰다. 이 테스트는 그 목록을
쓰지 않는다 — (1) 공개 API 로 만든 뿌리(sync·aio 파사드, 값, 실제 실패 호출이 낸 오류)에서
리플렉션으로 **닿는 이 SDK 의 객체 전부**를 `repr`·`str`·`format`·`pprint.pformat` 으로 찍어
카나리아를 찾고, (2) `keycloak_sdk` 소스를 `ast` 로 파싱해 얻은 **클래스 선언 전수**가 그 걷기에
걸렸는지 대조한다. 새 타입은 걷기에 닿거나, 파생 규칙에 걸리거나, 아래 면제 표에 이유와 함께
적혀야 통과한다. Go `facade_dump_test.go` · PHP `FacadeDumpTest.php` 와 같은 모양이다.

⚠️ **새 자리를 스스로 찾는 것이 요점이다**(등록부 `guard-detection-surface-hand-narrowed`).

⚠️ 걷기는 **SDK 자신의 타입만 찍는다**(하위 라이브러리 객체를 쥐는 자리는 §4(b) `raw` 탈출구다).
그러나 **내려가기는 남의 객체도 지나간다** — 필드(비공개·`__slots__`), 컨테이너 원소, 예외의
`args`/`__cause__`/`__context__`/`__traceback__`, 트레이스백 프레임의 지역 변수. SDK 객체 사이에
끼는 남의 객체는 `_FOREIGN_LAYERS` 층까지 본다. 처음(SDK 타입만 따라가던 판)은 Grok 교차검토가
낸 다섯 변이에 전부 SILENT 였다(실측): SDK 가 만든 `str` 하위 타입, `SimpleNamespace`·
`KeycloakOpenID`·남의 예외 `args` 안에 숨은 SDK 객체, 버려지는 `JwtValidator`, 별칭으로 생성을 숨긴
기반 클래스. 지금 판은 다섯 다 잡는다.

⚠️ 하네스 위생: 트레이스백을 걸으면 실패 뿌리를 만든 이 테스트의 람다 프레임이 걸리고, 그 클로저가
이 테스트의 `_Jwts`(카나리아 JWT 원문을 쥔)를 가리킨다 — 실측으로 걷기가 거기 들어갔다. 이 모듈의
타입은 걷기가 **들어가지 않는 벽**이다(찍지 않으니 누출로 잡히지는 않았지만, 테스트가 쥔 것이
「공개 API 에서 닿았다」로 세이면 대조가 거짓이 된다). 프레임은 `f_locals` 만 걷고 `f_back`·
`f_globals` 는 걷지 않는다.

⚠️ 한계: 카나리아는 뿌리를 만드는 호출이 흘려 넣은 비밀뿐이다. 새 타입이 이 뿌리들이 안 밟는
경로로 비밀을 받으면 그 비밀은 여기 없다 — 그때는 그 경로를 뿌리에 더한다. Python 에는 소비자가
주입하는 토큰 provider 가 없다(admin 이 토큰을 자체 소유한다, CLAUDE.md §4). `AdminClient(config,
admin=...)` 는 docstring 이 「테스트 주입용」이라 적는 이음매이고 기본 경로와 같은 상태 모양을
만들므로 따로 뿌리로 두지 않는다.

⚠️ 클라이언트 수를 줄여 둔 이유: python-keycloak 은 `ConnectionManager` 마다 `httpx.AsyncClient`
를 만들고, 그 생성이 이 머신에서 0.5초다(실측 2026-09-26, Windows · certifi 로드). 그래서 실패 경로
셋(401·연결 끊김·JWKS 상한 초과)을 realm `bad` 클라이언트 하나에 모았다. 「도달 불가 서버」는
`127.0.0.1:1` 대신 **응답 없이 끊는 경로**로 만든다 — Windows 는 거부된 연결에 시도당 2초를 쓴다
(실측 sync 4.0초 · aio 2.0초). SDK 가 내는 타입(`KeycloakTransportError`)은 같다.
"""

from __future__ import annotations

import ast
import asyncio
import json
import pprint
import threading
import time
import types
import weakref
from collections import deque
from collections.abc import Awaitable, Callable, Iterator, Mapping
from contextlib import AsyncExitStack, ExitStack, contextmanager
from dataclasses import dataclass, field, replace
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from joserfc import jwt as jjwt
from joserfc.jwk import KeySet, RSAKey

import keycloak_sdk
from keycloak_sdk import (
    KeycloakAdminError,
    KeycloakAuthError,
    KeycloakClient,
    KeycloakConfig,
    KeycloakConfigError,
    KeycloakConflictError,
    KeycloakForbiddenError,
    KeycloakNotFoundError,
    KeycloakTransportError,
    TokenKeyError,
    TokenSignatureError,
    TokenValidationError,
)
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.aio.admin import AsyncAdminClient

SECRET = "CANARY-DUMP-CLIENT-SECRET"
ACCESS = "CANARY-DUMP-ACCESS-TOKEN"
REFRESH = "CANARY-DUMP-REFRESH-TOKEN"
ID_TOKEN = "CANARY-DUMP-ID-TOKEN"
GARBAGE = "CANARY-DUMP-GARBAGE-TOKEN"
PASSWORD = "CANARY-DUMP-ADMIN-PASSWORD"

#: 걷기에 안 닿아도 되는 선언과 그 이유. ⚠️ 이유 없는 면제는 넣지 않는다.
#: (비어 있다 — `JwtValidator` 는 `validate` 가 지역으로 만들고 버리지만, 실패한 검증 오류의
#: 트레이스백 프레임이 그것을 쥐어 소비자 손에 닿으므로 면제가 아니라 걷기 대상이다.)
EXEMPT: dict[str, str] = {}

#: 알려진 누출 — `"뿌리|카나리아"` → 사유. ⚠️ 고쳐져 더 안 새면 **여기서 지워야 통과한다**
#: (낡은 항목 검사).
KNOWN_LEAKS: dict[str, str] = {}

_OC = "/protocol/openid-connect"
#: JWKS 바이트 상한(`_internal/jwks_fetch.py` 의 51 200)을 넘는 본문 — `_TooBig` 경로를 연다.
_OVERSIZED_JWKS = b'{"keys": [], "pad": "' + b"x" * 60_000 + b'"}'


# --- 가짜 IdP ------------------------------------------------------------------------------


@dataclass
class _Idp:
    """토큰·introspect·JWKS·실패 realm·admin 4xx/5xx 를 한 서버가 낸다(경로로 고른다)."""

    jwks: bytes
    url: str = ""
    hits: list[tuple[str, str, str]] = field(default_factory=list)  # (메서드, 경로, 본문)


def _answer(idp: _Idp, method: str, path: str) -> tuple[int, bytes] | None:
    """경로별 응답. `None` 은 응답 없이 연결을 끊는다(전송 오류)."""
    if path == f"/realms/r{_OC}/token":
        tokens = {
            "access_token": ACCESS,
            "refresh_token": REFRESH,
            "id_token": ID_TOKEN,
            "token_type": "Bearer",
            "expires_in": 300,
            "scope": "openid",
        }
        return 200, json.dumps(tokens).encode()
    if path == f"/realms/r{_OC}/token/introspect":
        return 200, b'{"active": true, "username": "svc", "client_id": "c", "sub": "u1"}'
    if path == f"/realms/r{_OC}/certs":
        return 200, idp.jwks
    # 실패 realm — 토큰은 401, introspect 는 응답 없이 끊고, JWKS 는 상한을 넘긴다.
    if path == f"/realms/bad{_OC}/token":
        return (
            401,
            b'{"error": "invalid_client", "error_description": "Invalid client credentials"}',
        )
    if path == f"/realms/bad{_OC}/token/introspect":
        return None
    if path == f"/realms/bad{_OC}/certs":
        return 200, _OVERSIZED_JWKS
    admin = {
        ("GET", "/admin/realms/r/users/u1"): (200, b'{"id": "u1", "username": "svc"}'),
        ("GET", "/admin/realms/r/users/missing"): (404, b'{"error": "User not found"}'),
        ("POST", "/admin/realms/r/users"): (409, b'{"errorMessage": "User exists"}'),
        ("GET", "/admin/realms/r/roles/forbidden"): (403, b'{"error": "unknown_error"}'),
        ("GET", "/admin/realms/r/groups/broken"): (500, b'{"error": "unknown_error"}'),
    }
    return admin.get((method, path), (404, b"{}"))


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            path = urlsplit(self.path).path
            idp.hits.append((self.command, path, body))
            answer = _answer(idp, self.command, path)
            if answer is None:
                self.close_connection = True
                return
            status, payload = answer
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve

    return Handler


class _QuietServer(ThreadingHTTPServer):
    """상한에 걸린 클라이언트가 JWKS 를 읽다 끊으면 서버가 트레이스백을 찍는다 — 상한이
    작동한 증거지 오류가 아니다."""

    def handle_error(self, *_args: Any) -> None:
        pass


@contextmanager
def _fake_idp(jwks: bytes) -> Iterator[_Idp]:
    idp = _Idp(jwks=jwks)
    server = _QuietServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    # 기본 poll 0.5초면 shutdown 이 그만큼 기다린다.
    threading.Thread(target=server.serve_forever, args=(0.05,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


# --- 뿌리 ----------------------------------------------------------------------------------


@dataclass
class _Jwts:
    """서명한 JWT 셋 — 원문 문자열 전부가 카나리아다."""

    ok: str
    unknown_kid: str
    bad_issuer: str


def _sign_jwts(issuer: str) -> tuple[bytes, _Jwts]:
    served = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig", "alg": "RS256"})
    rotated = RSAKey.generate_key(2048, {"kid": "k-rotated", "use": "sig", "alg": "RS256"})
    now = int(time.time())

    def claims(iss: str) -> dict[str, Any]:
        return {"iss": iss, "sub": "u1", "aud": "c", "iat": now, "exp": now + 60}

    jwks = json.dumps(KeySet([served]).as_dict(private=False)).encode()
    return jwks, _Jwts(
        ok=jjwt.encode({"alg": "RS256", "kid": "k1"}, claims(issuer), served),
        unknown_kid=jjwt.encode({"alg": "RS256", "kid": "k-rotated"}, claims(issuer), rotated),
        bad_issuer=jjwt.encode(
            {"alg": "RS256", "kid": "k1"}, claims("https://evil.example/realms/r"), served
        ),
    )


def _caught(fn: Callable[[], object]) -> Exception:
    try:
        fn()
    except Exception as exc:
        return exc
    raise AssertionError("실패 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다")


async def _acaught(awaitable: Awaitable[object]) -> Exception:
    try:
        await awaitable
    except Exception as exc:
        return exc
    raise AssertionError("실패 뿌리를 못 만들었다 — 가짜 IdP 가 실패를 안 냈다")


def _cached_admin_token(admin: AdminClient | AsyncAdminClient) -> str:
    token = admin.raw.connection.token
    assert token is not None, "admin 이 토큰을 캐시하지 않았다"
    return str(token["access_token"])


def _user_with_password() -> dict[str, Any]:
    return {"username": "svc", "credentials": [{"type": "password", "value": PASSWORD}]}


def _expect_errors(errors: list[tuple[str, Exception, type[Exception]]]) -> None:
    """실패 호출이 **그 SDK 타입**을 냈는가 — 아니면 뿌리 이름이 거짓이다."""
    wrong = [f"{name}: {type(e).__name__}" for name, e, want in errors if type(e) is not want]
    assert not wrong, f"실패 뿌리가 기대한 SDK 타입이 아니다: {wrong}"


def _sync_roots(
    idp: _Idp, jwts: _Jwts, stack: ExitStack
) -> tuple[list[tuple[str, object]], dict[str, str]]:
    cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id="c", client_secret=SECRET)
    kc = stack.enter_context(KeycloakClient.create(cfg))
    # 기본 경로 admin — 내부 KeycloakAdmin 이 토큰을 캐시한 뒤라야 그 상태가 걷기에 걸린다.
    admin = kc.admin
    admin.users.get("u1")
    ts = kc.auth.client_credentials_token()
    ar = kc.auth.authorization_url("https://app/cb")
    ir = kc.auth.introspect(ACCESS)
    vt = kc.auth.validate(jwts.ok)

    # ⚠️ 카나리아가 실제로 흘러 들어갔는가 — 안 흘렀으면 아래 누출 검사는 없는 것을 찾으며 통과한다.
    assert (ts.access_token, ts.refresh_token, ts.id_token) == (ACCESS, REFRESH, ID_TOKEN)
    assert _cached_admin_token(admin) == ACCESS
    assert len(ar.code_verifier) >= 43
    assert (vt.subject, ir.active) == ("u1", True)

    bad = stack.enter_context(KeycloakClient.create(replace(cfg, realm="bad")))
    errors: list[tuple[str, Exception, type[Exception]]] = [
        ("auth 401", _caught(bad.auth.client_credentials_token), KeycloakAuthError),
        ("validate garbage", _caught(lambda: kc.auth.validate(GARBAGE)), TokenSignatureError),
        (
            "validate unknown kid",
            _caught(lambda: kc.auth.validate(jwts.unknown_kid)),
            TokenKeyError,
        ),
        (
            "validate bad iss",
            _caught(lambda: kc.auth.validate(jwts.bad_issuer)),
            TokenValidationError,
        ),
        ("introspect down", _caught(lambda: bad.auth.introspect(ACCESS)), KeycloakTransportError),
        ("jwks oversized", _caught(lambda: bad.auth.validate(jwts.ok)), KeycloakTransportError),
        (
            "config",
            _caught(
                lambda: KeycloakConfig(
                    server_url="", realm="r", client_id="c", client_secret=SECRET
                )
            ),
            KeycloakConfigError,
        ),
        ("admin 404", _caught(lambda: admin.users.get("missing")), KeycloakNotFoundError),
        (
            "admin 409",
            _caught(lambda: admin.users.create(_user_with_password())),
            KeycloakConflictError,
        ),
        ("admin 403", _caught(lambda: admin.roles.get("forbidden")), KeycloakForbiddenError),
        ("admin 500", _caught(lambda: admin.groups.get("broken")), KeycloakAdminError),
    ]
    _expect_errors(errors)

    roots: list[tuple[str, object]] = [
        ("KeycloakClient.create", kc),
        ("admin", admin),
        ("admin.users", admin.users),
        ("admin.clients", admin.clients),
        ("admin.realms", admin.realms),
        ("admin.roles", admin.roles),
        ("admin.groups", admin.groups),
        ("client_credentials_token", ts),
        ("authorization_url", ar),
        ("introspect", ir),
        ("validate", vt),
        *((name, e) for name, e, _ in errors),
    ]
    return roots, {"VERIFIER": ar.code_verifier}


async def _aio_roots(
    idp: _Idp, jwts: _Jwts, stack: AsyncExitStack
) -> tuple[list[tuple[str, object]], dict[str, str]]:
    cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id="c", client_secret=SECRET)
    akc = await stack.enter_async_context(AsyncKeycloakClient.create(cfg))
    admin = akc.admin
    await admin.users.get("u1")
    ts = await akc.auth.client_credentials_token()
    ar = akc.auth.authorization_url("https://app/cb")
    ir = await akc.auth.introspect(ACCESS)
    vt = await akc.auth.validate(jwts.ok)

    assert (ts.access_token, ts.refresh_token, ts.id_token) == (ACCESS, REFRESH, ID_TOKEN)
    assert _cached_admin_token(admin) == ACCESS
    assert len(ar.code_verifier) >= 43
    assert (vt.subject, ir.active) == ("u1", True)

    bad = await stack.enter_async_context(AsyncKeycloakClient.create(replace(cfg, realm="bad")))
    errors: list[tuple[str, Exception, type[Exception]]] = [
        ("aio auth 401", await _acaught(bad.auth.client_credentials_token()), KeycloakAuthError),
        ("aio validate garbage", await _acaught(akc.auth.validate(GARBAGE)), TokenSignatureError),
        (
            "aio introspect down",
            await _acaught(bad.auth.introspect(ACCESS)),
            KeycloakTransportError,
        ),
        ("aio jwks oversized", await _acaught(bad.auth.validate(jwts.ok)), KeycloakTransportError),
        ("aio admin 404", await _acaught(admin.users.get("missing")), KeycloakNotFoundError),
        (
            "aio admin 409",
            await _acaught(admin.users.create(_user_with_password())),
            KeycloakConflictError,
        ),
    ]
    _expect_errors(errors)

    roots: list[tuple[str, object]] = [
        ("AsyncKeycloakClient.create", akc),
        ("aio admin", admin),
        ("aio admin.users", admin.users),
        ("aio admin.clients", admin.clients),
        ("aio admin.realms", admin.realms),
        ("aio admin.roles", admin.roles),
        ("aio admin.groups", admin.groups),
        ("aio client_credentials_token", ts),
        ("aio authorization_url", ar),
        ("aio introspect", ir),
        ("aio validate", vt),
        *((name, e) for name, e, _ in errors),
    ]
    return roots, {"AIO_VERIFIER": ar.code_verifier}


# --- 걷기 ----------------------------------------------------------------------------------

#: **정확히** 이 타입이면 값일 뿐이다. ⚠️ `isinstance` 로 거르면 SDK 가 만든 `str` 하위 타입
#: (비밀을 쥔 채 `repr` 이 원문을 내는)이 스칼라로 보여 찍히지 않는다(Grok 교차검토, SILENT 실측).
_SCALARS = frozenset({str, bytes, bytearray, int, float, complex, bool, type(None)})
_SEQUENCES = (list, tuple, set, frozenset, deque)
#: 상태가 아니라 코드·모듈·타입·약한 참조다 — 내려가지 않는다.
_OPAQUE = (
    types.ModuleType,
    type,
    types.FunctionType,
    types.BuiltinFunctionType,
    types.MethodType,
    types.MethodWrapperType,
    types.WrapperDescriptorType,
    types.MethodDescriptorType,
    types.GetSetDescriptorType,
    types.MemberDescriptorType,
    types.CodeType,
    types.CoroutineType,
    types.GeneratorType,
    types.AsyncGeneratorType,
    weakref.ReferenceType,
)
#: 층으로 세지 않는 구조 — 컨테이너, 그리고 예외가 쥔 트레이스백·프레임.
_STRUCTURAL = (*_SEQUENCES, dict, types.MappingProxyType, types.TracebackType, types.FrameType)
#: SDK 객체와 SDK 객체 사이에 끼어도 되는 **남의 객체 층 수**. 남의 객체는 찍지 않고 지나가기만
#: 한다 — `KeycloakOpenID`·`SimpleNamespace`·남의 예외 `args` 안에 숨은 SDK 객체를 잡으려고.
_FOREIGN_LAYERS = 4


def _type_name(cls: type) -> str:
    return f"{cls.__module__}.{cls.__qualname__}"


def _module_of(cls: type) -> str:
    module = getattr(cls, "__module__", "")
    return module if isinstance(module, str) else ""


def _is_own(cls: type) -> bool:
    module = _module_of(cls)
    return module == "keycloak_sdk" or module.startswith("keycloak_sdk.")


def _items(obj: object) -> list[tuple[object, object]]:
    try:
        return list(obj.items()) if isinstance(obj, Mapping) else []
    except Exception:  # 남의 Mapping 이 순회를 거부하면 그 원소만 못 본다(SDK 객체는 dict 다)
        return []


def _children(obj: object) -> Iterator[tuple[str, object]]:
    """비공개까지 전부 — `__dict__`·`__slots__`, 컨테이너 원소, 예외의 사슬과 트레이스백,
    트레이스백 프레임의 지역 변수."""
    if isinstance(obj, types.TracebackType):
        yield ".tb_frame", obj.tb_frame
        yield ".tb_next", obj.tb_next
        return
    if isinstance(obj, types.FrameType):
        # `f_back`·`f_globals` 는 걷지 않는다 — 호출자(테스트·pytest) 프레임과 모듈 전역이다.
        yield from ((f".<{name}>", value) for name, value in list(obj.f_locals.items()))
        return
    for key, value in _items(obj):
        yield "[key]", key
        yield f"[{key[:40] if isinstance(key, str) else type(key).__name__!r}]", value
    if isinstance(obj, _SEQUENCES):
        yield from ((f"[{i}]", item) for i, item in enumerate(list(obj)))
    try:
        instance_dict = object.__getattribute__(obj, "__dict__")
    except AttributeError:
        instance_dict = None
    if isinstance(instance_dict, dict):
        yield from ((f".{name}", value) for name, value in list(instance_dict.items()))
    for cls in type(obj).__mro__:
        slots = cls.__dict__.get("__slots__", ())
        for slot in (slots,) if isinstance(slots, str) else slots:
            if slot in ("__dict__", "__weakref__"):
                continue
            mangled = f"_{cls.__name__.lstrip('_')}{slot}" if slot.startswith("__") else slot
            try:
                yield f".{slot}", object.__getattribute__(obj, mangled)
            except AttributeError:
                continue
    if isinstance(obj, BaseException):
        yield ".args", obj.args
        yield ".__cause__", obj.__cause__
        yield ".__context__", obj.__context__
        yield ".__traceback__", obj.__traceback__


class _Walker:
    def __init__(self, canaries: Mapping[str, str]) -> None:
        self._canaries = canaries
        # id → 그 객체에 닿았을 때 남은 층 수. 더 많은 층을 들고 다시 닿으면 다시 편다.
        self._layers: dict[int, int] = {}
        self._alive: list[object] = []  # id() 재사용을 막는다
        self.reached: dict[str, type] = {}
        self.leaks: list[str] = []
        self.known_seen: set[str] = set()
        self.foreign_visits = 0

    def walk(self, start: object, root: str) -> None:
        stack: list[tuple[object, str, int]] = [(start, root, _FOREIGN_LAYERS)]
        while stack:
            obj, path, layers = stack.pop()
            cls = type(obj)
            # 하네스 위생: 이 테스트 자신의 타입(가짜 IdP·JWT 묶음·걷기 상태)에는 들어가지 않는다 —
            # 거기서 닿은 것을 「공개 API 뿌리에서 닿았다」고 세면 대조가 거짓이 된다.
            if cls in _SCALARS or isinstance(obj, _OPAQUE) or _module_of(cls) == __name__:
                continue
            own = _is_own(cls)
            if own:
                layers = _FOREIGN_LAYERS
            elif not isinstance(obj, _STRUCTURAL):
                if layers == 0:
                    continue
                layers -= 1
            if self._layers.get(id(obj), -1) >= layers:
                continue
            if id(obj) not in self._layers:
                self._alive.append(obj)
                if own:
                    self.reached.setdefault(_type_name(cls), cls)
                    self._render(obj, path, root)
                else:
                    self.foreign_visits += 1
            self._layers[id(obj)] = layers
            stack.extend((child, path + label, layers) for label, child in _children(obj))

    def _render(self, obj: object, path: str, root: str) -> None:
        outs = {
            "repr": repr(obj),
            "str": str(obj),
            "format": format(obj, ""),
            "pformat": pprint.pformat(obj),
            # 폭을 넘치면 pprint 가 다른 분기(데이터클래스·컨테이너 재귀)를 탄다.
            "pformat(width=1)": pprint.pformat(obj, width=1),
        }
        for how, out in outs.items():
            for name, value in self._canaries.items():
                if value not in out:
                    continue
                key = f"{root}|{name}"
                if key in KNOWN_LEAKS:
                    self.known_seen.add(key)
                    continue
                self.leaks.append(
                    f"{path} [{_type_name(type(obj))}] {how}: 비밀 {name} 이 원문으로 찍혔다"
                )


# --- 선언 파생 -----------------------------------------------------------------------------


def _is_trivial(stmt: ast.stmt) -> bool:
    docstring = isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant)
    return docstring or isinstance(stmt, ast.Pass)


class _Declarations(ast.NodeVisitor):
    """클래스 선언(중첩·함수 안 포함), 본문이 docstring 뿐인 선언, 그리고 SDK 소스가 **값으로
    쓰는** 이름을 모은다. 값으로 쓰는 이름은 호출·`raise`·별칭 대입(`_B = Base`)을 모두 덮는다 —
    호출만 세면 `_B = Base; _B()` 가 생성을 숨긴다(Grok 교차검토에서 SILENT 실측). 기반 클래스
    목록과 `except` 절의 타입은 생성이 아니므로 세지 않는다."""

    def __init__(self) -> None:
        self.module = ""
        self._stack: list[str] = []
        self.classes: list[str] = []
        self.trivial: set[str] = set()
        self.used: set[str] = set()

    def visit_ClassDef(self, node: ast.ClassDef) -> None:
        qualname = ".".join([self.module, *self._stack, node.name])
        self.classes.append(qualname)
        if all(_is_trivial(stmt) for stmt in node.body):
            self.trivial.add(qualname)
        for extra in [*node.decorator_list, *node.keywords]:
            self.visit(extra)
        self._stack.append(node.name)
        for stmt in node.body:
            self.visit(stmt)
        self._stack.pop()

    def visit_FunctionDef(self, node: ast.FunctionDef | ast.AsyncFunctionDef) -> None:
        self._stack += [node.name, "<locals>"]
        self.generic_visit(node)
        del self._stack[-2:]

    visit_AsyncFunctionDef = visit_FunctionDef

    def visit_ExceptHandler(self, node: ast.ExceptHandler) -> None:
        for stmt in node.body:
            self.visit(stmt)

    def visit_Name(self, node: ast.Name) -> None:
        if isinstance(node.ctx, ast.Load):
            self.used.add(node.id)

    def visit_Attribute(self, node: ast.Attribute) -> None:
        self.used.add(node.attr)
        self.generic_visit(node)


def _declarations() -> _Declarations:
    """임포트된 `keycloak_sdk` 트리의 선언 전수 — 손 목록이 아니라 트리에서 파생한다."""
    package = Path(keycloak_sdk.__file__).parent
    found = _Declarations()
    for file in sorted(package.rglob("*.py")):
        parts = list(file.relative_to(package.parent).with_suffix("").parts)
        if parts[-1] == "__init__":
            parts.pop()
        found.module = ".".join(parts)
        found.visit(ast.parse(file.read_text(encoding="utf-8"), filename=str(file)))
    return found


def _reconcile(decl: _Declarations, reached: Mapping[str, type]) -> tuple[list[str], list[str]]:
    """(문제, 파생 규칙으로 빠진 선언)."""
    declared = set(decl.classes)
    # 파생 규칙(추상 기반): 본문이 docstring 뿐이라 자기 상태·표현 훅이 없고, SDK 소스가 그 이름을
    # 값으로 쓰지 않아 인스턴스가 생길 수 없으며, 걷기에 닿은 하위 타입이 있다 — 그 하위 타입의
    # 표현이 곧 이 기반의 표현이다(예: KeycloakSdkError).
    bases_of_reached = {_type_name(b) for cls in reached.values() for b in cls.__mro__[1:]}
    problems: list[str] = []
    derived: list[str] = []
    for name in sorted(declared):
        is_reached = name in reached
        exempt = name in EXEMPT
        abstract_base = (
            not is_reached
            and name in bases_of_reached
            and name in decl.trivial
            and name.rsplit(".", 1)[-1] not in decl.used
        )
        if abstract_base:
            derived.append(name)
        if is_reached and exempt:
            problems.append(f"{name}: 걷기에 닿는데 면제 표에도 있다 — 면제를 지워라")
        elif not is_reached and not exempt and not abstract_base:
            problems.append(
                f"{name}: 공개 API 뿌리에서 닿지 않는 선언이다 — 그 타입을 만드는 경로를 뿌리에 "
                "더하거나, 이유와 함께 면제하라"
            )
    problems += [
        f"{name}: 면제 표에 있지만 선언이 없다 — 낡은 면제다"
        for name in sorted(EXEMPT)
        if name not in declared
    ]
    problems += [
        f"{name}: 걷기에 닿은 SDK 타입인데 선언 파생에 없다 — 파생이 트리를 놓친다"
        for name in sorted(reached)
        if name not in declared
    ]
    return problems, derived


# --- 테스트 --------------------------------------------------------------------------------


async def _walk_everything(idp: _Idp, jwts: _Jwts) -> _Walker:
    """sync·aio 뿌리를 만들고 **닫기 전에** 걷는다 — 캐시가 살아 있는 상태가 소비자가 쥔 상태다."""
    with ExitStack() as sync_stack:
        async with AsyncExitStack() as aio_stack:
            sync_roots, sync_dynamic = _sync_roots(idp, jwts, sync_stack)
            aio_roots, aio_dynamic = await _aio_roots(idp, jwts, aio_stack)
            # 요청 본문으로 흘렀는가 — 시크릿·admin 비밀번호는 뿌리 값이 아니라 호출에 실린다.
            assert any(SECRET in body for _, p, body in idp.hits if p.endswith("/token"))
            assert any(PASSWORD in body for m, p, body in idp.hits if m == "POST" and "/users" in p)
            walker = _Walker(
                {
                    "SECRET": SECRET,
                    "ACCESS": ACCESS,
                    "REFRESH": REFRESH,
                    "ID": ID_TOKEN,
                    "GARBAGE": GARBAGE,
                    "PASSWORD": PASSWORD,
                    "JWT": jwts.ok,
                    "JWT_UNKNOWN_KID": jwts.unknown_kid,
                    "JWT_BAD_ISSUER": jwts.bad_issuer,
                    **sync_dynamic,
                    **aio_dynamic,
                }
            )
            for name, obj in [*sync_roots, *aio_roots]:
                walker.walk(obj, name)
    return walker


def test_reachable_objects_do_not_render_secrets() -> None:
    with _fake_idp(b"") as idp:
        # issuer 가 서버 주소를 품으므로 서버가 먼저 뜨고 나서 서명한다.
        idp.jwks, jwts = _sign_jwts(f"{idp.url}/realms/r")
        walker = asyncio.run(_walk_everything(idp, jwts))

    assert not walker.leaks, "기본 표현이 비밀을 찍는다:\n" + "\n".join(walker.leaks)
    stale = sorted(set(KNOWN_LEAKS) - walker.known_seen)
    assert not stale, f"알려진 누출이 더 안 난다 — 고쳐졌으면 KNOWN_LEAKS 에서 지워라: {stale}"

    decl = _declarations()
    assert len(decl.classes) >= 30, f"선언을 거의 못 찾았다 — 파생이 공허하다({decl.classes})"
    problems, derived = _reconcile(decl, walker.reached)
    assert not problems, "\n".join(problems)
    print(
        f"facade-dump: declared={len(decl.classes)} reached={len(walker.reached)} "
        f"derived={derived} exempt={sorted(EXEMPT)} known_leaks={sorted(KNOWN_LEAKS)} "
        f"foreign_transit={walker.foreign_visits}"
    )
    print("reached:", *sorted(walker.reached), sep="\n  ")
