"""브라우저 없는 로그인 — 실제 Keycloak 로그인 폼을 HTTP 로 채워 인가 코드를 받는다.

세 걸음이고 다른 언어도 이 모양을 그대로 옮긴다:

1. SDK 가 만든 인가 URL 을 GET 한다(로그인 페이지 + 인증 세션 쿠키 — 쿠키는 2 에서 직접 되싣는다).
2. `<form id="kc-form-login">` 의 `action` 에 사용자명·비밀번호를 POST 하되 **리다이렉트는 따라가지
   않는다** — redirect_uri 에는 아무것도 떠 있지 않다. 302 의 `Location` 이 곧 콜백이다.
3. `Location` 에서 `code`·`state` 를 꺼내고, `state` 가 SDK 가 발급한 값인지 확인한다.

폼을 못 찾거나 상태 코드가 틀리면 받은 HTML 앞부분을 실어 실패한다 — 테마가 바뀌었을 때 원인이
바로 보이게.
"""

from __future__ import annotations

from html.parser import HTMLParser
from urllib.parse import parse_qs, urlsplit

import httpx
import pytest

from keycloak_sdk.auth import AuthorizationUrl

LOGIN_FORM_ID = "kc-form-login"


class _LoginForm(HTMLParser):
    """`<form id="kc-form-login">` 의 action 만 집는다(속성 값의 `&amp;` 는 파서가 푼다)."""

    def __init__(self) -> None:
        super().__init__()
        self.action: str | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "form" and attributes.get("id") == LOGIN_FORM_ID:
            self.action = attributes.get("action")


def _snippet(response: httpx.Response) -> str:
    return f"HTTP {response.status_code} {response.url}\n{response.text[:1500]}"


def browser_login(
    request: AuthorizationUrl, redirect_uri: str, username: str, password: str
) -> str:
    """`request`(SDK 의 `authorization_url` 결과)로 로그인해 인가 코드를 돌려준다."""
    with httpx.Client(follow_redirects=False, timeout=30.0) as browser:
        page = browser.get(request.url)
        if page.status_code != 200:
            pytest.fail(f"login page did not render:\n{_snippet(page)}")
        form = _LoginForm()
        form.feed(page.text)
        if not form.action:
            pytest.fail(f'no <form id="{LOGIN_FORM_ID}"> in the login page:\n{_snippet(page)}')
        # ⚠️ 쿠키 저장소에 맡기지 말고 **직접 되싣는다.** Keycloak 26 은 http 에서도 로그인 쿠키에
        # `Secure` 를 단다. 브라우저는 localhost 를 안전한 출처로 봐서 보내지만, RFC 6265 대로 사는
        # 저장소(Python cookiejar 등)는 http 요청에 싣지 않아 POST 가 400 "Restart login cookie not
        # found" 로 끝난다(실측).
        cookie = "; ".join(f"{name}={value}" for name, value in page.cookies.items())
        answer = browser.post(
            form.action,
            data={"username": username, "password": password},
            headers={"Cookie": cookie},
        )

    if answer.status_code != 302:
        pytest.fail(f"login POST did not redirect:\n{_snippet(answer)}")
    location = answer.headers["location"]
    callback = urlsplit(location)
    if f"{callback.scheme}://{callback.netloc}{callback.path}" != redirect_uri:
        pytest.fail(f"login redirected somewhere else: {location}")
    query = parse_qs(callback.query)
    # state 는 SDK 가 인가 URL 에 실은 CSRF 값이다 — 서버가 그대로 되돌려야 한다.
    if query.get("state") != [request.state]:
        pytest.fail(f"state mismatch: sent {request.state!r}, got {query.get('state')!r}")
    codes = query.get("code")
    if not codes or len(codes) != 1 or not codes[0]:
        pytest.fail(f"no single authorization code in the callback: {location}")
    return codes[0]
