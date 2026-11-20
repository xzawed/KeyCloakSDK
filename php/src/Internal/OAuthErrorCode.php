<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

/**
 * Accepts the `error` value of an IdP error response **only when it is an OAuth error code**. @internal
 *
 * ⚠️ `error` is response body too — when it echoed a token back, `KeycloakAuthError`'s message and the public property
 * `oauthError` printed it as is (measured by the Grok leg 2026-09-26, through `var_dump` · `print_r`). The codes of
 * RFC 6749 · 6750 · 8628 · OIDC and Keycloak are all lowercase letters and underscores (`invalid_grant` · `login_required` ·
 * `authorization_pending` …), so only that shape is let through — JWT, base64url and hex tokens contain uppercase letters,
 * digits, `-` or `.` and are filtered out. It is the same shape as the python leg.
 *
 * ⚠️ The anchors are `\A` · `\z` — `$` (without `D`) and `\Z` also match **before one trailing newline**, so
 * `"invalid_client\n"` passed as a code and was put into the message and `oauthError` newline and all (it splits log lines,
 * measured 2026-10-02). Pinned by: `OAuthErrorCodeTest`.
 *
 * ⚠️ A lowercase-only secret has that shape too — an echoed `echoedlowersecret` was carried by the grants, the provider and
 * the admin grant (measured 2026-11-11). So the callers use {@see self::carried()}: a value that overlaps a non-empty secret
 * the request sent (`$sent` — neither contains the other, ASCII case ignored, so a truncated, extended or lowercased echo
 * goes too) is no code either. The price: a secret that is a piece of a registered code (`client`) withholds that code.
 * Pinned by: `OAuthErrorCodeEchoTest`.
 * `of()` keeps its 1.5.2 signature (the semver gate counts a parameter added to a public method as MAJOR).
 */
final class OAuthErrorCode
{
    public static function of(mixed $error): ?string
    {
        return self::carried($error);
    }

    public static function carried(mixed $error, #[\SensitiveParameter] ?string ...$sent): ?string
    {
        if (!\is_string($error) || preg_match('/\A[a-z_]{1,64}\z/', $error) !== 1) {
            return null;
        }
        foreach ($sent as $secret) {
            // An absent or empty secret is not compared — '' is a piece of every code (a public client sends none).
            if ($secret === null || $secret === '') {
                continue;
            }
            // A–Z → a–z only, so the nine languages agree: `strtolower` is ASCII-only since PHP 8.2 (a Unicode lowercase
            // maps U+212A KELVIN SIGN to `k`).
            $folded = strtolower($secret);
            if (str_contains($error, $folded) || str_contains($folded, $error)) {
                return null;
            }
        }

        return $error;
    }
}
