<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Http\Client\ClientExceptionInterface;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Client\NetworkExceptionInterface;
use Psr\Http\Message\{RequestInterface, ResponseInterface, StreamInterface};
use GuzzleHttp\Psr7\{HttpFactory, Response};
use Xzawed\Keycloak\{KeycloakConfig, OidcEndpoints, ClientCredentialsTokenProvider};
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;

final class ClientCredentialsTokenProviderTest extends TestCase
{
    private function config(): KeycloakConfig
    {
        return new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 's');
    }

    public function testFetchesAndCachesToken(): void
    {
        $calls = 0;
        $http = new class ($calls) implements ClientInterface {
            public function __construct(public int &$calls) {}
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $this->calls++;
                return new Response(
                    200,
                    ['Content-Type' => 'application/json'],
                    json_encode(['access_token' => 'AT', 'token_type' => 'Bearer', 'expires_in' => 300], JSON_THROW_ON_ERROR),
                );
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        self::assertSame('AT', $p->getToken());
        self::assertSame('AT', $p->getToken());   // 캐시 재사용
        self::assertSame(1, $calls);              // 두 번째는 네트워크 없음
    }

    /**
     * ⚠️ **만료 시각 미상인 토큰을 캐시가 영원히 재사용하면 안 된다.**
     *
     * `expires_in` 이 없는 응답은 `expiresAt === null` 을 만든다. `isExpired()` 가 그때
     * `false`(=살아있다)를 돌려주던 시절에는 `ClientCredentialsTokenProvider` 의 캐시 조건
     * (`!$this->cached->isExpired(...)`)이 **영원히 참**이어서 죽은 토큰을 무한 재사용했다 —
     * 네트워크 호출은 딱 1회로 멈춘다. fail-safe 로 고친 지금은 매번 재발급해야 한다.
     *
     * 위 `testFetchesAndCachesToken`(`expires_in: 300` → 1회)이 대조군이다: 이 테스트가
     * "캐시가 아예 동작하지 않는다"로 통과하는 것을 그쪽이 막는다.
     */
    public function testTokenWithUnknownExpiryIsNotCachedForever(): void
    {
        $calls = 0;
        $http = new class ($calls) implements ClientInterface {
            public function __construct(public int &$calls) {}
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $this->calls++;
                return new Response(
                    200,
                    ['Content-Type' => 'application/json'],
                    // expires_in 없음 → expiresAt === null
                    json_encode(['access_token' => 'AT', 'token_type' => 'Bearer'], JSON_THROW_ON_ERROR),
                );
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        self::assertSame('AT', $p->getToken());
        self::assertSame('AT', $p->getToken());
        self::assertSame(2, $calls, '만료 시각 미상 토큰은 캐시에서 영원히 재사용되면 안 된다');
    }

    public function testOauthErrorMapped(): void
    {
        $http = new class () implements ClientInterface {
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                return new Response(
                    401,
                    ['Content-Type' => 'application/json'],
                    json_encode(['error' => 'invalid_client', 'error_description' => 'bad'], JSON_THROW_ON_ERROR),
                );
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        $this->expectException(KeycloakAuthError::class);
        $p->getToken();
    }

    public function testClientExceptionMappedToTransport(): void
    {
        $http = new class () implements ClientInterface {
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                throw new class ('connection failed') extends \RuntimeException implements ClientExceptionInterface {};
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        $this->expectException(KeycloakTransportError::class);
        $p->getToken();
    }

    public function testNetworkExceptionMappedToTransport(): void
    {
        $http = new class () implements ClientInterface {
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                throw new class ('unreachable', $request) extends \RuntimeException implements NetworkExceptionInterface {
                    public function __construct(string $message, private readonly RequestInterface $request)
                    {
                        parent::__construct($message);
                    }
                    public function getRequest(): RequestInterface
                    {
                        return $this->request;
                    }
                };
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        $this->expectException(KeycloakTransportError::class);
        $p->getToken();
    }

    /**
     * A 200 whose body still carries an OAuth `error` fails as the error status does — `client-credentials failed` with the
     * vetted code — and nothing in it is cached: B2's token beside the `error` was cached and returned (registry
     * `auth-2xx-error-code-divergent`). B1 is the error alone, B2 the error beside a usable token, `zero` the error `"0"` (a
     * non-empty string — PHP's `empty()` calls it empty) beside one.
     *
     * @return array<string, array{string}>
     */
    public static function successStatusOAuthErrors(): array
    {
        return ['B1' => ['B1'], 'B2' => ['B2'], 'zero' => ['zero']];
    }

    #[DataProvider('successStatusOAuthErrors')]
    public function testSuccessStatusOAuthErrorFailsAndCachesNothing(string $body): void
    {
        $http = new class () implements ClientInterface {
            public int $calls = 0;
            public string $body = '';

            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $this->calls++;

                return new Response(200, ['Content-Type' => 'application/json'], $this->body);
            }
        };
        $http->body = match ($body) {
            'B1' => '{"error":"invalid_grant","error_description":"d"}',
            'B2' => '{"error":"invalid_grant","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}',
            default => '{"error":"0","access_token":"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl","token_type":"Bearer","expires_in":300}',
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        try {
            $p->getToken();
            self::fail("$body: a token came back");
        } catch (KeycloakAuthError $e) {
            self::assertSame('client-credentials failed', $e->getMessage());
            self::assertSame($body === 'zero' ? null : 'invalid_grant', $e->oauthError);
        }
        // Nothing was cached — the next call asks the token endpoint again and gets the token it answers now.
        $http->body = json_encode(['access_token' => 'AT', 'token_type' => 'Bearer', 'expires_in' => 300], JSON_THROW_ON_ERROR);
        self::assertSame('AT', $p->getToken());
        self::assertSame(2, $http->calls);
    }

    /**
     * Only a non-empty string `error` counts — an empty string, null, a number or false beside a usable token is ignored as
     * before (the control for the rows above).
     *
     * @return array<string, array{string}> JSON literal of `error`
     */
    public static function successStatusOAuthErrorIgnored(): array
    {
        return ['empty string' => ['""'], 'null' => ['null'], 'number' => ['0'], 'false' => ['false']];
    }

    #[DataProvider('successStatusOAuthErrorIgnored')]
    public function testSuccessStatusOAuthErrorIgnoresAnErrorThatIsNotANonEmptyString(string $literal): void
    {
        $http = new class () implements ClientInterface {
            public int $calls = 0;
            public string $body = '';

            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $this->calls++;

                return new Response(200, ['Content-Type' => 'application/json'], $this->body);
            }
        };
        $http->body = '{"error":' . $literal . ',"access_token":"AT","token_type":"Bearer","expires_in":300}';
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        self::assertSame('AT', $p->getToken());
        self::assertSame('AT', $p->getToken());
        self::assertSame(1, $http->calls, 'the token was cached');
    }
}
