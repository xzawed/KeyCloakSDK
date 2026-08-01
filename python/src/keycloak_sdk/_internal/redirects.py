"""백채널 리다이렉트 차단 — python-keycloak의 sync(requests) 경로 하드닝.

python-keycloak의 `ConnectionManager.raw_get/raw_post/raw_put/raw_delete`는
`allow_redirects`를 한 번도 전달하지 않는다(connection.py). requests의 기본값이 True라
IdP가 돌려준 3xx를 그대로 따라가며, 실측된 결과는 다음과 같다:

* 307/308은 POST 본문을 보존한다 → `client_secret`·`refresh_token`·인가코드가
  리다이렉트 대상 호스트로 재전송된다(requests의 `rebuild_auth`는 `Authorization`
  **헤더**만 교차 호스트에서 제거한다 — 자격증명이 본문에 있는 이 경로는 보호하지 않는다).
* `introspect()`는 리다이렉트 대상이 돌려준 `{"active": true}`를 그대로 반환한다 —
  조용한 거짓 성공(인가 우회).
* `logout()`은 대상이 204를 돌려주면 성공으로 반환한다 — 세션은 살아있고 refresh
  token은 이미 넘어간 뒤다.
* `certs()`는 리다이렉트 대상이 돌려준 JWKS를 검증 키로 캐시한다 — 인증 전면 우회.

**왜 이 훅인가.** 호출마다 `allow_redirects=False`를 넘길 공개 시임이 없다 —
`raw_get(path, **kwargs)`는 kwargs를 `params=`(쿼리 문자열)로 흘리므로 `allow_redirects`는
URL에 `?allow_redirects=False`로 붙을 뿐 아무 효과가 없다. 세션 주입 시임도 없다 —
`ConnectionManager.__init__`이 `requests.Session()`을 직접 생성한다. 전송 어댑터로는
막을 수 없다 — 리다이렉트 해석은 어댑터보다 위인 `Session.send`에서 일어난다(실측 확인).
남는 최소 훅은 이미 만들어진 세션의 **공개** 메서드 `Session.resolve_redirects`
(requests `SessionRedirectMixin`의 공개 API)를 덮어써 해석 결과를 빈 반복자로 만드는
것이다 — requests의 `Session.send`가 모든 verb·모든 호출지점에서 이 한 곳을 지나므로
우리가 놓친 코드 경로로 우회될 수 없다.

훅 안에서 우리 예외를 던지지 않는 이유: `raw_*`가 `except Exception`으로 전부 감싸
`KeycloakConnectionError("Can't connect to server")`로 바꿔버리기 때문에 메시지도 상태
코드도 남지 않는다. 빈 반복자를 돌려주면 원래의 3xx가 최종 응답이 되고,
`raise_error_from_response`가 이를 기대 코드 밖으로 보아 `response_code=3xx`를 실은
`Keycloak*Error`를 던진다 — 경계(`_wrap`/`translate`)가 그대로 SDK 예외로 옮긴다.

`session.max_redirects = 0`도 차단은 하지만 `TooManyRedirects`가 위 `except Exception`에
걸려 `KeycloakTransportError("Can't connect to server")`가 된다 — 보안 차단이 IdP 장애와
구분되지 않으므로 채택하지 않는다.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

from ..exceptions import KeycloakConfigError

#: python-keycloak `ConnectionManager`가 requests 세션을 보관하는 (비공개) 속성.
_SESSION_ATTR = "_s"
#: requests `SessionRedirectMixin`의 공개 훅. 이 이름만 덮어쓴다.
_HOOK_ATTR = "resolve_redirects"


def _refuse_redirects(*_args: Any, **_kwargs: Any) -> Iterator[Any]:
    """리다이렉트를 해석하지 않는다 — 3xx 응답 자체가 최종 응답이 된다.

    `Session.send`는 이 함수가 만든 history를 소비할 뿐이므로, 빈 반복자를 돌려주면
    원래의 3xx가 호출자에게 그대로 보이고 대상 URL로는 아무것도 나가지 않는다.
    """
    return iter(())


def _unsupported(what: str, attr: str) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot harden the {what} against HTTP redirects: this SDK expects "
        f"python-keycloak to expose its requests session at "
        f"connection.{_SESSION_ATTR}.{_HOOK_ATTR}, but {attr!r} is missing or not "
        f"callable. Refusing to build a client that would silently follow 3xx from the "
        f"identity provider and re-send credentials to the redirect target. Pin "
        f"python-keycloak to a supported version (>=7.1,<8) and report this at "
        f"https://github.com/xzawed/KeyCloakSDK/issues."
    )


def _require(obj: Any, name: str, *, what: str) -> Any:
    """`obj.name`을 읽되 부재 시 SDK 설정 오류로 바꾼다.

    기본값 있는 `getattr`을 쓰지 않는 이유: 지연 프로퍼티(`keycloak_openid`)가 내부에서
    던지는 `AttributeError`까지 기본값으로 삼켜져 "속성이 없다"와 "속성 계산이 실패했다"가
    구분되지 않는다. 둘 다 "중첩 세션을 하드닝할 수 없다"는 같은 결론이므로 함께 잡되,
    조용히 넘어가지는 않는다.
    """
    try:
        return getattr(obj, name)
    except AttributeError as exc:
        raise _unsupported(what, name) from exc


def _harden_connection(connection: Any, *, what: str) -> None:
    session = _require(connection, _SESSION_ATTR, what=what)
    if not callable(getattr(session, _HOOK_ATTR, None)):
        raise _unsupported(what, f"{_SESSION_ATTR}.{_HOOK_ATTR}")
    setattr(session, _HOOK_ATTR, _refuse_redirects)


def harden_openid(openid: Any, *, what: str = "auth back-channel") -> None:
    """`KeycloakOpenID`의 sync 세션이 3xx를 따라가지 않게 만든다.

    token·refresh·exchange_code·logout·introspect·certs(JWKS)가 모두 이 한 세션을 쓴다.
    """
    _harden_connection(_require(openid, "connection", what=what), what=what)


def harden_admin(admin: Any) -> None:
    """`KeycloakAdmin`이 쓰는 **두 개의** sync 세션을 모두 막는다.

    admin 경로에는 세션이 둘 있다:

    1. `admin.connection._s` — admin REST 호출(`Authorization: Bearer` 동반).
    2. `admin.connection.keycloak_openid.connection._s` — admin 자신의
       client-credentials 토큰 그랜트(`client_secret` 동반).

    2번은 `keycloak_openid` **지연 프로퍼티** 뒤에 있어 `KeycloakAdmin` 생성 시점에는
    아직 존재하지 않는다. 여기서 프로퍼티를 강제로 실체화해 함께 막는다 — 실측상 1번만
    막으면 admin 첫 호출의 토큰 그랜트가 `client_secret`을 그대로 리다이렉트 대상에
    넘긴다. 프로퍼티 실체화는 객체 생성뿐이라 네트워크 왕복이 없다.
    """
    connection = _require(admin, "connection", what="admin REST call")
    _harden_connection(connection, what="admin REST call")
    nested = _require(connection, "keycloak_openid", what="admin token grant")
    harden_openid(nested, what="admin token grant")
