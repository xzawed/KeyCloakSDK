"""업로드가 나가 있는 동안에도 같은 admin 의 다른 요청은 `application/json` 이다(등록부
`python-upload-certificate-in-flight-multipart`).

python-keycloak 7.1.1 의 `upload_certificate`·`a_upload_certificate`(`keycloak_admin.py` L7550 ·
L14374)는 연결의 헤더를 multipart `Content-Type` 의 사본으로 갈아 끼운 채
(`self.connection.headers = new_headers`) 보내고 돌아온 뒤 되돌린다. 그 admin 의 요청은 전부 그 연결
하나를 쓴다.

감시 클래스(`_internal/admin_guard.py` 머리 주석 6)는 MRO 가 python-keycloak 자신의 업로드에 닿으면
SDK 의 업로드(`_internal/admin_upload.py`)를 돈다 — 연결의 헤더를 쓰지 않고 그 요청 하나의 헤더로
보낸다. 소비자 하위 클래스 · 클래스 패치의 업로드는 예전처럼 감싼다
(`test_admin_upload_certificate_headers.py`).

순서는 이벤트로 강제한다 — 잠들지 않는다. 대기 상한(`_WAIT`)은 시험이 깨졌을 때의 교착 방지다.
"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import Callable
from typing import Any
from urllib.parse import urlsplit

import pytest
from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakConnectionError, KeycloakPostError
from requests_toolbelt.multipart.decoder import MultipartDecoder

from keycloak_sdk.exceptions import KeycloakAuthError, KeycloakTransportError

from .test_admin_bearer_in_url import (
    _TOKEN,
    _UPLOAD,
    _USER,
    ELSEWHERE,
    IN_URL,
    TOKENS,
    _client,
    _fake_idp,
    _Idp,
    _Seen,
)
from .test_admin_grant import LANES, _attempt
from .test_admin_guard_live import _close
from .test_admin_guard_send_time import _SEND, CAP
from .test_admin_upload_certificate_headers import (
    _ADMIN_CLIENTS,
    _JSON,
    _MULTIPART,
    _UPLOADS,
    _cfg,
    _kinds,
)

pytestmark = pytest.mark.usefixtures("fast_tls")

_WAIT = 10
#: python-keycloak 의 업로드가 싣는 두 필드 — `upload_certificate("c1", "PEM")`.
_FIELDS = {"keystoreFormat": b"Certificate PEM", "file": b"PEM"}
_FIRST = "GD5k2w-first-access-token"
_SECOND = "GD5k2w-second-access-token"
_UNREACHABLE = "Can't connect to server"


def _form(seen: _Seen) -> dict[str, bytes] | str:
    """받은 multipart 본문의 필드 — 그 요청이 실은 `Content-Type` 의 경계로 푼다. 못 풀면 까닭."""
    try:
        parts = MultipartDecoder(seen.body, seen.content_type or "").parts
    except Exception as exc:
        return f"{type(exc).__name__}: declared {seen.length} B, received {len(seen.body)} B"
    out: dict[str, bytes] = {}
    for part in parts:
        disposition = part.headers.get(b"Content-Disposition", b"").decode()
        out[disposition.partition('name="')[2].partition('"')[0]] = part.content
    return out


def _uploads(idp: _Idp) -> list[_Seen]:
    return [s for s in idp.admin_requests() if urlsplit(s.target).path == _UPLOAD]


def _admin_paths(idp: _Idp) -> list[str]:
    return [urlsplit(s.target).path for s in idp.admin_requests()]


def _uploading(lane: str, *args: Any) -> Callable[[Any], Any]:
    """`_attempt` 에 넘길 업로드 — `raw` 의 것(감시 클래스가 덮은 것) 그대로."""
    return lambda kc: getattr(kc.admin.raw, _UPLOADS[lane])(*args)


def _start(lane: str, raw: Any, *args: Any) -> asyncio.Future[Any]:
    """업로드를 다른 스레드(sync) · 태스크(aio)에서 시작한다."""
    if lane == "sync":
        return asyncio.ensure_future(asyncio.to_thread(raw.upload_certificate, *args))
    return asyncio.ensure_future(raw.a_upload_certificate(*args))


async def _get(lane: str, kc: Any) -> Any:
    """같은 admin 의 다른 요청 — 파사드."""
    result = kc.admin.users.get("u1")
    return await result if lane == "aio" else result


async def _held(idp: _Idp) -> bool:
    """붙잡을 요청이 IdP 에 닿았나."""
    return await asyncio.to_thread(idp.holding.wait, _WAIT)


def _raw_user(lane: str, raw: Any, user_id: str = "u1") -> Any:
    return raw.get_user(user_id) if lane == "sync" else raw.a_get_user(user_id)


def _shape(err: BaseException | None) -> tuple[Any, ...]:
    """(타입, 문구, 원인 타입, 원인 문구) — 탈출구는 python-keycloak 의 모양 그대로다."""
    cause = None if err is None else err.__cause__
    return type(err), str(err), None if cause is None else type(cause), str(cause)


# --- 나가 있는 동안 -----------------------------------------------------------------------------


@pytest.mark.parametrize("lane", LANES)
async def test_a_request_sent_while_the_upload_is_out_goes_as_json(lane: str) -> None:
    """업로드 요청이 IdP 에 붙잡힌 동안 같은 admin 의 다른 요청(다른 스레드 · 태스크)은
    `application/json` 이다. 풀린 업로드는 답을 받는다."""
    release = threading.Event()
    with _fake_idp(TOKENS["plain"]) as idp:
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)  # 토큰을 받아 둔다 — 업로드 안에서는 그랜트가 없다
            idp.hold, idp.held_path, idp.answer_held = release, _UPLOAD, True
            upload = _start(lane, kc.admin.raw, "c1", "PEM")
            try:
                arrived = await _held(idp)
                if arrived:
                    await _get(lane, kc)  # 업로드가 나가 있는 동안
            finally:
                release.set()
            result, err = await _attempt("aio", kc, lambda _c: upload)

    assert arrived, f"업로드가 IdP 에 닿지 않았다 — {err!r}"
    assert _kinds(idp) == [
        (f"/{_USER}", _JSON),
        (_UPLOAD, _MULTIPART),
        (f"/{_USER}", _JSON),  # 업로드가 나가 있는 동안
    ], "업로드가 나가 있는 동안 다른 요청이 multipart 로 나갔다"
    assert (result, err) == ({"certificate": "PEM"}, None)


@pytest.mark.parametrize("lane", LANES)
async def test_a_request_sent_while_the_upload_awaits_its_grant_goes_as_json(lane: str) -> None:
    """콜드 토큰 — 업로드 안의 첫 그랜트가 IdP 에 붙잡힌 동안 같은 admin 의 다른 요청(제 그랜트는
    답을 받는다)은 `application/json` 이다. 그랜트가 풀리면 업로드가 나가 답을 받는다."""
    release = threading.Event()
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.hold, idp.answer_held = release, True  # 첫 그랜트 — 업로드 안의 것
        async with _client(lane, idp.url) as kc:
            upload = _start(lane, kc.admin.raw, "c1", "PEM")
            try:
                arrived = await _held(idp)
                if arrived:
                    await _get(lane, kc)  # 업로드가 그랜트를 기다리는 동안
            finally:
                release.set()
            result, err = await _attempt("aio", kc, lambda _c: upload)

    assert arrived, f"업로드 안의 그랜트가 IdP 에 닿지 않았다 — {err!r}"
    assert _kinds(idp) == [
        (f"/{_USER}", _JSON),  # 업로드가 그랜트를 기다리는 동안
        (_UPLOAD, _MULTIPART),
    ], "업로드가 그랜트를 기다리는 동안 다른 요청이 multipart 로 나갔다"
    assert (result, err) == ({"certificate": "PEM"}, None)


async def _refresh(lane: str, conn: Any) -> None:
    """토큰을 새로 받는다 — python-keycloak 의 401 재시도 · 만료 갱신이 부르는 공개 메서드."""
    if lane == "aio":
        await conn.a_refresh_token()
    else:
        conn.refresh_token()


@pytest.mark.parametrize("lane", LANES)
async def test_a_token_refreshed_while_the_upload_awaits_its_grant_stays_on_the_connection(
    lane: str,
) -> None:
    """업로드 안의 갱신 그랜트가 붙잡힌 동안 다른 스레드 · 태스크가 토큰을 새로 받는다 — 토큰
    세터는 연결의 헤더에 bearer 를 제자리에 싣는다(`add_param_headers`). 업로드가 끝난 뒤에도 연결의
    헤더는 그 bearer 를 싣고, 다음 요청도 그것으로 나간다."""
    release = threading.Event()
    with _fake_idp(_FIRST) as idp:
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            conn = kc.admin.raw.connection
            conn.token = {"access_token": _FIRST, "expires_in": 0}  # 공개 세터 — 곧바로 만료다
            idp.hold, idp.answer_held = release, True  # 업로드 안의 갱신 그랜트
            idp.access_token = _SECOND
            upload = _start(lane, kc.admin.raw, "c1", "PEM")
            try:
                arrived = await _held(idp)
                if arrived:
                    await _refresh(lane, conn)  # 업로드가 그랜트를 기다리는 동안
            finally:
                release.set()
            result, err = await _attempt("aio", kc, lambda _c: upload)
            carried = conn.headers.get("Authorization")
            await _get(lane, kc)

    assert arrived, f"업로드 안의 그랜트가 IdP 에 닿지 않았다 — {err!r}"
    assert carried == f"Bearer {_SECOND}", "업로드 동안 받은 토큰이 연결의 헤더에서 사라졌다"
    assert idp.admin_requests()[-1].authorization == f"Bearer {_SECOND}"
    assert (result, err) == ({"certificate": "PEM"}, None)


# --- 업로드 요청 자체 ---------------------------------------------------------------------


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_goes_out_whole_with_no_query(lane: str) -> None:
    """업로드는 경로 그대로 · 쿼리 없이 나가고 python-keycloak 이 돌려주던 값을 돌려준다 — 본문은 두
    필드의 multipart, bearer 는 연결의 것이다. 연결의 헤더는 같은 객체 그대로다."""
    token = TOKENS["plain"]
    with _fake_idp(token) as idp:
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            headers = kc.admin.raw.connection.headers
            before = dict(headers)
            result, err = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))
            after = kc.admin.raw.connection.headers

    assert (result, err) == ({"certificate": "PEM"}, None)
    sent = idp.admin_requests()[-1]
    assert (sent.method, sent.target) == ("POST", _UPLOAD), "업로드의 URL 에 쿼리가 실렸다"
    assert sent.authorization == f"Bearer {token}"
    assert _form(sent) == _FIELDS
    assert after is headers, "업로드가 연결의 헤더를 갈아 끼웠다"
    assert after == before


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_carries_one_content_type_whatever_the_connection_spells(
    lane: str,
) -> None:
    """연결의 헤더에 철자가 다른 `Content-Type` 이 더 있어도(공개 `add_param_headers` — 소문자
    이름 · bytes 이름) 업로드는 인코더의 것 하나만 싣는다(RFC 9110 §5.1 — 이름은 대소문자를
    가리지 않는다)."""
    with _fake_idp(TOKENS["plain"]) as idp:
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            conn = kc.admin.raw.connection
            conn.add_param_headers("content-type", "text/plain")
            conn.add_param_headers(b"CONTENT-TYPE", b"text/plain")
            result, err = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))

    assert (result, err) == ({"certificate": "PEM"}, None)
    sent = idp.admin_requests()[-1]
    assert [kind.startswith(_MULTIPART) for kind in sent.content_types] == [True], sent
    assert _form(sent) == _FIELDS


@pytest.mark.parametrize("lane", LANES)
async def test_a_401_retry_sends_the_whole_multipart_body_again(lane: str) -> None:
    """IdP 가 업로드에 401 을 답한다 — 토큰을 새로 받아 한 번 더 보내는 재시도도 두 필드를 다
    싣고, 선언한 `Content-Length` 만큼 보낸다(인코더는 한 번 읽으면 빈다)."""
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.uploads = [(401, b'{"error": "unauthorized"}')]
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            result, err = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))

    sent = _uploads(idp)
    measured = [(s.length, len(s.body)) for s in sent]
    assert [_form(s) for s in sent] == [_FIELDS, _FIELDS], f"(선언 B, 받은 B) {measured} — {err!r}"
    assert all(declared == received for declared, received in measured), measured
    assert idp.paths()[-3:] == [_UPLOAD, _TOKEN, _UPLOAD], "401 뒤 토큰을 새로 받아 보내지 않았다"
    assert (result, err) == ({"certificate": "PEM"}, None)


@pytest.mark.parametrize("lane", LANES)
async def test_an_upload_answered_with_a_non_object_is_a_type_error(lane: str) -> None:
    """python-keycloak 과 같은 검사 · 같은 문구 — 2xx 본문이 JSON 객체가 아니면 `TypeError`."""
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.uploads = [(200, b"[1]")]
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            _, err = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))

    expected = "Unexpected response type. Expected 'dict', received '<class 'list'>', value '[1]'."
    assert (type(err), str(err)) == (TypeError, expected)


# --- 보내는 자리의 훅 — 다른 `raw` 호출과 같다 --------------------------------------------


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_is_judged_at_send_like_other_raw_calls(lane: str) -> None:
    """세션 기본 헤더의 규칙 밖 bearer(`admin_guard.py` 머리 주석 3) — 연결의 헤더에 bearer 가
    없는(자격증명도 토큰도 없는) admin 이라야 기본값이 실린다. 업로드도 대조(`get_user`)처럼
    보내는 자리에서 거부되고, python-keycloak 의 `raw_*` 처럼 `KeycloakConnectionError` 가 그
    거부를 감싼다."""
    with _fake_idp(TOKENS["plain"]) as idp:
        admin = KeycloakAdmin(server_url=idp.url, realm_name="r")
        client = _ADMIN_CLIENTS[lane](_cfg(idp.url), admin=admin)
        try:
            session = admin.connection._s if lane == "sync" else admin.connection.async_s
            session.headers["Authorization"] = "Bearer a=bc"
            upload = getattr(client.raw, _UPLOADS[lane])
            _, uploaded = await _attempt(lane, client, lambda _c: upload("c1", "PEM"))
            _, other = await _attempt(lane, client, lambda c: _raw_user(lane, c.raw))
        finally:
            await _close(lane, client)

    assert idp.admin_requests() == [], "규칙 밖의 bearer 가 나갔다"
    expected = (KeycloakConnectionError, _UNREACHABLE, KeycloakAuthError, _SEND)
    assert _shape(uploaded) == _shape(other) == expected


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_checks_the_bearer_after_the_refresh_like_other_raw_calls(
    lane: str,
) -> None:
    """연결의 헤더에 실린 규칙 밖 bearer — 갱신 자리 뒤의 검사(머리 주석 2)가 보내기 전에 거부한다.
    업로드도 대조(`get_user`)처럼 `KeycloakAuthError` 그대로다."""
    with _fake_idp(TOKENS["plain"]) as idp:
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            kc.admin.raw.connection.add_param_headers("Authorization", "Bearer a=bc")
            _, uploaded = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))
            _, other = await _attempt(lane, kc, lambda c: _raw_user(lane, c.admin.raw))

    assert _admin_paths(idp) == [f"/{_USER}"], "규칙 밖의 bearer 가 나갔다"
    assert _shape(uploaded) == _shape(other) == (KeycloakAuthError, _SEND, None, "None")


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_whose_url_carries_the_token_is_refused_like_other_raw_calls(
    lane: str,
) -> None:
    """클라이언트 id 가 지금 보낼 토큰이다 — URL 이 토큰을 싣는 업로드는 보내지 않는다(`IN_URL`,
    머리 주석 3). 대조는 같은 토큰을 사용자 id 로 넘긴 `get_user`."""
    token = TOKENS["plain"]
    with _fake_idp(token) as idp:
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            _, uploaded = await _attempt(lane, kc, _uploading(lane, token, "PEM"))
            _, other = await _attempt(lane, kc, lambda c: _raw_user(lane, c.admin.raw, token))

    assert _admin_paths(idp) == [f"/{_USER}"], "토큰을 URL 에 실었다"
    expected = (KeycloakConnectionError, _UNREACHABLE, KeycloakTransportError, IN_URL)
    assert _shape(uploaded) == _shape(other) == expected


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_reads_an_error_body_only_up_to_the_cap(lane: str) -> None:
    """IdP 가 업로드에 상한을 넘는 404 본문을 답한다 — 상한에서 잘린다(`admin_body.py`)."""
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.uploads = [(404, b"x" * (CAP + 1))]
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            _, err = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))

    assert type(err) is KeycloakPostError, repr(err)
    assert (err.response_code, len(err.response_body)) == (404, CAP)


@pytest.mark.parametrize("lane", LANES)
async def test_the_upload_does_not_follow_a_redirect(lane: str) -> None:
    """IdP 가 업로드에 307 을 답한다 — 따라가지 않고(`redirects.py`) 그 상태의 오류다."""
    with _fake_idp(TOKENS["plain"]) as idp:
        idp.uploads = [(307, b"{}")]
        async with _client(lane, idp.url) as kc:
            await _get(lane, kc)
            _, err = await _attempt(lane, kc, _uploading(lane, "c1", "PEM"))

    assert ELSEWHERE not in idp.paths(), "업로드가 리다이렉트를 따라갔다"
    assert (type(err), getattr(err, "response_code", None)) == (KeycloakPostError, 307), repr(err)
