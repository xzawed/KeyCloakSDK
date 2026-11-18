"""`upload_certificate`·`a_upload_certificate` 가 실패해도 연결의 헤더는 부르기 전 값으로 돌아온다
(등록부 `python-upload-certificate-headers-not-restored`).

python-keycloak 7.1.1(`keycloak_admin.py` L7550 · L14374)은 연결의 헤더를 multipart
`Content-Type` 의 사본으로 갈아 끼운 채(`self.connection.headers = new_headers`) 보내고, 보내기가
**돌아온 뒤에만** 원래 값을 되돌린다 — `try`/`finally` 가 없다. 보내기가 던지면 그 admin 의 이후
요청이 전부 `Content-Type: multipart/form-data; boundary=…` 로 나갔다(수정 전 실측). aio 는 오늘
**언제나** 던진다 — 헤더 사전을 쿼리로 넘겨 bearer 가 URL 에 실리므로 이 SDK 가 보내기 전에
거부한다(`IN_URL`, `test_admin_bearer_in_url.py`). sync 는 전송 실패에서 던진다. 취소
(`CancelledError`)·`KeyboardInterrupt` 는 `Exception` 이 아니어도 같은 자리를 건너뛴다.

감시 클래스(`_internal/admin_guard.py`)가 둘을 덮는다 — 부르기 전에 읽은 연결과 그 헤더 값을
기억하고, 감싼 클래스의 메서드를 같은 인자로 부른 뒤, 그것이 무엇을 던지든 그 연결에 그 값을
되돌리고 같은 예외를 다시 던진다. 성공하면 아무것도 하지 않는다(python-keycloak 이 되돌렸다).
"""

from __future__ import annotations

import asyncio
import inspect
import threading
from collections.abc import Callable
from typing import Any
from unittest.mock import MagicMock, patch
from urllib.parse import urlsplit

import pytest
import requests
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakConnectionError

from keycloak_sdk.admin import AdminClient
from keycloak_sdk.aio.admin import AsyncAdminClient
from keycloak_sdk.config import KeycloakConfig

from .test_admin_bearer_in_url import _UPLOAD, _USER, TOKENS, _client, _fake_idp, _raw_refused
from .test_admin_grant import LANES, _attempt
from .test_admin_guard_live import _close, _close_connection, _connection

pytestmark = pytest.mark.usefixtures("fast_tls")

_JSON = "application/json"
#: python-keycloak 의 multipart 업로드가 싣는 `Content-Type` 의 머리 — 경계 값은 매번 다르다.
_MULTIPART = "multipart/form-data; boundary="
_NOWHERE = "http://127.0.0.1:9"
_ADMIN_CLIENTS: dict[str, Any] = {"sync": AdminClient, "aio": AsyncAdminClient}
_UPLOADS = {"sync": "upload_certificate", "aio": "a_upload_certificate"}


def _cfg(url: str) -> KeycloakConfig:
    return KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret="s")


def _kinds(idp: Any) -> list[tuple[str, str | None]]:
    """admin 요청마다 (경로, 받은 `Content-Type`) — multipart 는 경계 값을 떼고 머리만."""
    out: list[tuple[str, str | None]] = []
    for seen in idp.admin_requests():
        kind = seen.content_type
        if kind is not None and kind.startswith(_MULTIPART):
            kind = _MULTIPART
        out.append((urlsplit(seen.target).path, kind))
    return out


class _Consumer(KeycloakAdmin):
    """소비자의 하위 클래스 — 자기 업로드를 둔다(서명도 다르다: `note`). 받은 인자를 적고, `act` 가
    있으면 그것(소비자 코드)을, 없으면 python-keycloak 의 것을 부른다. 거기서 나온 예외도 적는다 —
    감시 클래스가 감싸는 것은 이 메서드다."""

    def upload_certificate(self, client_id: str, certcont: str, *, note: str = "") -> Any:
        self.__dict__.setdefault("calls", []).append((client_id, certcont, note))
        act: Callable[[KeycloakAdmin], Any] | None = self.__dict__.get("act")
        try:
            return act(self) if act else super().upload_certificate(client_id, certcont)
        except BaseException as exc:
            self.__dict__["raised"] = exc
            raise

    async def a_upload_certificate(self, client_id: str, certcont: str, *, note: str = "") -> Any:
        self.__dict__.setdefault("calls", []).append((client_id, certcont, note))
        act: Callable[[KeycloakAdmin], Any] | None = self.__dict__.get("act")
        try:
            return act(self) if act else await super().a_upload_certificate(client_id, certcont)
        except BaseException as exc:
            self.__dict__["raised"] = exc
            raise


