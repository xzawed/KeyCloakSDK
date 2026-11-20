"""admin 레인의 하드닝을 **요청이 나가는 순간에** 성립시킨다 — 생성 때 한 번이 아니라.

⚠️ **python-keycloak 은 하드닝이 걸린 객체를 갈아 끼우는 공개 세터를 둔다** —
`KeycloakAdmin.connection` 과 `KeycloakOpenID.connection`. 예전에는 리다이렉트 하드닝
(`redirects.py`)과 그랜트 검사(`admin_grant.py`)를 생성 때 **그 객체들에** 한 번 걸었으므로
`raw.connection = ...` 한 줄이면 둘 다 사라졌다 — sync 는 빈 `access_token` 을
`Authorization: Bearer ` 로 보냈고, aio 는 h11 이 그 헤더를 거부해 `KeycloakTransportError` 였다.
이미 빈 bearer 를 쥔 채 주입된 admin 은 그랜트 없이 곧바로 보냈고, 설치 중 `setattr` 이 실패하면
raw `AttributeError` 와 반쯤 감긴 객체가 남았다(등록부 `python-admin-grant-guard-install-time`,
`tests/unit/test_admin_guard_live.py`).

그 뒤에도 검사는 **무장 때**였다 — `admin.connection` 을 읽을 때와 갱신 자리 바로 뒤. 송신까지의
틈으로 공개 API 만으로 닿았다(등록부 `python-admin-guard-send-time`, 수정 전 실측
`tests/unit/test_admin_guard_send_time.py`): python-keycloak 의 401 재시도는 갱신 자리를 거치지
않고 다시 보내므로(`KeycloakOpenIDConnection.raw_get`·`a_raw_get` 등) 첫 요청이 나가 있는 동안
다른 호출자가 토큰 세터로 실은 bearer 가 나갔고, 글자 그대로 찾던 `Authorization`·`Bearer ` 와
철자가 다른 bearer(`bearer …`·`authorization: …`·토큰 없는 `Bearer`)와 세션의 기본 헤더도 검사
없이 나갔으며, 그랜트 객체에 공개 세터로 끼운 연결은 다음 읽기 전까지 훅이 없었다.

**어떻게.**

1. 진짜 `KeycloakAdmin`(과 그 하위 클래스)은 인스턴스의 클래스를 하위 클래스로 바꾼다 —
   정체성과 `isinstance` 는 그대로다. 그 클래스의 `connection` 게터는 python-keycloak 의 admin
   메서드가 요청 직전에 읽는 자리다(모두 `self.connection.raw_*` 로 보내고 `_connection` 을
   직접 읽는 메서드는 없다, 7.1.1 실측). 읽을 때마다 **지금 살아 있는** 연결 그래프에 훅이 다
   걸렸는지 보고 빠진 것을 다시 건다.
2. 그래프의 훅 열두 자리(전부 인스턴스 속성): 두 세션의 `resolve_redirects`(`redirects.py`),
   중첩 `KeycloakOpenID` 의 그랜트 넷(`admin_grant.py`), 그랜트 세션 둘(`_s`·`async_s`)의 `send` —
   그랜트 응답 본문의 크기 상한(`token_cap.py`), REST 세션 둘(`_s`·`async_s`)의 `send` — 보내는
   순간의 bearer 검사(아래 3)와 응답 본문의 끝(`admin_body.py` — 오류 본문은 상한까지, 파사드
   쓰기의 2xx 는 읽지 않는다), 그리고 연결의 `_refresh_if_required`·`a__refresh_if_required` —
   그 **뒤**에서 연결의 헤더에 실린 bearer 를 같은 판정으로 본다. 그 밖에 두 sync 세션의 어댑터마다
   `max_retries` 를 재시도 없는 정책으로 두고(`retries.py`), HTTPAdapter 마다 풀 관리자의
   `connection_from_pool_key`·`proxy_manager_for`(와 이미 있는 프록시 관리자)를 응답 읽기의
   마감·예산 훅으로 감싼다(`wire.py`) — 어댑터 수만큼의 자리다. 그리고 그랜트 객체의 감시(아래 4).
3. **보내는 순간의 bearer 검사.** REST 세션의 `send` 는 나갈 요청의 헤더 — 세션 기본값과 요청
   헤더를 합친 것 — 에서 `Authorization` 을 이름도 scheme 도 대소문자 없이 찾아(RFC 9110 §5.1 ·
   RFC 7235 §2.1) bearer 규칙대로 둔다(`bearer.py` — 빈 것·맞지 않는 것은 거부, 다듬을 것은
   다듬어 싣는다). 401 재시도도, 다른 호출자가 그 사이 실은 것도 이 자리를 지난다. 규칙을 지난
   bearer 의 토큰이 요청 URL 에 — 그대로든 퍼센트 디코딩한 꼴(`unquote_plus`)로든 — 나타나면 그
   요청도 보내지 않는다(`KeycloakTransportError(IN_URL)` — 등록부
   `python-raw-upload-certificate-bearer-in-url`): python-keycloak 의 `raw_*` 는 남은 키워드 인자를
   전부 쿼리로 보내고, `a_upload_certificate` 는 그 자리에 bearer 를 실은 헤더 사전을 넘겨 httpx 가
   그 글을 URL 에 실었다(7.1.1 실측 — 서버·프록시의 접근 로그에 토큰이 남는다). `raw` 의 업로드는
   이제 쿼리 없이 보낸다(6) — python-keycloak 의 것을 부르는 소비자 코드는 여전히 여기서 거부된다.
   세션 안의 거부는 python-keycloak 의 `raw_*`(와 6 의 업로드)가 `KeycloakConnectionError` 로
   감싸므로 파사드 경계가 같은 타입·메시지로 새로 만든다(`admin/_translate.refused_send`) — 탈출구
   `raw` 는 감싼 채 받는다(§4(b)). 갱신 자리 뒤의 검사(2)는 남긴다 — 연결의 헤더에서 거부되는 것은
   `raw` 로도 오늘의 `KeycloakAuthError` 그대로이고, 다듬은 값이 연결에 남는다.
4. **그랜트 객체의 공개 세터.** 그랜트 객체(중첩 `KeycloakOpenID`)는 처음 무장할 때 클래스를
   바꿔(`openid_watch.py`) `connection` 세터가 새 연결을 끼우기 **전에** 그랜트 세션의 훅을 다
   건다(`arm_grant_connection` — 전부이거나 아무것도, 못 걸면 끼우지 않는다). 쥔 그랜트 객체로
   직접 부르든 다른 호출자가 401 재시도 도중 바꾸든, 그 연결로 나가는 그랜트는 무장된 뒤다.
5. 설치는 전부이거나 아무것도 아니다 — 먼저 다 계획(검증)하고, 걸다가 하나라도 실패하면 건
   것을 되돌린 뒤 `KeycloakConfigError` 로 거부한다. 그래프를 읽다 난 실패는 무엇을 던졌든
   그 거부이고, 훅은 되돌림과 같은 통로(인스턴스 `__dict__`, 그랜트 객체의 클래스)로 쓰며, 설치
   도중의 재진입은 거부한다(`_install`·`_apply`).
6. **업로드가 갈아 끼운 헤더.** python-keycloak 의 `upload_certificate`·`a_upload_certificate` 는
   연결의 헤더를 multipart `Content-Type` 사본으로 갈아 끼운 채 보내고, 보내기가 **돌아온 뒤에만**
   되돌린다(`try`/`finally` 없음, 7.1.1 실측). 그 연결은 admin 의 요청이 전부 함께 쓴다 — 보내는
   동안 · 업로드 안의 그랜트를 기다리는 동안 다른 스레드·태스크의 요청이 multipart 로 나갔고, 그
   사이 토큰 세터가 사본에 실은 bearer 는 되돌릴 때 사라졌다(등록부
   `python-upload-certificate-in-flight-multipart`,
   `tests/unit/test_admin_upload_certificate_in_flight.py`). 던지면 — aio 는 위 3 의 `IN_URL` 로
   언제나, sync 는 전송 실패에서, 취소도 — 이후 요청이 전부 multipart 였다(등록부
   `python-upload-certificate-headers-not-restored`,
   `tests/unit/test_admin_upload_certificate_headers.py`).
   감시 클래스가 둘을 덮고, 감싼 클래스의 것을 부를 때 MRO 대로 찾는다(`_unwatched`). 그것이
   python-keycloak 자신의 함수면(import 때 쥔 객체 그대로) SDK 의 업로드(`admin_upload.py`)를 돈다
   — `connection` 을 읽어(무장) 같은 경로 · 필드를 그 요청 하나의 헤더로 보내고, 연결의 헤더는
   쓰지 않는다. 소비자의 하위 클래스 · 클래스 패치면 그것을 같은 인자로 부르고, 무엇을 던지든
   (`BaseException`) 부르기 **전**에 읽은 연결에 그때의 헤더 값을 되돌린 뒤 같은 예외를 다시
   던진다(성공이면 아무것도 하지 않는다). ⚠️ 그 소비자 코드가 python-keycloak 의 업로드를
   부르면(`super()`) 보내는 **동안**의 multipart 는 그대로다 — 감시 클래스는 소비자 코드를 바꾸지
   않는다.
7. **업로드가 던진 오류의 프레임 로컬.** 그 둘이 던지면 python-keycloak 의 업로드
   (`orig_headers`·`new_headers`)와 `raw_post`·`a_raw_post`(`kwargs`), httpx `request`(`params`·
   `headers`·`request` — 토큰이 URL 문자열 안이다)·requests·urllib3(`headers`), 위 3 의
   `sent`(`request`) 프레임이 bearer 를 쥔 채 오류 수집기(Sentry Python 기본값 ·
   `TracebackException(capture_locals=True)`)에 찍혔다(등록부
   `python-raw-upload-traceback-locals-bearer`, `tests/unit/test_admin_upload_traceback_locals.py`).
   6 의 SDK 업로드도 그 요청 하나의 헤더를 프레임에 쥔다. 감시 클래스가 (소비자의 업로드면 6 의
   되돌림 뒤에) 그 예외에서 닿는 traceback 마다 끝난 프레임의 로컬을 비우고(`_clear_locals`) 같은
   객체를 다시 던진다. 타입·메시지·사슬·프레임(줄 번호)은 그대로다 —
   `_internal/frames.py` 처럼 traceback 을 떼지 않는다: 탈출구의 traceback 은 python-keycloak 의
   것이다(§4(b)).

**지키는 범위.** 비공개 상태를 쓰지 않고 닿는 것 — 파사드, `raw` 의 python-keycloak 공개 API
(메서드·프로퍼티 세터), 여러 스레드·태스크가 함께 쓰는 클라이언트, python-keycloak 자신의 동작
(401 재시도, 그랜트 객체·그 연결·세션의 지연 생성 — 7.1.1 은 처음 읽을 때 한 번 만들고 다시 만들지
않는다). ⚠️ **범위 밖** — 밑줄 속성의 쓰기·교체(`_connection`·`_keycloak_openid`·`_s` …)와 HTTP
클라이언트 객체 자체의 교체·설정(`async_s` · 그 auth·이벤트 훅·리다이렉트 설정), 내부의
`copy.copy`, 프록시(`wrapt.ObjectProxy`)로 감싸기, 클래스 몽키패치, 소비자 코드가 부른
python-keycloak 업로드의 보내는 동안의 헤더(6): 이 중 막히는 것이 있어도 계약이 아니다.

**왜 저장된 토큰이 아니라 헤더인가.** 보내는 것이 헤더다. 둘은 갈린다 — 자격증명 없이 토큰만
받은 admin 이 만료되면 python-keycloak 은 토큰을 `None` 으로 비우고 헤더(`Bearer `)는 남긴다.

**기각한 것.** (a) SDK 진입점(`raw` 게터·`call`/`acall`)에서만 재설치 — `raw` 를 쥔 소비자가
연결을 바꾸고 곧바로 메서드를 부르면 그 사이에 SDK 코드가 한 줄도 돌지 않는다. (b) 연결에 한 번
거는 요청 시점 검사 — 연결째 갈아 끼워진다. (c) `connection` **세터**만 가로채기 — 비공개
`_connection` 쓰기를 못 본다(그랜트 객체는 세터만 본다 — 4, 비공개 쓰기는 범위 밖이다). (d) 보내는
자리 검사만 두고 갱신 자리 뒤의 검사를 없애기 — 연결의 헤더에서 거부할 수 있는 것까지 `raw` 에서
python-keycloak 의 `KeycloakConnectionError` 로 바뀐다. 게터가 치르는 값은 읽기마다 그 자리들(훅
열두 자리와 어댑터)을 확인하는 것이다.

⚠️ 목(`MagicMock(spec=KeycloakAdmin)`)은 클래스를 바꾸면 `isinstance` 가 깨진다(실측) — 그래서
진짜 `KeycloakAdmin`·`KeycloakOpenID` 만 감시하고, 그 밖의 객체는 생성 때 한 번 건다.
"""

