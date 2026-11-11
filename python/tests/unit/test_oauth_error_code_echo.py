"""The OAuth `error` code an SDK error carries is a code, never a value the request sent
(registry `token-error-code-secret-echo` · `oauth-error-field-echo-unmasked`).

The IdP's `error` is response body too. An IdP (or a proxy in front of it) that echoes what the
request sent puts the client secret, the refresh token or the introspected token there — and the
auth lanes copied it into `KeycloakAuthError.error` as is (any JSON value, `str()`-ed) and, when it
was lowercase, into the message (measured on main `a7d0fdf3`: a Keycloak-style secret
`Kx7mQ2…` and a JWT refresh token in `vars(e)`, a lowercase secret in `str(e)` and the traceback).

The rule, one predicate for the attribute and the message: the value is carried only when it is a
string of `[a-z_]{1,64}` (every registered OAuth and Keycloak code has that shape) **and** it does
not overlap a non-empty secret that request sent — neither contains the other, so a truncated or
extended echo is withheld too. The price is fixed below: a secret that is a piece of a registered
code (`client`) withholds that code — the status stays in the message, nothing leaks.

The admin self-grant never carries a code (`test_admin_grant_echo.py`) — unchanged.
"""

from __future__ import annotations

import base64
import contextlib
import json
import threading
import traceback
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qsl, unquote_plus

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import KeycloakAuthError

from .test_admin_grant import _attempt

pytestmark = pytest.mark.usefixtures("fast_tls")

LANES = ("sync", "aio")
_HTTP = "Keycloak request failed: HTTP 400"

SECRET = "echoedlowersecret"  # code-shaped on purpose: the shape check alone cannot withhold it
REFRESH = "echoedlowerrefresh"
TOKEN = "echoedlowerintrospected"
CODE = "echoedlowercode"
VERIFIER = "echoedlowerverifierechoedlowerverifierechoedlower"  # 49 characters
KC_SECRET = "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5"  # the shape a Keycloak-generated secret has
JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl"


@dataclass
class _Idp:
    """Answers every POST with 400 `{"error": …}` — `error` is `fixed`, or built by `echo` from
    the form and the client secret this request sent (Basic or form field)."""

    echo: Callable[[dict[str, str]], Any] | None = None
    fixed: Any = None
    url: str = ""
    seen: list[dict[str, str]] = field(default_factory=list)
    lock: threading.Lock = field(default_factory=threading.Lock)

    def error_for(self, sent: dict[str, str]) -> Any:
        with self.lock:
            self.seen.append(sent)
        return self.echo(sent) if self.echo is not None else self.fixed


def _sent(headers: Any, body: str) -> dict[str, str]:
    sent = dict(parse_qsl(body, keep_blank_values=True))
    auth = headers.get("Authorization") or ""
    if auth.lower().startswith("basic "):
        user, _, password = base64.b64decode(auth[6:]).decode().partition(":")
        sent.setdefault("client_id", unquote_plus(user))
        sent["client_secret"] = unquote_plus(password)
    return sent


def _handler(idp: _Idp) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_args: Any) -> None:
            pass

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode() if length else ""
            payload = json.dumps({"error": idp.error_for(_sent(self.headers, body))}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    return Handler


@contextlib.contextmanager
def _echo_idp(
    *, echo: Callable[[dict[str, str]], Any] | None = None, fixed: Any = None
) -> Iterator[_Idp]:
    idp = _Idp(echo=echo, fixed=fixed)
    server = ThreadingHTTPServer(("127.0.0.1", 0), _handler(idp))
    idp.url = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, args=(0.01,), daemon=True).start()
    try:
        yield idp
    finally:
        server.shutdown()
        server.server_close()


#: surface → (call, the secret form fields it sends besides the client secret)
SURFACES: dict[str, tuple[Callable[[Any], Any], tuple[str, ...]]] = {
    "client_credentials": (lambda c: c.auth.client_credentials_token(), ()),
    "refresh": (lambda c: c.auth.refresh(REFRESH), ("refresh_token",)),
    "logout": (lambda c: c.auth.logout(REFRESH), ("refresh_token",)),
    "introspect": (lambda c: c.auth.introspect(TOKEN), ("token",)),
    "exchange_code": (
        lambda c: c.auth.exchange_code(CODE, "http://localhost/cb", VERIFIER),
        ("code", "code_verifier"),
    ),
}


async def _fail(lane: str, url: str, act: Callable[[Any], Any], secret: str | None = SECRET) -> Any:
    cfg = KeycloakConfig(server_url=url, realm="r", client_id="c", client_secret=secret)
    if lane == "sync":
        with KeycloakClient.create(cfg) as kc:
            _, err = await _attempt(lane, kc, act)
    else:
        async with AsyncKeycloakClient.create(cfg) as akc:
            _, err = await _attempt(lane, akc, act)
    assert isinstance(err, KeycloakAuthError), repr(err)
    return err


