"""SDK 의 sync 세션은 요청을 저절로 다시 보내지 않는다 — IdP 가 이미 처리했을지 모르는 요청이다.

⚠️ **python-keycloak 은 POST 까지 다시 보내게 해 둔다.** `ConnectionManager.__init__` 이 requests
세션에 `HTTPAdapter(max_retries=1)` 을 걸고 urllib3 재시도 허용 목록에 POST 를 더한다(7.1.1, 「adds
POST to retry whitelist」). urllib3 는 요청을 보낸 **뒤** 난 연결 오류(응답 없이 끊김·RST·HTTP 가
아닌 상태 줄·65,536 바이트를 넘는 헤더 줄·읽기 타임아웃)를 「읽기 오류」로 보고, 허용된 메서드면
같은 요청을 한 번 더 보낸다 — 서버가 첫 요청을 처리했는지는 모른다. 503·429·413 + `Retry-After`
면 그 초만큼(urllib3 2.7.0 의 상한 21,600 초) 잠든 뒤 보낸다. 실측(2026-10-09, 요청을 끝까지 읽고
깨뜨리는 가짜 IdP — `tests/unit/test_no_automatic_retry.py`): sync 는 토큰 그랜트 셋·introspection·
logout·admin 그랜트·admin 생성/수정/삭제/액션·JWKS·admin GET 이 여섯 고장 모두에서 IdP 에 두 번
닿았다. aio 는 한 번이다 — httpcore 의 재시도는 연결 수립(`_connect`)만 다시 하고, python-keycloak
은 그것도 켜지 않는다.

**무엇으로 바꾸는가.** 세션의 어댑터마다 `max_retries` 를 `NO_RETRY` 로 — requests 가 새
`HTTPAdapter` 에 주는 기본값이다. ⚠️ **허용 목록에서 POST 를 빼는 것으로는 모자란다** — 응답을
읽다 난 TLS 레코드 오류(`SSLError`)를 urllib3 는 「연결」도 「읽기」도 아닌 「그 밖」 오류로 보고
메서드와 무관하게 다시 보낸다(실측: `Retry(1)` 도 `Retry(total=1, allowed_methods={"GET"})` 도
토큰 POST 를 두 번 보냈다). 막는 것은 `total=0` 이다. 멱등 메서드의 재시도도 남기지 않는다:
Keycloak 의 PUT 에는 액션이 있고(`send-verify-email`), 다시 보내면 호출자가 받는 것은 두 번째
요청의 응답이며, GET 도 `Retry-After` 만큼 잠든다 — JWKS 면 `_jwks_lock` 을 쥔 채라 그동안 모든
검증이 기다리고, 강제 재조회 창 하나가 IdP 요청 둘이 된다. 다시 보내도 되는지는 소비자만 안다.

**어디에 거는가.** auth 레인은 생성 때 한 번(`forbid_retries` — `harden_openid`·`cap_openid` 와 같은
자리). admin 레인은 `admin_guard.py` 가 요청마다 두 세션(REST·그랜트)의 어댑터를 다시 본다 —
`raw.connection` 을 갈아 끼우거나 어댑터를 새로 `mount` 해도 다음 요청 전에 잡힌다. `max_retries`
가 없는 어댑터(requests `HTTPAdapter` 가 아닌, 소비자가 직접 건 전송)는 건드리지 않는다 — 그
재시도는 이 SDK 가 볼 수 없고, 막으면 목 어댑터로 시험하는 소비자가 깨진다.
"""

from __future__ import annotations

from typing import Any

from urllib3.util.retry import Retry

from ..exceptions import KeycloakConfigError

#: requests 가 새 `HTTPAdapter` 에 주는 정책 — 어떤 요청도 다시 보내지 않는다(연결 수립 실패도).
NO_RETRY = Retry(0, read=False)


def _unsupported(where: str) -> KeycloakConfigError:
    return KeycloakConfigError(
        f"cannot turn off automatic retries: this SDK expects python-keycloak's requests session "
        f"to expose its transport adapters at {where}, but it does not. Refusing to build a client "
        f"that could re-send a request the identity provider may already have processed. Pin "
        f"python-keycloak to a supported version (>=7.1,<8) and report this at "
        f"https://github.com/xzawed/KeyCloakSDK/issues."
    )


def retrying_adapters(session: Any, where: str) -> list[tuple[str, Any]]:
    """(접두, 어댑터) — `session` 의 어댑터 중 `max_retries` 가 아직 `NO_RETRY` 가 아닌 것.

    어댑터 표를 읽지 못하면 `KeycloakConfigError` 다(`where` 는 메시지에 쓸 세션 자리)."""
    try:
        return [
            (prefix, adapter)
            for prefix, adapter in session.adapters.items()
            if hasattr(adapter, "max_retries")
            and getattr(adapter, "__dict__", {}).get("max_retries") is not NO_RETRY
        ]
    except Exception as exc:
        raise _unsupported(f"{where}.adapters") from exc


def forbid_retries(openid: Any) -> None:
    """auth 레인의 `KeycloakOpenID` — sync 세션의 어댑터에서 재시도를 끈다(생성 때 한 번).

    `connection._s` 의 존재는 먼저 부르는 `harden_openid` 가 강제한다."""
    for _prefix, adapter in retrying_adapters(openid.connection._s, "connection._s"):
        adapter.max_retries = NO_RETRY