def _consumer(url: str) -> _Consumer:
    return _Consumer(
        server_url=url,
        realm_name="r",
        client_id="c",
        client_secret_key="s",
        grant_type="client_credentials",
    )


async def _upload(lane: str, raw: Any, *args: Any, **kwargs: Any) -> Any:
    result = getattr(raw, _UPLOADS[lane])(*args, **kwargs)
    return await result if lane == "aio" else result


# --- python-keycloak 의 업로드 그대로 ---------------------------------------------------------


async def test_a_refused_a_upload_certificate_leaves_the_next_request_json() -> None:
    """aio 업로드는 보내기 전에 거부된다(IN_URL) — 그 뒤의 admin 요청은 `application/json` 이다."""
    with _fake_idp(TOKENS["plain"]) as idp:
        async with _client("aio", idp.url) as kc:
            await kc.admin.users.get("u1")  # 토큰을 받아 둔다 — 업로드 안에서는 그랜트가 없다
            raw = kc.admin.raw
            before = raw.connection.headers
            _, err = await _attempt(
                "aio", kc, lambda c: c.admin.raw.a_upload_certificate("c1", "PEM")
            )
            after = raw.connection.headers
            await kc.admin.users.get("u1")

    assert _kinds(idp) == [(f"/{_USER}", _JSON)] * 2, "거부된 업로드 뒤 요청이 multipart 로 나갔다"
    assert _raw_refused(err) == [], "python-keycloak 이 낸 오류가 그대로 닿지 않았다"
    assert after is before


async def test_a_sync_upload_that_fails_in_transport_leaves_the_next_request_json() -> None:
    """업로드 요청이 응답 없이 끊긴다 — python-keycloak 의 그 전송 오류가 그대로 닿고, 그 뒤의
    admin 요청은 `application/json` 이다. 업로드가 나가 있는 **동안** 다른 스레드의 요청은 여전히
    multipart 다 — 연결 하나를 함께 쓰는 python-keycloak 의 구조라 고치는 범위 밖이다(머리 주석 6 의
    ⚠️ — 이 줄이 바뀌면 그것도 바꾼다)."""
    release = threading.Event()
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.hold, idp.held_path = release, _UPLOAD
        async with _client("sync", idp.url) as kc:
            kc.admin.users.get("u1")
            raw = kc.admin.raw
            before = raw.connection.headers
            upload = asyncio.ensure_future(asyncio.to_thread(raw.upload_certificate, "c1", "PEM"))
            try:
                assert await asyncio.to_thread(idp.holding.wait, 10), "업로드가 오지 않았다"
                kc.admin.users.get("u1")  # 업로드가 나가 있는 동안 — 다른 스레드
            finally:
                release.set()  # 붙잡은 업로드를 응답 없이 끊는다
            _, err = await _attempt("aio", kc, lambda _c: upload)  # 스레드의 업로드를 기다린다
            after = raw.connection.headers
            kc.admin.users.get("u1")

    assert _kinds(idp) == [
        (f"/{_USER}", _JSON),
        (_UPLOAD, _MULTIPART),
        (f"/{_USER}", _MULTIPART),  # 나가 있는 동안 — 범위 밖
        (f"/{_USER}", _JSON),
    ], "끊긴 업로드 뒤 요청이 multipart 로 나갔다"
    assert type(err) is KeycloakConnectionError, repr(err)
    assert str(err) == "Can't connect to server"
    assert isinstance(err.__cause__, requests.ConnectionError), repr(err.__cause__)
    assert after is before


