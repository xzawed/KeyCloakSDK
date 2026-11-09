<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Exception\BuilderException;
use Fschmtt\Keycloak\Exception\VersionDetectionException;
use GuzzleHttp\Exception\BadResponseException;
use GuzzleHttp\Exception\ClientException;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Exception\RequestException;
use GuzzleHttp\Exception\ServerException;
use GuzzleHttp\Psr7\Message;
use Lcobucci\JWT\Exception as JwtException;
use Psr\Http\Message\RequestInterface;
use Xzawed\Keycloak\Exception\KeycloakAdminError;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakConfigError;
use Xzawed\Keycloak\Exception\KeycloakConflictError;
use Xzawed\Keycloak\Exception\KeycloakException;
use Xzawed\Keycloak\Exception\KeycloakForbiddenError;
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\Exception\SanitizedCause;
use Xzawed\Keycloak\Internal\BearerToken;
use Xzawed\Keycloak\Internal\OAuthErrorCode;
use Xzawed\Keycloak\Internal\TokenResponseCap;

/**
 * fschmtt does not translate Guzzle exceptions (404/409/403 are all a raw ClientException), so they are translated here,
 * at the boundary.
 *
 * ⚠️ The underlying exception is attached not as the original but as a `SanitizedCause` copy, and the message is built here
 * (the same rule as `AuthClient` — the rationale is in `SanitizedCause`'s docblock). With the original attached, when admin's
 * token grant (fschmtt performs it) or an admin request failed, the response-body summary in Guzzle's message and the
 * arguments of the underlying frames — the token response body, the `client_secret` form, the `Bearer` header, the
 * representation sent — were printed through `getMessage()` · `(string)$e` · `var_dump` · `print_r` (measured 2026-10-02).
 * What is kept: the type · the HTTP status (`getStatusCode()`) · the OAuth `error` code of a token-grant error (only when
 * it has the `OAuthErrorCode` shape). The input the facade sends (representations, search criteria) is hidden by each
 * resource method with `#[\SensitiveParameter]` — identifiers that go into the path remain visible, as the cause's URL does.
 *
 * ⚠️ fschmtt 0.44 wraps **every** failure of the version detection it runs first on each resource access made before the
 * version is known (`GET /admin/serverinfo` — the first admin token grant happens there) in a
 * `VersionDetectionException` and attaches it as the cause (`Keycloak::fetchVersion`). While wrapped, a token-grant 401,
 * a transport failure and a cap rejection fell through to the bottom net (#750: "admin request failed unexpectedly",
 * status null). So the cause is taken out and thrown down the same ladder again —
 * it is the very object 0.43 threw as is, so the type, status, message and cause copy are the same. Without a cause (a
 * serverinfo that hides systemInfo) the wrapper goes to the net as it is — in 0.43 the `\Error` raised by a call on null
 * went to the same net (the two serverinfo cells of `AdminFacadeErrorLeakTest`).
 */
final class ErrorTranslation
{
    /**
     * Where fschmtt gets the admin token — the tail after `{base}/realms/{realm}`. ⚠️ The tail alone cannot tell them apart —
     * an identifier that goes into the path can make an admin REST path end with this too (fschmtt does not encode path
     * values). What tells them apart is the Bearer (`failed()`). The token response cap in `AdminClient` also picks out the
     * token grant by the same rule.
     */
    public const TOKEN_PATH = '/protocol/openid-connect/token';

    /** OAuth 오류 응답은 작다 — 이보다 긴 본문에서는 코드를 찾지 않는다(적대적 IdP 의 큰 본문을 통째로 디코드하지 않는다). */
    private const MAX_ERROR_BODY = 8192;

    /** fschmtt(lcobucci)가 부여의 access token 을 JWT 로 풀지 못했다 — Keycloak 의 access token 은 늘 JWT 다. */
    private const GRANT_NOT_A_JWT = 'admin token request failed: the access token is not a JWT';

