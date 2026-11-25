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

    /**
     * Whether a body the lane got at a status it takes as success is an OAuth error response all the same — a JSON object
     * whose `error` is present and neither null nor `""`: a string, code-shaped or not, and a number, array, object or bool
     * too (what is carried is `carried()`'s — a string only). Every token lane and introspection then fails with the type
     * and message it gives an error status carrying that `error`, the code vetted by `carried()`, and nothing else in the
     * body (a token, `active`) is used — this is checked before anything else in the body (registry
     * `auth-2xx-error-code-divergent`: a token beside it was cached and sent, an `active: true` beside it reported ·
     * `token-response-residual-divergence` A: an `error` that is no string was ignored). ⚠️ `"0"`, `0` and `false` count —
     * PHP's `empty()` and `(bool)` call them empty. A null or `""` `error` is none; nor is a body that is no JSON object — a
     * JSON list decodes to an array too, but it has no string key.
     */
    public static function isErrorResponse(mixed $decoded): bool
    {
        if (!\is_array($decoded)) {
            return false;
        }
        $error = $decoded['error'] ?? null;

        return $error !== null && $error !== '';
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