from __future__ import annotations

import functools
import inspect
import threading
import traceback
import weakref
from collections.abc import Awaitable, Callable, Coroutine, Iterable
from types import FunctionType
from typing import Any, cast
from urllib.parse import unquote_plus

import httpx
import requests
from keycloak import KeycloakAdmin, KeycloakOpenID

from ..exceptions import KeycloakAuthError, KeycloakConfigError, KeycloakTransportError
from ..tokens import _usable_access_token
from .admin_body import abounded_send, bounded_send
from .admin_grant import _ASYNC_GRANTS, _SYNC_GRANTS, _achecked, _checked
from .admin_upload import aupload, upload
from .bearer import _TRIM, SENDING, sendable
from .frames import reachable
from .openid_watch import HARDENERS, watched_type
from .redirects import _refuse_redirects, _require, _unsupported
from .retries import NO_RETRY, retrying_adapters
from .token_cap import acapped_send, capped_send
from .wire import read_hooks

#: 훅을 거는 일은 한 번에 하나 — 되돌림이 다른 스레드가 막 건 훅을 지우지 않게 한다.
_LOCK = threading.RLock()
#: 이 스레드가 지금 그래프를 읽거나 훅을 거는 중인가(`_install`). RLock 은 **같은 스레드**의
#: 재진입을 막지 않는다 — 그 사이 소비자 코드(`__getattribute__`·디스크립터·지연 프로퍼티)가
#: `admin.connection` 을 다시 읽으면 안쪽 설치가 끝까지 걸고, 바깥 설치가 실패해 되돌리면 자기가
#: 먼저 건 자리만 지워 거부된 연결에 SDK 훅이 반쯤 남았다(실측: 여덟 중 일곱). 재진입한 설치는
#: 그래서 거부한다 — 그 거부가 바깥 설치를 실패시키고, 바깥이 전부 되돌린다.
_LOCAL = threading.local()
#: 이 모듈이 건 래퍼. 「이미 걸려 있나」를 이것과 아래 주인으로 가른다.
_OURS: weakref.WeakSet[Callable[..., Any]] = weakref.WeakSet()
#: 래퍼가 걸린 객체. 얕은 복사본(`copy.copy(conn)`)은 원본의 래퍼를 인스턴스 속성째 물려받는데 그
#: 래퍼는 **원본의** 헤더를 본다 — 주인을 대조하지 않으면 복사본의 빈 bearer 가 검사 없이 나갔다
#: (실측). 래퍼 함수의 속성으로 둔다: 전역 표에 두면 객체를 붙잡아 놓아 주지 않는다.
_OWNER = "__kcsdk_owner__"
#: 래퍼를 걸기 **전** 그 자리의 인스턴스 상태(`_ABSENT` 면 클래스의 것이었다). 복사본이 물려받은
#: 래퍼는 다시 감싸지 않고 이것으로 **벗긴다** — 그 래퍼는 원본에 묶인 메서드로 원본의 갱신·그랜트를
#: 부르고 원본의 헤더를 본다. 감싸기만 하면 복사본의 만료 갱신이 원본에서 돌았고, bearer 를 싣지
#: 않는 복사본의 요청이 원본의 빈 bearer 로 거부됐다(실측). 복사본이 SDK 없이 가졌을 것이 이것이다.
_PRIOR = "__kcsdk_prior__"
#: 감시 클래스가 감싼 원래 `connection` 프로퍼티 — 정리 경로가 무장 없이 읽는 자리다.
_BASE = "__kcsdk_connection__"
#: 계획에서 그랜트 객체의 클래스를 바꾸는 자리 — `_apply`·`_undo` 가 인스턴스 `__dict__` 대신
#: 클래스로 쓰고 되돌린다.
_CLASS = "__class__"
_WATCHED: dict[type[KeycloakAdmin], type[KeycloakAdmin]] = {}
#: python-keycloak 자신의 업로드 둘 — 감시 클래스가 MRO 로 찾은 것이 이것이면 SDK 의 업로드를
#: 돈다(머리 주석 6). import 때 쥔다: 클래스 패치는 부를 때 찾은 것이 이것이 아니어야 그대로 돈다.
_OWN_UPLOAD = KeycloakAdmin.upload_certificate
_OWN_AUPLOAD = KeycloakAdmin.a_upload_certificate
_ABSENT = object()
_GRANT = "admin token grant"
#: 그랜트 연결의 자리(메시지용) — 중첩 `KeycloakOpenID` 의 `connection`.
_GRANTED = "connection.keycloak_openid.connection"
#: RFC 7235 §2.1 — auth-scheme 은 대소문자를 가리지 않는다(ASCII). 이 scheme 의 자격증명만 본다.
_SCHEME = "bearer"
#: RFC 9110 §5.1 — 헤더 이름도 대소문자를 가리지 않는다.
_AUTHORIZATION = "authorization"
#: 보내는 순간의 URL 거부 — 나갈 bearer 의 토큰이 요청 URL 에 나타난다(머리 주석 3).
IN_URL = "admin request refused: the request URL would carry the access token"
_SUPPORT = (
    "Pin python-keycloak to a supported version (>=7.1,<8) and report this at "
    "https://github.com/xzawed/KeyCloakSDK/issues."
)
#: 훅을 걸 수 없을 때 거부 메시지가 말하는 위험.
_UNUSABLE = "send an unusable access token to the admin API"
_UNBOUNDED = "read an unbounded token grant response into memory"
_UNREAD = "read an unbounded admin error response, or a response body it never uses, into memory"
_LATE = "keep an admin request waiting on a trickled response past its timeout"

