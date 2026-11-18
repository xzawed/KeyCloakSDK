"""The `redirect_uri` an authorization request may carry -- checked, never rewritten.

Registry `authz-request-redirect-unvalidated`. Both mirrors' `authorization_url` call
`checked_redirect_uri` first, before PKCE, state or nonce exist, and put the string it returns
into the URL. That string is `str(redirect_uri)` -- what `urlencode` made of any value before
(a URL object such as Starlette's `request.url_for(...)` result worked, so it still does) -- and
it is checked and sent as is: the code exchange sends the caller's string verbatim, and the two
requests must carry the same value (RFC 6749 §4.1.3), so normalising one of them breaks the
flow. Checking the converted string is also what keeps a `str` subclass whose `__str__` differs
from its value from sending something that was never checked.

Four rules, in this order:

- R1 absolute (RFC 6749 §3.1.2, RFC 3986 §4.3): a scheme, then `:`. `None` becomes "None" and
  `bytes` become "b'...'" (the signature says `str`), so neither is an absolute URI.
- R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere; `https://app/cb#` has an empty one.
- R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with
  `java.net.URI.create` and refuses the request when that throws -- for every character in
  U+0000-U+0020 and U+007F-U+00A0, for the Unicode space separators U+1680, U+2000-U+200A,
  U+2028, U+2029, U+202F, U+205F and U+3000, for `" < > \\ ^ ` { | }`, and for a `%` that is
  not followed by two hex digits (measured on JDK 21.0.8). A lone surrogate (U+D800-U+DFFF;
  a `str` never holds a paired one) is refused here too: `urlencode` encodes UTF-8 strictly and
  would raise `UnicodeEncodeError` outside the SDK's errors.
- R4 what `java.net.URI.create` still refuses once R1-R3 hold (same message as R3, measured on
  JDK 21.0.8): nothing after the scheme's `:` (`https:`, R4a); and, when the part after the `:`
  starts with `/`, a `[` or `]` before the first `?` anywhere but in the authority's one
  bracketed host -- `https://app/c[b`, `https://app[1]/cb`, `myapp:/c[b` (R4b); `//` with
  nothing after it (`https://`, `myapp://` -- R4c; `https:///cb` and `https://?x=1` are read);
  a bracketed host that is not an RFC 3986 IPv6 address with Java's dotted quads (leading zeros
  allowed), optionally followed by a zone id of letters, digits, `_` and `.` after a `%`
  (`[zz]`, `[v1.x]`, `[::1::2]` -- R4d); and a port after that host above 2147483647 once its
  leading zeros are dropped (R4e). An opaque value (`myapp:c[b`, `urn:x[y]`) and the query may
  hold brackets. R3 still refuses a zone id whose `%` is not followed by two hex digits
  (`[fe80::1%eth0]`), which `URI.create` reads, because RFC 6874 §2 writes that `%` as `%25`
  in a URI (`[fe80::1%25eth0]`).

A refusal is `KeycloakConfigError` with a fixed message: it never quotes the value.
"""

from __future__ import annotations

import re

from ..exceptions import KeycloakConfigError

NOT_ABSOLUTE = "invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)"
FRAGMENT = "invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)"
NOT_VALID = "invalid redirect_uri: not a valid URI (RFC 3986 §2)"

