<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use Xzawed\Keycloak\Exception\KeycloakAuthError;

/**
 * Keycloak answers a back-channel logout with 204 and nothing else — any other status is not a logout and fails as auth,
 * naming the status (registry `logout-2xx-html-false-success`, decision 2026-11-12). @internal
 *
 * ⚠️ Guzzle's `http_errors` lets every status below 400 through as a response and redirects are not followed
 * (`HttpOptions`), so a 200 page that intercepted the request — or a 302 to one — returned normally and `logout()` reported
 * a logout that never happened (measured 2026-11-12). The body is not judged: it is read only to hold the cap. An error
 * status never reaches `check` — `http_errors` raises it first, and `ResponseFailure::of(…, withStatus: true)` names it.
 */
final class LogoutAnswer
{
    public static function check(int $status): void
    {
        if ($status !== 204) {
            throw new KeycloakAuthError(sprintf('logout failed (HTTP %d)', $status));
        }
    }
}
