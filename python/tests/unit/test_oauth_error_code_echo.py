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

The admin self-grant takes the same rule for `error` at an error status (registry
`oauth-error-code-surface-divergent`) — its message stays the status alone (the section at the end).
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
from urllib.parse import parse_qsl, unquote_plus, urlsplit

import pytest

from keycloak_sdk import KeycloakClient, KeycloakConfig
from keycloak_sdk.aio import AsyncKeycloakClient
from keycloak_sdk.exceptions import KeycloakAuthError

from .test_admin_grant import _attempt

pytestmark = pytest.mark.usefixtures("fast_tls")

LANES = ("sync", "aio")
_HTTP = "Keycloak request failed: HTTP 400"

# Code-shaped on purpose (the shape check alone cannot withhold them), and no two share a piece —
# an echo of one value must be withheld by comparing against THAT value, not a sibling's prefix.
SECRET = "zebrasecretjk"
REFRESH = "yakrefreshvq"
TOKEN = "walrustokenpx"
CODE = "vulturecodeby"
VERIFIER = "ocelotverifier" * 3 + "xx"  # 44 characters
KC_SECRET = "Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5"  # the shape a Keycloak-generated secret has
JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl"
#: where the 3xx cells point `Location` (this server, same origin) — a client that follows it
#: shows up in `_Idp.requests`
REDIRECT_TARGET = "/redirect-target"


@dataclass
class _Idp:
    """Answers every POST with 400 `{"error": …}` — `error` is `fixed`, or built by `echo` from
    the form and the client secret this request sent (Basic or form field). `description`, when
    set, rides along as `error_description`; `raw`, when set, is the whole body instead, and
    `location` a `Location` header. `requests` is every request as `METHOD /path`."""

    echo: Callable[[dict[str, str]], Any] | None = None
    fixed: Any = None
    status: int = 400
    description: str | None = None
    raw: str | None = None
    location: str | None = None
    url: str = ""
    seen: list[dict[str, str]] = field(default_factory=list)
    requests: list[str] = field(default_factory=list)
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
            path = urlsplit(self.path).path
            with idp.lock:
                idp.requests.append(f"{self.command} {path}")
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode() if length else ""
            if path == REDIRECT_TARGET:
                self._send(400, b'{"error":"redirect_target_reached"}', None)
                return
            answer = {"error": idp.error_for(_sent(self.headers, body))}
            if idp.description is not None:
                answer["error_description"] = idp.description
            payload = idp.raw.encode() if idp.raw is not None else json.dumps(answer).encode()
            self._send(idp.status, payload, idp.location)

        do_GET = do_PUT = do_DELETE = do_POST

        def _send(self, status: int, payload: bytes, location: str | None) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            if location is not None:
                self.send_header("Location", location)
            self.end_headers()
            self.wfile.write(payload)

    return Handler


@contextlib.contextmanager
def _echo_idp(
    *,
    echo: Callable[[dict[str, str]], Any] | None = None,
    fixed: Any = None,
    status: int = 400,
    description: str | None = None,
    raw: str | None = None,
) -> Iterator[_Idp]:
    idp = _Idp(echo=echo, fixed=fixed, status=status, description=description, raw=raw)
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


def _withheld(err: KeycloakAuthError, value: str, status: int = 400) -> None:
    assert err.error is None
    assert str(err) == f"Keycloak request failed: HTTP {status}"
    for text in _renderings(err):
        assert value not in text


def _carried(err: KeycloakAuthError, code: str) -> None:
    assert err.error == code
    assert str(err) == f"{_HTTP} ({code})"


# --- echoes of what the request sent ---------------------------------------------------------