#: (걸 객체, 속성 이름, 걸 값, 메시지에 쓸 자리). 클래스로 두지 않는다 — 공개 뿌리에서 닿지
#: 않는 SDK 선언은 `test_facade_dump.py` 가 면제를 요구한다.
_Hook = tuple[Any, str, Any, str]


def _text(value: object) -> str | None:
    """헤더 값의 글자 — bytes 는 HTTP 가 싣는 그대로(latin-1) 읽는다(requests 는 bytes 값을 그대로
    보낸다). 둘 다 아니면 `None` — 보지 않는다."""
    if isinstance(value, (bytes, bytearray)):
        return bytes(value).decode("latin-1")
    return value if isinstance(value, str) else None


def _is_authorization(name: object) -> bool:
    text = _text(name)
    return text is not None and text.isascii() and text.lower() == _AUTHORIZATION


def _bearer_parts(value: str) -> tuple[str, str] | None:
    """`value`(Authorization 값 하나)가 bearer 자격증명이면 (scheme 철자, 토큰 자리), 아니면 `None`.

    scheme 은 첫 SP·HTAB·CR·LF 앞까지(없으면 끝까지)이고 ASCII 대소문자를 가리지 않는다 —
    `bearer …`·`BEARER …`·토큰 없는 `Bearer` 도 bearer 다. 토큰 자리는 그 뒤에서 가르는 SP 하나를
    뗀 나머지다 — 다른 공백은 규칙(`bearer.py`)이 다듬거나 거부한다. `Bearer <토큰>` 은 예전과 같은
    자리를 낸다."""
    end = next((i for i, ch in enumerate(value) if ch in _TRIM), len(value))
    scheme = value[:end]
    if not (scheme.isascii() and scheme.lower() == _SCHEME):
        return None
    return scheme, value[end + 1 :] if value.startswith(" ", end) else value[end:]


