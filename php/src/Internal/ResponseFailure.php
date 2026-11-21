<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use GuzzleHttp\Exception\BadResponseException;
use GuzzleHttp\Exception\GuzzleException;
use GuzzleHttp\Exception\RequestException;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakException;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\Exception\SanitizedCause;

/**
 * The class of a Guzzle failure on a request whose response the SDK judges — a response that arrived in full but cannot be
 * used is `KeycloakAuthError`, one that did not arrive is `KeycloakTransportError` (registry `token-response-class-divergent`
 * · residue 2026-11-11). @internal
 *
 * ⚠️ Introspection and logout called every non-connect Guzzle failure auth — so a TLS failure, or a response head Guzzle
 * could not build into a response (a header name outside RFC 7230), was an IdP rejection (measured 2026-11-11). And every
 * lane called a body whose content coding curl could not decode (CURLE_BAD_CONTENT_ENCODING) a transport failure.
 */
final class ResponseFailure
{
    /** CURLE_BAD_CONTENT_ENCODING — by value: without ext-curl Guzzle picks `StreamHandler`, and the constant is undefined. */
    private const BAD_CONTENT_ENCODING = 61;

    /**
     * Whether the head arrived and the body bytes that arrived could not be decoded — a corrupt content coding, the IdP's and
     * no retry's to fix (registry decision Q1, 2026-11-11). ⚠️ It does not mean the whole body arrived: curl decodes as it
     * reads and stops at the first bytes it cannot decode, so a corrupt start with the rest never sent is the same errno 61
     * (review leg: `size_download=0` of 1000). A clean cut inside a valid stream is curl 18 or 28 — transport. ⚠️
     * `StreamHandler` reports a corrupt body as a bare "Unable to read from stream" — no response, no errno — exactly as a
     * socket read that failed, so there it stays a transport failure (measured: it cannot be told apart).
     */
    public static function undecodable(#[\SensitiveParameter] \Throwable $e): bool
    {
        return $e instanceof RequestException && ($e->getHandlerContext()['errno'] ?? null) === self::BAD_CONTENT_ENCODING;
    }

    /**
     * The SDK error for a failed introspection or logout request — `"<what> failed"` (auth) for an answer the server sent (an
     * error status, or a body that could not be decoded), `"<what> request failed"` (transport) for a request that got none.
     * `$withStatus` names the status of that answer when Guzzle kept it — `"<what> failed (HTTP N)"`, the wording of every
     * failed logout (`LogoutAnswer`). `$sent` — the secrets the request sent — makes the auth error carry the answer's OAuth
     * `error` as `oauthError` (`oauthError()`): introspection passes its client secret and token, logout none.
     *
     * ⚠️ `$e` is sensitive — the error is built in this frame, and the Guzzle exception holds the request (Basic credentials,
     * the token or refresh token in the form): without the attribute, `var_dump` of the SDK error printed them from the trace
     * (`MalformedTokenResponseTest`, measured).
     *
     * @param list<?string>|null $sent
     */
    public static function of(#[\SensitiveParameter] GuzzleException $e, string $what, bool $withStatus = false, #[\SensitiveParameter] ?array $sent = null): KeycloakException
    {
        if (!$e instanceof BadResponseException && !self::undecodable($e)) {
            return new KeycloakTransportError("$what request failed", previous: SanitizedCause::of($e));
        }
        $status = $withStatus && $e instanceof RequestException ? $e->getResponse()?->getStatusCode() : null;
        $code = $sent !== null && $e instanceof BadResponseException ? self::oauthError($e, $sent) : null;

        return new KeycloakAuthError($status === null ? "$what failed" : "$what failed (HTTP $status)", $code, SanitizedCause::of($e));
    }

    /**
     * The OAuth `error` an error-status answer's body names, when `OAuthErrorCode::carried()` lets it through against what the
     * request sent — introspection carries it at an error status as the grants do (registry `oauth-error-code-surface-divergent`:
     * it was null there, while the same `error` at 200 was carried). The body is read within the cap (`TokenResponseCap::read`);
     * one over the cap, unreadable or not a JSON object carries none.
     *
     * @param list<?string> $sent
     */
    private static function oauthError(#[\SensitiveParameter] BadResponseException $e, #[\SensitiveParameter] array $sent): ?string
    {
        try {
            $body = TokenResponseCap::read($e->getResponse()->getBody());
        } catch (\Throwable) {
            return null;   // an unreadable body carries no code — the read error does not cross the boundary
        }
        $json = $body === null ? null : json_decode($body, true);

        return OAuthErrorCode::carried(\is_array($json) ? ($json['error'] ?? null) : null, ...$sent);
    }
}
