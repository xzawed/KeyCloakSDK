"""업로드 둘이 던져도 그 오류의 프레임 로컬에 bearer 가 없다(등록부
`python-raw-upload-traceback-locals-bearer`).

오류 수집기(Sentry Python 기본값)·`TracebackException(capture_locals=True)` 는 traceback 이 닿는
프레임의 로컬을 사슬(`__cause__`·`__context__`)까지 `repr` 로 찍는다. 탈출구 `raw` 의 업로드가
던지면 그 프레임들이 bearer 를 쥐고 있었다(수정 전 실측, 3.10.21 · 3.13.11): python-keycloak 의
업로드(`orig_headers`·`new_headers`)와 `raw_post`·`a_raw_post`(`kwargs`), aio 는 httpx `request`
(`params`·`headers`·`request` — 토큰이 **URL 문자열** 안이라 키로 거르는 수집기는 못 본다)와 이
SDK 의 `sent`(`request`), sync 의 전송 실패는 requests·urllib3 의 `headers`. 서버가 거절한 업로드
(404)는 업로드 프레임이 쥐었다.

감시 클래스의 업로드 둘(`_internal/admin_guard.py`)이 헤더를 되돌린 뒤, 그 예외에서 닿는
traceback(사슬과 `BaseExceptionGroup` 의 구성원)마다 끝난 프레임의 로컬을 비우고 같은 객체를 다시
던진다 — 타입·메시지·사슬·프레임(줄 번호)은 그대로다.

`raw` 의 업로드는 이제 SDK 의 것이다(`_internal/admin_upload.py` — 연결의 헤더를 갈아 끼우지
않는다). 그 실패도 같은 걸음이 비운다 — 전송 실패면 그 요청 하나의 헤더를 쥔 SDK 프레임과 하위
라이브러리 프레임이 bearer 를 쥔다. python-keycloak 의 업로드를 밟는 시험은 소비자 하위 클래스가
`super()` 로 부른다.
"""

from __future__ import annotations

import builtins
import inspect
import threading
import traceback
from typing import Any, NoReturn
from urllib.parse import urlsplit

import httpx
import pytest
import requests
from keycloak.exceptions import KeycloakConnectionError, KeycloakPostError

from keycloak_sdk._internal import admin_guard
from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.exceptions import KeycloakTransportError

from .test_admin_bearer_in_url import _UPLOAD, _USER, IN_URL, TOKENS, _client, _fake_idp
from .test_admin_grant import LANES, _attempt, _inner_frames
from .test_admin_upload_certificate_headers import _UPLOADS, _cfg, _consumer

pytestmark = pytest.mark.usefixtures("fast_tls")

#: 그랜트가 돌려줄 bearer — aio 업로드의 쿼리에 글자 그대로 실린다.
_TOKEN = TOKENS["plain"]


def _render(err: BaseException) -> str:
    """오류 수집기가 모으는 것 — 사슬까지, 프레임마다 로컬을 찍는다."""
    return "".join(traceback.TracebackException.from_exception(err, capture_locals=True).format())


def _dropped() -> threading.Event:
    """이미 풀린 붙잡기 — 가짜 IdP 가 그 요청을 응답 없이 곧바로 끊는다(보낸 쪽에는 전송 실패)."""
    release = threading.Event()
    release.set()
    return release


def _paths(idp: Any) -> list[str]:
    return [urlsplit(seen.target).path for seen in idp.admin_requests()]


# --- 업로드 ----------------------------------------------------------------------------------