def _settled(value: str) -> str | None:
    """보낼 Authorization 값 하나 — bearer 가 아니면 그대로, bearer 면 토큰을 규칙대로 다듬은 값
    (scheme 의 철자는 그대로), 규칙에 맞지 않으면 `None`(거부). 빈 토큰은 auth 레인과 같은 오류를
    여기서 던진다(`tokens._usable_access_token`)."""
    parts = _bearer_parts(value)
    if parts is None:
        return value
    scheme, token = parts
    bearer = sendable(_usable_access_token({"access_token": token}))
    return None if bearer is None else f"{scheme} {bearer}"


def _settle_bearer(conn: Any) -> bool:
    """연결의 헤더에 실린 bearer 를 규칙대로 둔다 — 이름·scheme 의 철자와 무관하게 전부. 다듬어야
    하면 다듬은 값으로 바꿔 싣고, 맞지 않는 것이 있으면 참(거부)이다."""
    for name, value in list((conn.headers or {}).items()):
        text = _text(value) if _is_authorization(name) else None
        if text is None:
            continue
        settled = _settled(text)
        if settled is None:
            return True
        if settled != text:
            conn.add_param_headers(name, settled)
    return False


def _require_usable_bearer(conn: Any) -> None:
    """연결의 헤더에 실린 bearer 가 쓸 수 있고 bearer 규칙에 맞는가(다듬어 싣는 것 포함) — 아니면
    `KeycloakAuthError`.

    거부는 헤더 값을 쥐지 않은 이 프레임에서 던진다 — 탈출구 `raw` 의 traceback 은 python-keycloak
    프레임을 지나 소비자에게 그대로 가고, 오류 수집기는 프레임 로컬을 찍는다."""
    if _settle_bearer(conn):
        raise KeycloakAuthError(SENDING)


def _bearer_checked(conn: Any, refresh: Callable[..., Any]) -> Callable[..., Any]:
    def checked(*args: Any, **kwargs: Any) -> Any:
        result = refresh(*args, **kwargs)
        _require_usable_bearer(conn)
        return result

    return checked


def _abearer_checked(
    conn: Any, refresh: Callable[..., Any]
) -> Callable[..., Coroutine[Any, Any, Any]]:
    async def checked(*args: Any, **kwargs: Any) -> Any:
        result = await refresh(*args, **kwargs)
        _require_usable_bearer(conn)
        return result

    return checked


def _unsendable(request: requests.PreparedRequest) -> bool:
    """나갈 sync 요청의 Authorization 을 규칙대로 둔다 — requests 가 세션 기본값과 요청 헤더를 합친
    `CaseInsensitiveDict` 라 값은 하나다. 참이면 거부."""
    value = request.headers.get("Authorization")
    text = _text(value)
    if text is None:
        return False
    settled = _settled(text)
    if settled is None:
        return True
    if settled != text:
        request.headers["Authorization"] = settled
    return False


def _aunsendable(request: httpx.Request) -> bool:
    """나갈 aio 요청의 Authorization 을 규칙대로 둔다 — httpx 가 클라이언트 기본값과 요청 헤더를
    합친 `Headers` 다. 철자가 다른 이름 둘이면 값도 둘이다(그대로 둘 다 나간다) — 전부 본다.
    참이면 거부."""
    headers = request.headers
    values = headers.get_list(_AUTHORIZATION)
    kept = [settled for settled in map(_settled, values) if settled is not None]
    if len(kept) != len(values):
        return True
    if kept != values:
        pairs = [("Authorization", value) for value in kept]
        headers.update(httpx.Headers(pairs, encoding=headers.encoding))
    return False


