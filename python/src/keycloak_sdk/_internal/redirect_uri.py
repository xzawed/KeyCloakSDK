"""The `redirect_uri` an authorization request may carry -- checked, never rewritten.

Registry `authz-request-redirect-unvalidated`. Both mirrors' `authorization_url` call
`checked_redirect_uri` first, before PKCE, state or nonce exist, and put the string it returns
into the URL. That string is `str(redirect_uri)` -- what `urlencode` made of any value before
(a URL object such as Starlette's `request.url_for(...)` result worked, so it still does) -- and
it is checked and sent as is: the code exchange sends the caller's string verbatim, and the two
requests must carry the same value (RFC 6749 §4.1.3), so normalising one of them breaks the
flow. Checking the converted string is also what keeps a `str` subclass whose `__str__` differs
from its value from sending something that was never checked.

Three rules, in this order:

- R1 absolute (RFC 6749 §3.1.2, RFC 3986 §4.3): a scheme, then `:`. `None` becomes "None" and
  `bytes` become "b'...'" (the signature says `str`), so neither is an absolute URI.
- R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere; `https://app/cb#` has an empty one.
- R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with
  `java.net.URI.create` and refuses the request when that throws -- for every character in
  U+0000-U+0020 and U+007F-U+00A0, for the Unicode space separators U+1680, U+2000-U+200A,
  U+2028, U+2029, U+202F, U+205F and U+3000, for `" < > \\ ^ ` { | }`, and for a `%` that is
  not followed by two hex digits (measured on JDK 21.0.8). A lone surrogate (U+D800-U+DFFF;
  a `str` never holds a paired one) is refused here too: `urlencode` encodes UTF-8 strictly and
  would raise `UnicodeEncodeError` outside the SDK's errors. Keycloak also refuses `[` or `]`
  outside the query and the host, and an empty part after the scheme; those are not checked.

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


def checked_redirect_uri(redirect_uri: object) -> str:
    """`str(redirect_uri)` once it passes R1, R2 and R3 (in that order) -- the string to send.

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
    return text