async def test_a_refused_a_upload_certificate_renders_without_the_bearer() -> None:
    """aio 업로드는 보내기 전에 거부된다(IN_URL). 소비자 하위 클래스가 python-keycloak 에서 나온
    예외를 적는다 — 같은 객체·타입·메시지·원인이 닿고, traceback 은 여전히 python-keycloak 프레임을
    지난다."""
    with _fake_idp(_TOKEN) as idp:
        admin = _consumer(idp.url)
        client = AsyncAdminClient(_cfg(idp.url), admin=admin)
        try:
            await client.users.get("u1")  # 토큰을 받아 둔다 — 업로드 전에 bearer 가 헤더에 있다
            held = _TOKEN in repr(client.raw.connection.headers)
            _, err = await _attempt(
                "aio", client, lambda c: c.raw.a_upload_certificate("c1", "PEM")
            )
        finally:
            await client.aclose()

    assert held, "전제 — 업로드 전에 bearer 가 연결의 헤더에 없다"
    assert err is admin.__dict__["raised"]
    assert (type(err), str(err)) == (KeycloakConnectionError, "Can't connect to server")
    assert (type(err.__cause__), str(err.__cause__)) == (KeycloakTransportError, IN_URL)
    assert "keycloak.keycloak_admin.a_upload_certificate" in _inner_frames(err)
    assert _TOKEN not in _render(err), "프레임 로컬이 bearer 를 찍는다"


async def test_a_sync_upload_that_fails_in_transport_renders_without_the_bearer() -> None:
    """업로드 요청이 응답 없이 끊긴다 — python-keycloak 의 그 전송 오류가 같은 객체로 닿는다."""
    with _fake_idp(_TOKEN) as idp:
        admin = _consumer(idp.url)
        client = AdminClient(_cfg(idp.url), admin=admin)
        try:
            client.users.get("u1")
            held = _TOKEN in repr(client.raw.connection.headers)
            idp.hold, idp.held_path = _dropped(), _UPLOAD
            _, err = await _attempt("sync", client, lambda c: c.raw.upload_certificate("c1", "PEM"))
        finally:
            client.close()

    assert held, "전제 — 업로드 전에 bearer 가 연결의 헤더에 없다"
    assert _paths(idp) == [f"/{_USER}", _UPLOAD], "업로드가 나가서 끊기지 않았다"
    assert err is admin.__dict__["raised"]
    assert (type(err), str(err)) == (KeycloakConnectionError, "Can't connect to server")
    assert isinstance(err.__cause__, requests.ConnectionError), repr(err.__cause__)
    assert "keycloak.keycloak_admin.upload_certificate" in _inner_frames(err)
    assert _TOKEN not in _render(err), "프레임 로컬이 bearer 를 찍는다"


async def test_a_sync_upload_the_server_rejects_renders_without_the_bearer() -> None:
    """서버가 업로드를 404 로 거절한다(없는 클라이언트) — 오류는 python-keycloak 이 응답에서 만든
    그것이고, 업로드 프레임의 `orig_headers`·`new_headers` 가 bearer 를 쥐고 있었다."""
    missing = "/admin/realms/r/clients/missing/certificates/jwt.credential/upload-certificate"
    with _fake_idp(_TOKEN) as idp:
        admin = _consumer(idp.url)
        client = AdminClient(_cfg(idp.url), admin=admin)
        try:
            client.users.get("u1")
            _, err = await _attempt(
                "sync", client, lambda c: c.raw.upload_certificate("missing", "PEM")
            )
        finally:
            client.close()

    assert _paths(idp) == [f"/{_USER}", missing]
    assert err is admin.__dict__["raised"]
    assert (type(err), err.response_code) == (KeycloakPostError, 404)
    assert "keycloak.keycloak_admin.upload_certificate" in _inner_frames(err)
    assert _TOKEN not in _render(err), "프레임 로컬이 bearer 를 찍는다"


async def _sdk_upload(lane: str, kc: Any, client_id: str) -> Any:
    """`raw` 의 업로드 — 감시 클래스가 SDK 의 것으로 보낸다."""
    result = getattr(kc.admin.raw, _UPLOADS[lane])(client_id, "PEM")
    return await result if lane == "aio" else result


async def _admin_get(lane: str, kc: Any) -> None:
    """토큰을 받아 둔다 — 업로드 전에 bearer 가 연결의 헤더에 있다."""
    result = kc.admin.users.get("u1")
    if lane == "aio":
        await result


