"""적대 경로 행렬 — 공개 호출 경로를 파생해 분류하고, 적대 변형을
**메서드 손 목록이 아니라 계급에** 붙인다(등록부 `guard-detection-surface-hand-narrowed`).
Go 파일럿 `go/hostile_path_matrix_test.go` 의 이식이다.

nonce·콜드캐시 백오프·토큰응답 타입검증 축은 `scripts/test/test-security-defaults.sh` 가
손으로 고른 자리에 앵커를 건다. 그래서 **새 공개 교환 경로**가 생기면 세 축 모두 모른다.
여기서는 경로를 손 목록이 아니라 파생한다:

- 선언 집합: `test_facade_dump.py` 의 뿌리·걷기(`_walk_everything`)가 닿는 SDK 타입마다
  공개 멤버 전부 — 메서드·`async def`·프로퍼티·정적/클래스 메서드, 소스에 선언된
  dunder(`__repr__`·`__exit__`…), 그리고 **생성자**(`T.__init__` 행 = 클래스 호출).
  여기에 공개 모듈의 공개 함수(`keycloak_sdk.mask`)와 소스(`ast`)에 선언된 공개 메서드
  전수를 합친다. 걷기에 안 닿아 부르지 못한 소스 선언은 UNDETERMINED 행이다.
- 호출: 행마다 **새** 기록 IdP 와 **새** 클라이언트(캐시가 옆 행으로 새지 않게).
  sync·aio 둘 다 — 행 하나를 이벤트 루프 하나에서 돌고 코루틴은 거기서 await 한다
  (httpx 풀은 루프에 묶인다). 인자는 타입 힌트만 보고 합성한다(`_Synth`). 행이 SDK 가
  정의한 함수를 돌려주면(팩토리·`__getattr__`) 그것까지 한 번 더 부른다(`_sdk_function`).
  오버로드는 파이썬에 없다(SDK 에 `@overload` 0) — 행은 이름당 하나다.
- 분류: 그 호출이 IdP 에 실제로 보낸 요청으로 가른다(`_classify`) — 경로 **꼬리**로.
  grant_type 은 폼 본문·JSON 본문·쿼리 순으로 읽는다(`_grant_of`).

단언:
  (1) UNDETERMINED 가 없다(면제는 이유와 함께, 낡은 면제는 실패).
  (2) CODE_EXCHANGE·TOKEN_GRANT·JWKS_FETCH 가 각각 비어 있지 않다.
  (W1) 손으로 고른 보안 테스트가 겨누는 메서드(`_hand_table`)가 전부 행이고, 기대
       계급이고, 그 축의 파생 대상이다. 표도 손 목록이라 셋과 대조한다 — 앵커가 정말
       그 이름을 부르는가 · `test_token_response_leaks.py` 호출 표의 공개 이름이 전부
       표에 있는가 · 보안 기본값 가드의 python 행위 앵커가 전부 표의 앵커인가.
  (W3a) TOKEN_GRANT·CODE_EXCHANGE 행마다 형식이 틀린 토큰 응답 변형 — 새로 만들지
       않고 기존 테스트에서 가져온다(`_token_variants`). 칸마다: SDK 예외 타입
       (`keycloak_sdk.exceptions` 에서 파생) · 카나리아가 `traceback.format_exception`
       과 원인 사슬(억제된 `__context__` 까지)의 `str`·`repr` 어디에도 없음 · 토큰
       엔드포인트에 닿음 · 대조보다 많이 묻지 않음 · 그 응답 **뒤로** 요청이 없음.
       nonce 파라미터는 비운다(None) — 「missing id_token」으로 공허하게 통과하지 않게.
  (W3b) CODE_EXCHANGE 행 중 **서명에 nonce 파라미터가 있는** 것(`inspect.signature`
       의 이름으로 파생) — nonce≠ · 다른 키(같은 kid·다른 kid) · id_token 없음 ·
       nonce 클레임 없음. 대조(맞는 id_token)는 성공하고 JWKS 에 닿아야 한다. 거부
       오류는 받은 id_token·입력을 찍지 않는다. nonce 파라미터 없는 CODE_EXCHANGE 행은
       `_NONCE_DROP_EXEMPT` 에 이유가 있어야 빠진다.
  (W3c) 분류 실행에서 JWKS 를 조회한 행마다 콜드 캐시 + /certs 503 에서 k 회 — 전부
       실패, 1 <= /certs <= k-1. 시간이 아니라 요청 수만 잰다.
  (W3d) JWKS_FETCH 행마다 서명 위조 — IdP 키로 서명한 대조는 성공하고, 같은 kid 의
       다른 키로 서명한 토큰은 SDK 예외로 거부된다(Grok 레그가 연 축 — 아래).
  실패한 칸은 `_KNOWN_GAPS` 에 이유와 함께 있으면 GAP 으로 찍히고, 관측되지 않는 항목은
  낡은 것이라 실패한다.

⚠️ Go 와 다른 자리(파이썬이 요구한 것):
  - 공개 표면이 메서드 집합보다 넓다 — 생성자·프로퍼티·클래스/정적 메서드·dunder·
    모듈 함수. 전부 행이다. 생성 중에 요청을 내는 새 타입은 `T.__init__` 행이,
    프로퍼티 게터의 요청은 그 프로퍼티 행이 잡는다.
  - 영값 수신자가 없다 — 빌더(`_BUILDERS`)로 닿지 않는 타입은 **합성 인자로 생성자를
    불러** 만든다. `KeycloakConfig`·`OidcEndpoints`·`KeySet` 은 그 행의 IdP 에 묶인
    값이고, 다른 SDK 타입은 재귀로 생성한다.
  - admin 은 토큰을 스스로 들고 첫 호출에서 받는다 — admin 자원 메서드가 TOKEN_GRANT 다.
  - `httpx.AsyncClient` 하나마다 certifi 번들을 읽는다(0.45초 · Windows 실측). 기록
    IdP 는 평문 HTTP 라 TLS 문맥을 쓰지 않으므로 이 테스트 동안만 문맥을 재사용한다
    (`fast_tls`) — 분류와 무관한 속도 이음매다.

⚠️ Grok 레그(파일 둘 · 계약 인라인)의 주장 여덟 중 넷을 SDK 에 심어 쟀고 넷 다 SILENT
였다 — `__getattr__` 이 돌려준 함수(NONE) · JSON 본문 코드 교환(TOKEN_GRANT 로 읽혀
W3b 밖) · JWKS 적재 뒤 서명 없이 디코드(W3c 통과) · nonce 거부 오류의 id_token 인용.
그래서 두 번째 호출 · `_grant_of` · W3d · W3b/W3c 누출 검사를 뒀다. 나머지 넷은 채택하지
않았다: 요청 없는 값 생성(교환 경로가 아니다 — `TokenSet(...)` 자체가 공개 생성자다) ·
응답과 무관하게 늘 두 번 묻기(대조와 같아 증폭이 아니다) · 측정 칸(브리프 규칙) ·
이 IdP 밖·비동기 요청(아래 한계).

⚠️ 한계(Go 머리 주석과 같은 부류 — 전부 NONE 으로 읽힌다): 기록된 요청도 오류도 없이
끝나는 교환 경로. 합성 인자(1·False·한 원소)나 가짜 IdP 설정이 요청 앞에서 갈라 세우는
것, 스레드·태스크로 내보내고 기다리지 않는 요청(표는 반환 직후 찍힌다), 이 IdP 가 아닌
호스트로 나가 오류를 버리는 것. 수신자 빌더가 **생성하며** 낸 요청은 그 타입의 행이
아니라 생성자 행(`T.__init__`·`create`)의 몫이다.
"""

from __future__ import annotations

import ast
import asyncio
import collections.abc
import contextlib
import functools
import importlib
import inspect
import json
import pkgutil
import re
import threading
import time
import traceback
import types
import typing
from collections.abc import Callable, Iterator, Mapping
from contextlib import contextmanager
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlsplit

import pytest
from joserfc import jwt as jjwt
from joserfc.jwk import KeySet, RSAKey

import keycloak_sdk
from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk import exceptions as sdk_exceptions
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.oidc import OidcEndpoints

from . import test_tokens as tokens_tests
from .test_facade_dump import _fake_idp as _dump_idp
from .test_facade_dump import (
    _is_own,
    _QuietServer,
    _sign_jwts,
    _type_name,
    _walk_everything,
    _Walker,
)
from .test_token_response_leaks import (
    _PREFIX,
    ADMIN,
    CANARIES,
    CC,
    EXCHANGE,
    EXCHANGE_NONCE,
    REFRESH,
    REFRESH_CALL,
    VARIANTS,
    _json,
    _reachable,
)

CODE_EXCHANGE = "CODE_EXCHANGE"
TOKEN_GRANT = "TOKEN_GRANT"
JWKS_FETCH = "JWKS_FETCH"
OTHER = "OTHER"
NONE = "NONE"
UNDETERMINED = "UNDETERMINED"
_CLASSES = (CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH, OTHER, NONE, UNDETERMINED)

_BASE = "/realms/r/protocol/openid-connect"
# 분류는 realm 과 무관하게 **꼬리**로 본다 — 인자로 받은 realm 의 엔드포인트도
# 교환이다(Go 레그 실측: 정확한 경로로 가르면 `/realms/{U}/…/certs` 가 OTHER 였다).
_TOKEN_SUFFIX = "/protocol/openid-connect/token"
_CERTS_SUFFIX = "/protocol/openid-connect/certs"
_HP_SECRET = "HP7s2c9x-matrix-client-secret"
_PKG = "keycloak_sdk."
#: 콜드 캐시 JWKS 칸의 호출 수 — 상한 k-1 이 백오프, 하한 1 이 콜드 경로 도달의 증명이다.
_COLD_K = 5

