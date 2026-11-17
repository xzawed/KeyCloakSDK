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
 *    request when that throws — for every character in U+0000–U+0020 and U+007F–U+00A0, for `" < > \ ^ ` { | }`, and for a
 *    `%` that is not followed by two hex digits. A string that is not valid UTF-8 is refused here too: with `/u`,
 *    `preg_match` returns false for it instead of matching, and false is a refusal.
 *
 * R1 and R2 read bytes (no `/u`), so an invalid UTF-8 string still gets R1 and R2 first. A refusal is a KeycloakConfigError
 * whose message never quotes the value. null means "none given" and is not checked: `AuthClient` then sends the config
 * value, which `KeycloakConfig` already checked.
 */
final class RedirectUri
{
    public const NOT_ABSOLUTE = 'invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)';
    public const FRAGMENT = 'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)';
    public const NOT_VALID = 'invalid redirect_uri: not a valid URI (RFC 3986 §2)';

    public static function check(?string $redirectUri): void
    {
        if ($redirectUri === null) {
            return;
        }
        if (preg_match('/^[A-Za-z][A-Za-z0-9+.-]*:/', $redirectUri) !== 1) {
            throw new KeycloakConfigError(self::NOT_ABSOLUTE);
        }
        if (str_contains($redirectUri, '#')) {
            throw new KeycloakConfigError(self::FRAGMENT);
        }
        if (preg_match('/[\x{00}-\x{20}\x{7F}-\x{A0}"<>\\\\^`{|}]|%(?![0-9A-Fa-f]{2})/u', $redirectUri) !== 0) {
            throw new KeycloakConfigError(self::NOT_VALID);
        }
    }
}