def _in_url(url: object, values: Iterable[object]) -> bool:
    """나갈 Authorization 값(`values`) 가운데 bearer 의 토큰이 요청 URL 에 나타나는가 — 그대로든
    퍼센트 디코딩한 꼴(`unquote_plus` — 쿼리의 `+` 는 공백이다)로든(머리 주석 3). 규칙
    (`_unsendable`·`_aunsendable`)을 지난 뒤에 부른다 — bearer 값의 토큰 자리는 다듬어진, 비어 있지
    않은 b64token 이다."""
    shown = str(url)
    decoded = unquote_plus(shown)
    for value in values:
        text = _text(value)
        parts = None if text is None else _bearer_parts(text)
        if parts is not None and (parts[1] in shown or parts[1] in decoded):
            return True
    return False


def _bearer_sent(send: Callable[..., requests.Response]) -> Callable[..., requests.Response]:
    """REST 세션의 `send` — 보내는 순간의 bearer 검사(머리 주석 3). 거부는 헤더 값을 쥐지 않은
    프레임에서 던진다."""

    def sent(request: requests.PreparedRequest, **kwargs: Any) -> requests.Response:
        if _unsendable(request):
            raise KeycloakAuthError(SENDING)
        if _in_url(request.url, [request.headers.get("Authorization")]):
            raise KeycloakTransportError(IN_URL)
        return send(request, **kwargs)

    return sent


def _abearer_sent(
    send: Callable[..., Awaitable[httpx.Response]],
) -> Callable[..., Coroutine[Any, Any, httpx.Response]]:
    """sync `_bearer_sent` 와 같다 — httpx `AsyncClient.send`."""

    async def sent(request: httpx.Request, **kwargs: Any) -> httpx.Response:
        if _aunsendable(request):
            raise KeycloakAuthError(SENDING)
        if _in_url(request.url, request.headers.get_list(_AUTHORIZATION)):
            raise KeycloakTransportError(IN_URL)
        return await send(request, **kwargs)

    return sent


def _missing(what: str, where: str, risk: str = _UNUSABLE) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot check the {what}: this SDK expects python-keycloak to expose {where}, but it is "
        f"missing or not callable. Refusing to build an admin client that could {risk}. {_SUPPORT}"
    )


def _own(target: Any, name: str) -> Any:
    """인스턴스 자신의 속성(클래스에서 온 것이 아닌) — 우리가 건 훅은 여기에만 산다."""
    return getattr(target, "__dict__", {}).get(name)


def _is_ours(hook: object) -> bool:
    """이 모듈이 만든 래퍼인가. 래퍼는 언제나 함수라 그것부터 본다 — 소비자가 먼저 건 훅이 해시되지
    않는 객체여도(`eq=True` 데이터클래스) 소속 대조가 raw `TypeError` 로 설치를 깨지 않는다
    (실측)."""
    return isinstance(hook, FunctionType) and hook in _OURS


def _hooked(target: Any, name: str) -> bool:
    """`target.name` 이 이 모듈이 **바로 이 객체에** 건 래퍼인가(복사본이 물려받은 것은 아니다)."""
    hook = _own(target, name)
    return _is_ours(hook) and getattr(hook, _OWNER, None) is target


def _base(target: Any, name: str) -> tuple[Any, object]:
    """(감쌀 것, 감싸기 전 인스턴스 상태). 복사본이 물려받은 래퍼면 벗겨 **복사본 자신의** 것을 낸다
    — 원본이 인스턴스에 두었던 것(소비자의 훅)이면 그것, 아니면 클래스의 것을 이 객체에 묶은 것."""
    state = getattr(target, "__dict__", {}).get(name, _ABSENT)
    if not _is_ours(state):
        return getattr(target, name, None), state
    prior = vars(state)[_PRIOR]  # 우리 래퍼가 아니다 — 걸 때 벗겨 둔 상태다
    if prior is not _ABSENT:
        return prior, prior
    attr = inspect.getattr_static(type(target), name, None)
    get = getattr(type(attr), "__get__", None)
    return (attr if get is None else get(attr, target, type(target))), _ABSENT


def _plan_redirects(hooks: list[_Hook], session: Any, what: str, where: str) -> None:
    if _own(session, "resolve_redirects") is _refuse_redirects:
        return
    if not callable(getattr(session, "resolve_redirects", None)):
        raise _unsupported(what, "_s.resolve_redirects")
    hooks.append((session, "resolve_redirects", _refuse_redirects, f"{where}.resolve_redirects"))


def _plan_retries(hooks: list[_Hook], session: Any, where: str) -> None:
    """세션의 어댑터마다 재시도 없는 정책(`retries.py`) — 소비자가 나중에 `mount` 한 것도."""
    for prefix, adapter in retrying_adapters(session, where):
        hooks.append((adapter, "max_retries", NO_RETRY, f"{where}.adapters[{prefix!r}]"))


def _plan_reads(hooks: list[_Hook], session: Any, what: str, where: str) -> None:
    """세션의 HTTPAdapter 마다 응답 읽기의 마감·예산 훅(`wire.py`) — 소비자가 나중에 `mount` 한
    것도, `init_poolmanager` 로 새로 생긴 풀 관리자도."""
    for target, name, wrap, at in read_hooks(session, where):
        _plan_wrap(hooks, target, name, what, f"{at}.{name}", wrap, _LATE)


def _plan_wrap(
    hooks: list[_Hook],
    target: Any,
    name: str,
    what: str,
    where: str,
    wrap: Callable[[Callable[..., Any]], Callable[..., Any]],
    risk: str = _UNUSABLE,
) -> None:
    if _hooked(target, name):
        return
    current, prior = _base(target, name)
    if not callable(current):
        raise _missing(what, where, risk)
    wrapped = wrap(current)
    vars(wrapped)[_OWNER] = target
    vars(wrapped)[_PRIOR] = prior
    _OURS.add(wrapped)
    hooks.append((target, name, wrapped, where))


