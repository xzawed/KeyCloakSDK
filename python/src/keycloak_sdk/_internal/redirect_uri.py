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
  JDK 21.0.8): nothing after the scheme's `:` (`https:`); and, when the part after the `:`
  starts with `/`, a `[` or `]` before the first `?` anywhere but in the authority's one
  bracketed host (`https://[::1]:8443/cb`) -- `https://app/c[b`, `https://app[1]/cb`,
  `myapp:/c[b`. An opaque value (`myapp:c[b`, `urn:x[y]`) and the query may hold brackets.
  Not checked: what a bracketed host holds (`[zz]`, `[v1.x]`), and an empty authority
  (`https://`).

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
#: R4 -- the one bracketed host an authority may hold: optional user info, `[`, no bracket or
#: `/`, `]`, optional port. `fullmatch` anchors it at both ends.
_BRACKETED_HOST = re.compile(r"([^@\[\]/]*@)?\[[^\[\]/]+\](:[0-9]*)?")


def _bracketed(part: str) -> bool:
    return "[" in part or "]" in part


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
    authority, _, path = head[2:].partition("/")
    if _bracketed(authority) and _BRACKETED_HOST.fullmatch(authority) is None:
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