    /**
     * ⚠️ `$fn` is a closure that captures the representation being sent (password, client secret) — it is an argument of
     * the #0 frame in the SDK exception's trace.
     *
     * @template T
     * @param callable():T $fn
     * @return T
     */
    public static function call(#[\SensitiveParameter] callable $fn): mixed
    {
        try {
            try {
                return $fn();
            } catch (VersionDetectionException $e) {
                throw $e->getPrevious() ?? $e;   // fschmtt 0.44 의 감싸기를 벗긴다 — 클래스 docblock.
            }
        } catch (ClientException $e) {
            if (self::isTokenGrant($e->getRequest())) {
                throw self::grantFailed($e);
            }
            $status = $e->getResponse()->getStatusCode();
            $message = self::failed($e);
            $cause = SanitizedCause::of($e);
            throw match ($status) {
                404 => new KeycloakNotFoundError($message, 404, $cause),
                409 => new KeycloakConflictError($message, 409, $cause),
                403 => new KeycloakForbiddenError($message, 403, $cause),
                default => new KeycloakAdminError($message, $status, $cause),
            };
        } catch (ServerException $e) {
            if (self::isTokenGrant($e->getRequest())) {
                throw self::grantFailed($e);
            }
            throw new KeycloakAdminError(self::failed($e), $e->getResponse()->getStatusCode(), SanitizedCause::of($e));
        } catch (ConnectException $e) {
            throw new KeycloakTransportError('admin request unreachable', previous: SanitizedCause::of($e));
        } catch (RequestException $e) {
            if (TokenResponseCap::isRejection($e)) {
                // admin 의 토큰 응답이 상한을 넘었거나 끝을 알리기 전에 막혔다(`AdminClient` 의 미들웨어) — 토큰 부여에서 끝나 admin
                // REST 요청은 나가지 않았다. 메시지는 그 미들웨어가 만든 문구다. ⚠️ 원인을 달지 않는다 — 그 예외의 트레이스는 Guzzle `request()` 의
                // `form_params`(client_secret) 프레임 인자를 쥔다.
                throw new KeycloakTransportError($e->getMessage());
            }
            if (BearerToken::isRejection($e)) {
                // admin 의 토큰 부여가 쓸 수 없는 2xx 를 줬다 — JSON 아님 · access_token 없음 · Bearer 문법 밖(`AdminClient` 의 미들웨어).
                // fschmtt 가 받아 두기 전에 거부해 캐시되지 않았고 admin REST 요청은 나가지 않았다. 끝까지 온 응답이라 auth 계급이다 —
                // auth 클라이언트의 같은 칸과 같다(등록부 token-response-class-divergent). ⚠️ 원인을 달지 않는다 — 위와 같은 이유.
                throw new KeycloakAuthError($e->getMessage());
            }
            throw new KeycloakTransportError('admin request failed', previous: SanitizedCause::of($e));
        } catch (BuilderException $e) {
            // fschmtt Builder 의 고정 문구 둘(`Base URL is not set`·`Grant type is not set`) — 네트워크 앞이라 응답·토큰이 없다.
            throw new KeycloakConfigError($e->getMessage(), previous: SanitizedCause::of($e));
        } catch (KeycloakException $e) {
            throw $e;   // 우리 자신의 SDK 예외 — 재래핑하지 않는다.
        } catch (JwtException $e) {
            // fschmtt 는 부여가 준 access token(과 refresh token)을 lcobucci 로 JWT 로 푼다 — lcobucci 는 거기서만 쓰이므로 이 예외는
            // 끝까지 온 부여 응답이 쓸 수 없다는 뜻이다(auth 계급). ⚠️ 메시지는 우리가 만든다 — lcobucci 의 문구는 감사하지 않았다.
            throw new KeycloakAuthError(self::GRANT_NOT_A_JWT, previous: SanitizedCause::of($e));
        } catch (\Throwable $e) {
            // fschmtt SerializerException(역직렬화 실패)·토큰 응답 파싱 실패(JsonException·lcobucci 예외·TypeError) 및 그 밖의
            // 미분류 하위 라이브러리 예외를 전부 여기로 수렴시켜 admin 파사드 밖으로 새지 않게 한다(JwtValidator의 \Throwable net과
            // 동형). ⚠️ 메시지는 옮기지 않는다 — 감사하지 않은 라이브러리가 만든 것이다(원본 클래스명은 원인에 남는다).
            throw new KeycloakAdminError('admin request failed unexpectedly', null, SanitizedCause::of($e));
        }
    }

    /**
     * admin 의 토큰 부여인가 — Bearer 없이 나가는 요청 하나뿐이다(fschmtt `Client::fetchTokens`). admin 요청은 전부 Bearer 를
     * 싣는다. 꼬리만 보면 `users()->get('x/protocol/openid-connect/token')` 이 admin 요청을 토큰 부여로 바꿨다. `AdminClient` 의
     * 미들웨어가 같은 규칙으로 고른다(공개하면 적대 경로 행렬이 인자를 합성하지 못해 한 줄을 두 곳에 둔다).
     */
    private static function isTokenGrant(RequestInterface $request): bool
    {
        return !$request->hasHeader('Authorization') && str_ends_with($request->getUri()->getPath(), self::TOKEN_PATH);
    }

    /** admin REST 요청의 HTTP 오류 메시지 — 상태만. 본문은 싣지 않는다(코드 모양이어도 OAuth 응답이 아니다). */
    private static function failed(BadResponseException $e): string
    {
        return 'admin request failed: HTTP ' . $e->getResponse()->getStatusCode();
    }

    /**
     * admin 의 토큰 부여가 끝까지 온 오류 응답으로 실패했다 — auth 계급이다(auth 클라이언트의 같은 칸과 같다). 상태는 메시지에,
     * 코드 모양의 OAuth `error` 는 메시지와 `oauthError` 에. ⚠️ 상태로 형을 고르지 않는다 — 토큰 엔드포인트의 404 가
     * `KeycloakNotFoundError` 가 되어 토큰을 못 받은 `users()->delete()` 가 admin 요청 0 번에 「이미 없다」로 읽혔다(403 · 409 도 —
     * 실측 2026-11-10, go #952 와 같은 위험).
     *
     * ⚠️ `$e` 에 `#[\SensitiveParameter]` — 예외는 여기서 만들어져 이 프레임을 트레이스에 담는다. 원본 Guzzle 예외가 인자로 실리면
     * `var_dump` · `print_r` 이 요청 폼의 `client_secret` 과 응답 본문을 찍었다(`AdminFacadeErrorLeakTest` 실측).
     */
    private static function grantFailed(#[\SensitiveParameter] BadResponseException $e): KeycloakAuthError
    {
        try {
            // 감사한 하위 라이브러리(psr7)의 요약 — 시크·되감기를 맡고, 상한을 넘으면 꼬리표가 붙어 JSON 이 아니게 된다.
            $error = json_decode(Message::bodySummary($e->getResponse(), self::MAX_ERROR_BODY) ?? '', true);
        } catch (\Throwable) {
            $error = null;   // 읽을 수 없는 본문 — 코드 없이 상태만 싣는다(읽기 오류가 경계를 넘지 않게).
        }
        $code = OAuthErrorCode::of(\is_array($error) ? ($error['error'] ?? null) : null);
        $status = $e->getResponse()->getStatusCode();

        return new KeycloakAuthError(
            "admin token request failed: HTTP $status" . ($code === null ? '' : " ($code)"),
            $code,
            SanitizedCause::of($e),
        );
    }
}
