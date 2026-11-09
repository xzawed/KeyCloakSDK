<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Internal;

use GuzzleHttp\Exception\RequestException;
use GuzzleHttp\Promise\Create;
use GuzzleHttp\Promise\PromiseInterface;
use GuzzleHttp\Psr7\Utils;
use Lcobucci\JWT\Encoding\JoseEncoder;
use Lcobucci\JWT\Token\Parser;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;

/**
 * The Bearer grammar — the same rule in all nine languages. Only SP · HTAB · CR · LF are trimmed from both ends (not NBSP ·
 * U+3000 · VT · FF), and the rest must be an RFC 6750 `b64token` (`1*( ALPHA / DIGIT / "-" / "." / "_" / "~" / "+" / "/" ) *"="`,
 * ASCII). @internal
 *
 * Two places use this one predicate. (1) The admin lane (`grantMiddleware`) — fschmtt gets the token itself, keeps it in its
 * own store and builds the header itself, so the SDK cannot rewrite the value sent (psr7 validates the header value in
 * `new Request()` — before the handler stack — and trims SP · HTAB from both ends). So from a token response it accepts only
 * a b64token that **needs no trimming**. (2) `ClientCredentialsTokenProvider` — it is its own cache, so it caches the trimmed
 * value.
 *
 * ⚠️ Before this predicate, lcobucci's base64url parsing happened to block that spot, and that depended on the sodium
 * extension — without sodium, lcobucci skipped whitespace, so a JWT carrying SP · HTAB at the front or in the middle went
 * out as is (measured 2026-10-29 — `Admin\AdminBearerGrammarTest`).
 */
final class BearerToken
{
    public const GRANT_REFUSED = 'admin token request failed: the access token is not a valid RFC 6750 bearer token (b64token)';

    /** A 2xx grant body that is not strict UTF-8 JSON (RFC 8259 §8.1) — HTML, a JSON-typed HTML page, invalid UTF-8 anywhere. */
    public const GRANT_NOT_JSON = 'admin token request failed: the token response is not JSON';

    /** A 2xx grant body that is JSON but carries no string `access_token` (not an object, missing, not a string). */
    public const GRANT_NO_TOKEN = 'admin token request failed: the token response has no access_token';

    /** A grant answered with a status that is neither a success nor an error (1xx · 3xx) — redirects are not followed. */
    public const GRANT_STATUS = 'admin token request failed: HTTP %d';

    /** An access token that fschmtt's parser (lcobucci) cannot read — fschmtt parses it when it stores the grant. */
    public const GRANT_ACCESS_NOT_JWT = 'admin token request failed: the access token cannot be read as a JWT';

    /** A truthy `refresh_token` that fschmtt's parser (lcobucci) cannot read — fschmtt parses it right after the access token. */
    public const GRANT_REFRESH_NOT_JWT = 'admin token request failed: the refresh token cannot be read as a JWT';

    public const PROVIDER_REFUSED = 'client-credentials failed: the access token is not a valid RFC 6750 bearer token (b64token)';

    /** 이 미들웨어의 거부를 다른 `RequestException` 과 가르는 Guzzle handler context 키 — `isRejection`. */
    private const REJECTION = 'xzawed_keycloak_bearer_grammar';