#: UNDETERMINED 여도 되는 행과 그 이유. ⚠️ **이유 없는 면제는 넣지 않는다.** 선언 집합에
#: 없거나 더는 UNDETERMINED 가 아닌 항목은 낡은 면제로 실패한다.
_UNDETERMINED_EXEMPT: dict[str, str] = {
    "keycloak_sdk.tokens.TokenSet.from_response": (
        "네트워크 없는 파서(tokens.py) — 합성 인자 {U: U} 에 access_token 이 없어 "
        "계약대로 거부한다. 교환 경로에서의 그 계약은 W3a 의 at:* 변형이 계급마다 재고, "
        "W1 이 client_credentials_token → from_response 를 잇는다"
    ),
    "keycloak_sdk._internal.jwt.JwtValidator.validate": (
        "네트워크 없는 검증기(_internal/jwt.py) — KeySet 을 인자로 받고 세션이 없다. "
        "합성 수신자의 issuer·allowed_algs 가 IdP 것이 아니라 거부한다. JWKS 를 치는 "
        "경로는 AuthClient.validate 행(JWKS_FETCH)이다"
    ),
}

#: W3b 에서 빠져도 되는 CODE_EXCHANGE 행과 그 이유. **이유 없는 면제는 넣지 않는다.**
#: nonce 를 다른 이름으로 받는 새 교환 메서드는 이 표가 없으면 조용히 빠진다(Go 레그가
#: 지목하고 실측으로 SILENT 를 확인). 오늘은 비어 있다.
_NONCE_DROP_EXEMPT: dict[str, str] = {}

_SYNC_ADMIN_EMPTY_BEARER = (
    "python-admin-grant-accepts-empty-access-token: sync admin 의 자체 "
    "client_credentials 그랜트가 빈 access_token 을 받아들이고 `Authorization: Bearer ` "
    "로 admin REST 요청을 보낸다 — python-keycloak 의 토큰 세터가 타입·빈 값을 안 보고, "
    "SDK 는 admin 레인에서 그 응답을 검사하지 않는다. aio 는 h11 이 그 헤더 값을 거부해 "
    "우연히 막힌다(`Can't connect to server` 로 잘못 보고된다)"
)

#: 현재 main 에서 실패하는 칸 — 키는 `_Cell.key`(`W3<축> 행/변형`), 값은 `등록부 id: 이유`.
#: SDK 를 고치지 않고 드러내 둔다. 관측되지 않는(이제 통과하거나 칸이 없는) 항목은 낡은
#: 것이라 실패한다. **이유 없는 항목은 넣지 않는다.**
_KNOWN_GAPS: dict[str, str] = {
    f'W3a keycloak_sdk.admin.{module}.{cls}.{method}/at:""': _SYNC_ADMIN_EMPTY_BEARER
    for module, cls, methods in (
        ("clients", "ClientsResource", ("create", "delete", "find_by_client_id", "get", "update")),
        ("groups", "GroupsResource", ("create", "delete", "get", "list", "update")),
        ("realms", "RealmsResource", ("create", "delete", "get", "list", "update")),
        ("roles", "RolesResource", ("create", "delete", "get", "list", "update")),
        ("users", "UsersResource", ("create", "delete", "get", "search", "update")),
    )
    for method in methods
}


# --- 기록하는 가짜 IdP ---------------------------------------------------------------------

_Resp = tuple[int, str, bytes]
#: 토큰 엔드포인트의 응답을 요청 본문(디코드 전 폼)으로 정한다 — `e'` 가 요청을 되돌린다.
_Responder = Callable[[str], _Resp]


@dataclass(frozen=True)
class _Req:
    method: str
    path: str
    grant: str = ""


class _Recorder:
    """모든 요청을 (메서드, 경로, 토큰 요청이면 grant_type) 로 남긴다.

    기록은 라우팅 **앞**이라 라우트가 없는 경로(admin 404 포함)도 남는다 — 분류는 SDK 가
    무엇을 **시도했나**를 본다."""

    def __init__(self, key: RSAKey) -> None:
        self.key = key
        self.url = ""
        self.universal = ""  # 모든 str 인자에 넣는 값 — 이 IdP 키로 서명한 JWS
        self.id_token = ""  # 정상 토큰 응답의 id_token — nonce 가 universal 이다
        self.jwks = json.dumps(KeySet([key]).as_dict(private=False)).encode()
        self.served: list[str] = []  # 변형이 응답에 실은 토큰 — 오류에 찍히면 안 된다(W3b)
        self._lock = threading.Lock()
        self._reqs: list[_Req] = []
        self._token: _Responder | None = None
        self._certs_down = False

    @property
    def issuer(self) -> str:
        return f"{self.url}/realms/r"

    def cfg(self) -> KeycloakConfig:
        return KeycloakConfig(
            server_url=self.url, realm="r", client_id="c", client_secret=_HP_SECRET
        )

    def record(self, req: _Req) -> None:
        with self._lock:
            self._reqs.append(req)

    def reset(self) -> None:
        with self._lock:
            self._reqs.clear()

    def snapshot(self) -> list[_Req]:
        with self._lock:
            return list(self._reqs)

    def set_token(self, responder: _Responder | None) -> None:
        with self._lock:
            self._token = responder

    def set_certs_down(self, down: bool) -> None:
        with self._lock:
            self._certs_down = down

    def answer(self, method: str, path: str, body: str) -> _Resp:
        with self._lock:
            override, down = self._token, self._certs_down
        if method == "POST" and path == f"{_BASE}/token":
            if override is not None:
                return override(body)
            # expires_in 을 skew(30s)보다 짧게 준다 — admin 의 토큰 캐시(수명의 0.9)가 늘
            # 식어 있어 부여에 닿을 수 있는 메서드는 실제로 닿는다(Go 실측: 300 이면
            # TOKEN_GRANT 29→3).
            tokens = {
                "access_token": "hp-access",
                "token_type": "Bearer",
                "expires_in": 1,
                "refresh_token": "hp-refresh",
                "id_token": self.id_token,
                "scope": "openid",
            }
            return _json(200, tokens)
        if method == "POST" and path == f"{_BASE}/token/introspect":
            return _json(200, {"active": True, "username": "svc", "client_id": "c", "sub": "u1"})
        if method == "GET" and path == f"{_BASE}/certs":
            return (
                (503, "application/json", b"{}") if down else (200, "application/json", self.jwks)
            )
        if method == "POST" and path == f"{_BASE}/logout":
            return 204, "application/json", b""
        return _json(404, {})


def _grant_of(body: str, query: str) -> str:
    """토큰 요청의 grant_type — 폼 본문, JSON 본문, 쿼리 문자열 순으로 읽는다.

    ⚠️ 폼만 읽으면 JSON 본문·쿼리로 보낸 코드 교환이 TOKEN_GRANT 로 읽혀 W3b(nonce)를
    조용히 빠져나간다(Grok 레그 지목, 심은 `redeem` 으로 실측 SILENT)."""
    form = parse_qs(body).get("grant_type")
    if form:
        return form[0]
    with contextlib.suppress(ValueError):
        data = json.loads(body)
        if isinstance(data, dict) and isinstance(data.get("grant_type"), str):
            return str(data["grant_type"])
    return parse_qs(query).get("grant_type", [""])[0]