#: name → how the IdP derives `error` from one sent value — every piece and every padding, so each
#: direction of the overlap is pinned (the code inside the value · the value inside the code)
ECHO_FORMS: dict[str, Callable[[str], str]] = {
    "whole": lambda v: v,
    "prefix": lambda v: v[:11],
    "suffix": lambda v: v[-11:],
    "middle": lambda v: v[2:11],
    "extended": lambda v: v + "_x",
    "prefixed": lambda v: "x_" + v,
    "wrapped": lambda v: "x_" + v + "_x",
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


@pytest.mark.parametrize("surface", list(SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_lowercased_echo_of_the_client_secret_is_never_carried(
    lane: str, surface: str
) -> None:
    """An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case."""
    act, _ = SURFACES[surface]
    with _echo_idp(echo=lambda sent: sent["client_secret"].lower()) as idp:
        err = await _fail(lane, idp.url, act, secret="EchoMixedCase")
    assert idp.seen and idp.seen[0]["client_secret"] == "EchoMixedCase"
    _withheld(err, "echomixedcase")


@pytest.mark.parametrize("lane", LANES)
async def test_success_status_oauth_error_withholds_a_lowercased_echo_of_the_client_secret(
    lane: str,
) -> None:
    """A 200 that names an OAuth error fails like the 400 that does (registry
    auth-2xx-error-code-divergent) — and its code takes the same rule: the secret echoed back
    lowercased is no code. Before the fix this 200 failed as "no usable access_token"."""
    with _echo_idp(
        echo=lambda sent: sent["client_secret"].lower(), status=200, description="d"
    ) as idp:
        err = await _fail(lane, idp.url, SURFACES["client_credentials"][0], secret="EchoedSecret")
    assert idp.seen and idp.seen[0]["client_secret"] == "EchoedSecret"
    _withheld(err, "echoedsecret", status=200)
    for text in _renderings(err):
        assert "EchoedSecret" not in text


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


@pytest.mark.parametrize(
    ("surface", "param"),
    [(s, "client_secret") for s in SURFACES]
    + [(s, p) for s, (_, ps) in SURFACES.items() for p in ps],
)
@pytest.mark.parametrize("lane", LANES)
async def test_an_echo_on_a_401_is_never_carried(lane: str, surface: str, param: str) -> None:
    """Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes
    the same rule (in .NET it is a branch of its own)."""
    act, _ = SURFACES[surface]
    with _echo_idp(echo=lambda sent: sent[param], status=401) as idp:
        err = await _fail(lane, idp.url, act)
    _withheld(err, idp.seen[0][param], status=401)


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


# --- the admin self-grant ----------------------------------------------------------------------
# Its error status carries the code in `error` too (registry oauth-error-code-surface-divergent —
# before, never), so the overlap is what keeps an echo of the grant's client secret out of it. Its
# message is the status alone, as before — `_withheld` fits it as it is.


def _admin_get(client: Any) -> Any:
    return client.admin.users.get("u1")


@pytest.mark.parametrize("status", [400, 401])
@pytest.mark.parametrize("form", list(ECHO_FORMS))
@pytest.mark.parametrize("lane", LANES)
async def test_the_admin_grant_never_carries_an_echoed_client_secret(
    lane: str, form: str, status: int
) -> None:
    with _echo_idp(echo=lambda sent: ECHO_FORMS[form](sent["client_secret"]), status=status) as idp:
        err = await _fail(lane, idp.url, _admin_get)
    assert idp.seen and idp.seen[0]["client_secret"] == SECRET
    _withheld(err, ECHO_FORMS[form](SECRET), status)


@pytest.mark.parametrize("lane", LANES)
async def test_the_admin_grant_never_carries_a_lowercased_echo_of_the_client_secret(
    lane: str,
) -> None:
    with _echo_idp(echo=lambda sent: sent["client_secret"].lower()) as idp:
        err = await _fail(lane, idp.url, _admin_get, secret="EchoMixedCase")
    assert idp.seen and idp.seen[0]["client_secret"] == "EchoMixedCase"
    _withheld(err, "echomixedcase")


# --- the OAuth `error` at a 3xx and a 5xx ------------------------------------------------------
# Registry node-5xx-oauth-error-code-empty. The contract puts it in the code field "at any status";
# that was measured at 400 · 401 (#1199) and the other 2xx (#1207) only. 5xx: pinned as the
# contract reads. 302 (`Location` on this server): recorded, not pinned — the 3xx contract is open;
# only "never followed" is asserted.

B5 = '{"error":"temporarily_unavailable","error_description":"down"}'
NO_ERROR = '{"message":"down"}'
#: every lane the cells drive — the auth surfaces and the admin self-grant
ERROR_STATUS_SURFACES: dict[str, Callable[[Any], Any]] = {
    **{name: act for name, (act, _) in SURFACES.items()},
    "admin": _admin_get,
}


async def _error_status_cell(
    lane: str, surface: str, status: int, raw: str, *, redirect: bool = False
) -> tuple[str | None, str, list[str]]:
    """One lane on a new client at one status and body: `error` (None when not an auth error),
    one line, and every request the IdP saw."""
    with _echo_idp(status=status, raw=raw) as idp:
        if redirect:
            idp.location = idp.url + REDIRECT_TARGET
        cfg = KeycloakConfig(server_url=idp.url, realm="r", client_id="c", client_secret=SECRET)
        act = ERROR_STATUS_SURFACES[surface]
        if lane == "sync":
            with KeycloakClient.create(cfg) as kc:
                _, err = await _attempt(lane, kc, act)
        else:
            async with AsyncKeycloakClient.create(cfg) as akc:
                _, err = await _attempt(lane, akc, act)
        with idp.lock:
            requests = list(idp.requests)
    code = err.error if isinstance(err, KeycloakAuthError) else None
    shown = repr(code) if isinstance(err, KeycloakAuthError) else "-"
    outcome = "success" if err is None else f"{type(err).__name__}({err}) code={shown}"
    return code, f"{status} {lane} {surface} → {outcome} requests={requests}", requests


@pytest.mark.parametrize("status", [500, 503])
@pytest.mark.parametrize("surface", list(ERROR_STATUS_SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_server_error_status_carries_the_oauth_error(
    lane: str, surface: str, status: int
) -> None:
    code, line, _ = await _error_status_cell(lane, surface, status, B5)
    print(line)
    assert code == "temporarily_unavailable", line


@pytest.mark.parametrize("surface", list(ERROR_STATUS_SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_the_error_status_controls_carry_it_at_400_and_none_without_one(
    lane: str, surface: str
) -> None:
    """Controls: the same body at 400 carries it; a 503 whose body names no `error` carries none."""
    at400, at400_line, _ = await _error_status_cell(lane, surface, 400, B5)
    none, none_line, _ = await _error_status_cell(lane, surface, 503, NO_ERROR)
    print(at400_line)
    print(none_line)
    assert at400 == "temporarily_unavailable", at400_line
    assert none is None, none_line


@pytest.mark.parametrize("surface", list(ERROR_STATUS_SURFACES))
@pytest.mark.parametrize("lane", LANES)
async def test_a_redirect_error_status_to_this_server_is_recorded_and_never_followed(
    lane: str, surface: str
) -> None:
    _, line, requests = await _error_status_cell(lane, surface, 302, B5, redirect=True)
    print(line)
    assert not [r for r in requests if r.endswith(" " + REDIRECT_TARGET)], line
