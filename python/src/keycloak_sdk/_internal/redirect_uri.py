"""The `redirect_uri` an authorization request may carry -- checked, never rewritten.

Registry `authz-request-redirect-unvalidated`. Both mirrors' `authorization_url` call
`check_redirect_uri` first, before PKCE, state or nonce exist. The value goes into the URL
exactly as given: the code exchange sends the caller's string verbatim, and the two requests
must carry the same value (RFC 6749 §4.1.3), so normalising one of them breaks the flow.

Three rules, in this order:

- R1 absolute (RFC 6749 §3.1.2, RFC 3986 §4.3): a scheme, then `:`. A non-`str` -- the
  signature says `str`, the runtime does not -- is not an absolute URI either.
- R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere; `https://app/cb#` has an empty one.
- R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with
  `java.net.URI.create` and refuses the request when that throws -- for every character in
  U+0000-U+0020 and U+007F-U+00A0, for `" < > \\ ^ ` { | }`, and for a `%` that is not
  followed by two hex digits (measured on JDK 21, 2026-11-18).

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
#: R3 -- one character `java.net.URI.create` refuses, or a `%` without two hex digits.
_UNREADABLE = re.compile(r'[\x00-\x20\x7f-\xa0"<>\\^`{|}]|%(?![0-9A-Fa-f]{2})')


def check_redirect_uri(redirect_uri: object) -> None:
    """Raise `KeycloakConfigError` unless `redirect_uri` passes R1, R2 and R3 (in that order)."""
    if not isinstance(redirect_uri, str) or _SCHEME.match(redirect_uri) is None:
        raise KeycloakConfigError(NOT_ABSOLUTE)
    if "#" in redirect_uri:
        raise KeycloakConfigError(FRAGMENT)
    if _UNREADABLE.search(redirect_uri) is not None:
        raise KeycloakConfigError(NOT_VALID)
