<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use Xzawed\Keycloak\Exception\KeycloakConfigError;

/**
 * The `redirect_uri` an authorization request may carry (registry `authz-request-redirect-unvalidated`) — checked, never
 * rewritten: the URL carries the caller's string exactly as given, and the code exchange sends that same string (RFC 6749
 * §4.1.3 wants the two to match, so normalising one of them breaks the flow). @internal
 *
 * Four rules, in this order:
 *  - R1 absolute (RFC 6749 §3.1.2): a scheme, then `:`.
 *  - R2 no fragment (RFC 6749 §3.1.2): no `#` anywhere — `https://app/cb#` has an empty one.
 *  - R3 a URI Keycloak can read (RFC 3986 §2): Keycloak parses `redirect_uri` with `java.net.URI.create` and refuses the
 *    request when that throws — for every character in U+0000–U+0020 and U+007F–U+00A0, for the Unicode space separators
 *    U+1680, U+2000–U+200A, U+2028, U+2029, U+202F, U+205F and U+3000, for `" < > \ ^ ` { | }`, and for a `%` that is not
 *    followed by two hex digits (measured on JDK 21.0.8). A string that is not valid UTF-8 is refused here too: with
 *    `/u`, `preg_match` returns false for it instead of matching, and false is a refusal.
 *  - R4 what `java.net.URI.create` still refuses after R1–R3 (same message as R3, measured on JDK 21.0.8): nothing after
 *    the scheme's `:` (`https:`, R4a); and, when the part after the `:` starts with `/`, a `[` or `]` before the first `?`
 *    anywhere but in the authority's one bracketed host — `https://app/c[b`, `https://app[1]/cb`, `myapp:/c[b` (R4b);
 *    `//` with nothing after it (`https://`, `myapp://` — R4c; `https:///cb` and `https://?x=1` are read); a bracketed
 *    host that is not an RFC 3986 IPv6 address with Java's dotted quads (leading zeros allowed), optionally followed by a
 *    zone id of letters, digits, `_` and `.` after a `%` (`[zz]`, `[v1.x]`, `[::1::2]` — R4d); and a port after that
 *    host above 2147483647 once its leading zeros are dropped (R4e). An opaque value (`myapp:c[b`, `urn:x[y]`) and the
 *    query may hold brackets. R3 still refuses a zone id whose `%` is not followed by two hex digits (`[fe80::1%eth0]`),
 *    which `URI.create` reads, because RFC 6874 §2 writes that `%` as `%25` in a URI (`[fe80::1%25eth0]`).
 *
 * R1, R2 and R4 read bytes (no `/u`), so an invalid UTF-8 string still gets R1 and R2 first; R4 runs only on what R3 let
 * through. A refusal is a KeycloakConfigError whose message never quotes the value.
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

    /** R4d — RFC 3986's `h16`. */
    private const H16 = '[0-9A-Fa-f]{1,4}';
    /** R4d — RFC 3986's `dec-octet` as Java reads it: leading zeros allowed (`01`, `0001`, `00000000255`). */
    private const DEC = '0*(?:25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])';
    /** R4d — RFC 3986's `ls32`. */
    private const LS32 = '(?:' . self::H16 . ':' . self::H16
        . '|' . self::DEC . '\.' . self::DEC . '\.' . self::DEC . '\.' . self::DEC . ')';
    /** R4d — RFC 3986's `IPv6address`, one alternative per line. */
    private const IPV6 = '(?:(?:' . self::H16 . ':){6}' . self::LS32
        . '|::(?:' . self::H16 . ':){5}' . self::LS32
        . '|(?:' . self::H16 . ')?::(?:' . self::H16 . ':){4}' . self::LS32
        . '|(?:(?:' . self::H16 . ':){0,1}' . self::H16 . ')?::(?:' . self::H16 . ':){3}' . self::LS32
        . '|(?:(?:' . self::H16 . ':){0,2}' . self::H16 . ')?::(?:' . self::H16 . ':){2}' . self::LS32
        . '|(?:(?:' . self::H16 . ':){0,3}' . self::H16 . ')?::' . self::H16 . ':' . self::LS32
        . '|(?:(?:' . self::H16 . ':){0,4}' . self::H16 . ')?::' . self::LS32
        . '|(?:(?:' . self::H16 . ':){0,5}' . self::H16 . ')?::' . self::H16
        . '|(?:(?:' . self::H16 . ':){0,6}' . self::H16 . ')?::)';

    /**
     * R4d — the one bracketed host an authority may hold: optional user info, `[`, an IPv6 address, an optional zone id
     * (Java's scope_id: letters, digits, `_`, `.`), `]`, an optional port (group 1 — R4e reads it).
     */
    private const BRACKETED_AUTHORITY = '~^(?:[^@\[\]/]*@)?\[' . self::IPV6 . '(?:%[A-Za-z0-9_.]+)?\](?::([0-9]*))?$~D';

    /** R4e — Java's `Integer.MAX_VALUE`: `URI` reads a port with `Integer.parseInt`. */
    private const PORT_MAX = 2147483647;

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
        if (!self::parsable(explode(':', $redirectUri, 2)[1] ?? '')) {
            throw new KeycloakConfigError(self::NOT_VALID);
        }
    }

    /** R4 on the part after the scheme's `:` (R1 matched, so the first `:` is the scheme's). */
    private static function parsable(string $rest): bool
    {
        if ($rest === '') {
            return false;
        }
        if (!str_starts_with($rest, '/')) {
            return true;
        }
        $head = explode('?', $rest, 2)[0];
        if (!str_starts_with($head, '//')) {
            return strpbrk($head, '[]') === false;
        }
        if ($rest === '//') {
            return false;
        }
        [$authority, $path] = explode('/', substr($head, 2), 2) + [1 => ''];

        return (strpbrk($authority, '[]') === false || self::bracketedHost($authority))
            && strpbrk($path, '[]') === false;
    }

    /**
     * R4d and R4e on an authority that holds a bracket: its one bracketed host, then the port's digits without their
     * leading zeros — at most ten, and no larger than PORT_MAX.
     */
    private static function bracketedHost(string $authority): bool
    {
        if (preg_match(self::BRACKETED_AUTHORITY, $authority, $host) !== 1) {
            return false;
        }
        $digits = ltrim($host[1] ?? '', '0');

        return strlen($digits) <= 10 && (int) $digits <= self::PORT_MAX;
    }
}