def _renderings(err: BaseException) -> list[str]:
    out = ["".join(traceback.format_exception(err))]
    todo: list[BaseException | None] = [err]
    while todo:
        node = todo.pop()
        if node is None:
            continue
        out += [str(node), repr(node), repr(vars(node)), repr(node.args)]
        todo += [node.__cause__, node.__context__]
    return out


def _withheld(err: KeycloakAuthError, value: str) -> None:
    assert err.error is None
    assert str(err) == _HTTP
    for text in _renderings(err):
        assert value not in text


def _carried(err: KeycloakAuthError, code: str) -> None:
    assert err.error == code
    assert str(err) == f"{_HTTP} ({code})"


# --- echoes of what the request sent ---------------------------------------------------------

#: name → how the IdP derives `error` from one sent value
ECHO_FORMS: dict[str, Callable[[str], str]] = {
    "whole": lambda v: v,
    "truncated": lambda v: v[:11],
    "extended": lambda v: v + "_x",
}


@pytest.mark.parametrize("form", list(ECHO_FORMS))
@pytest.mark.parametrize("surface", list(SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_an_echoed_client_secret_is_never_carried(lane: str, surface: str, form: str) -> None:
    """Every auth surface authenticates the client, so every one can get its secret back."""
    act, _ = SURFACES[surface]
    with _echo_idp(echo=lambda sent: ECHO_FORMS[form](sent["client_secret"])) as idp:
        err = await _fail(lane, idp.url, act)
    assert idp.seen and idp.seen[0]["client_secret"] == SECRET
    _withheld(err, ECHO_FORMS[form](SECRET))


@pytest.mark.parametrize("form", list(ECHO_FORMS))
@pytest.mark.parametrize(
    ("surface", "param"),
    [(s, p) for s, (_, params) in SURFACES.items() for p in params],
)
@pytest.mark.parametrize("lane", LANES)
async def test_an_echoed_grant_value_is_never_carried(
    lane: str, surface: str, param: str, form: str
) -> None:
    """The refresh token, the introspected token, the code and the PKCE verifier."""
    act, _ = SURFACES[surface]
    with _echo_idp(echo=lambda sent: ECHO_FORMS[form](sent[param])) as idp:
        err = await _fail(lane, idp.url, act)
    _withheld(err, ECHO_FORMS[form](idp.seen[0][param]))


@pytest.mark.parametrize("lane", LANES)
async def test_a_public_client_still_withholds_its_echoed_refresh_token(lane: str) -> None:
    """No client secret is sent — the refresh token alone is compared (and an absent secret
    is not compared at all: the empty string would be a piece of every code)."""
    with _echo_idp(echo=lambda sent: sent["refresh_token"]) as idp:
        err = await _fail(lane, idp.url, SURFACES["refresh"][0], secret=None)
    assert "client_secret" not in idp.seen[0]
    _withheld(err, REFRESH)


# --- values that are not a code ----------------------------------------------------------------

NOT_A_CODE: dict[str, Any] = {
    "keycloak-style secret": KC_SECRET,
    "jwt": JWT,
    "capital letter": "Invalid_client",
    "space": "invalid client",
    "digit": "invalid_client2",
    "65 characters": "a" * 65,
    "empty": "",
    "array": ["invalid_client"],
    "number": 400,
    "object": {"code": "invalid_client"},
}


@pytest.mark.parametrize("value", list(NOT_A_CODE))
@pytest.mark.parametrize("surface", list(SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_value_that_is_not_a_code_is_never_carried(
    lane: str, surface: str, value: str
) -> None:
    with _echo_idp(fixed=NOT_A_CODE[value]) as idp:
        err = await _fail(lane, idp.url, SURFACES[surface][0])
    assert err.error is None
    assert str(err) == _HTTP
    if isinstance(NOT_A_CODE[value], str) and NOT_A_CODE[value]:
        for text in _renderings(err):
            assert NOT_A_CODE[value] not in text


# --- controls: a code is still a code ----------------------------------------------------------


@pytest.mark.parametrize("code", ["invalid_client", "invalid_grant", "slow_down", "a" * 64])
@pytest.mark.parametrize("surface", list(SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_code_that_overlaps_nothing_sent_is_carried(
    lane: str, surface: str, code: str
) -> None:
    with _echo_idp(fixed=code) as idp:
        err = await _fail(lane, idp.url, SURFACES[surface][0])
    _carried(err, code)


@pytest.mark.parametrize("lane", LANES)
async def test_a_public_client_still_gets_the_code(lane: str) -> None:
    with _echo_idp(fixed="invalid_grant") as idp:
        err = await _fail(lane, idp.url, SURFACES["refresh"][0], secret=None)
    _carried(err, "invalid_grant")


@pytest.mark.parametrize("lane", LANES)
async def test_the_price_a_secret_that_is_a_piece_of_the_code_withholds_it(lane: str) -> None:
    """Fixed on purpose — the overlap check cannot tell `client` inside `invalid_client` from a
    truncated echo, and it errs toward withholding (the status stays, nothing leaks)."""
    with _echo_idp(fixed="invalid_client") as idp:
        err = await _fail(lane, idp.url, SURFACES["client_credentials"][0], secret="client")
    _withheld(err, "invalid_client")