async def test_a_successful_sync_upload_is_unchanged() -> None:
    """대조 — 성공한 업로드는 python-keycloak 그대로다: multipart 로 나가고, 헤더는 python-keycloak
    이 되돌린 값이다."""
    with _fake_idp(TOKENS["plain"]) as idp:
        async with _client("sync", idp.url) as kc:
            kc.admin.users.get("u1")
            raw = kc.admin.raw
            before = dict(raw.connection.headers)
            result = raw.upload_certificate("c1", certcont="PEM")
            after = dict(raw.connection.headers)
            kc.admin.users.get("u1")

    assert result == {"certificate": "PEM"}
    assert _kinds(idp) == [(f"/{_USER}", _JSON), (_UPLOAD, _MULTIPART), (f"/{_USER}", _JSON)]
    assert after == before


async def test_a_cancelled_a_upload_certificate_leaves_the_next_request_json() -> None:
    """업로드 안의 첫 그랜트를 기다리는 동안 취소된다 — `CancelledError` 는 `Exception` 이 아니다.
    같은 예외 객체가 닿고(소비자 하위 클래스가 python-keycloak 에서 나온 것을 적는다), 그 뒤의
    admin 요청은 `application/json` 이다. 기다리는 **동안** 다른 태스크의 요청은 여전히 multipart
    다(위 sync 와 같다 — 범위 밖)."""
    release = threading.Event()
    left: list[BaseException] = []
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.hold = release  # 첫 그랜트 — 업로드 안의 것
        admin = _consumer(idp.url)
        client = AsyncAdminClient(_cfg(idp.url), admin=admin)

        async def upload_certificate() -> Any:
            try:
                return await client.raw.a_upload_certificate("c1", "PEM")
            except BaseException as exc:  # 감시 래퍼가 내보낸 그대로 — Task 가 받기 전
                left.append(exc)  # (3.10 의 Task 는 기다리는 쪽에 새 CancelledError 를 준다)
                raise

        try:
            raw = client.raw
            before = raw.connection.headers
            upload = asyncio.ensure_future(upload_certificate())
            assert await asyncio.to_thread(idp.holding.wait, 10), "업로드 안의 그랜트가 오지 않았다"
            await client.users.get("u1")  # 기다리는 동안 — 다른 태스크(제 그랜트는 답을 받는다)
            upload.cancel()
            with pytest.raises(asyncio.CancelledError):
                await upload
            after = raw.connection.headers
            await client.users.get("u1")
        finally:
            release.set()
            await client.aclose()

    assert _kinds(idp) == [
        (f"/{_USER}", _MULTIPART),  # 기다리는 동안 — 범위 밖
        (f"/{_USER}", _JSON),
    ], "취소된 업로드 뒤 요청이 multipart 로 나갔다"
    assert [type(e) for e in left] == [asyncio.CancelledError]
    assert left[0] is admin.__dict__["raised"]
    assert after is before


# --- 감싼 클래스의 메서드 ----------------------------------------------------------------------


@pytest.mark.parametrize(
    "boom",
    [RuntimeError("consumer upload failed"), KeyboardInterrupt(), asyncio.CancelledError()],
    ids=lambda e: type(e).__name__,
)
@pytest.mark.parametrize("lane", LANES)
async def test_a_failed_consumer_upload_is_undone_on_the_connection_it_started_on(
    lane: str, boom: BaseException
) -> None:
    """소비자의 업로드가 돈다(인자 그대로) — 연결의 헤더를 바꾸고 연결을 갈아 끼운 뒤 던진다. 그
    예외 객체가 그대로 닿고, 헤더는 부르기 전에 읽은 연결에만 되돌린다 — 갈아 끼운 연결은 건드리지
    않는다."""
    admin = _consumer(_NOWHERE)
    client = _ADMIN_CLIENTS[lane](_cfg(_NOWHERE), admin=admin)
    raw = client.raw
    conn = raw.connection
    before = conn.headers
    other = _connection(_NOWHERE)
    other_before = other.headers

    def act(self: KeycloakAdmin) -> Any:
        self.connection.headers = {**before, "Content-Type": f"{_MULTIPART}consumer"}
        self.connection = other
        raise boom

    admin.__dict__["act"] = act
    try:
        with pytest.raises(type(boom)) as raised:
            await _upload(lane, raw, "c1", certcont="PEM", note="n")
    finally:
        await _close(lane, client)  # 갈아 끼운 연결(`other`)을 닫는다
        await _close_connection(lane, conn)

    assert raised.value is boom
    assert admin.__dict__["calls"] == [("c1", "PEM", "n")]
    assert conn.headers is before
    assert vars(raw)["_connection"] is other
    assert other.headers is other_before