def _plan_grant_connection(hooks: list[_Hook], nested_conn: Any) -> None:
    """그랜트 연결(중첩 `KeycloakOpenID.connection`)의 훅 — 그 sync 세션의 리다이렉트·재시도·읽기와,
    두 세션의 그랜트 응답 본문 상한(`token_cap.py`). REST 세션(`connection._s`)의 응답(사용자 목록
    등)은 정당하게 크다 — 상한은 그랜트 세션에만 건다."""
    nested_session = _require(nested_conn, "_s", what=_GRANT)
    granted = f"{_GRANTED}._s"
    _plan_redirects(hooks, nested_session, _GRANT, granted)
    _plan_retries(hooks, nested_session, granted)
    _plan_reads(hooks, nested_session, "token grant response read", granted)
    size = "token grant response size"
    _plan_wrap(hooks, nested_session, "send", size, f"{granted}.send", capped_send, _UNBOUNDED)
    async_session = getattr(nested_conn, "async_s", None)
    at = f"{_GRANTED}.async_s.send"
    _plan_wrap(hooks, async_session, "send", size, at, acapped_send, _UNBOUNDED)


def _plan_watch(hooks: list[_Hook], nested: Any) -> None:
    """그랜트 객체의 공개 세터 `connection` 이 새 연결을 끼우기 전에 무장하게 한다(머리 주석 4) —
    진짜 `KeycloakOpenID` 만. 등록(`HARDENERS`)과 클래스 교체 둘 다 이 설치의 자리다."""
    cls = type(nested)
    if not issubclass(cls, KeycloakOpenID):
        return
    watched = watched_type(cls, _GRANT)
    hardeners = vars(nested).get(HARDENERS, ())
    if arm_grant_connection not in hardeners:
        armed = (*hardeners, arm_grant_connection)
        hooks.append((nested, HARDENERS, armed, "connection.keycloak_openid"))
    if cls is not watched:
        hooks.append((nested, _CLASS, watched, "connection.keycloak_openid"))


def _plan(conn: Any) -> list[_Hook]:
    """`conn` 그래프에서 빠진 훅. 하나라도 걸 수 없으면 아무것도 바꾸기 전에 거부한다."""
    hooks: list[_Hook] = []
    rest = "admin REST call"
    rest_session = _require(conn, "_s", what=rest)
    _plan_redirects(hooks, rest_session, rest, "connection._s")
    _plan_retries(hooks, rest_session, "connection._s")
    _plan_reads(hooks, rest_session, "admin response read", "connection._s")
    nested = _require(conn, "keycloak_openid", what=_GRANT)
    _plan_grant_connection(hooks, _require(nested, "connection", what=_GRANT))
    # admin REST 세션의 송신 — 보내는 순간의 bearer 검사(머리 주석 3) 안에 응답 본문의 끝
    # (`admin_body.py` — 오류 본문은 상한까지, 파사드 쓰기의 2xx 는 읽지 않는다). 성공 본문은
    # 그대로다.
    body = "admin response body"

    def sent(send: Callable[..., Any]) -> Callable[..., Any]:
        return _bearer_sent(bounded_send(send))

    def asent(send: Callable[..., Any]) -> Callable[..., Any]:
        return _abearer_sent(abounded_send(send))

    _plan_wrap(hooks, rest_session, "send", body, "connection._s.send", sent, _UNREAD)
    rest_async = getattr(conn, "async_s", None)
    _plan_wrap(hooks, rest_async, "send", body, "connection.async_s.send", asent, _UNREAD)
    # 그랜트 래퍼는 그 그랜트의 주인(중첩 `KeycloakOpenID`)을 함께 받는다 — 성공 상태의 OAuth
    # `error` 를 코드로 실을지 그 client secret 과 대조한다(`admin_grant._sent`).
    for name in _SYNC_GRANTS:
        _plan_wrap(
            hooks,
            nested,
            name,
            _GRANT,
            f"connection.keycloak_openid.{name}",
            lambda grant: _checked(grant, nested),
        )
    for name in _ASYNC_GRANTS:
        _plan_wrap(
            hooks,
            nested,
            name,
            _GRANT,
            f"connection.keycloak_openid.{name}",
            lambda grant: _achecked(grant, nested),
        )
    bearer = "admin bearer"
    _plan_wrap(
        hooks,
        conn,
        "_refresh_if_required",
        bearer,
        "connection._refresh_if_required",
        lambda refresh: _bearer_checked(conn, refresh),
    )
    _plan_wrap(
        hooks,
        conn,
        "a__refresh_if_required",
        bearer,
        "connection.a__refresh_if_required",
        lambda refresh: _abearer_checked(conn, refresh),
    )
    _plan_watch(hooks, nested)
    return hooks


def _planned_grant(conn: Any) -> list[_Hook]:
    hooks: list[_Hook] = []
    _plan_grant_connection(hooks, conn)
    return hooks


def _undo(done: list[tuple[Any, str, object]]) -> None:
    for target, name, previous in reversed(done):
        if name == _CLASS:
            # 바꾸지 못했으면(소비자의 `__setattr__` 가 거부·무시) 되돌릴 것도 없다 — 다시 쓰면 그
            # 거부가 되돌림 안에서 raw 로 샌다.
            if type(target) is not previous:
                target.__class__ = previous
            continue
        state = vars(target)
        if previous is _ABSENT:
            state.pop(name, None)
        else:
            state[name] = previous


def _refused(what: str, exc: BaseException) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot guard the admin client: {what} failed ({type(exc).__name__}), so nothing was "
        f"changed. Refusing to use an admin client that could follow redirects or send an "
        f"unusable access token to the admin API. {_SUPPORT}"
    )


