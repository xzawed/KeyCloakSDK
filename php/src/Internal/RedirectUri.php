<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use Xzawed\Keycloak\Exception\KeycloakConfigError;

/**
 * The `redirect_uri` an authorization request may carry (registry `authz-request-redirect-unvalidated`) — checked, never
 * rewritten: the URL carries the caller's string exactly as given, and the code exchange sends that same string (RFC 6749
 * §4.1.3 wants the two to match, so normalising one of them breaks the flow). @internal
 *
 * Three rules, in this order:
 *  - R1 absolute (RFC 6749 §3.1.2): a scheme, then `:`.
 *  - R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere — `https://app/cb#` has an empty one.
 *  - R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with `java.net.URI.create` and refuses the
 *    request when that throws — for every character in U+0000–U+0020 and U+007F–U+00A0, for the Unicode space separators
 *    U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F and U+3000, for `" < > \ ^ ` { | }`, and for a `%` that is not
 *    followed by two hex digits (measured on JDK 21.0.8). A string that is not valid UTF-8 is refused here too: with
 *    `/u`, `preg_match` returns false for it instead of matching, and false is a refusal. Keycloak also refuses `[` or
 *    `]` outside the query and the host, and an empty part after the scheme; those are not checked here.
 *
 * R1 and R2 read bytes (no `/u`), so an invalid UTF-8 string still gets R1 and R2 first. A refusal is a KeycloakConfigError
 * whose message never quotes the value.
 *
 * `check()` is given the value about to be sent, so null — no redirect URI at all — is not an absolute URI: the league
 * provider would put an empty `redirect_uri=` on the URL, which Keycloak refuses for every client. `KeycloakConfig` checks
 * its `redirectUri` only when it is set, since a client may give one per request instead.
 */
final class RedirectUri
{
    public const NOT_ABSOLUTE = 'invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)';
    public const FRAGMENT = 'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)';
    public const NOT_VALID = 'invalid redirect_uri: not a valid URI (RFC 3986 §2)';

    /** R3 — one character `java.net.URI.create` refuses, or a `%` without two hex digits. */
    private const UNREADABLE = '/[\x{00}-\x{20}\x{7F}-\x{A0}\x{1680}\x{2000}-\x{200A}\x{2028}\x{2029}\x{202F}\x{205F}\x{3000}'
        . '"<>\\\\^`{|}]|%(?![0-9A-Fa-f]{2})/u';

    public static function check(?string $redirectUri): void
    {
        if ($redirectUri === null || preg_match('/^[A-Za-z][A-Za-z0-9+.-]*:/', $redirectUri) !== 1) {
            throw new KeycloakConfigError(self::NOT_ABSOLUTE);
        }
        if (str_contains($redirectUri, '#')) {
            throw new KeycloakConfigError(self::FRAGMENT);
        }
        if (preg_match(self::UNREADABLE, $redirectUri) !== 0) {
            throw new KeycloakConfigError(self::NOT_VALID);
        }
    }
}
