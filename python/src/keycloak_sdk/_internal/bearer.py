"""admin 이 보낼 `Authorization: Bearer <토큰>` 을 그 레인의 HTTP 전송이 실을 수 있는가.

⚠️ python-keycloak 의 토큰 세터는 `"Bearer " + access_token` 을 헤더에 그대로 싣는다. 헤더가 실을
수 없는 토큰이면 sync 는 requests·http.client 가, aio 는 httpx·h11 이 **보내는 순간** 거부하고,
python-keycloak 의 `raw_*` 가 그 예외를 `KeycloakConnectionError("Can't connect to server")` 로 감싸
경계에서 `KeycloakTransportError` 가 됐다 — 요청은 나가지 않았는데 연결 실패로 보고됐다. 전송이
거르지 않는 제어 문자는 그대로 나갔다 — sync 는 NUL·SOH·BS·VT·FF·US·DEL 을, aio 는 SOH·BS·US·DEL
을 실은 Authorization 을 보냈다(실측 대표 열, 등록부 `wave4-hardening-python` (2)(3)).

**거부하는 것.** (1) RFC 9110 §5.5 가 필드 값에서 빼는 것 — NUL·CR·LF 를 포함한 C0 제어 문자(HTAB
제외)와 DEL. .NET·Go·Ruby 가 같은 집합을 거부한다. (2) 그 레인의 전송이 헤더 값으로 **싣지 못하는**
것 — sync 는 http.client 가 latin-1 로 인코딩하므로 U+00FF 위(짝 없는 서로게이트 포함), aio 는
httpx 가 ASCII 로 인코딩하므로 U+007F 위, 그리고 h11 이 값 끝의 SP·HTAB 을 거부한다. (2) 는 원래도
나가지 않던 것이다 — 바뀌는 것은 오류의 타입과 메시지뿐이다.

**거부하지 않는 것.** 전송이 바이트 그대로 싣는 것 — HTAB·SP(가운데·앞), 그리고 sync 의
U+0080..U+00FF·끝 SP·HTAB. 판정은 서버다(언어 횡단 판정 `bearer-token-grammar-divergent`). 두
집합은 시험이 RFC 와 **전송에 물어서** 고정한다(`tests/unit/test_admin_bearer_header.py` — 전송
오라클이 python-keycloak 의 `ConnectionManager` 로 같은 헤더를 실제로 보낸다).

**어디서.** 받는 자리(`admin_grant.py` 의 그랜트 래퍼 — 토큰 세터 앞이라 거부한 토큰은 캐시되지
않고 다음 호출이 다시 그랜트한다)와 보내는 자리(`admin_guard.py` 의 갱신 뒤 검사 — 주입·토큰
세터로 실린 bearer, 그리고 한 레인이 받은 토큰을 다른 레인으로 보내는 `raw`). 레인은 그 그랜트·
요청이 sync 메서드인가 `a_*` 인가다. 타입은 쓸 수 없는 access_token 의 선례(`tokens.
_usable_access_token`)와 같은 `KeycloakAuthError` 이고, 메시지는 토큰을 인용하지 않는다 — 문자의
부류만 말한다.
"""

from __future__ import annotations

from typing import Literal

Lane = Literal["sync", "aio"]

#: 받는 자리·보내는 자리의 메시지. `{}` 에 아래 이유 하나가 들어간다.
GRANTED = "admin token grant returned an access token an HTTP header cannot carry ({})"
SENDING = "admin request not sent: an HTTP header cannot carry the access token ({})"

_CONTROL = "it holds CR, LF, NUL, DEL or another control character other than HTAB"
#: 레인 → (전송이 헤더 값으로 인코딩하는 가장 큰 문자, 넘었을 때의 이유).
_CEILING: dict[str, tuple[str, str]] = {
    "sync": (
        "\xff",
        "it holds a character above U+00FF, which the sync admin client cannot encode in a header",
    ),
    "aio": (
        "\x7f",
        "it holds a non-ASCII character, which the async admin client cannot encode in a header",
    ),
}
_TRAILING = (
    "it ends with a space or tab, which the async admin client cannot send at the end of a header"
)


def _control(ch: str) -> bool:
    return (ch < " " and ch != "\t") or ch == "\x7f"


def unsendable(token: str, lane: Lane) -> str | None:
    """`Bearer <token>` 을 `lane` 의 전송이 헤더로 실을 수 없는 이유 — 실을 수 있으면 `None`."""
    if any(_control(ch) for ch in token):
        return _CONTROL
    ceiling, reason = _CEILING[lane]
    if any(ch > ceiling for ch in token):
        return reason
    if lane == "aio" and token.endswith((" ", "\t")):
        return _TRAILING
    return None