def _handler(rec: _Recorder) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def _serve(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace") if length else ""
            path = urlsplit(self.path).path
            grant = ""
            if self.command == "POST" and path.endswith(_TOKEN_SUFFIX):
                grant = _grant_of(body, urlsplit(self.path).query)
            rec.record(_Req(self.command, path, grant))
            status, content_type, payload = rec.answer(self.command, path, body)
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if payload:
                self.wfile.write(payload)

        do_GET = _serve
        do_POST = _serve
        do_PUT = _serve
        do_DELETE = _serve

    return Handler


def _sign(key: RSAKey, kid: str, issuer: str, extra: Mapping[str, object]) -> str:
    now = int(time.time())
    claims = {"iss": issuer, "sub": "u1", "aud": "c", "iat": now, "exp": now + 300, **extra}
    return jjwt.encode({"alg": "RS256", "kid": kid}, claims, key)


@contextmanager
def _recording_idp(key: RSAKey) -> Iterator[_Recorder]:
    rec = _Recorder(key)
    server = _QuietServer(("127.0.0.1", 0), _handler(rec))
    rec.url = f"http://127.0.0.1:{server.server_address[1]}"
    # ⚠️ 평문이면 토큰을 받는 메서드(validate 둘)가 JWS 파싱에서 요청 없이 실패해
    # UNDETERMINED 가 되고 JWKS_FETCH 가 빈다(Go 실측) — 그래서 이 IdP 키로 서명한 JWS 다.
    rec.universal = _sign(key, "k1", rec.issuer, {})
    rec.id_token = _sign(key, "k1", rec.issuer, {"nonce": rec.universal})
    threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
    try:
        yield rec
    finally:
        server.shutdown()
        server.server_close()


#: 행렬 전체가 쓰는 이벤트 루프 하나(`one_loop` 가 채운다).
_LOOP: dict[str, asyncio.AbstractEventLoop] = {}
_T = typing.TypeVar("_T")


def _run(coro: collections.abc.Coroutine[Any, Any, _T]) -> _T:
    return _LOOP["loop"].run_until_complete(coro)


@pytest.fixture
def one_loop() -> Iterator[None]:
    """⚠️ 칸마다 `asyncio.run` 을 부르지 않는다 — Windows 는 이벤트 루프마다 자기 파이프로
    소켓 쌍을 만들고, 칸 수천 개가 임시 포트를 말리면 그 소켓 쌍의 `accept` 가 영원히
    멈췄다(실측: py-spy 로 `_fallback_socketpair` 의 `accept` 에서 멈춘 주 스레드를 봤다).
    루프 하나를 행렬 전체가 쓴다 — 칸마다 새 클라이언트라는 격리는 그대로다."""
    loop = asyncio.new_event_loop()
    _LOOP["loop"] = loop
    try:
        yield
    finally:
        _LOOP.clear()
        loop.run_until_complete(loop.shutdown_asyncgens())
        loop.close()


@pytest.fixture
def fast_tls(monkeypatch: pytest.MonkeyPatch) -> None:
    """`httpx.AsyncClient` 하나마다 certifi 번들을 읽는다(0.45초) — 행·칸마다 새
    클라이언트라 그대로면 수천 초다. 기록 IdP 는 평문 HTTP 라 TLS 문맥을 쓰지 않는다.
    같은 인자의 문맥을 재사용할 뿐 검증 설정은 그대로다."""
    transport = importlib.import_module("httpx._transports.default")
    original = getattr(transport, "create_ssl_context", None)
    if original is None:  # httpx 가 이음매를 옮겼다 — 느려질 뿐 결과는 같다
        return
    cache: dict[bool, object] = {}

    def cached(verify: object = True, cert: object = None, trust_env: bool = True) -> object:
        if verify is True and cert is None:
            if trust_env not in cache:
                cache[trust_env] = original(verify=verify, cert=cert, trust_env=trust_env)
            return cache[trust_env]
        return original(verify=verify, cert=cert, trust_env=trust_env)

    monkeypatch.setattr(transport, "create_ssl_context", cached)


# --- 선언 집합 -----------------------------------------------------------------------------


@dataclass(frozen=True)
class _Member:
    owner: str  # 타입 이름(`모듈.클래스`) 또는 모듈 이름(모듈 함수)
    name: str
    kind: str  # ctor · method · property · static · class · func
    cls: type | None = None
    func: Callable[..., object] | None = None

    @property
    def label(self) -> str:
        return f"{self.owner}.{self.name}"


@dataclass
class _Source:
    """SDK 소스(`ast`)의 선언 — 손 목록이 아니라 트리에서 파생한다."""

    labels: set[str] = field(default_factory=set)  # 공개 메서드·dunder·__init__·모듈 함수
    dunders: dict[str, set[str]] = field(default_factory=dict)  # 타입 → 선언된 dunder
    nodes: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = field(default_factory=dict)


#: dunder 중 행이 아닌 것 — `__post_init__` 은 생성자가 부른다(생성자 행이 덮는다).
_NOT_ROWS = frozenset({"__post_init__"})


def _public_module(module: str) -> bool:
    return not any(part.startswith("_") for part in module.split(".")[1:])


def _source() -> _Source:
    package = Path(keycloak_sdk.__file__).parent
    out = _Source()
    for file in sorted(package.rglob("*.py")):
        parts = list(file.relative_to(package.parent).with_suffix("").parts)
        if parts[-1] == "__init__":
            parts.pop()
        module = ".".join(parts)
        tree = ast.parse(file.read_text(encoding="utf-8"), filename=str(file))
        for node in tree.body:
            is_func = isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
            if is_func and not node.name.startswith("_") and _public_module(module):
                out.labels.add(f"{module}.{node.name}")
                out.nodes[f"{module}.{node.name}"] = node
            if isinstance(node, ast.ClassDef):
                _source_class(out, module, node)
    return out


def _source_class(out: _Source, prefix: str, node: ast.ClassDef) -> None:
    qual = f"{prefix}.{node.name}"
    for item in node.body:
        if isinstance(item, ast.ClassDef):
            _source_class(out, qual, item)
            continue
        is_func = isinstance(item, (ast.FunctionDef, ast.AsyncFunctionDef))
        if not is_func or item.name in _NOT_ROWS:
            continue
        dunder = item.name.startswith("__") and item.name.endswith("__")
        if dunder and item.name != "__init__":
            out.dunders.setdefault(qual, set()).add(item.name)
        if dunder or not item.name.startswith("_"):
            out.labels.add(f"{qual}.{item.name}")
            out.nodes[f"{qual}.{item.name}"] = item


def _declared_types() -> dict[str, type]:
    """`test_facade_dump.py` 의 뿌리와 걷기 그대로 — 두 번째 걷기를 만들지 않는다."""
    with _dump_idp(b"") as idp:
        idp.jwks, jwts = _sign_jwts(f"{idp.url}/realms/r")
        walker = asyncio.run(_walk_everything(idp, jwts))
    return dict(walker.reached)


def _kind(attr: object) -> str | None:
    if isinstance(attr, property):
        return "property"
    if isinstance(attr, staticmethod):
        return "static"
    if isinstance(attr, classmethod):
        return "class"
    if inspect.isfunction(attr):
        return "method"
    return None


def _members_of(tname: str, cls: type, src: _Source) -> list[_Member]:
    """생성자 행 + MRO 의 공개 멤버(남의 기반 포함 — builtins 만 뺀다). 하위가 덮은 이름은
    하위 것이다."""
    found: dict[str, str] = {}
    for klass in reversed(cls.__mro__):
        if klass.__module__ == "builtins":
            continue
        declared_dunders = src.dunders.get(_type_name(klass), set())
        for name, attr in vars(klass).items():
            if name.startswith("_") and name not in declared_dunders:
                continue
            kind = _kind(attr)
            if kind is not None:
                found[name] = kind
    rows = [_Member(tname, "__init__", "ctor", cls)]
    rows += [_Member(tname, name, kind, cls) for name, kind in sorted(found.items())]
    return rows


def _module_functions() -> list[_Member]:
    """공개 모듈의 공개 함수 — `__all__` 이 있으면 그것, 없으면 그 모듈이 정의한 것
    (다른 모듈에서 임포트한 이름은 표면이 아니다)."""
    modules = [keycloak_sdk]
    for info in pkgutil.walk_packages(keycloak_sdk.__path__, _PKG):
        if _public_module(info.name):
            modules.append(importlib.import_module(info.name))
    rows: dict[str, _Member] = {}
    for mod in modules:
        exported = getattr(mod, "__all__", None)
        names = exported if exported is not None else [n for n in vars(mod) if n[:1] != "_"]
        for name in names:
            obj = getattr(mod, name, None)
            if not inspect.isfunction(obj) or not obj.__module__.startswith("keycloak_sdk"):
                continue
            if exported is None and obj.__module__ != mod.__name__:
                continue
            member = _Member(mod.__name__, name, "func", func=obj)
            rows[member.label] = member
    return [rows[k] for k in sorted(rows)]


def _declared_members(reached: Mapping[str, type], src: _Source) -> list[_Member]:
    out: list[_Member] = []
    for tname, cls in sorted(reached.items()):
        out += _members_of(tname, cls, src)
    return out + _module_functions()


# --- 인자 합성 -------------------------------------------------------------------------------

_UNSET = object()


class _Synth:
    """타입만 보고 인자를 만든다. SDK·IdP 에 묶인 타입(`KeycloakConfig`·`OidcEndpoints`·
    `KeySet`)은 그 행의 IdP 값이고, 다른 SDK 타입은 합성 인자로 생성자를 부른다(깊이 2).
    못 만들면 `_UNSET`."""

    def __init__(self, rec: _Recorder) -> None:
        self._rec = rec

    def value(self, tp: object, depth: int = 0) -> object:
        simple = self._simple(tp)
        if simple is not _UNSET:
            return simple
        origin, args = typing.get_origin(tp), typing.get_args(tp)
        if origin in (typing.Union, types.UnionType):
            for arg in args:
                if arg is not type(None):
                    got = self.value(arg, depth)
                    if got is not _UNSET:
                        return got
            return None
        if origin is tuple:
            if len(args) == 2 and args[1] is Ellipsis:
                return (self.value(args[0], depth),)
            return tuple(self.value(a, depth) for a in args)
        if origin in (list, collections.abc.Sequence):
            return [self.value(args[0] if args else Any, depth)]
        if origin in (dict, collections.abc.Mapping):
            return {self._rec.universal: self.value(args[1] if len(args) > 1 else Any, depth)}
        if isinstance(tp, type) and _is_own(tp) and depth < 2:
            return _construct(tp, self, depth + 1)
        return _UNSET

    def _simple(self, tp: object) -> object:
        if tp is Any or tp is str:
            return self._rec.universal
        table: dict[object, Callable[[], object]] = {
            bool: lambda: False,
            int: lambda: 1,
            float: lambda: 1.0,
            KeycloakConfig: self._rec.cfg,
            OidcEndpoints: lambda: OidcEndpoints.for_realm(self._rec.cfg()),
            KeySet: lambda: KeySet.import_key_set(json.loads(self._rec.jwks)),
        }
        make = table.get(tp)
        return make() if make is not None else _UNSET


def _hints(target: object) -> dict[str, object]:
    fn = getattr(target, "__func__", target)
    try:
        return dict(typing.get_type_hints(fn))
    except Exception:  # 힌트를 못 풀면 Any 로 합성한다(str 자리 값)
        return {}


def _ctor_hints(cls: type) -> dict[str, object]:
    hints = _hints(cls)  # 데이터클래스 필드
    hints.update(_hints(cls.__init__))
    return hints


def _signature(target: Callable[..., object]) -> inspect.Signature | None:
    try:
        return inspect.signature(target)
    except (TypeError, ValueError):
        return None


def _call_args(
    sig: inspect.Signature | None,
    hints: Mapping[str, object],
    synth: _Synth,
    blank: frozenset[str] = frozenset(),
    depth: int = 0,
) -> tuple[list[object], dict[str, object]]:
    """`blank` 의 이름은 None 이다(W3a 가 nonce 를 비운다). 못 만드는 인자는 기본값이
    있으면 기본값, 없으면 None."""
    args: list[object] = []
    kwargs: dict[str, object] = {}
    for p in sig.parameters.values() if sig is not None else ():
        if p.kind in (p.VAR_POSITIONAL, p.VAR_KEYWORD) or p.name == "self":
            continue
        value = None if p.name in blank else synth.value(hints.get(p.name, Any), depth)
        if value is _UNSET:
            if p.default is not p.empty:
                continue
            value = None
        if p.kind is p.POSITIONAL_ONLY:
            args.append(value)
        else:
            kwargs[p.name] = value
    return args, kwargs


def _construct(cls: type, synth: _Synth, depth: int) -> object:
    args, kwargs = _call_args(_signature(cls), _ctor_hints(cls), synth, depth=depth)
    return cls(*args, **kwargs)


def _nonce_params(member: _Member) -> frozenset[str]:
    """이름에 "nonce" 가 든(대소문자 무시) 파라미터 — **이름 목록이 아니라 서명에서**."""
    if member.kind in ("ctor", "property"):
        return frozenset()
    target = member.func if member.kind == "func" else getattr(member.cls, member.name, None)
    sig = _signature(target) if callable(target) else None
    names = sig.parameters if sig is not None else {}
    return frozenset(n for n in names if "nonce" in n.lower())


# --- 수신자 ---------------------------------------------------------------------------------

_RESOURCES = ("users", "clients", "realms", "roles", "groups")


def _sync_roots(cfg: KeycloakConfig) -> dict[str, object]:
    return {"client": KeycloakClient.create(cfg)}


def _sync_admin_roots(cfg: KeycloakConfig) -> dict[str, object]:
    kc = KeycloakClient.create(cfg)
    admin = kc.admin
    resources = {f"admin.{n}": getattr(admin, n) for n in _RESOURCES}
    return {"client": kc, "admin": admin, **resources}


def _aio_roots(cfg: KeycloakConfig) -> dict[str, object]:
    return {"client": AsyncKeycloakClient.create(cfg)}


def _aio_admin_roots(cfg: KeycloakConfig) -> dict[str, object]:
    akc = AsyncKeycloakClient.create(cfg)
    admin = akc.admin
    resources = {f"admin.{n}": getattr(admin, n) for n in _RESOURCES}
    return {"client": akc, "admin": admin, **resources}


#: 수신자를 얻는 공개 API 뿌리 — **덜 데운 것부터**. 타입은 자기를 처음 닿게 하는 빌더의
#: 새 인스턴스에서 불린다. 어느 빌더에도 안 닿는 타입(값·오류·내부 타입)은 합성 인자로
#: 생성자를 불러 만든다.
_BUILDERS: list[tuple[str, Callable[[KeycloakConfig], dict[str, object]]]] = [
    ("create", _sync_roots),
    ("create+admin", _sync_admin_roots),
    ("aio.create", _aio_roots),
    ("aio.create+admin", _aio_admin_roots),
]


class _Found(Exception):
    def __init__(self, obj: object) -> None:
        super().__init__()
        self.obj = obj


class _InstanceWalker(_Walker):
    """`test_facade_dump.py` 의 걷기를 그대로 쓰되 찍지 않고 인스턴스를 모은다(`want` 가
    있으면 찾는 즉시 멈춘다)."""

    def __init__(self, want: str | None = None) -> None:
        super().__init__({})
        self.want = want
        self.instances: dict[str, object] = {}

    def _render(self, obj: object, path: str, root: str) -> None:
        name = _type_name(type(obj))
        if name == self.want:
            raise _Found(obj)
        self.instances.setdefault(name, obj)


def _instances(roots: Mapping[str, object]) -> dict[str, object]:
    walker = _InstanceWalker()
    for name in sorted(roots):
        walker.walk(roots[name], name)
    return walker.instances


def _find(root: object, want: str) -> object | None:
    try:
        _InstanceWalker(want).walk(root, "root")
    except _Found as found:
        return found.obj
    return None


async def _close(*objs: object) -> None:
    """정리 실패는 분류와 무관하다(요청은 이미 찍었다)."""
    for obj in objs:
        if obj is None or not _is_own(type(obj)):
            continue
        aclose, close = getattr(obj, "aclose", None), getattr(obj, "close", None)
        with contextlib.suppress(Exception):
            if callable(aclose):
                await aclose()
            elif callable(close):
                close()


def _probe_builders(key: RSAKey) -> dict[str, tuple[int, str]]:
    """타입마다 처음 닿게 하는 (빌더, 뿌리) — 버리는 IdP 위에서 빌더마다 한 번씩 걷는다."""
    out: dict[str, tuple[int, str]] = {}

    async def probe(rec: _Recorder) -> None:
        for i, (_, build) in enumerate(_BUILDERS):
            roots = build(rec.cfg())
            for root in sorted(roots):
                for tname in _instances({root: roots[root]}):
                    out.setdefault(tname, (i, root))
            await _close(roots["client"])

    with _recording_idp(key) as rec:
        _run(probe(rec))
    return out


@dataclass
class _Target:
    recv: object | None
    source: str
    roots: dict[str, object]


def _receiver(
    rec: _Recorder, member: _Member, builder_of: Mapping[str, tuple[int, str]], synth: _Synth
) -> _Target:
    if member.kind in ("ctor", "func", "static", "class"):
        return _Target(None, "-", {})
    where = builder_of.get(member.owner)
    if where is None:
        assert member.cls is not None
        try:
            return _Target(_construct(member.cls, synth, 1), "ctor", {})
        except Exception as exc:  # 못 만들면 부르지 못한다 — UNDETERMINED 로 드러난다
            return _Target(None, f"없음({type(exc).__name__})", {})
    name, build = _BUILDERS[where[0]]
    roots = build(rec.cfg())
    recv = _find(roots[where[1]], member.owner)
    assert recv is not None, f"{member.label}: 빌더 {name} 가 탐침 때는 닿았는데 지금은 안 닿는다"
    return _Target(recv, name, roots)


async def _invoke(
    member: _Member, target: _Target, synth: _Synth, blank: frozenset[str] = frozenset()
) -> tuple[BaseException | None, object]:
    try:
        if member.kind == "property":
            result = getattr(target.recv, member.name)
        else:
            if member.kind == "ctor":
                assert member.cls is not None
                fn: Callable[..., object] = member.cls
                sig, hints = _signature(member.cls), _ctor_hints(member.cls)
            elif member.kind == "func":
                assert member.func is not None
                fn = member.func
                sig, hints = _signature(fn), _hints(fn)
            else:
                holder = target.recv if member.kind == "method" else member.cls
                fn = getattr(holder, member.name)
                sig, hints = _signature(fn), _hints(fn)
            args, kwargs = _call_args(sig, hints, synth, blank)
            result = fn(*args, **kwargs)
        if inspect.isawaitable(result):
            result = await result
        # 한 번 더 — 행이 SDK 가 정의한 함수를 돌려주면(팩토리·`__getattr__`) 그것이 소비자가
        # 실제로 부르는 경로다. 부르지 않으면 그 행은 NONE 으로 읽힌다(Grok 레그 지목, 심은
        # `__getattr__` 로 실측 SILENT). 그 요청은 이 행의 몫이다.
        hop = _sdk_function(result)
        if hop is not None:
            args, kwargs = _call_args(_signature(hop), _hints(hop), synth, blank)
            result = hop(*args, **kwargs)
            if inspect.isawaitable(result):
                result = await result
    except Exception as exc:
        return exc, None
    return None, result


def _sdk_function(obj: object) -> Callable[..., object] | None:
    """SDK 모듈이 정의한 함수·메서드·partial 이면 그것(클래스·남의 함수는 아니다)."""
    # ⚠️ `getattr(obj, "__func__")` 로 벗기지 않는다 — `__getattr__` 을 가진 SDK 객체가 그
    # 탐침에 함수를 돌려줘 객체 자체를 부르게 된다(심은 `__getattr__` 으로 실측).
    fn = obj.func if isinstance(obj, functools.partial) else obj
    fn = fn.__func__ if inspect.ismethod(fn) else fn
    if inspect.isfunction(fn) and fn.__module__.startswith("keycloak_sdk"):
        return typing.cast(Callable[..., object], obj)
    return None


# --- 분류 -----------------------------------------------------------------------------------


def _is_token_post(r: _Req) -> bool:
    return r.method == "POST" and r.path.endswith(_TOKEN_SUFFIX)


def _is_certs_get(r: _Req) -> bool:
    return r.method == "GET" and r.path.endswith(_CERTS_SUFFIX)


def _classify(sent: list[_Req], failed: bool) -> str:
    """앞 줄이 이긴다: 코드 교환 > 토큰 부여 > JWKS 조회 > 그 밖의 요청 > 요청 없음.

    ⚠️ 토큰 POST 는 grant_type 이 무엇이든 TOKEN_GRANT 다 — 새 grant(password·
    token-exchange…)가 OTHER 로 새지 않게. grant 는 표의 요청 열에 그대로 찍힌다."""
    if any(_is_token_post(r) and r.grant == "authorization_code" for r in sent):
        return CODE_EXCHANGE
    if any(_is_token_post(r) for r in sent):
        return TOKEN_GRANT
    if any(_is_certs_get(r) for r in sent):
        return JWKS_FETCH
    if sent:
        return OTHER
    return UNDETERMINED if failed else NONE


def _format(sent: list[_Req], universal: str = "") -> str:
    if not sent:
        return "-"
    count: dict[str, int] = {}
    for r in sent:
        path = r.path.removeprefix(_BASE)
        if universal:
            path = path.replace(universal, "{U}")
        k = f"{r.method} {path}" + (f"[{r.grant}]" if r.grant else "")
        count[k] = count.get(k, 0) + 1
    return ", ".join(k if n == 1 else f"{k} x{n}" for k, n in count.items())


def _short(label: str) -> str:
    return label.removeprefix(_PKG)


@dataclass
class _Row:
    label: str
    klass: str
    reqs: str
    recv: str
    outcome: str
    note: str = ""
    sent: list[_Req] = field(default_factory=list)


def _run_row(key: RSAKey, member: _Member, builder_of: Mapping[str, tuple[int, str]]) -> _Row:
    async def go(rec: _Recorder) -> tuple[BaseException | None, list[_Req], str]:
        synth = _Synth(rec)
        target = _receiver(rec, member, builder_of, synth)
        rec.reset()  # 뿌리를 만들며 나간 요청은 이 행의 몫이 아니다
        err: BaseException | None
        result: object = None
        if target.recv is None and member.kind in ("method", "property"):
            err = RuntimeError(f"수신자 없음: {target.source}")
        else:
            err, result = await _invoke(member, target, synth)
        sent = rec.snapshot()
        await _close(target.roots.get("client"), result)
        return err, sent, target.source

    with _recording_idp(key) as rec:
        err, sent, source = _run(go(rec))
        universal = rec.universal
    klass = _classify(sent, failed=err is not None)
    outcome = "ok" if err is None else f"err {type(err).__name__}"
    note = ""
    if klass == UNDETERMINED and err is not None:
        note = f" · {type(err).__name__}: {str(err)[:120]}"
    return _Row(member.label, klass, _format(sent, universal), source, outcome, note, sent)


def _unreached_rows(src: _Source, by_label: Mapping[str, _Row]) -> list[_Row]:
    """소스에는 있는데 걷기가 안 닿아 부르지 못한 선언 — 분류할 수 없으니 UNDETERMINED."""
    note = (
        " · 걷기가 닿지 않는 선언이라 수신자가 없다(test_facade_dump.py 의 뿌리에 "
        "닿게 하거나 이유와 함께 면제하라)"
    )
    return [
        _Row(label, UNDETERMINED, "-", "없음", "-", note)
        for label in sorted(src.labels)
        if label not in by_label
    ]


def _log_table(rows: list[_Row], called: int) -> dict[str, int]:
    counts = dict.fromkeys(_CLASSES, 0)
    print(
        f"\n선언 집합 {len(rows)} 행(부른 것 {called} + 소스에만 있는 것 {len(rows) - called})"
        f" — 경로의 {_BASE} 는 생략, {{U}} 는 보편 인자(서명된 JWS), 라벨의 {_PKG} 생략"
    )
    for r in rows:
        counts[r.klass] += 1
        where = f"[수신자 {r.recv} · {r.outcome}]"
        print(f"{_short(r.label):<58} → {r.klass:<13} · {r.reqs}  {where}{r.note}")
    print("계급별: " + " · ".join(f"{c} {counts[c]}" for c in _CLASSES))
    return counts


# --- W3: 계급별 적대 변형 ------------------------------------------------------------------

_SDK_ERRORS = frozenset(
    v
    for v in vars(sdk_exceptions).values()
    if isinstance(v, type)
    and issubclass(v, BaseException)
    and v.__module__ == sdk_exceptions.__name__
)


def _is_sdk_error(err: BaseException) -> bool:
    """반환 예외 **자체**가 `keycloak_sdk.exceptions` 의 타입인가(하위 오류는 경계에서
    변환된다 — §4)."""
    return type(err) in _SDK_ERRORS


@dataclass(frozen=True)
class _Variant:
    code: str
    source: str  # 단언의 출처 — 비면 측정만 한다
    respond: _Responder


def _token_json(fields: Mapping[str, object]) -> _Responder:
    return lambda _body: _json(200, dict(fields))


def _dedupe(code: str, taken: set[str]) -> str:
    out, n = code, 1
    while out in taken:
        n += 1
        out = f"{code}.{n}"
    taken.add(out)
    return out


def _param_values(test: Callable[..., object]) -> list[object]:
    """`@pytest.mark.parametrize` 의 값 — 손 테스트의 표를 그대로 읽는다(사본을 안 둔다)."""
    marks = [m for m in getattr(test, "pytestmark", []) if m.name == "parametrize"]
    assert marks, f"{test.__name__}: parametrize 표를 못 읽었다"
    return list(marks[0].args[1])


#: `test_token_response_leaks.py` 의 호출 중 토큰 엔드포인트를 치는 것 — 변형이 이 전부에
#: 실패로 단언돼야 가져온다.
_TOKEN_CALLS = frozenset({CC, EXCHANGE, EXCHANGE_NONCE, REFRESH_CALL, ADMIN})


def _token_variants() -> tuple[list[_Variant], list[str]]:
    """변형 집합을 새로 만들지 않고 기존 테스트에서 가져온다.

    - `test_token_response_leaks.py` 의 `VARIANTS` 중 토큰 호출 전부(`_TOKEN_CALLS`)에
      실패가 단언된 것.
    - `test_tokens.py` 의 access_token 표(`test_non_string_access_token_is_rejected` 의
      값과 `test_missing_access_token_is_an_sdk_error`) — 보안 기본값 가드 축 1c 의
      교차언어 불변식이라 계급 전부에 단언한다(Go 의 `ccAccessTokenCases` 와 같다).
    - `test_tokens.py` 의 다른 필드 표(refresh_token·id_token·token_type·scope·
      expires_in) — `TokenSet` 파서의 계약이지 계급의 계약이 아니다(admin 레인은 그
      파서를 안 탄다). **측정만** 한다.

    ⚠️ 공허 함정: 이 본문들엔 쓸 수 있는 id_token 이 없다. nonce 를 준 교환은 정상
    응답이어도 「missing id_token」으로 실패해 적대 응답이 안 닿아도 통과한다 — 그래서
    W3a 는 nonce 파라미터를 비운다.
    """
    out: list[_Variant] = []
    skipped: list[str] = []
    taken: set[str] = set()
    for name, v in VARIANTS.items():
        head = name.split()[0]
        if not v.fails >= _TOKEN_CALLS:
            skipped.append(f"{head}(토큰 호출 전부에 단언되지 않는다)")
            continue
        code = _dedupe(head, taken)
        out.append(_Variant(code, f"test_token_response_leaks.py VARIANTS[{name!r}]", v.respond))
    base = {"token_type": "Bearer", "expires_in": 300, "refresh_token": REFRESH}
    for bad in _param_values(tokens_tests.test_non_string_access_token_is_rejected):
        code = _dedupe(f"at:{json.dumps(bad)}", taken)
        src = f"test_tokens.py test_non_string_access_token_is_rejected[{bad!r}]"
        out.append(_Variant(code, src, _token_json({"access_token": bad, **base})))
    src = "test_tokens.py test_missing_access_token_is_an_sdk_error"
    out.append(_Variant(_dedupe("at:missing", taken), src, _token_json(base)))
    fields = tokens_tests.test_wrong_typed_field_is_rejected_by_name_only
    expires = tokens_tests.test_unusable_expires_in_is_rejected_without_quoting_it
    measured = [
        *(tuple(pair) for pair in _param_values(fields)),
        *(("expires_in", bad) for bad in _param_values(expires)),
    ]
    for name, bad in measured:
        code = _dedupe(f"m:{name}:{type(bad).__name__}", taken)
        body = {"access_token": "hp-access", **base, str(name): bad}
        out.append(_Variant(code, "", _token_json(body)))
    return out, skipped


#: W3a 대조 — 변형들과 같은 모양(id_token 없음)의 쓸 수 있는 토큰 응답이다.
_WELL_FORMED = _token_json(
    {
        "access_token": "hp-access",
        "token_type": "Bearer",
        "expires_in": 300,
        "refresh_token": "hp-refresh",
    }
)


@dataclass
class _Cell:
    axis: str
    label: str
    variant: str
    why: list[str] = field(default_factory=list)
    measure: bool = False
    note: str = ""

    @property
    def key(self) -> str:
        return f"W3{self.axis} {self.label}/{self.variant}"


async def _cell_async(
    rec: _Recorder,
    member: _Member,
    builder_of: Mapping[str, tuple[int, str]],
    blank: frozenset[str],
    responder: _Responder | None,
) -> tuple[list[_Req], BaseException | None]:
    synth = _Synth(rec)
    target = _receiver(rec, member, builder_of, synth)
    rec.reset()
    rec.set_token(responder)  # 수신자를 만든 **뒤에** 건다
    err, result = await _invoke(member, target, synth, blank)
    sent = rec.snapshot()
    await _close(target.roots.get("client"), result)
    return sent, err


def _cell(
    key: RSAKey,
    member: _Member,
    builder_of: Mapping[str, tuple[int, str]],
    blank: frozenset[str],
    make: Callable[[_Recorder], _Responder | None],
) -> tuple[list[_Req], BaseException | None, _Recorder]:
    with _recording_idp(key) as rec:
        sent, err = _run(_cell_async(rec, member, builder_of, blank, make(rec)))
        return sent, err, rec


def _after_token(sent: list[_Req]) -> tuple[int, list[_Req]]:
    """토큰 엔드포인트 요청 수와, 첫 토큰 요청 **뒤에** 나간 토큰 아닌 요청."""
    hits, after = 0, []
    for r in sent:
        if _is_token_post(r):
            hits += 1
        elif hits:
            after.append(r)
    return hits, after


def _renders(err: BaseException) -> dict[str, str]:
    """`logging.exception` 이 찍는 것(사슬 포함)과, 사슬(억제된 `__context__` 까지)의
    예외마다 `str`·`repr`."""
    out = {"traceback": "".join(traceback.format_exception(err))}
    for i, e in enumerate(_reachable(err)):
        out[f"chain[{i}].str"] = str(e)
        out[f"chain[{i}].repr"] = repr(e)
    return out


def _leaks(err: BaseException, rec: _Recorder) -> list[str]:
    """카나리아(앞 10 자까지)와, 요청이 실은 입력(보편 인자 — code·refresh·verifier·nonce)·
    변형이 응답에 실은 토큰(JWS 머리는 흔하니 전체만)이 오류 렌더링에 없는가."""
    canaries = {**CANARIES, "HP_SECRET": _HP_SECRET, "VX8": tokens_tests._CANARY}
    whole = {"보편 인자": rec.universal, **{f"응답 토큰 {i}": t for i, t in enumerate(rec.served)}}
    found = []
    for how, out in sorted(_renders(err).items()):
        for name, value in canaries.items():
            if value in out:
                found.append(f"카나리아 {name} 가 {how} 에 찍혔다")
            elif value[:_PREFIX] in out:
                found.append(f"카나리아 {name} 의 앞 {_PREFIX} 자가 {how} 에 찍혔다")
        found += [f"{name} 이 {how} 에 찍혔다" for name, v in whole.items() if v and v in out]
    return found


def _hostile_why(
    sent: list[_Req], err: BaseException | None, rec: _Recorder, ctl_hits: int
) -> list[str]:
    why: list[str] = []
    if err is None:
        why.append("오류 없이 성공했다")
    else:
        if not _is_sdk_error(err):
            why.append(f"SDK 예외 타입이 아니다: {type(err).__module__}.{type(err).__qualname__}")
        why += _leaks(err, rec)
    hits, after = _after_token(sent)
    if hits == 0:
        why.append("토큰 엔드포인트에 한 번도 안 닿았다 — 변형이 공허하다")
    # 상한은 손 상수가 아니라 같은 행의 대조다 — 틀린 응답마다 재시도하는 새 메서드를
    # 잡는다(Go 레그 지목, 실측 SILENT).
    if hits > ctl_hits:
        why.append(
            f"토큰 요청 {hits} 건 — 정상 응답 대조({ctl_hits} 건)보다 많다: "
            "틀린 응답이 재시도를 부른다"
        )
    if after:
        why.append(f"적대 토큰 응답 뒤로 나아갔다: {_format(after, rec.universal)}")
    return why


def _control_a(
    key: RSAKey, member: _Member, builder_of: Mapping[str, tuple[int, str]], label: str
) -> tuple[_Cell, int]:
    """대조 — 변형과 **같은 모양의** 정상 응답(id_token 없음). 성공하면 「오류다」가,
    토큰 뒤로 나아가면(admin 자원 → 404) 「뒤로 안 나아갔다」가 무게를 진다. 둘 다
    아니면 행 전체가 공허하다."""
    blank = _nonce_params(member)
    sent, err, _ = _cell(key, member, builder_of, blank, lambda _rec: _WELL_FORMED)
    hits, after = _after_token(sent)
    ctl = _Cell("a", label, "대조")
    if hits == 0:
        ctl.why.append("정상 응답에서 토큰 엔드포인트에 안 닿았다 — 이 행의 변형은 공허하다")
    elif err is not None and not after:
        ctl.why.append(
            "정상 응답에 실패했고 토큰 뒤로 나아가지도 않았다 — 변형이 무엇을 바꿨는지 "
            f"가를 수 없다: {err!r}"
        )
    ctl.note = "ok" if err is None else f"↓{len(after)}"
    return ctl, hits


def _const_responder(respond: _Responder) -> Callable[[_Recorder], _Responder]:
    return lambda _rec: respond


def _run_variants_a(
    key: RSAKey,
    members: Mapping[str, _Member],
    builder_of: Mapping[str, tuple[int, str]],
    labels: list[str],
) -> list[_Cell]:
    variants, skipped = _token_variants()
    n_measured = sum(1 for v in variants if not v.source)
    print(
        f"\n(a) 토큰응답 형식 변형 {len(variants)}(측정만 {n_measured} 포함) — "
        f"기존 테스트에서 파생 · 뺀 것: {', '.join(skipped)}"
    )
    for v in variants:
        print(f"    {v.code:<22} ← {v.source or '(측정만)'}")
    cells: list[_Cell] = []
    for label in labels:
        member = members[label]
        blank = _nonce_params(member)
        ctl, ctl_hits = _control_a(key, member, builder_of, label)
        cells.append(ctl)
        for v in variants:
            make = _const_responder(v.respond)
            sent, err, rec = _cell(key, member, builder_of, blank, make)
            cell = _Cell("a", label, v.code, measure=not v.source)
            cell.why = _hostile_why(sent, err, rec, ctl_hits)
            if cell.measure:
                cell.note = type(err).__name__ if err is not None else "성공"
            cells.append(cell)
    return cells


#: W3b 의 변형 — 대조와 다섯. 다른 키로 서명할 때 kid 가 k1 이면 캐시된 키로 서명 검증이
#: 실패하고, k2 면 키를 못 찾아 강제 재조회까지 간다.
#: (code, kid, 다른 키, 클레임(None → {"nonce": 보편 인자}), id_token 없음, 기대)
_NONCE_VARIANTS: list[tuple[str, str, bool, dict[str, object] | None, bool, str]] = [
    ("대조", "k1", False, None, False, "ok"),
    ("nonce≠", "k1", False, {"nonce": "hp-other-nonce"}, False, "reject"),
    ("key≠·kid=k1", "k1", True, None, False, "reject"),
    ("key≠·kid=k2", "k2", True, None, False, "reject"),
    ("id_token없음", "", False, None, True, "reject"),
    ("nonce클레임없음", "k1", False, {}, False, "reject"),
]


def _nonce_responder(
    other: RSAKey, kid: str, other_key: bool, claims: dict[str, object] | None, no_id: bool
) -> Callable[[_Recorder], _Responder]:
    def make(rec: _Recorder) -> _Responder:
        body: dict[str, object] = {
            "access_token": "hp-access",
            "token_type": "Bearer",
            "expires_in": 300,
            "refresh_token": "hp-refresh",
        }
        if not no_id:
            signer = other if other_key else rec.key
            extra = claims if claims is not None else {"nonce": rec.universal}
            body["id_token"] = _sign(signer, kid, rec.issuer, extra)
            rec.served.append(str(body["id_token"]))
        return _token_json(body)

    return make


def _nonce_why(
    sent: list[_Req], err: BaseException | None, rec: _Recorder, no_id: bool, want: str
) -> list[str]:
    # 거부 오류도 찍는 길이다 — nonce 대조가 id_token 을 인용하면 W3a 는 못 본다(nonce 를
    # 비우므로). Grok 레그 지목, 심은 인용으로 실측 SILENT.
    why: list[str] = _leaks(err, rec) if err is not None else []
    if not any(_is_token_post(r) for r in sent):
        why.append("토큰 엔드포인트에 안 닿았다 — 변형이 공허하다")
    # id_token 이 있는 변형은 검증기에 닿아야 한다(콜드 캐시라 JWKS 를 조회한다).
    if not no_id and not any(_is_certs_get(r) for r in sent):
        why.append("JWKS 를 조회하지 않았다 — id_token 이 검증기에 닿지 않았다")
    if want == "ok" and err is not None:
        why.append(f"맞는 id_token 에 실패했다 — 변형의 실패가 아무것도 증명 못 한다: {err!r}")
    elif want != "ok" and err is None:
        why.append("틀린 id_token 을 받아들였다")
    elif want != "ok" and err is not None and not _is_sdk_error(err):
        why.append(f"SDK 예외 타입이 아니다: {type(err).__qualname__}")
    return why


def _run_nonce_b(
    key: RSAKey,
    members: Mapping[str, _Member],
    builder_of: Mapping[str, tuple[int, str]],
    labels: list[str],
) -> list[_Cell]:
    other = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig", "alg": "RS256"})
    names = [f"{_short(lb)}{sorted(_nonce_params(members[lb]))}" for lb in labels]
    print(f"\n(b) nonce 대상(서명에서 파생 — 파라미터 이름): {', '.join(names) or '없음'}")
    cells: list[_Cell] = []
    for label in labels:
        for code, kid, other_key, claims, no_id, want in _NONCE_VARIANTS:
            make = _nonce_responder(other, kid, other_key, claims, no_id)
            sent, err, rec = _cell(key, members[label], builder_of, frozenset(), make)
            certs = sum(1 for r in sent if _is_certs_get(r))
            cell = _Cell("b", label, code, note=f"certs {certs}")
            cell.why = _nonce_why(sent, err, rec, no_id, want)
            cells.append(cell)
    return cells


async def _cold_calls(
    rec: _Recorder, member: _Member, builder_of: Mapping[str, tuple[int, str]]
) -> list[BaseException | None]:
    synth = _Synth(rec)
    target = _receiver(rec, member, builder_of, synth)  # 새 클라이언트 — 캐시가 비어 있다
    rec.reset()
    rec.set_certs_down(True)
    errors = []
    for _ in range(_COLD_K):
        err, _result = await _invoke(member, target, synth)
        errors.append(err)
    await _close(target.roots.get("client"))
    return errors


def _run_cold_c(
    key: RSAKey,
    members: Mapping[str, _Member],
    builder_of: Mapping[str, tuple[int, str]],
    labels: list[str],
) -> list[_Cell]:
    names = ", ".join(map(_short, labels))
    print(f"\n(c) 콜드 캐시 JWKS 대상(분류 실행이 /certs 를 조회한 행): {names}")
    cells: list[_Cell] = []
    for label in labels:
        with _recording_idp(key) as rec:
            errors = _run(_cold_calls(rec, members[label], builder_of))
            hits = sum(1 for r in rec.snapshot() if _is_certs_get(r))
        cell = _Cell("c", label, f"503x{_COLD_K}", note=f"certs {hits}")
        for i, err in enumerate(errors, 1):
            if err is None:
                cell.why.append(f"{i}번째 호출이 JWKS 503 인데 성공했다")
                continue
            if not _is_sdk_error(err):
                cell.why.append(
                    f"{i}번째 호출의 오류가 SDK 예외가 아니다: {type(err).__qualname__}"
                )
            cell.why += [f"{i}번째 호출: {w}" for w in _leaks(err, rec)]
        if hits < 1:
            cell.why.append(f"/certs 요청 {hits} — 콜드 경로에 닿지 않았다(하한 1)")
        if hits > _COLD_K - 1:
            cell.why.append(
                f"/certs 요청 {hits} — 실패한 조회가 물러서지 않았다(상한 {_COLD_K - 1})"
            )
        cells.append(cell)
    return cells


def _forged_why(
    sent: list[_Req], err: BaseException | None, rec: _Recorder, forged: bool
) -> list[str]:
    why: list[str] = []
    if not any(_is_certs_get(r) for r in sent):
        why.append("JWKS 를 조회하지 않았다 — 토큰이 검증기에 닿지 않았다")
    if not forged and err is not None:
        why.append(f"IdP 키로 서명한 토큰에 실패했다 — 위조 칸이 아무것도 증명 못 한다: {err!r}")
    elif forged and err is None:
        why.append("다른 키로 서명한 토큰을 받아들였다 — 서명을 검증하지 않는다")
    elif forged and err is not None:
        if not _is_sdk_error(err):
            why.append(f"SDK 예외 타입이 아니다: {type(err).__qualname__}")
        why += _leaks(err, rec)
    return why


def _run_forged_d(
    key: RSAKey,
    members: Mapping[str, _Member],
    builder_of: Mapping[str, tuple[int, str]],
    labels: list[str],
) -> list[_Cell]:
    """(d) JWKS_FETCH 행 — JWKS 를 치고도 서명을 안 보는 새 메서드는 (c) 만으로는 통과한다
    (503 에서는 실패하므로). 대조(IdP 키로 서명한 보편 인자)는 성공하고, 같은 kid 의 다른
    키로 서명한 보편 인자는 SDK 예외로 거부돼야 한다. 그 계약은
    `test_signature_forgery_does_not_refetch_jwks`(sync·aio)가 단언한다 — Grok 레그 지목,
    심은 `peek`(JWKS 적재 뒤 서명 없이 디코드)로 실측 SILENT."""
    other = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig", "alg": "RS256"})
    print(f"\n(d) 서명 위조 대상(분류가 JWKS_FETCH 인 행): {', '.join(map(_short, labels))}")
    cells: list[_Cell] = []
    for label in labels:
        for code, forged in (("대조", False), ("key≠·kid=k1", True)):
            with _recording_idp(key) as rec:
                if forged:
                    rec.universal = _sign(other, "k1", rec.issuer, {})
                sent, err = _run(_cell_async(rec, members[label], builder_of, frozenset(), None))
            certs = sum(1 for r in sent if _is_certs_get(r))
            cell = _Cell("d", label, code, note=f"certs {certs}")
            cell.why = _forged_why(sent, err, rec, forged)
            cells.append(cell)
    return cells


def _verdicts(cells: list[_Cell]) -> tuple[dict[str, str], list[str], set[str]]:
    verdict: dict[str, str] = {}
    fails: list[str] = []
    observed: set[str] = set()
    for c in cells:
        v = "pass"
        if c.measure:
            v = "m:ACC" if c.why else "m:rej"
        elif c.why and c.key in _KNOWN_GAPS:
            v = "GAP"
            observed.add(c.key)
        elif c.why:
            v = "FAIL"
            fails.append(f"{c.key}: {' · '.join(c.why)}")
        if c.note and (c.axis != "a" or c.variant == "대조"):
            v += f"({c.note})"
        verdict[c.key] = v
    return verdict, fails, observed


def _judge(cells: list[_Cell]) -> tuple[list[str], list[str]]:
    """칸마다 pass·GAP·FAIL 을 정하고 판정표를 찍는다. (실패 사유, 요약 줄) — 둘 다 표
    **뒤에** 찍힌다(변이 실행은 출력 꼬리를 본다)."""
    verdict, fails, observed = _verdicts(cells)
    for axis in ("a", "b", "c", "d"):
        _log_verdicts(axis, cells, verdict)
    measured: dict[str, tuple[list[str], list[str]]] = {}
    for c in cells:
        if not c.measure:
            continue
        rejected, accepted = measured.setdefault(f"W3{c.axis} {c.variant}", ([], []))
        if c.why:
            accepted.append(f"{_short(c.label)}({' · '.join(c.why)})")
        else:
            rejected.append(c.note)
    for k, (rejected, accepted) in measured.items():
        example = f" 예: {accepted[0]}" if accepted else ""
        print(
            f"측정(단언 안 함) {k} — 거부 {len(rejected)} · 받아들임 {len(accepted)} · "
            f"거부 오류 {sorted(set(rejected))}{example}"
        )
    fails += [
        f"_KNOWN_GAPS[{k}]: 더는 관측되지 않는다 — 낡은 항목을 지워라({reason})"
        for k, reason in sorted(_KNOWN_GAPS.items())
        if k not in observed
    ]
    summaries = []
    for axis in ("a", "b", "c", "d"):
        n: dict[str, int] = {}
        by_col: dict[str, int] = {}
        for c in cells:
            if c.axis != axis:
                continue
            v = verdict[c.key].split("(", 1)[0]
            n[v] = n.get(v, 0) + 1
            if v in ("FAIL", "GAP"):
                by_col[f"{v}:{c.variant}"] = by_col.get(f"{v}:{c.variant}", 0) + 1
        rej, acc = n.get("m:rej", 0), n.get("m:ACC", 0)
        summaries.append(
            f"W3{axis} 요약: pass {n.get('pass', 0)} · GAP {n.get('GAP', 0)} · "
            f"FAIL {n.get('FAIL', 0)} · 측정 {rej + acc}(m:rej {rej} · m:ACC {acc}) · "
            f"열 {by_col}"
        )
    return fails, summaries


def _log_verdicts(axis: str, cells: list[_Cell], verdict: Mapping[str, str]) -> None:
    labels = list(dict.fromkeys(c.label for c in cells if c.axis == axis))
    cols = list(dict.fromkeys(c.variant for c in cells if c.axis == axis))
    if not labels:
        print(f"\nW3{axis} 판정표: 대상 행이 없다")
        return

    def cell(lb: str, col: str) -> str:
        return verdict.get(f"W3{axis} {lb}/{col}", "")

    width = [max(len(col), *(len(cell(lb, col)) for lb in labels)) for col in cols]
    print(
        f"\nW3{axis} 판정표 — {len(labels)}행 x {len(cols)}열 "
        "(pass · GAP=알려진 틈 · FAIL · m:rej/m:ACC=측정만: 거부/받아들임)"
    )
    head = " ".join(c.ljust(w) for c, w in zip(cols, width, strict=True))
    print(f"{'행 / 변형':<58} {head}".rstrip())
    for lb in labels:
        vals = " ".join(cell(lb, c).ljust(w) for c, w in zip(cols, width, strict=True))
        print(f"{_short(lb):<58} {vals}".rstrip())


# --- W1: 손 목록 포함 -----------------------------------------------------------------------


@dataclass(frozen=True)
class _Hand:
    label: str
    klass: str
    axis: str  # a·b·c·d = 그 W3 축의 파생 대상이어야 한다 · row = 행이고 계급만 맞으면 된다
    anchor: str  # `python/ 기준 파일|함수 또는 모듈 수준 이름`
    call: str  # 앵커가 부르는 이름 — 비공개면 label 이 그 공개 입구다(입구 소스를 대조)


_LEAKS = "tests/unit/test_token_response_leaks.py"


def _hand_table() -> list[_Hand]:
    """손으로 고른 python 보안 테스트가 겨누는 메서드 — 파생 집합이 이것 밑으로 **조용히**
    줄지 않게 한다. sync·aio 두 미러가 같은 모양이다."""
    rows: list[_Hand] = []
    mirrors = (
        ("keycloak_sdk.auth.AuthClient", "SYNC_CALLS", "_sync_admin_grant", ""),
        ("keycloak_sdk.aio.auth.AsyncAuthClient", "AIO_CALLS", "_aio_admin_grant", "aio."),
    )
    for auth, calls, grant, aio in mirrors:
        users = f"keycloak_sdk.{aio}admin.users.{'Async' if aio else ''}UsersResource"
        tests = f"tests/unit/{aio.replace('.', '/')}test_auth.py"
        leaks = f"{_LEAKS}|{calls}"
        cc = f"{auth}.client_credentials_token"
        # 형식이 틀린 토큰 응답 손 테스트(#619)의 호출 표 — 그 표가 부르는 공개 이름 전부.
        rows += [
            _Hand(cc, TOKEN_GRANT, "a", leaks, "client_credentials_token"),
            _Hand(f"{auth}.exchange_code", CODE_EXCHANGE, "a", leaks, "exchange_code"),
            _Hand(f"{auth}.refresh", TOKEN_GRANT, "a", leaks, "refresh"),
            _Hand(f"{auth}.introspect", OTHER, "row", leaks, "introspect"),
            _Hand(f"{auth}.logout", OTHER, "row", leaks, "logout"),
            _Hand(f"{users}.get", TOKEN_GRANT, "a", f"{_LEAKS}|{grant}", "get"),
        ]
        # 보안 기본값 가드의 python 행위 앵커(nonce · 백오프) + 가드 밖의 서명 위조 손 테스트.
        rows += [
            _Hand(f"{auth}.exchange_code", CODE_EXCHANGE, "b", f"{tests}|{t}", "exchange_code")
            for t in (
                "test_exchange_code_rejects_mismatched_nonce",
                "test_exchange_code_rejects_missing_id_token_when_nonce_expected",
                "test_exchange_code_rejects_a_forged_rs256_id_token_whose_nonce_matches",
            )
        ]
        rows += [
            _Hand(f"{auth}.validate", JWKS_FETCH, "c", f"{tests}|{t}", "_load_jwks")
            for t in (
                "test_cold_cache_failing_idp_collapses_to_one_certs_call",
                "test_backoff_window_expires_and_the_next_load_reaches_the_idp",
                "test_recovered_idp_resets_the_backoff",
            )
        ]
        # 토큰 타입 축(1c)의 앵커는 파서를 직접 부른다 — 그 공개 입구가 client_credentials_token.
        anchor = "tests/unit/test_tokens.py|test_non_string_access_token_is_rejected"
        rows.append(_Hand(cc, TOKEN_GRANT, "a", anchor, "from_response"))
        # (d) 의 계약 — 같은 kid 의 다른 키로 서명한 토큰을 validate 가 거부한다.
        forged = f"{tests}|test_signature_forgery_does_not_refetch_jwks"
        rows.append(_Hand(f"{auth}.validate", JWKS_FETCH, "d", forged, "validate"))
    return rows


#: 보안 기본값 가드가 python 행위 앵커를 적는 모양(`python/<파일>|def <이름>(`).
_SCRIPT_ANCHOR = re.compile(r"python/(tests/[A-Za-z0-9_/]+\.py)\|(?:async )?def ([A-Za-z0-9_]+)\(")
_PYTHON_DIR = Path(__file__).resolve().parents[2]


def _calls_in(node: ast.AST) -> set[str]:
    """`x.name(…)` 꼴로 부르는 이름 전부."""
    return {
        n.func.attr
        for n in ast.walk(node)
        if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
    }


def _anchor_calls(anchor: str) -> set[str] | None:
    """앵커(`파일|이름`)의 함수 본문 또는 모듈 수준 대입이 부르는 이름. 없으면 None."""
    file, _, name = anchor.partition("|")
    path = _PYTHON_DIR / file
    if not path.is_file():
        return None
    for node in ast.parse(path.read_text(encoding="utf-8")).body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name:
            return _calls_in(node)
        targets: list[ast.expr] = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign):
            targets = [node.target]
        if any(isinstance(t, ast.Name) and t.id == name for t in targets):
            return _calls_in(node)
    return None


