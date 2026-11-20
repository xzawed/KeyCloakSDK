"""python-keycloak 의 multipart 업로드 둘을 연결의 헤더를 갈아 끼우지 않고 보낸다(sync · aio).

⚠️ **상류는 연결 하나의 헤더를 바꾼다.** python-keycloak 7.1.1 의 `upload_certificate`·
`a_upload_certificate`(`keycloak_admin.py` L7550 · L14374)는 연결의 헤더를 multipart `Content-Type`
의 사본으로 갈아 끼운 채 보내고 돌아온 뒤 되돌린다. 그 admin 의 요청은 전부 그 연결을 쓴다 — 수정 전
실측(`tests/unit/test_admin_upload_certificate_in_flight.py`): 업로드가 나가 있는 동안(sync) ·
업로드 안의 그랜트를 기다리는 동안(sync · aio) 다른 스레드 · 태스크의 요청이 multipart 로 나갔고,
그 사이 토큰 세터가 사본에 실은 bearer 는 되돌릴 때 사라졌다(sync · aio — 연결의 헤더는 옛
bearer). 사본은 `raw_post` 의 남은 키워드 인자(`headers=`)로도 넘어가 쿼리가 됐다 — aio(httpx)는
bearer 를 실은 그 글이라 송신 자리가 언제나 거부했고(`admin_guard.py` 머리 주석 3 의 `IN_URL`),
sync(requests)는 헤더 이름을 실었다. 연결에 철자가 다른 `content-type` 이 있으면 sync 는 그
값(`text/plain`)으로 나갔고, 401 재시도는 읽혀 빈 인코더를 다시 넘겨 sync 가 `Content-Length` 만
싣고 본문을 보내지 않았다(236 B 선언 · 0 B).

**어떻게.** 상류와 같은 경로 · 같은 필드를 연결의 세션으로 보내되 헤더는 그 요청 하나의 것이다 —
연결의 헤더 사본에서 `Content-Type` 을 이름의 대소문자 없이 다 빼고 인코더의 것을 싣는다. 쿼리는
없다. 순서는 상류 `raw_post` · `a_raw_post` 그대로다 — 갱신 자리를 지나 보내고, 401 이면 토큰을 새로
받아 **새 인코더**로 한 번 더 보낸다. 보내기의 실패는 `KeycloakConnectionError` 가 같은 문구로
감싸고(상류 `raw_post` 의 계약 — `raw` 는 그대로 받는다), 결과는 상류처럼
`raise_error_from_response` 와 dict 검사다. aio 는 상류 `_prepare_httpx_request_content` 처럼
인코더를 다 읽어(`to_string`) 싣는다.

세션 · 갱신 자리는 연결의 인스턴스 속성이라 `admin_guard.py` 가 건 훅(머리 주석 2 · 3)을 그대로
지난다 — 위 시험 파일이 보내는 순간의 bearer 검사 · `IN_URL` · 오류 본문 상한 · 리다이렉트 거부 ·
갱신 뒤의 bearer 검사를 다른 `raw` 호출과 나란히 잰다. 이 함수들은 감시 클래스만 부른다(머리 주석
6 — 무장한 연결을 받고, 실패의 프레임 로컬은 거기서 비운다).
"""

from __future__ import annotations

from typing import Any
from urllib.parse import urljoin

import httpx
import requests
from keycloak.exceptions import (
    HTTP_UNAUTHORIZED,
    KeycloakConnectionError,
    KeycloakPostError,
    raise_error_from_response,
)
from keycloak.urls_patterns import URL_ADMIN_CLIENT_CERT_UPLOAD
from requests_toolbelt import MultipartEncoder  # type: ignore[import-untyped]

#: 상류 `raw_post` 가 보내기의 실패를 감싸는 문구.
_UNREACHABLE = "Can't connect to server"
#: RFC 9110 §5.1 — 헤더 이름은 대소문자를 가리지 않는다.
_CONTENT_TYPE = "content-type"


def _path(conn: Any, client_id: str) -> str:
    params = {"realm-name": conn.realm_name, "id": client_id, "attr": "jwt.credential"}
    return URL_ADMIN_CLIENT_CERT_UPLOAD.format(**params)


def _is_content_type(name: object) -> bool:
    """헤더 이름이 `Content-Type` 인가 — bytes 는 HTTP 가 싣는 그대로(latin-1) 읽는다."""
    text = bytes(name).decode("latin-1") if isinstance(name, (bytes, bytearray)) else name
    return isinstance(text, str) and text.lower() == _CONTENT_TYPE


def _encoded(conn: Any, certcont: str) -> tuple[Any, dict[Any, Any]]:
    """(새 인코더, 그 요청 하나의 헤더). 연결의 헤더는 읽기만 한다 — 사본을 떠서 거른다."""
    encoder = MultipartEncoder(fields={"keystoreFormat": "Certificate PEM", "file": certcont})
    copied = dict(conn.headers or {})
    headers = {name: value for name, value in copied.items() if not _is_content_type(name)}
    headers["Content-Type"] = encoder.content_type
    return encoder, headers


def _post(conn: Any, path: str, certcont: str) -> requests.Response:
    encoder, headers = _encoded(conn, certcont)
    try:
        response: requests.Response = conn._s.post(
            urljoin(conn.base_url, path),
            data=encoder,
            headers=headers,
            timeout=conn.timeout,
            verify=conn.verify,
            cert=conn.cert,
        )
    except Exception as exc:
        raise KeycloakConnectionError(_UNREACHABLE) from exc
    return response


async def _apost(conn: Any, path: str, certcont: str) -> httpx.Response:
    encoder, headers = _encoded(conn, certcont)
    try:
        response: httpx.Response = await conn.async_s.request(
            method="POST",
            url=urljoin(conn.base_url, path),
            content=encoder.to_string(),
            headers=headers,
            timeout=conn.timeout,
        )
    except Exception as exc:
        raise KeycloakConnectionError(_UNREACHABLE) from exc
    return response


def _result(response: requests.Response | httpx.Response) -> dict[Any, Any]:
    # `object` — 상류 문구 그대로 찍는다(bytes 도 `str()` 꼴). JSON 본문이면 무엇이든 올 수 있다.
    res: object = raise_error_from_response(response, KeycloakPostError)
    if not isinstance(res, dict):
        msg = f"Unexpected response type. Expected 'dict', received '{type(res)}', value '{res}'."
        raise TypeError(msg)
    return res


def upload(conn: Any, client_id: str, certcont: str) -> dict[Any, Any]:
    """`KeycloakAdmin.upload_certificate` 를 `conn`(무장한 연결)으로 — 연결의 헤더를 쓰지 않는다."""
    path = _path(conn, client_id)
    conn._refresh_if_required()
    response = _post(conn, path, certcont)
    if response.status_code == HTTP_UNAUTHORIZED:
        conn.refresh_token()
        response = _post(conn, path, certcont)  # 새 인코더 — 앞의 것은 읽혀 비었다
    return _result(response)


async def aupload(conn: Any, client_id: str, certcont: str) -> dict[Any, Any]:
    """`KeycloakAdmin.a_upload_certificate` 를 `conn`(무장한 연결)으로 — sync `upload` 와 같다."""
    path = _path(conn, client_id)
    await conn.a__refresh_if_required()
    response = await _apost(conn, path, certcont)
    if response.status_code == HTTP_UNAUTHORIZED:
        await conn.a_refresh_token()
        response = await _apost(conn, path, certcont)  # 새 인코더
    return _result(response)