@pytest.mark.parametrize("lane", LANES)
async def test_an_sdk_upload_that_fails_in_transport_renders_without_the_bearer(lane: str) -> None:
    """`raw` 의 업로드 요청이 응답 없이 끊긴다 — 그 오류는 python-keycloak 의 `raw_post` 와 같은
    모양이고, 그 요청 하나의 헤더를 쥔 SDK 프레임 · 하위 라이브러리 프레임의 로컬이 빈다."""
    with _fake_idp(_TOKEN) as idp:
        async with _client(lane, idp.url) as kc:
            await _admin_get(lane, kc)
            held = _TOKEN in repr(kc.admin.raw.connection.headers)
            idp.hold, idp.held_path = _dropped(), _UPLOAD
            _, err = await _attempt("aio", kc, lambda c: _sdk_upload(lane, c, "c1"))

    assert held, "전제 — 업로드 전에 bearer 가 연결의 헤더에 없다"
    assert _paths(idp) == [f"/{_USER}", _UPLOAD], "업로드가 나가서 끊기지 않았다"
    assert (type(err), str(err)) == (KeycloakConnectionError, "Can't connect to server")
    lower = (requests.ConnectionError, httpx.TransportError)
    assert isinstance(err.__cause__, lower), repr(err.__cause__)
    assert _TOKEN not in _render(err), "프레임 로컬이 bearer 를 찍는다"


@pytest.mark.parametrize("lane", LANES)
async def test_an_sdk_upload_the_server_rejects_renders_without_the_bearer(lane: str) -> None:
    """서버가 `raw` 의 업로드를 404 로 거절한다 — 오류는 python-keycloak 이 응답에서 만든
    그것이다. 대조: 그 요청의 헤더는 이미 돌아온 보내기 프레임(`_post`)의 것이라 로컬을 비우지
    않아도 bearer 를 쥔 프레임이 없다 — 업로드 프레임이 헤더를 쥐게 되면 이 시험이 잡는다."""
    missing = "/admin/realms/r/clients/missing/certificates/jwt.credential/upload-certificate"
    with _fake_idp(_TOKEN) as idp:
        async with _client(lane, idp.url) as kc:
            await _admin_get(lane, kc)
            _, err = await _attempt("aio", kc, lambda c: _sdk_upload(lane, c, "missing"))

    assert _paths(idp) == [f"/{_USER}", missing]
    assert (type(err), err.response_code) == (KeycloakPostError, 404)
    assert "keycloak.exceptions.raise_error_from_response" in _inner_frames(err)
    assert _TOKEN not in _render(err), "프레임 로컬이 bearer 를 찍는다"


@pytest.mark.parametrize("lane", LANES)
async def test_a_facade_call_that_fails_in_transport_renders_without_the_bearer(lane: str) -> None:
    """대조 — 파사드 경계는 오류를 사슬 없이 새로 만든다(`admin/_translate.py`). 그 길의 전송 실패는
    고치기 전에도 bearer 를 찍지 않았다(실측) — 그것을 고정한다."""
    with _fake_idp(_TOKEN) as idp:
        idp.hold, idp.held_path = _dropped(), f"/{_USER}"
        async with _client(lane, idp.url) as kc:
            _, err = await _attempt(lane, kc, lambda c: c.admin.users.get("u1"))
            held = _TOKEN in repr(kc.admin.raw.connection.headers)

    assert held, "전제 — 끊긴 요청이 bearer 를 싣고 나가지 않았다"
    assert _paths(idp) == [f"/{_USER}"]
    assert (type(err), str(err)) == (KeycloakTransportError, "Can't connect to server")
    assert _TOKEN not in _render(err), "프레임 로컬이 bearer 를 찍는다"


# --- 걸음 자체 --------------------------------------------------------------------------------

_SECRET = "walk-secret-canary"
#: 3.11 부터의 내장 — 3.10 에는 없어 구성원 시험은 건너뛴다.
_GROUP: Any = getattr(builtins, "BaseExceptionGroup", None)