def _check_hand_row(
    h: _Hand, src: _Source, row: _Row | None, tgt: Mapping[str, list[str]]
) -> list[str]:
    why: list[str] = []
    lb = _short(h.label)
    if row is None:
        why.append(f"W1 {lb}: 손 테스트({h.anchor})가 겨누는데 파생 집합에 행이 없다")
    elif row.klass != h.klass:
        why.append(f"W1 {lb}: 손 테스트({h.anchor})의 계급은 {h.klass} 인데 파생은 {row.klass}")
    elif h.axis != "row" and h.label not in tgt[h.axis]:
        why.append(f"W1 {lb}: 손 테스트({h.anchor})가 겨누는데 W3{h.axis} 파생 대상에 없다")
    calls = _anchor_calls(h.anchor)
    if calls is None:
        return [*why, f"W1 {h.anchor}: 앵커가 없다 — 손 테스트가 옮겨졌으면 표를 고쳐라"]
    if h.call not in calls:
        why.append(f"W1 {h.anchor}: 앵커가 .{h.call}( 를 안 부른다 — 손 테스트의 대상이 바뀌었다")
    if not h.label.endswith(f".{h.call}"):
        node = src.nodes.get(h.label)
        if node is None or h.call not in _calls_in(node):
            why.append(f"W1 {lb}: 공개 입구가 {h.call} 를 안 부른다 — 앵커({h.anchor})와 끊겼다")
    return why