def _put(target: Any, name: str, value: object, done: list[tuple[Any, str, object]]) -> None:
    """훅 하나를 건다 — 되돌림(`_undo`)과 같은 통로로. 그랜트 객체의 클래스는 클래스로, 나머지는
    인스턴스 `__dict__` 로 쓴다(클래스는 걸지 않는다)."""
    if name == _CLASS:
        done.append((target, name, type(target)))
        target.__class__ = value
        if type(target) is not value:  # 소비자의 `__setattr__` 가 조용히 버릴 수 있다
            raise AttributeError("the grant object did not keep its watched class")
        return
    state = cast("dict[str, Any]", vars(target))
    done.append((target, name, state.get(name, _ABSENT)))
    # `setattr` 은 소비자의 `__setattr__`·슬롯으로 새어 되돌림이 못 보는 곳에 훅을 두었다 — 곁
    # 사전·슬롯에 산 소비자의 훅이 거부 뒤 `_refuse_redirects` 로 바뀌어 있었다(실측). 쓴 값이
    # 보이지 않으면(슬롯·데이터 디스크립터·`__getattribute__` 가 가린다) 건 것이 아니다.
    state[name] = value
    if getattr(target, name) is not value:
        raise AttributeError(f"{name} did not keep the hook")


def _apply(hooks: list[_Hook]) -> list[tuple[Any, str, object]]:
    done: list[tuple[Any, str, object]] = []
    for target, name, value, where in hooks:
        try:
            _put(target, name, value, done)
        except Exception as exc:
            _undo(done)
            raise _refused(f"installing the hook at {where}", exc) from exc
    return done


def _reentered() -> KeycloakConfigError:
    return KeycloakConfigError(
        "cannot guard the admin client: its connection was read again while the guard was being "
        "installed on it (code that runs while this SDK reads or hooks the connection graph "
        "called back into the admin client), so nothing was changed. Refusing to leave an admin "
        "client half-guarded."
    )


def _install(plan: Callable[[], list[_Hook]]) -> list[tuple[Any, str, object]]:
    """`plan` 이 낸 빠진 훅을 건다(전부이거나 아무것도) — `_LOCK` 을 쥔 채 부른다.

    그래프를 읽다 난 실패는 무엇이든 `KeycloakConfigError` 다 — 프로퍼티·지연 생성·디스크립터는
    `AttributeError` 만 던지지 않는다(실측: raw `TypeError`·`ValueError` 가 생성과 `raw` 로 샜고
    리소스로는 `KeycloakTransportError` 였다). 재진입은 `_LOCAL` 이 거부한다."""
    if getattr(_LOCAL, "installing", False):
        raise _reentered()
    _LOCAL.installing = True
    try:
        try:
            hooks = plan()
        except KeycloakConfigError:
            raise
        except Exception as exc:
            raise _refused("reading the connection graph", exc) from exc
        return _apply(hooks)
    finally:
        _LOCAL.installing = False


def _read_connection(read: Callable[[], Any]) -> Any:
    """`admin.connection` — 생성 때든 요청 직전이든 읽지 못하면 같은 `KeycloakConfigError` 다.

    지워진 연결 필드(`AttributeError`)는 걸 자리가 없다는 거부, 그 밖의 실패(하위 클래스의
    프로퍼티가 던진 `TypeError` 등)는 읽기가 실패했다는 거부다. 이미 감시 중인 admin 이면 읽기가
    곧 무장이라 그 거부는 그대로 지난다."""
    try:
        return read()
    except KeycloakConfigError:
        raise
    except AttributeError as exc:
        raise _unsupported("admin REST call", "connection") from exc
    except Exception as exc:
        raise _refused("reading the admin's connection", exc) from exc


def arm_connection(conn: Any) -> None:
    """`conn` 그래프에 빠진 훅을 건다(전부이거나 아무것도). 다 걸려 있으면 아무것도 안 한다."""
    with _LOCK:
        _install(lambda: _plan(conn))


def arm_grant_connection(conn: Any) -> None:
    """그랜트 객체의 공개 세터가 `conn` 을 끼우기 **전에** 부른다(`openid_watch.py`) — 그 연결에
    그랜트 세션의 훅을 다 건다(전부이거나 아무것도). 못 걸면 `KeycloakConfigError` 이고 끼우지
    않는다."""
    with _LOCK:
        _install(lambda: _planned_grant(conn))


def _headers_restorer(conn: Any) -> Callable[[], None]:
    """`conn` 에 지금의 `headers` 값을 되돌리는 함수(머리 주석 6) — 그 연결 하나에만 쓴다."""
    headers = conn.headers

    def restore() -> None:
        conn.headers = headers

    return restore


def _clear_locals(exc: BaseException) -> None:
    """`exc` 에서 닿는 traceback 마다 끝난 프레임의 로컬을 비운다(머리 주석 7).

    닿는 예외는 `frames.reachable` 이 정한다 — `__cause__`·`__context__` 와 그룹의 구성원
    (`.exceptions` — 3.10 은 백포트 `exceptiongroup` 의 그룹)을 따라 예외마다 한 번, 순환이어도
    끝난다. 공개 메서드의 traceback 떼기(`frames._detached`)와 같은 걸음이다. 아직 도는
    프레임(업로드 래퍼 자신)은 `traceback.clear_frames` 가 건너뛴다. 프레임·줄 번호·사슬은
    그대로다. ⚠️ 3.12 이하의 `clear_frames` 는 traceback 에 든 **멈춘** 제너레이터·코루틴을
    끝낸다(3.13 은 건너뛴다 — 실측 3.10.21 · 3.12.14 · 3.13.11). 업로드 실패의 사슬에는 끝나지 않은
    제너레이터·코루틴의 프레임이 없다(실측: 전송 실패 · 404 · `IN_URL`; SDK 업로드는 그 셋과 보내는
    자리 · 갱신 뒤의 bearer 거부, aio 취소까지 — 도는 감시 래퍼뿐, gc 참조 3.10.21 · 3.13.11) —
    다른 자리에서 부르려면 그것부터 잰다."""
    for node in reachable(exc):
        traceback.clear_frames(node.__traceback__)


def _unwatched(watched: type[KeycloakAdmin], admin: KeycloakAdmin) -> KeycloakAdmin:
    """감시 클래스 **다음부터** 찾는 `admin`(`super`) — 감싼 클래스의 메서드가 MRO 대로 묶인다."""
    return cast("KeycloakAdmin", super(watched, admin))