#: RFC 3986 §3.1 scheme, then `:`. `match` anchors it at the start.
_SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*:")
#: R3 -- one character `java.net.URI.create` refuses, a lone surrogate, or a `%` without two
#: hex digits.
_UNREADABLE = re.compile(
    r"[\x00-\x20\x7f-\xa0\U00001680\U00002000-\U0000200a\U00002028\U00002029\U0000202f"
    r'\U0000205f\U00003000\ud800-\udfff"<>\\^`{|}]|%(?![0-9A-Fa-f]{2})'
)
#: R4d -- RFC 3986's `h16`, and its `dec-octet` as Java reads it (leading zeros allowed: `01`,
#: `00000000255`).
_H16 = "[0-9A-Fa-f]{1,4}"
_DEC = "0*(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])"
_LS32 = rf"(?:{_H16}:{_H16}|{_DEC}\.{_DEC}\.{_DEC}\.{_DEC})"
#: R4d -- RFC 3986's `IPv6address`, one alternative per line in the RFC's own terms, then spelled
#: out (`_LS32` and `_H16` hold neither token, so the two replacements cannot interfere).
_IPV6 = (
    (
        "(?:(?:H16:){6}LS32"
        "|::(?:H16:){5}LS32"
        "|(?:H16)?::(?:H16:){4}LS32"
        "|(?:(?:H16:){0,1}H16)?::(?:H16:){3}LS32"
        "|(?:(?:H16:){0,2}H16)?::(?:H16:){2}LS32"
        "|(?:(?:H16:){0,3}H16)?::H16:LS32"
        "|(?:(?:H16:){0,4}H16)?::LS32"
        "|(?:(?:H16:){0,5}H16)?::H16"
        "|(?:(?:H16:){0,6}H16)?::)"
    )
    .replace("LS32", _LS32)
    .replace("H16", _H16)
)
#: R4d -- the one bracketed host an authority may hold: optional user info, `[`, an IPv6 address,
#: an optional zone id (Java's scope_id: letters, digits, `_`, `.`), `]`, an optional port (group
#: 1 -- R4e reads it). `fullmatch` anchors it at both ends.
_BRACKETED_AUTHORITY = re.compile(rf"(?:[^@\[\]/]*@)?\[{_IPV6}(?:%[A-Za-z0-9_.]+)?\](?::([0-9]*))?")
#: R4e -- Java's `Integer.MAX_VALUE`: `URI` reads a port with `Integer.parseInt`.
_PORT_MAX = 2147483647


def _bracketed(part: str) -> bool:
    return "[" in part or "]" in part


def _bracketed_host(authority: str) -> bool:
    """R4d and R4e on an authority that holds a bracket: its one bracketed host, then the port's
    digits without their leading zeros -- at most ten (so `int()` never meets more than ten), and
    no larger than `_PORT_MAX`."""
    host = _BRACKETED_AUTHORITY.fullmatch(authority)
    if host is None:
        return False
    digits = (host.group(1) or "").lstrip("0")
    return len(digits) <= 10 and int(digits or "0") <= _PORT_MAX


def _parsable(text: str) -> bool:
    """R4 on a value R1-R3 let through -- R1 matched, so the first `:` is the scheme's."""
    rest = text.partition(":")[2]
    if not rest:
        return False
    if not rest.startswith("/"):
        return True
    head = rest.partition("?")[0]
    if not head.startswith("//"):
        return not _bracketed(head)
    if rest == "//":
        return False
    authority, _, path = head[2:].partition("/")
    if _bracketed(authority) and not _bracketed_host(authority):
        return False
    return not _bracketed(path)


def checked_redirect_uri(redirect_uri: object) -> str:
    """`str(redirect_uri)` once it passes R1, R2, R3 and R4 (in that order) -- the string to
    send.

    Anything else raises `KeycloakConfigError`. An exception from the value's own `__str__`
    propagates as it did from `urlencode`.
    """
    # `str()` is what `urlencode` did. `str.__str__` then makes it a plain `str`: a `__str__` may
    # return a `str` subclass, whose own `__str__` would have `urlencode` send something else.
    text = str.__str__(str(redirect_uri))
    if _SCHEME.match(text) is None:
        raise KeycloakConfigError(NOT_ABSOLUTE)
    if "#" in text:
        raise KeycloakConfigError(FRAGMENT)
    if _UNREADABLE.search(text) is not None:
        raise KeycloakConfigError(NOT_VALID)
    if not _parsable(text):
        raise KeycloakConfigError(NOT_VALID)
    return text
