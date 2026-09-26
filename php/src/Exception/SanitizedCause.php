<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Exception;

use GuzzleHttp\Exception\RequestException;
use League\OAuth2\Client\Provider\Exception\IdentityProviderException;

/**
 * SDK 예외의 `getPrevious()` 자리에 하위 라이브러리 예외 **원본 대신** 달리는 정화된 사본이다(§4 — 하위
 * 타입은 공개 API 로 새지 않는다). 직접 던지지 않는다.
 *
 * ⚠️ 원본을 그대로 달면 형식이 틀린·적대적인 IdP 응답이 원인 사슬로 샌다(실측 2026-09-26): league 의
 * `IdentityProviderException` 은 오류 응답 본문 전체를 쥐고 메시지에 `error_description` 을 싣고, Guzzle 의
 * `BadResponseException` 은 메시지에 응답 본문 앞부분을 싣고, 하위 예외의 **트레이스 인자**는 토큰 응답 배열·
 * 호출 옵션(refresh_token·code·Basic 헤더)·원문 JWT 를 쥔다 — `(string)$e`·`var_dump`·`print_r` 가 그 사슬을
 * 따라간다. `#[\SensitiveParameter]` 는 제3자 프레임에 닿지 않으므로 사본으로 바꾸는 것만이 경계에서 막는 길이다.
 *
 * 사본이 남기는 것: 원본 클래스명(`originalClass`)·코드·파일·줄·**인자를 뺀** 트레이스·같은 규칙으로 정화된 원인
 * 사슬. 메시지는 원본을 옮기되 응답을 인용하는 둘만 바꾼다 — HTTP 오류는 상태·메서드·URL(쿼리·사용자정보 제외),
 * OAuth 오류 응답은 `error` 코드만.
 */
final class SanitizedCause extends \RuntimeException
{
    private const MAX_DEPTH = 8;

    /** @param class-string $originalClass */
    private function __construct(public readonly string $originalClass, string $message, int $code, ?\Throwable $previous)
    {
        parent::__construct($message, $code, $previous);
    }

    /**
     * 하위 예외를 SDK 예외의 `previous` 로 달 수 있는 사본으로 바꾼다. SDK 자신의 예외는 이미 경계를 지났으므로 그대로 둔다.
     */
    public static function of(#[\SensitiveParameter] \Throwable $e): \Throwable
    {
        return self::copy($e, 0);
    }

    private static function copy(#[\SensitiveParameter] \Throwable $e, int $depth): \Throwable
    {
        if ($e instanceof KeycloakException || $e instanceof self) {
            return $e;
        }
        $previous = $e->getPrevious();
        $code = $e->getCode();
        $copy = new self(
            $e::class,
            self::safeMessage($e),
            \is_int($code) ? $code : 0,
            $previous === null || $depth >= self::MAX_DEPTH ? null : self::copy($previous, $depth + 1),
        );
        $copy->file = $e->getFile();
        $copy->line = $e->getLine();
        // 인자만 뺀 원본 프레임 — 어디서 났는지는 남기고, 무엇을 쥐고 있었는지는 버린다.
        $frames = array_map(static function (array $frame): array {
            unset($frame['args']);

            return $frame;
        }, $e->getTrace());
        (new \ReflectionProperty(\Exception::class, 'trace'))->setValue($copy, $frames);

        return $copy;
    }

    private static function safeMessage(\Throwable $e): string
    {
        if ($e instanceof IdentityProviderException) {
            $body = $e->getResponseBody();
            $error = \is_array($body) && isset($body['error']) && \is_string($body['error']) ? $body['error'] : null;

            return $error === null ? 'OAuth error response (body withheld)' : "OAuth error response: $error (description withheld)";
        }
        if ($e instanceof RequestException) {
            $response = $e->getResponse();
            if ($response !== null) {
                $request = $e->getRequest();
                $uri = $request->getUri()->withUserInfo('')->withQuery('')->withFragment('');

                return sprintf('HTTP %d from %s %s (response body withheld)', $response->getStatusCode(), $request->getMethod(), (string) $uri);
            }
        }

        return $e->getMessage();
    }
}