def _check_hand(
    src: _Source, by_label: Mapping[str, _Row], tgt: Mapping[str, list[str]]
) -> list[str]:
    hand = _hand_table()
    anchors = {h.anchor for h in hand}
    why = [w for h in hand for w in _check_hand_row(h, src, by_label.get(h.label), tgt)]
    # 손 테스트 호출 표가 부르는 공개 이름은 전부 표에 있다 — 대상이 늘면 여기가 먼저 운다.
    n_leaks = 0
    for anchor in sorted(a for a in anchors if a.startswith(f"{_LEAKS}|")):
        public = {n for n in (_anchor_calls(anchor) or set()) if not n.startswith("_")}
        n_leaks += len(public)
        listed = {h.call for h in hand if h.anchor == anchor}
        why += [f"W1 {anchor} 가 {name} 를 부르는데 표에 없다" for name in sorted(public - listed)]
    if n_leaks == 0:
        why.append("W1 형식이 틀린 토큰 응답 손 테스트에서 공개 호출을 못 읽었다 — 공허하다")
    # 보안 기본값 가드의 python 행위 앵커는 전부 표의 앵커다 — 가드에 앵커가 늘면 여기가 운다.
    root = _PYTHON_DIR.parent
    script = root / "scripts" / "test" / "test-security-defaults.sh"
    if script.is_file():
        found = _SCRIPT_ANCHOR.findall(script.read_text(encoding="utf-8"))
        print(
            f"\nW1 손 목록 {len(hand)} 항목 · 앵커 {len(anchors)} — 손 테스트 호출 표의 공개 "
            f"호출 {n_leaks} · 보안 기본값 가드의 python 행위 앵커 {len(found)} 와 대조"
        )
        if not found:
            why.append("W1 보안 기본값 가드에서 python 행위 앵커를 못 읽었다 — 모양이 바뀌었나?")
        why += [
            f"W1 보안 기본값 가드의 python 앵커 {file}|{fn} 가 표에 없다"
            for file, fn in found
            if f"{file}|{fn}" not in anchors
        ]
    elif (root / ".git").exists():
        why.append(f"W1 저장소 체크아웃인데 보안 기본값 가드를 못 읽었다: {script}")
    else:
        print("W1: 저장소 밖에서 돌아 보안 기본값 가드 대조는 건너뛴다")
    return why