    /**
     * The value to put after Bearer (the trimmed token), or null if it cannot be sent. ⚠️ `trim()` with its default set also
     * trims NUL · VT — so the set is spelled out. The end is `\z` — `$` also matches before a trailing LF.
     */
    public static function sendable(#[\SensitiveParameter] string $token): ?string
    {
        $t = trim($token, " \t\r\n");

        return preg_match('/\A[A-Za-z0-9\-._~+\/]+=*\z/', $t) === 1 ? $t : null;
    }

    /**
     * Admin handler-stack middleware — a response below 400 to a request picked by `$isTokenGrant` (fschmtt's token grant)
     * must be a 2xx (`GRANT_STATUS`) and a usable token response: strict UTF-8 JSON (`GRANT_NOT_JSON`), an object with a string
     * `access_token` (`GRANT_NO_TOKEN`), that token a b64token that needs no trimming (`GRANT_REFUSED`), and both tokens
     * fschmtt parses readable by its parser (`GRANT_ACCESS_NOT_JWT` · `GRANT_REFRESH_NOT_JWT`). Otherwise it rejects the grant
     * with a Guzzle `RequestException` (that message · no response or cause) — before fschmtt stores it, so nothing is cached
     * (the next call asks again) and no admin REST request goes out. `Admin\ErrorTranslation` turns the rejection into
     * `KeycloakAuthError`: the response arrived and is unusable (registry `token-response-class-divergent`). Why it is
     * Guzzle's: the same as `TokenResponseCap::middleware` — it reaches a `raw()` consumer as is.
     *
     * ⚠️ The JSON is decoded strictly. Read leniently (`JSON_INVALID_UTF8_SUBSTITUTE`), a byte that is not UTF-8 outside the
     * token passed here and then failed in fschmtt's own `json_decode` as an unclassified error — and the auth lanes of five
     * other languages returned a token carrying U+FFFD as a success (measured 2026-11-10).
     *
     * ⚠️ It goes **outside** `TokenResponseCap::middleware` in the stack — it sees the body the cap has judged.
     *
     * ⚠️ A 3xx is not passed on. Redirects are not followed (`HttpOptions`) and `http_errors` lets everything below 400
     * through, so fschmtt read a 3xx body as the token response — it took a 302 that carried a token, and an empty 302 ended
     * as an unclassified `JsonException` (independent review leg, measured 2026-11-10).
     *
     * ⚠️ fschmtt parses the access token and then a truthy `refresh_token` with lcobucci (`Http\Client::authorize`) — the
     * access token is already stored when the second parse fails, so the next call went out with it. So the same parser reads
     * both first, under the same condition. This mirrors fschmtt's own choice of library (lcobucci `^4.1 || ^5.2`, fschmtt's
     * requirement — not ours): when fschmtt is bumped, read `authorize()` again.
     *
     * @param \Closure(RequestInterface): bool $isTokenGrant
     * @return \Closure(callable(RequestInterface, array<string, mixed>): PromiseInterface): (\Closure(RequestInterface, array<string, mixed>): PromiseInterface)
     */
    public static function grantMiddleware(\Closure $isTokenGrant): \Closure
    {
        return static fn (callable $handler): \Closure => static function (RequestInterface $request, array $options) use ($handler, $isTokenGrant): PromiseInterface {
            $result = $handler($request, $options);
            $promise = $result instanceof PromiseInterface ? $result : Create::promiseFor($result);
            if (!$isTokenGrant($request)) {
                return $promise;
            }

            return $promise->then(static function (ResponseInterface $response) use ($request): ResponseInterface {
                $status = $response->getStatusCode();
                if ($status >= 400) {
                    return $response;   // 오류 응답은 http_errors 와 `Admin\ErrorTranslation` 의 몫이다
                }
                if ($status < 200 || $status >= 300) {
                    throw new RequestException(sprintf(self::GRANT_STATUS, $status), $request, null, null, [self::REJECTION => true]);
                }
                $raw = (string) $response->getBody();
                try {
                    $json = json_decode($raw, true, 512, JSON_THROW_ON_ERROR);   // 엄격하다 — 잘못된 UTF-8 도 여기서 거부된다
                } catch (\JsonException) {
                    throw new RequestException(self::GRANT_NOT_JSON, $request, null, null, [self::REJECTION => true]);
                }
                $token = \is_array($json) && !array_is_list($json) ? ($json['access_token'] ?? null) : null;
                if (!\is_string($token)) {
                    throw new RequestException(self::GRANT_NO_TOKEN, $request, null, null, [self::REJECTION => true]);
                }
                if (self::sendable($token) !== $token) {
                    throw new RequestException(self::GRANT_REFUSED, $request, null, null, [self::REJECTION => true]);
                }
                if (!self::readsAsJwt($token)) {
                    throw new RequestException(self::GRANT_ACCESS_NOT_JWT, $request, null, null, [self::REJECTION => true]);
                }
                // fschmtt 와 같은 조건이다 — `if ($tokens['refresh_token'])`(참인 값만 푼다 — "0" · "" · null 은 건너뛴다).
                $refresh = $json['refresh_token'] ?? null;
                if ((bool) $refresh && (!\is_string($refresh) || !self::readsAsJwt($refresh))) {
                    throw new RequestException(self::GRANT_REFRESH_NOT_JWT, $request, null, null, [self::REJECTION => true]);
                }

                return $response->withBody(Utils::streamFor($raw));   // 위에서 끝까지 읽었다 — fschmtt 는 처음부터 읽는다
            });
        };
    }

    /**
     * Whether fschmtt's parser reads it — the very call fschmtt makes (`new Token\Parser(new JoseEncoder())`). Any
     * `\Throwable` is "no": lcobucci also throws a `\TypeError` for a registered claim of the wrong type (an `exp` that is
     * `null` or `true`).
     */
    private static function readsAsJwt(#[\SensitiveParameter] string $token): bool
    {
        if ($token === '') {
            return false;
        }
        try {
            (new Parser(new JoseEncoder()))->parse($token);
        } catch (\Throwable) {
            return false;
        }

        return true;
    }

    /** Whether this is this middleware's rejection — `Admin\ErrorTranslation` tells it apart from other `RequestException`s (transport failures). */
    public static function isRejection(\Throwable $e): bool
    {
        return $e instanceof RequestException && ($e->getHandlerContext()[self::REJECTION] ?? null) === true;
    }
}