def _is_own(method: object, function: object) -> bool:
    """MRO 로 찾아 묶인 `method` 가 python-keycloak 의 `function` 그 자체인가(머리 주석 6)."""
    return getattr(method, "__func__", None) is function


def _watched_type(cls: type[KeycloakAdmin]) -> type[KeycloakAdmin]:
    """`cls` 의 하위 클래스 — `connection` 을 읽을 때마다 살아 있는 연결을 무장한다. multipart
    업로드 둘은 python-keycloak 자신의 것이면 SDK 의 것으로 보내고(연결의 헤더를 쓰지 않는다),
    소비자의 것이 던지면 그 연결의 헤더를 되돌린다 — 어느 쪽이든 그 오류의 프레임 로컬을 비운다."""
    if _BASE in vars(cls):
        return cls
    cached = _WATCHED.get(cls)
    if cached is not None:
        return cached
    prop = inspect.getattr_static(cls, "connection", None)
    if not isinstance(prop, property):
        raise KeycloakConfigError(
            f"cannot guard the admin client: {cls.__qualname__}.connection is not a property, so "
            f"this SDK cannot check the connection each admin request goes out on. {_SUPPORT}"
        )

    def connection(self: KeycloakAdmin) -> Any:
        conn = _read_connection(lambda: prop.__get__(self, type(self)))  # 생성 때와 같은 거부
        arm_connection(conn)
        return conn

    # 머리 주석 6 · 7 — 읽기가 무장이다(던지면 아무것도 바뀌지 않았다). 감싼 클래스의 것을 부를
    # 때 찾는다(`_unwatched`): python-keycloak 자신의 것이면 SDK 의 업로드가 연결의 헤더를 쓰지
    # 않고 보내고, 소비자의 하위 클래스가 덮은 업로드 · 클래스에 건 패치는 그대로 돈다.
    def upload_certificate(self: KeycloakAdmin, *args: Any, **kwargs: Any) -> Any:
        delegate = _unwatched(watched, self).upload_certificate
        if _is_own(delegate, _OWN_UPLOAD):
            conn = self.connection
            try:
                return upload(conn, *args, **kwargs)
            except BaseException as exc:
                _clear_locals(exc)
                raise
        restore = _headers_restorer(self.connection)
        try:
            return delegate(*args, **kwargs)
        except BaseException as exc:
            restore()
            _clear_locals(exc)
            raise

    async def a_upload_certificate(self: KeycloakAdmin, *args: Any, **kwargs: Any) -> Any:
        delegate = _unwatched(watched, self).a_upload_certificate
        if _is_own(delegate, _OWN_AUPLOAD):
            conn = self.connection
            try:
                return await aupload(conn, *args, **kwargs)
            except BaseException as exc:  # 취소(`CancelledError`)도
                _clear_locals(exc)
                raise
        restore = _headers_restorer(self.connection)
        try:
            return await delegate(*args, **kwargs)
        except BaseException as exc:  # 취소(`CancelledError`)도
            restore()
            _clear_locals(exc)
            raise

    # 이름·모듈은 감싼 클래스 그대로다 — `raw` 는 여전히 python-keycloak 의 객체로 보이고
    # 읽힌다(§4(b) 의 탈출구, 오류 수집기·걷기 도구의 분류도 그대로). 피클은 원래도 안 됐다
    # (python-keycloak 의 `lambda`·`RLock`, 실측). 달라지는 것은 `type(raw) is KeycloakAdmin`
    # 하나다 — `isinstance` 는 참이고, 덮은 업로드 둘도 감싼 메서드의 이름·문서·서명 그대로다.
    namespace = {
        "__slots__": (),
        "__module__": cls.__module__,
        "__qualname__": cls.__qualname__,
        "connection": property(connection, prop.fset, prop.fdel, prop.__doc__),
        "upload_certificate": functools.wraps(cls.upload_certificate)(upload_certificate),
        "a_upload_certificate": functools.wraps(cls.a_upload_certificate)(a_upload_certificate),
        _BASE: prop,
    }
    try:
        watched = cast("type[KeycloakAdmin]", type(cls.__name__, (cls,), namespace))
    except Exception as exc:  # `__init_subclass__`·메타클래스가 하위 클래스를 막는다(런타임 final)
        raise _refused(f"subclassing {cls.__qualname__} to watch its connection", exc) from exc
    return _WATCHED.setdefault(cls, watched)


def arm_admin(admin: KeycloakAdmin) -> None:
    """생성 때 부른다 — 지금 연결 그래프에 훅을 다 걸고(전부이거나 아무것도), 진짜
    `KeycloakAdmin` 이면 이후 `connection` 을 읽을 때마다 다시 보게 클래스를 바꾼다.
    실패는 `KeycloakConfigError` 다."""
    cls = type(admin)
    with _LOCK:
        watched = _watched_type(cls) if issubclass(cls, KeycloakAdmin) else cls
        # 읽기는 설치 **밖**이다 — 이미 감시 중인 admin 이면 읽기가 곧 무장(설치)이다.
        conn = _read_connection(lambda: admin.connection)
        done = _install(lambda: _plan(conn))
        # 이미 감시 중이거나 진짜 KeycloakAdmin 이 아니다. 목에 `__class__` 를 쓰면 클래스가
        # 아니라 spec 이 바뀌어 `isinstance` 가 깨진다.
        if watched is cls:
            return
        try:
            admin.__class__ = watched
        except Exception as exc:
            _undo(done)
            raise _refused(f"replacing the class of {cls.__qualname__}", exc) from exc


def unarmed_connection(admin: KeycloakAdmin | None) -> Any:
    """`admin.connection` 을 **무장하지 않고** 읽는다 — 요청을 보내지 않는 정리 전용.

    정리가 보안 검사에 막혀 세션을 못 닫으면 안 된다. 없으면 `None`(예전 `getattr` 과 같다)."""
    prop = getattr(type(admin), _BASE, None)
    if prop is None:
        return getattr(admin, "connection", None)
    try:
        return prop.__get__(admin, type(admin))
    except AttributeError:
        return None