# --- 테스트 ---------------------------------------------------------------------------------


def _targets(
    rows: list[_Row], by_member: Mapping[str, _Member]
) -> tuple[dict[str, list[str]], list[str]]:
    """W3 대상 — 전부 파생이다: (a) 계급 · (b) 계급 ∩ 서명 · (c) 분류 실행이 보낸 요청."""
    tgt: dict[str, list[str]] = {"a": [], "b": [], "c": [], "d": []}
    late: list[str] = []
    for r in rows:
        member = by_member.get(r.label)
        if member is None:
            continue
        if r.klass in (TOKEN_GRANT, CODE_EXCHANGE):
            tgt["a"].append(r.label)
        if r.klass == CODE_EXCHANGE and _nonce_params(member):
            tgt["b"].append(r.label)
        elif r.klass == CODE_EXCHANGE and r.label in _NONCE_DROP_EXEMPT:
            print(f"(b) nonce 파라미터가 없어 빠진 행: {r.label} — {_NONCE_DROP_EXEMPT[r.label]}")
        elif r.klass == CODE_EXCHANGE:
            late.append(
                f"W3b {_short(r.label)}: CODE_EXCHANGE 인데 이름에 nonce 가 든 파라미터가 "
                "없다 — nonce 를 그 이름으로 받게 하거나, 정말 nonce 없는 흐름이면 이유와 "
                "함께 _NONCE_DROP_EXEMPT 에 적어라"
            )
        if any(_is_certs_get(q) for q in r.sent):
            tgt["c"].append(r.label)
        if r.klass == JWKS_FETCH:
            tgt["d"].append(r.label)
    by_label = {r.label: r for r in rows}
    for label, reason in sorted(_NONCE_DROP_EXEMPT.items()):
        row, member = by_label.get(label), by_member.get(label)
        if row is None or member is None or row.klass != CODE_EXCHANGE or _nonce_params(member):
            late.append(f"_NONCE_DROP_EXEMPT[{label}]: 낡은 면제다({reason})")
    return tgt, late


