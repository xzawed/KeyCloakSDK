<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use GuzzleHttp\Client;
use GuzzleHttp\Handler\MockHandler;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Psr7\HttpFactory;
use GuzzleHttp\Psr7\Response;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\AuthClient;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\JwtValidator;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\OidcEndpoints;

final class AuthMappingTest extends TestCase
{
    /** The access token B2 carries beside its `error` — JWT-shaped, so a lane that skipped the `error` would hand it back. */
    private const B2_ACCESS = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl';

    public function testIntrospectMapsActive(): void
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 's');
        $mock = new MockHandler([new Response(200, [], '{"active":true,"username":"alice","client_id":"c"}')]);
        $guzzle = new Client(['handler' => HandlerStack::create($mock)]);
        $endpoints = new OidcEndpoints($cfg);
        // JwtValidator는 introspect에 미사용 — 최소 구성
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $guzzle, new HttpFactory()));
        $auth = new AuthClient($cfg, $endpoints, $validator, $guzzle);
        $ir = $auth->introspect('some-token');
        self::assertTrue($ir->active);
        self::assertSame('alice', $ir->username);
    }

    public function testCreateAuthorizationRequestUsesPkceS256(): void
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'it-realm', clientId: 'it-client', clientSecret: 's', redirectUri: 'http://app/cb');
        $endpoints = new OidcEndpoints($cfg);
        $guzzle = new Client();  // not used — createAuthorizationRequest makes no HTTP call
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $guzzle, new HttpFactory()));
        $auth = new AuthClient($cfg, $endpoints, $validator, $guzzle);
        $req = $auth->createAuthorizationRequest();
        self::assertStringContainsString('code_challenge_method=S256', $req->url);
        self::assertStringContainsString('code_challenge=', $req->url);
        self::assertNotSame('', $req->codeVerifier);   // the PKCE verifier is captured
        self::assertNotSame('', $req->state);
    }

    /**
     * A token response at a success status that still carries an OAuth `error` fails as the error status does — the three
     * league grants share `checkResponse`, so the same type, message and code as a 400 carrying it (`token request rejected:
     * <code>`), and the token beside it is never returned (registry `auth-2xx-error-code-divergent`). B1 is the error alone,
     * B2 the error beside a usable token, `zero` the error `"0"` beside one — a non-empty string, though upstream's `empty()`
     * calls it no error.
     *
     * @return array<string, array{string, string}> [lane, body name]
     */
    public static function successStatusOAuthErrorTokenRows(): array
    {
        $rows = [];
        foreach (['clientCredentialsToken', 'refresh', 'exchangeCode'] as $lane) {
            foreach (['B1', 'B2', 'zero'] as $body) {
                $rows["$lane · $body"] = [$lane, $body];
            }
        }

        return $rows;
    }

    #[DataProvider('successStatusOAuthErrorTokenRows')]
    public function testSuccessStatusOAuthErrorFailsTheTokenLanes(string $lane, string $body): void
    {
        $mock = new MockHandler([new Response(200, ['Content-Type' => 'application/json'], self::tokenBody($body))]);
        $auth = self::client($mock);
        $e = self::thrown(static fn (): mixed => match ($lane) {
            'clientCredentialsToken' => $auth->clientCredentialsToken(),
            'refresh' => $auth->refresh('am-refresh-token'),
            default => $auth->exchangeCode('am-code', str_repeat('v', 64)),
        });

        self::assertSame(0, $mock->count(), 'the token request went out');
        self::assertInstanceOf(KeycloakAuthError::class, $e, "$lane $body: " . self::describe($e));   // final — the exact class
        $code = $body === 'zero' ? null : 'invalid_grant';
        self::assertSame('token request rejected' . ($code === null ? '' : ": $code"), $e->getMessage());
        self::assertSame($code, $e->oauthError);
    }

    /**
     * An introspection response at a success status that still carries an OAuth `error` fails with the message of the error
     * status (`introspection failed`) — B2's `"active": true` is never reported — and carries the vetted code.
     *
     * @return array<string, array{string}>
     */
    public static function successStatusOAuthErrorIntrospectionRows(): array
    {
        return ['B1' => ['B1'], 'B2' => ['B2'], 'zero' => ['zero']];
    }

    #[DataProvider('successStatusOAuthErrorIntrospectionRows')]
    public function testSuccessStatusOAuthErrorFailsIntrospection(string $body): void
    {
        $mock = new MockHandler([new Response(200, ['Content-Type' => 'application/json'], self::introspectionBody($body))]);
        $auth = self::client($mock);
        $e = self::thrown(static fn (): mixed => $auth->introspect('am-introspected-token'));

        self::assertSame(0, $mock->count(), 'the introspection request went out');
        self::assertInstanceOf(KeycloakAuthError::class, $e, "$body: " . self::describe($e));
        self::assertSame('introspection failed', $e->getMessage());
        self::assertSame($body === 'zero' ? null : 'invalid_token', $e->oauthError);
    }

    /**
     * An introspection answer at an error status carries its OAuth `error` in `oauthError` too, as every other lane does at
     * any status (registry `oauth-error-code-surface-divergent`) — A is 400 `invalid_grant`, B is 401 `invalid_client`, the
     * two cells the nine languages were measured with. The message stays `introspection failed`. Before: `oauthError` was
     * null for both, while the same `error` at 200 (above) was carried.
     *
     * @return array<string, array{int, string}>
     */
    public static function errorStatusOAuthErrorIntrospectionRows(): array
    {
        return ['A' => [400, 'invalid_grant'], 'B' => [401, 'invalid_client']];
    }

    #[DataProvider('errorStatusOAuthErrorIntrospectionRows')]
    public function testErrorStatusOAuthErrorIsCarriedByIntrospection(int $status, string $code): void
    {
        $mock = new MockHandler([new Response($status, ['Content-Type' => 'application/json'], '{"error":"' . $code . '"}')]);
        $auth = self::client($mock);
        $e = self::thrown(static fn (): mixed => $auth->introspect('am-introspected-token'));

        self::assertSame(0, $mock->count(), 'the introspection request went out');
        self::assertInstanceOf(KeycloakAuthError::class, $e, "$status: " . self::describe($e));
        self::assertSame('introspection failed', $e->getMessage());
        self::assertSame($code, $e->oauthError);
    }

    /**
     * Only a non-empty string `error` counts — an empty string, null, a number or false beside a usable answer is ignored as
     * before (the control for the rows above). One league grant stands for the three: they share `checkResponse`.
     *
     * @return array<string, array{string, string}> [lane, JSON literal of `error`]
     */
    public static function successStatusOAuthErrorIgnoredRows(): array
    {
        $rows = [];
        foreach (['clientCredentialsToken', 'introspect'] as $lane) {
            foreach (['empty string' => '""', 'null' => 'null', 'number' => '0', 'false' => 'false'] as $name => $literal) {
                $rows["$lane · $name"] = [$lane, $literal];
            }
        }

        return $rows;
    }

    #[DataProvider('successStatusOAuthErrorIgnoredRows')]
    public function testSuccessStatusOAuthErrorIgnoresAnErrorThatIsNotANonEmptyString(string $lane, string $literal): void
    {
        $body = $lane === 'introspect'
            ? '{"error":' . $literal . ',"active":true}'
            : '{"error":' . $literal . ',"access_token":"' . self::B2_ACCESS . '","token_type":"Bearer","expires_in":300}';
        $auth = self::client(new MockHandler([new Response(200, ['Content-Type' => 'application/json'], $body)]));

        if ($lane === 'introspect') {
            self::assertTrue($auth->introspect('am-introspected-token')->active);

            return;
        }
        self::assertSame(self::B2_ACCESS, $auth->clientCredentialsToken()->accessToken);
    }

    /**
     * The rule reads a JSON object — a form-encoded token response (league parses it into the same kind of array) keeps
     * upstream's reading: `error=0` beside a token is no error there, as before. Every other non-empty `error` already failed.
     */
    public function testSuccessStatusOAuthErrorLeavesAFormEncodedTokenResponseAsItWas(): void
    {
        $body = 'error=0&access_token=' . self::B2_ACCESS . '&token_type=Bearer&expires_in=300';
        $auth = self::client(new MockHandler([new Response(200, ['Content-Type' => 'application/x-www-form-urlencoded'], $body)]));

        self::assertSame(self::B2_ACCESS, $auth->clientCredentialsToken()->accessToken);
    }

    private static function tokenBody(string $name): string
    {
        return match ($name) {
            'B1' => '{"error":"invalid_grant","error_description":"d"}',
            'B2' => '{"error":"invalid_grant","access_token":"' . self::B2_ACCESS . '","token_type":"Bearer","expires_in":300}',
            default => '{"error":"0","access_token":"' . self::B2_ACCESS . '","token_type":"Bearer","expires_in":300}',
        };
    }

    private static function introspectionBody(string $name): string
    {
        return match ($name) {
            'B1' => '{"error":"invalid_token"}',
            'B2' => '{"error":"invalid_token","active":true}',
            default => '{"error":"0","active":true}',
        };
    }

    /** No piece of a code can be a piece of this secret (`-`), so an overlap never withholds the code here. */
    private static function client(MockHandler $mock): AuthClient
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 'am-client-secret');
        $guzzle = new Client(['handler' => HandlerStack::create($mock)]);
        $endpoints = new OidcEndpoints($cfg);
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $guzzle, new HttpFactory()));

        return new AuthClient($cfg, $endpoints, $validator, $guzzle);
    }

    private static function thrown(\Closure $call): ?\Throwable
    {
        try {
            $call();
        } catch (\Throwable $e) {
            return $e;
        }

        return null;
    }

    private static function describe(?\Throwable $e): string
    {
        return $e === null ? 'no exception' : $e::class . ': ' . $e->getMessage();
    }
}