@pytest.mark.parametrize("lane", LANES)
async def test_a_successful_consumer_upload_is_left_alone(lane: str) -> None:
    """성공하면 아무것도 하지 않는다 — 소비자가 바꾼 헤더도, 돌려준 값도 그대로다."""
    admin = _consumer(_NOWHERE)
    client = _ADMIN_CLIENTS[lane](_cfg(_NOWHERE), admin=admin)
    raw = client.raw
    conn = raw.connection
    changed = {"Content-Type": "text/plain"}
    answer = {"certificate": "PEM"}

    def act(self: KeycloakAdmin) -> Any:
        self.connection.headers = changed
        return answer

    admin.__dict__["act"] = act
    try:
        result = await _upload(lane, raw, client_id="c1", certcont="PEM")
    finally:
        await _close(lane, client)

    assert result is answer
    assert admin.__dict__["calls"] == [("c1", "PEM", "")]
    assert conn.headers is changed


@pytest.mark.parametrize("lane", LANES)
async def test_a_patch_on_the_wrapped_class_still_runs(lane: str) -> None:
    """감싼 클래스의 업로드는 부를 때 찾는다 — 소비자 시험이 감시 클래스가 생긴 뒤 `KeycloakAdmin`
    에 건 패치가 인자 그대로 불린다."""
    name = _UPLOADS[lane]
    client = _ADMIN_CLIENTS[lane](_cfg(_NOWHERE))
    try:
        raw = client.raw
        with patch.object(KeycloakAdmin, name) as patched:
            result = await _upload(lane, raw, "c1", certcont="PEM")
    finally:
        await _close(lane, client)

    patched.assert_called_once_with("c1", certcont="PEM")
    assert result is patched.return_value


@pytest.mark.parametrize("cls", [KeycloakAdmin, _Consumer], ids=lambda c: c.__name__)
@pytest.mark.parametrize("lane", LANES)
async def test_the_watched_upload_keeps_the_wrapped_signature(
    lane: str, cls: type[KeycloakAdmin]
) -> None:
    """감시 클래스가 덮은 업로드는 감싼 클래스의 것처럼 보인다 — 서명·이름·문서, 코루틴 여부."""
    name = _UPLOADS[lane]
    admin = cls(
        server_url=_NOWHERE,
        realm_name="r",
        client_id="c",
        client_secret_key="s",
        grant_type="client_credentials",
    )
    client = _ADMIN_CLIENTS[lane](_cfg(_NOWHERE), admin=admin)
    try:
        raw = client.raw
        wrapped = getattr(cls, name)
        assert name in vars(type(raw)), "감시 클래스가 업로드를 덮지 않았다"
        method = getattr(raw, name)
        expected = ["client_id", "certcont"] + (["note"] if cls is _Consumer else [])
        assert list(inspect.signature(method).parameters) == expected
        assert inspect.signature(method) == inspect.signature(wrapped.__get__(raw))
        assert (method.__name__, method.__qualname__, method.__doc__) == (
            wrapped.__name__,
            wrapped.__qualname__,
            wrapped.__doc__,
        )
        assert inspect.iscoroutinefunction(method) is (lane == "aio")
    finally:
        await _close(lane, client)


@pytest.mark.parametrize("lane", LANES)
async def test_a_mock_admin_is_not_watched(lane: str) -> None:
    """목(`MagicMock(spec=KeycloakAdmin)`)은 감시하지 않는다 — 업로드도 목의 것이 인자 그대로
    받는다."""
    admin = MagicMock(spec=KeycloakAdmin)
    mock_type = type(admin)  # MagicMock 은 인스턴스마다 제 하위 클래스를 둔다
    raw = _ADMIN_CLIENTS[lane](_cfg(_NOWHERE), admin=admin).raw

    result = await _upload(lane, raw, "c1", certcont="PEM")

    assert type(raw) is mock_type
    upload = getattr(admin, _UPLOADS[lane])
    upload.assert_called_once_with("c1", certcont="PEM")
    assert result is upload.return_value