def _undetermined(rows: list[_Row], by_label: Mapping[str, _Row]) -> list[str]:
    """(1) UNDETERMINED 없음 — 면제는 이유와 함께, 낡은 면제는 실패."""
    out = [
        f"{_short(r.label)}: 분류하지 못했다(UNDETERMINED) — 인자 합성·수신자를 고치거나 "
        f"이유와 함께 면제하라{r.note}"
        for r in rows
        if r.klass == UNDETERMINED and r.label not in _UNDETERMINED_EXEMPT
    ]
    out += [
        f"{label}: 낡은 면제다 — 선언 집합에 없거나 더는 UNDETERMINED 가 아니다({reason})"
        for label, reason in sorted(_UNDETERMINED_EXEMPT.items())
        if label not in by_label or by_label[label].klass != UNDETERMINED
    ]
    return out


def test_hostile_path_matrix(fast_tls: None, one_loop: None) -> None:
    key = RSAKey.generate_key(2048, {"kid": "k1", "use": "sig", "alg": "RS256"})
    src = _source()
    members = _declared_members(_declared_types(), src)
    labels = [m.label for m in members]
    assert len(labels) == len(set(labels)), "행 라벨이 겹친다 — 파생이 같은 멤버를 두 번 셌다"
    builder_of = _probe_builders(key)

    rows = [_run_row(key, m, builder_of) for m in members]
    by_member = {m.label: m for m in members}
    called = len(rows)
    rows += _unreached_rows(src, {r.label: r for r in rows})
    by_label = {r.label: r for r in rows}
    counts = _log_table(rows, called)

    late = _undetermined(rows, by_label)
    # (2) 세 교환 계급이 각각 비어 있지 않다 — 비면 분류기·IdP·인자 합성이 공허해진 것이다.
    late += [
        f"{c} 계급이 비었다 — 교환 경로를 하나도 못 찾았다"
        for c in (CODE_EXCHANGE, TOKEN_GRANT, JWKS_FETCH)
        if not counts[c]
    ]
    tgt, late_b = _targets(rows, by_member)
    cells = _run_variants_a(key, by_member, builder_of, tgt["a"])
    cells += _run_nonce_b(key, by_member, builder_of, tgt["b"])
    cells += _run_cold_c(key, by_member, builder_of, tgt["c"])
    cells += _run_forged_d(key, by_member, builder_of, tgt["d"])
    fails, summaries = _judge(cells)

    # W1 — 손 목록 포함. 실패 사유는 판정표 뒤에 모아 찍는다.
    fails += late + late_b + _check_hand(src, by_label, tgt)
    print()
    for f in fails:
        print(f"FAIL {f}")
    print("계급별: " + " · ".join(f"{c} {counts[c]}" for c in _CLASSES))
    for s in summaries:
        print(s)
    assert not fails, f"적대 경로 행렬 실패 {len(fails)}:\n" + "\n".join(fails)