def _raise(exc: BaseException, depth: int) -> NoReturn:
    """`exc` 를 `depth + 1` 겹의 프레임에서 던진다 — 프레임마다 로컬 `held` 를 쥔다."""
    held = _SECRET  # noqa: F841 — 걸음이 비워야 하는 로컬
    if depth:
        _raise(exc, depth - 1)
    raise exc


def _caught(exc: BaseException) -> BaseException:
    """`exc` 를 던지고 여기서 잡는다 — traceback 은 끝난 프레임 셋(이것과 `_raise` 둘)이다."""
    try:
        _raise(exc, 1)
    except BaseException as caught:
        return caught
    raise AssertionError("not raised")


def _walked(top: BaseException, reachable: list[BaseException]) -> None:
    """`top` 을 이 프레임에서 던지고 잡은 채(아직 도는 중) 걸음을 부른다. `top` 과 `reachable` 의
    traceback 이 지나는 끝난 프레임은 로컬을 잃고, 이 프레임은 남는다."""
    marker = "running-frame-marker"
    try:
        _raise(top, 0)
    except BaseException as err:
        running = inspect.currentframe()
        frames = [f for e in (err, *reachable) for f, _ in traceback.walk_tb(e.__traceback__)]
        finished = [f for f in frames if f is not running]
        assert err.__traceback__ is not None and err.__traceback__.tb_frame is running
        assert len(finished) == 3 * len(reachable) + 1, "전제 — 시험이 만든 traceback 이 아니다"
        assert all(dict(f.f_locals) for f in finished), "전제 — 끝난 프레임마다 로컬이 있다"

        admin_guard._clear_locals(err)

        assert [f.f_code.co_name for f in finished if dict(f.f_locals)] == []
        assert running is not None and running.f_locals["marker"] == marker


def test_the_walk_clears_the_chain_and_skips_the_running_frame() -> None:
    """원인·문맥 사슬 — 순환이어도 끝난다. 닿는 traceback 마다 끝난 프레임의 로컬이 빈다."""
    cause = _caught(KeyError("cause"))
    context = _caught(ValueError("context"))
    deeper = _caught(OSError("deeper"))
    cause.__context__ = context
    context.__cause__ = deeper
    deeper.__context__ = cause  # 순환
    top = RuntimeError("top")
    top.__cause__ = cause
    _walked(top, [cause, context, deeper])


@pytest.mark.skipif(_GROUP is None, reason="BaseExceptionGroup is a builtin from Python 3.11")
def test_the_walk_follows_the_members_of_an_exception_group() -> None:
    """`BaseExceptionGroup` 의 구성원 — 중첩된 그룹, 구성원의 사슬, 두 그룹에 든 구성원, 그룹을
    거치는 순환까지."""
    member_cause = _caught(TypeError("member cause"))
    member = _caught(OSError("member"))
    member.__cause__ = member_cause
    shared = _caught(KeyboardInterrupt())
    inner = _caught(_GROUP("inner", [member, shared]))
    outer = _caught(_GROUP("outer", [inner, shared]))
    member.__context__ = outer  # 그룹을 거치는 순환
    top = RuntimeError("top")
    top.__context__ = outer
    _walked(top, [outer, inner, member, member_cause, shared])


def test_the_walk_follows_the_members_of_a_backport_group() -> None:
    """3.10 의 그룹 — 내장이 없는 판에서 anyio 가 쓰는 백포트(`exceptiongroup`)의 구성원도
    따라간다. 걸음은 `_internal/frames.reachable` 하나다(등록부
    `python-scrub-frames-skips-exception-groups` — 예전 3.10 에서는 그 구성원의 로컬이 남았다,
    실측 3.10.21). 3.11+ 에서 그 백포트는 내장을 다시 내보낸다(깔려 있을 때)."""
    backport = pytest.importorskip("exceptiongroup").BaseExceptionGroup
    member = _caught(OSError("member"))
    group = _caught(backport("group", [member]))
    top = RuntimeError("top")
    top.__context__ = group
    _walked(top, [group, member])
