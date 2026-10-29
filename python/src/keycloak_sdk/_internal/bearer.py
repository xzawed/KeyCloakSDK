"""admin 이 보낼 `Authorization: Bearer <토큰>` 의 문법 — 아홉 언어 공통 규칙(등록부
`bearer-token-grammar-divergent`, 2026-10-29 판정).

**규칙(`sendable`).** 토큰의 앞뒤에서 SP·HTAB·CR·LF **만** 떼고(NBSP·U+3000·VT·FF
같은 다른 공백은 떼지 않는다 — 인자 없는 `str.strip()` 은 유니코드 공백을 떼므로 쓰지
않는다), 남은 것이 비어 있지 않은 RFC 6750 `b64token`(ASCII `[A-Za-z0-9\\-._~+/]+=*` —
`=` 는 끝의 채움으로만)이면 그것을 보낸다. 아니면 보내지 않는다. sync·aio 가 같은
판정이다 — 예전에는 그 레인의 전송이 헤더로 실을 수 있는가가 기준이라 sync(requests)는
Latin-1·끝 SP 를 그대로 보내고 aio(httpx·h11)는 거부했다(실측
`tests/unit/test_admin_bearer_header.py`).

**어디서.** 받는 자리(`admin_grant.py` 의 그랜트 래퍼 — 토큰 세터 앞이다. 거부한 토큰은
캐시되지 않고 다음 호출이 다시 그랜트하며, 받아들인 토큰은 다듬은 값으로 세터에 넘긴다:
python-keycloak 의 401 재시도는 보내는 자리를 거치지 않고 세터가 실은 값을 다시 보낸다)와
보내는 자리(`admin_guard.py` 의 갱신 뒤 검사 — 그랜트를 거치지 않고 실린 bearer, 곧
주입·토큰 세터의 것을 다듬은 값으로 바꿔 싣거나 거부한다). 타입은 쓸 수 없는 access_token
의 선례(`tokens._usable_access_token`)와 같은 `KeycloakAuthError` 이고, 메시지는 토큰을
인용하지 않는다 — 규칙만 말한다.
"""

from __future__ import annotations

import re

_RULE = "after trimming SP, HTAB, CR and LF it must be a non-empty RFC 6750 b64token"
#: 받는 자리·보내는 자리의 거부 메시지.
GRANTED = f"admin token grant returned an access token that is not a bearer token ({_RULE})"
SENDING = f"admin request not sent: the access token is not a bearer token ({_RULE})"

#: 앞뒤에서 떼는 글자 — 이 넷뿐이다.
_TRIM = " \t\r\n"
#: RFC 6750 §2.1 `b64token`. ⚠️ `fullmatch` 로 본다 — `$` 는 끝의 개행 앞에서도 맞는다.
_B64TOKEN = re.compile(r"[A-Za-z0-9\-._~+/]+=*")


def sendable(token: str) -> str | None:
    """`Bearer ` 뒤에 실을 값 — 규칙에 맞으면 다듬은 토큰, 아니면 `None`."""
    trimmed = token.strip(_TRIM)
    return trimmed if _B64TOKEN.fullmatch(trimmed) else None
