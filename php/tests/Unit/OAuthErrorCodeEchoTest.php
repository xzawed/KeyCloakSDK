<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use GuzzleHttp\Handler\MockHandler;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Psr7\HttpFactory;
use GuzzleHttp\Psr7\Response;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Http\Message\RequestInterface;
use Xzawed\Keycloak\AuthClient;
use Xzawed\Keycloak\ClientCredentialsTokenProvider;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakException;
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\JwtValidator;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\OidcEndpoints;

/**
 * The OAuth `error` code an SDK error carries is a code, never a value the request sent (registry
 * `token-error-code-secret-echo`).
 *
 * The IdP's `error` is response body too. An IdP (or a proxy) that echoes what the request sent puts the client secret,
 * the refresh token or the authorization code there. A lowercase-only secret has the code shape, so the shape check
 * alone let it into `oauthError` and the message of the grants, the provider and the admin grant (measured on main
 * `a7d0fdf3`). `OAuthErrorCode::of` now also withholds a value that overlaps a non-empty secret the request sent —
 * neither contains the other, so a truncated or extended echo goes too. The price is pinned below: a secret that is a
 * piece of a registered code (`client`) withholds that code (the status stays, nothing leaks).
 */
final class OAuthErrorCodeEchoTest extends TestCase
{
    // Code-shaped on purpose (the shape alone cannot withhold them), and no two share a piece — an echo of one value must be
    // withheld by comparing against THAT value, not a sibling's prefix.
    private const SECRET = 'zebrasecretjk';
    private const REFRESH = 'yakrefreshvq';
    private const CODE = 'vulturecodeby';
    private const VERIFIER = 'ocelotverifierocelotverifierocelotverifierxx';
    /** The token introspection asks about. */
    private const TOKEN = 'walrustokenpx';
    /** Every piece and every padding, so each direction of the overlap is pinned. */
    private const FORMS = ['whole', 'prefix', 'suffix', 'middle', 'extended', 'prefixed', 'wrapped'];

    private static string $dir = '';
    private static int $port = 0;
    /** @var resource|null */
    private static $proc = null;

    public static function setUpBeforeClass(): void
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
        self::assertNotFalse($sock, "no free port: $errstr");
        $name = (string) stream_socket_get_name($sock, false);
        fclose($sock);
        self::$port = (int) substr($name, (int) strrpos($name, ':') + 1);
        self::$dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'ei-idp-' . bin2hex(random_bytes(6));
        self::assertTrue(mkdir(self::$dir));
        self::state(['fixed' => 'invalid_request']);
        $env = getenv();
        $env['EI_STATE'] = self::$dir;
        $pipes = [];
        $proc = proc_open(
            [PHP_BINARY, '-S', '127.0.0.1:' . self::$port, __DIR__ . '/Fixtures/echo-idp-router.php'],
            [0 => ['pipe', 'r'], 1 => ['file', self::$dir . '/server.out', 'a'], 2 => ['file', self::$dir . '/server.err', 'a']],
            $pipes,
            self::$dir,
            $env,
        );
        self::assertIsResource($proc, 'the echo IdP did not start');
        self::$proc = $proc;
        // ⚠️ A fatal error or exit skips tearDownAfterClass — do not leave `php -S` orphaned on the port.
        register_shutdown_function(static function (): void {
            self::stopIdp();
        });
        for ($i = 0; $i < 500; $i++) {
            $c = @fsockopen('127.0.0.1', self::$port, $en, $es, 0.2);
            if ($c !== false) {
                fclose($c);

                return;
            }
            usleep(20_000);
        }
        self::fail('the echo IdP did not come up');
    }

    public static function tearDownAfterClass(): void
    {
        self::stopIdp();
    }

    private static function stopIdp(): void
    {
        if (self::$proc !== null) {
            proc_terminate(self::$proc);
            proc_close(self::$proc);
            self::$proc = null;
        }
        foreach (['state.json', 'requests.log', 'server.out', 'server.err'] as $f) {
            @unlink(self::$dir . '/' . $f);
        }
        @rmdir(self::$dir);
    }

    protected function setUp(): void
    {
        ini_set('zend.exception_ignore_args', '0');
        @unlink(self::$dir . '/requests.log');
    }

    /** @param array<string, mixed> $state */
    private static function state(array $state): void
    {
        file_put_contents(self::$dir . '/state.json', json_encode($state, JSON_THROW_ON_ERROR));
    }

    /** @return list<array<mixed, mixed>> the form fields each token POST sent */
    private static function sentForms(): array
    {
        $out = [];
        $lines = file(self::$dir . '/requests.log', FILE_IGNORE_NEW_LINES);
        foreach ($lines === false ? [] : $lines as $line) {
            $row = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
            self::assertIsArray($row);
            self::assertIsArray($row[1]);
            $out[] = $row[1];
        }

        return $out;
    }

    private static function fail2(string $surface, ?string $secret = self::SECRET): KeycloakException
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://127.0.0.1:' . self::$port, realm: 'r', clientId: 'c', clientSecret: $secret);
        $kc = KeycloakClient::create($cfg);
        $factory = new \GuzzleHttp\Psr7\HttpFactory();
        $call = match ($surface) {
            'client_credentials' => static fn (): mixed => $kc->auth()->clientCredentialsToken(),
            'refresh' => static fn (): mixed => $kc->auth()->refresh(self::REFRESH),
            'exchange_code' => static fn (): mixed => $kc->auth()->exchangeCode(self::CODE, self::VERIFIER, null, 'http://localhost/cb'),
            'provider' => static fn (): mixed => (new ClientCredentialsTokenProvider($cfg, new OidcEndpoints($cfg), new \GuzzleHttp\Client(), $factory, $factory))->getToken(),
            'admin' => static fn (): mixed => $kc->admin()->users()->get('u1'),
            default => throw new \LogicException($surface),
        };
        try {
            $call();
        } catch (KeycloakException $e) {
            return $e;
        }
        self::fail("$surface did not fail");
    }

    /** @return list<string> every rendering a log line could take of the error and its chain */
    private static function renderings(\Throwable $e): array
    {
        $out = [];
        for ($x = $e, $i = 0; $x !== null && $i < 10; $x = $x->getPrevious(), $i++) {
            ob_start();
            var_dump($x);
            $out[] = (string) ob_get_clean();
            $out[] = print_r($x, true);
            $out[] = (string) $x;
            $out[] = $x->getMessage();
        }

        return $out;
    }

    private static function assertWithheld(KeycloakException $e, string $value): void
    {
        self::assertInstanceOf(KeycloakAuthError::class, $e);
        self::assertNull($e->oauthError);
        self::assertNotRendered($e, $value);
    }

    /** ⚠️ Not `assertStringNotContainsString` — its failure exports the whole dump (MBs) and exhausts the memory limit. */
    private static function assertNotRendered(\Throwable $e, string $value): void
    {
        foreach (self::renderings($e) as $n => $text) {
            self::assertFalse(str_contains($text, $value), "rendering #$n of " . $e::class . ' shows the echoed value');
        }
    }

    /** @return array<string, array{string}> */
    public static function surfaces(): array
    {
        return array_combine(
            ['client_credentials', 'refresh', 'exchange_code', 'provider', 'admin'],
            [['client_credentials'], ['refresh'], ['exchange_code'], ['provider'], ['admin']],
        );
    }

    /** @return array<string, array{string, string}> */
    public static function secretEchoes(): array
    {
        $rows = [];
        foreach (array_keys(self::surfaces()) as $surface) {
            foreach (self::FORMS as $form) {
                $rows["$surface · $form"] = [$surface, $form];
            }
        }

        return $rows;
    }

    private static function shape(string $value, string $form): string
    {
        return match ($form) {
            'prefix' => substr($value, 0, 11),
            'suffix' => substr($value, -11),
            'middle' => substr($value, 2, 9),
            'extended' => $value . '_x',
            'prefixed' => 'x_' . $value,
            'wrapped' => 'x_' . $value . '_x',
            default => $value,
        };
    }

    /** @return array<string, array{string, string}> */
    public static function echoesOnA401(): array
    {
        $rows = [];
        foreach (['client_credentials' => [], 'refresh' => ['refresh_token'], 'exchange_code' => ['code', 'code_verifier'], 'provider' => [], 'admin' => []] as $surface => $params) {
            foreach (['client_secret', ...$params] as $param) {
                $rows["$surface · $param"] = [$surface, $param];
            }
        }

        return $rows;
    }

    /** Keycloak answers a bad client with 401, not 400 — an error status other than 400 takes the same rule. */
    #[DataProvider('echoesOnA401')]
    public function testAnEchoOnA401IsNeverCarried(string $surface, string $param): void
    {
        self::state(['echo' => $param, 'status' => 401]);
        $e = self::fail2($surface);
        $sent = self::sentForms()[0][$param] ?? null;
        self::assertIsString($sent);
        self::assertWithheld($e, $sent);
    }

    #[DataProvider('secretEchoes')]
    public function testAnEchoedClientSecretIsNeverCarried(string $surface, string $form): void
    {
        self::state(['echo' => 'client_secret', 'form' => $form]);
        $e = self::fail2($surface);
        self::assertSame(self::SECRET, self::sentForms()[0]['client_secret'] ?? null, 'the secret went out');
        self::assertWithheld($e, self::shape(self::SECRET, $form));
    }

    /** An IdP or proxy that echoes the secret lowercased — the overlap ignores ASCII case. */
    #[DataProvider('surfaces')]
    public function testALowercasedEchoOfTheClientSecretIsNeverCarried(string $surface): void
    {
        self::state(['echo' => 'client_secret', 'form' => 'lowercased']);
        $e = self::fail2($surface, 'EchoMixedCase');
        self::assertSame('EchoMixedCase', self::sentForms()[0]['client_secret'] ?? null, 'the secret went out');
        self::assertWithheld($e, 'echomixedcase');
    }

    /** @return array<string, array{string}> the lanes whose request sends the client secret by client credentials */
    public static function clientCredentialsSurfaces(): array
    {
        return ['client_credentials' => ['client_credentials'], 'provider' => ['provider'], 'admin' => ['admin']];
    }

    /**
     * The same rule at a success status — a 200 that answers an OAuth error fails like the error status does, and its `error`
     * is no code when it overlaps the secret the request sent (registry `auth-2xx-error-code-divergent`).
     */
    #[DataProvider('clientCredentialsSurfaces')]
    public function testSuccessStatusOAuthErrorALowercasedEchoOfTheClientSecretIsNeverCarried(string $surface): void
    {
        self::state(['echo' => 'client_secret', 'form' => 'lowercased', 'status' => 200, 'description' => 'd']);
        $e = self::fail2($surface, 'EchoedSecret');
        self::assertSame('EchoedSecret', self::sentForms()[0]['client_secret'] ?? null, 'the secret went out');
        self::assertWithheld($e, 'echoedsecret');
        foreach (['echoedsecret', 'EchoedSecret'] as $value) {
            self::assertFalse(str_contains($e->getMessage(), $value), "the message shows $value");
        }
    }

    /** @return array<string, array{string, string, string}> */
    public static function grantEchoes(): array
    {
        $rows = [];
        foreach (['refresh' => ['refresh_token'], 'exchange_code' => ['code', 'code_verifier']] as $surface => $params) {
            foreach ($params as $param) {
                foreach (self::FORMS as $form) {
                    $rows["$surface · $param · $form"] = [$surface, $param, $form];
                }
            }
        }

        return $rows;
    }

    #[DataProvider('grantEchoes')]
    public function testAnEchoedGrantValueIsNeverCarried(string $surface, string $param, string $form): void
    {
        self::state(['echo' => $param, 'form' => $form]);
        $e = self::fail2($surface);
        $sent = self::sentForms()[0][$param] ?? null;
        self::assertIsString($sent);
        self::assertWithheld($e, self::shape($sent, $form));
    }

    public function testAPublicClientWithholdsItsEchoedRefreshTokenAndStillGetsACode(): void
    {
        self::state(['echo' => 'refresh_token']);
        self::assertWithheld(self::fail2('refresh', null), self::REFRESH);
        // league sends `client_secret=` empty for a public client — an empty secret is not compared (it is a piece of every code)
        self::assertSame('', self::sentForms()[0]['client_secret'] ?? '');
        self::state(['fixed' => 'invalid_grant']);
        $e = self::fail2('refresh', null);
        self::assertInstanceOf(KeycloakAuthError::class, $e);
        self::assertSame('invalid_grant', $e->oauthError);
    }

    /** @return array<string, mixed> */
    private static function notACodeValues(): array
    {
        return [
            'keycloak-style secret' => 'Kx7mQ2vT9pLr4WzN8bYc3FhJ6sDa1gE5',
            'jwt' => 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl',
            'capital letter' => 'Invalid_client',
            'space' => 'invalid client',
            'digit' => 'invalid_client2',
            '65 characters' => str_repeat('a', 65),
            'number' => 400,
        ];
    }

    /**
     * ⚠️ Rows carry the value's name, not the value — the error's trace keeps the test method's arguments
     * (`zend.exception_ignore_args=0`), so a value passed in would show up in every dump of it.
     *
     * @return array<string, array{string, string}>
     */
    public static function notACode(): array
    {
        $rows = [];
        foreach (array_keys(self::surfaces()) as $surface) {
            foreach (array_keys(self::notACodeValues()) as $name) {
                $rows["$surface · $name"] = [$surface, $name];
            }
        }

        return $rows;
    }

    #[DataProvider('notACode')]
    public function testAValueThatIsNotACodeIsNeverCarried(string $surface, string $name): void
    {
        $value = self::notACodeValues()[$name];
        self::state(['fixed' => $value]);
        $e = self::fail2($surface);
        self::assertNull($e instanceof KeycloakAuthError ? $e->oauthError : null);
        if (\is_string($value)) {
            self::assertNotRendered($e, $value);
        }
    }

    /** @return array<string, array{string, string}> */
    public static function codes(): array
    {
        $rows = [];
        foreach (array_keys(self::surfaces()) as $surface) {
            foreach (['invalid_client', 'invalid_grant', 'slow_down', str_repeat('a', 64)] as $code) {
                $rows["$surface · " . substr($code, 0, 20)] = [$surface, $code];
            }
        }

        return $rows;
    }

    #[DataProvider('codes')]
    public function testACodeThatOverlapsNothingSentIsCarried(string $surface, string $code): void
    {
        self::state(['fixed' => $code]);
        $e = self::fail2($surface);
        self::assertInstanceOf(KeycloakAuthError::class, $e);
        self::assertSame($code, $e->oauthError);
    }

    public function testThePriceASecretThatIsAPieceOfTheCodeWithholdsIt(): void
    {
        self::state(['fixed' => 'invalid_client']);
        foreach (['client_credentials', 'provider', 'admin'] as $surface) {
            $e = self::fail2($surface, 'client');
            self::assertInstanceOf(KeycloakAuthError::class, $e, $surface);
            self::assertNull($e->oauthError, $surface);
        }
    }

    // --- introspection at an error status -----------------------------------------------------------------------------
    // Its error status carries the code in `oauthError` now (registry `oauth-error-code-surface-divergent` — before, never), so
    // the overlap is what keeps an echo of what it sent — the client secret (Basic) and the token asked about — out of it. The
    // mock answer echoes what THIS request sent (`introspect()` takes the client's Guzzle, so there is a handler to inject).

    /** @return array<string, array{int, string, string}> [status, the sent value echoed, its form] */
    public static function introspectionEchoes(): array
    {
        $rows = [];
        foreach ([400, 401] as $status) {
            foreach (['client_secret', 'token'] as $param) {
                foreach (self::FORMS as $form) {
                    $rows["$status · $param · $form"] = [$status, $param, $form];
                }
            }
        }

        return $rows;
    }

    #[DataProvider('introspectionEchoes')]
    public function testIntrospectionWithholdsAnEchoAtAnErrorStatus(int $status, string $param, string $form): void
    {
        $seen = [];
        $e = self::introspectionFailure(self::SECRET, $status, static fn (array $sent): string => self::shape($sent[$param] ?? '', $form), $seen);

        self::assertSame(['client_secret' => self::SECRET, 'token' => self::TOKEN], $seen, 'the request did not send both');
        self::assertWithheld($e, self::shape($param === 'token' ? self::TOKEN : self::SECRET, $form));
    }

    public function testIntrospectionWithholdsALowercasedEchoOfTheClientSecretAtAnErrorStatus(): void
    {
        $seen = [];
        $e = self::introspectionFailure('EchoMixedCase', 400, static fn (array $sent): string => strtolower($sent['client_secret'] ?? ''), $seen);

        self::assertSame('EchoMixedCase', $seen['client_secret'] ?? null, 'the secret went out');
        self::assertWithheld($e, 'echomixedcase');
    }

    /**
     * Introspects `TOKEN` against a mock answer at `$status` whose `error` is `$error(what the request sent)` — the client secret
     * from Basic (each part percent-encoded) and the form's `token`, recorded in `$seen`. ⚠️ `$secret` and `$seen` are
     * `#[\SensitiveParameter]` — the error's trace keeps this frame's arguments (`zend.exception_ignore_args=0`), so without it
     * every dump of the error shows the very value the rows assert is withheld.
     *
     * @param \Closure(array<string, string>): string $error
     * @param array<string, string> $seen
     */
    private static function introspectionFailure(#[\SensitiveParameter] string $secret, int $status, \Closure $error, #[\SensitiveParameter] array &$seen): KeycloakException
    {
        $mock = new MockHandler([static function (RequestInterface $request) use ($status, $error, &$seen): Response {
            parse_str((string) $request->getBody(), $fields);
            $pair = explode(':', (string) base64_decode(substr($request->getHeaderLine('Authorization'), 6), true), 2);
            $token = $fields['token'] ?? null;
            $seen = ['client_secret' => rawurldecode($pair[1] ?? ''), 'token' => \is_string($token) ? $token : ''];

            return new Response($status, ['Content-Type' => 'application/json'], json_encode(['error' => $error($seen)], JSON_THROW_ON_ERROR));
        }]);
        $cfg = new KeycloakConfig(serverUrl: 'http://kc.test', realm: 'r', clientId: 'c', clientSecret: $secret);
        $guzzle = new \GuzzleHttp\Client(['handler' => HandlerStack::create($mock)]);
        $endpoints = new OidcEndpoints($cfg);
        $auth = new AuthClient($cfg, $endpoints, new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $guzzle, new HttpFactory())), $guzzle);
        try {
            $auth->introspect(self::TOKEN);
        } catch (KeycloakException $e) {
            return $e;
        }
        self::fail('introspection did not fail');
    }

    // --- only 200 is a success ---------------------------------------------------------------------------------------------
    // A token or introspection response is a success only at HTTP 200 (RFC 6749 §5.1; for introspection the SDK's rule — RFC
    // 7662 §2.2 names no status, its examples and Keycloak answer 200), in all nine languages:
    // any other 2xx fails as a 400 with the same body does — the same type and message (its status in it), no token, nothing
    // cached, no admin request, no `active` (registry `token-success-status-range-divergent`). Before (main c4b5096a) the three
    // league grants, introspection and the admin grant took any 2xx as a success; the provider already took only 200.

    /** JWT-shaped, so the admin grant's parser reads it (`BearerToken::grantMiddleware`, then fschmtt). */
    private const GOOD_AT = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJlLXZhbHVl';
    private const GOOD_TOKEN = '{"access_token":"' . self::GOOD_AT . '","token_type":"Bearer","expires_in":300}';
    private const GOOD_INTROSPECT = '{"active":true,"username":"svc"}';
    private const NON_200_SUCCESS = [201, 202, 203, 204, 206, 299];

    /**
     * Every lane against the same body at 400 (pinned — what any other status is held to), at 200 (its success), at each other
     * 2xx, and at 201 carrying `error` (held to the 400 carrying it): the same type, message and code, the status in the message
     * where the 400's has one. A 204 carries no body, so it is held to the 400 without one. No admin request goes out but at
     * 200, and the same provider and facade then ask again at 200.
     */
    public function testNon200SuccessStatusFailsAsTheLanesErrorResponse(): void
    {
        // [the good body, no body, B1] at 400 — the type is KeycloakAuthError in each.
        $at400 = [
            'client_credentials' => ['token request rejected', 'token endpoint returned unexpected response', 'token request rejected: invalid_grant'],
            'provider' => ['client-credentials failed', 'client-credentials failed', 'client-credentials failed'],
            'refresh' => ['token request rejected', 'token endpoint returned unexpected response', 'token request rejected: invalid_grant'],
            'exchange_code' => ['token request rejected', 'token endpoint returned unexpected response', 'token request rejected: invalid_grant'],
            'introspect' => ['introspection failed', 'introspection failed', 'introspection failed'],
            'admin' => ['admin token request failed: HTTP 400', 'admin token request failed: HTTP 400', 'admin token request failed: HTTP 400 (invalid_grant)'],
        ];
        $wrong = [];
        $table = [];
        foreach ($at400 as $lane => [$good, $empty, $carrying]) {
            $code = $lane === 'introspect' ? 'invalid_token' : 'invalid_grant';
            $success = match ($lane) {
                'introspect' => 'success(true)',
                'admin' => 'success(alice)',
                default => 'success(' . self::GOOD_AT . ')',
            };
            $cells = [
                [400, 'good', "KeycloakAuthError($good) code=null"],
                [400, 'empty', "KeycloakAuthError($empty) code=null"],
                [200, 'good', $success],
            ];
            foreach (self::NON_200_SUCCESS as $status) {
                $cells[] = [$status, 'good', str_replace('HTTP 400', "HTTP $status", "KeycloakAuthError(" . ($status === 204 ? $empty : $good) . ') code=null')];
            }
            $cells[] = [400, 'B1', "KeycloakAuthError($carrying) code=$code"];
            $cells[] = [201, 'B1', str_replace('HTTP 400', 'HTTP 201', "KeycloakAuthError($carrying) code=$code")];
            foreach ($cells as [$status, $body, $expected]) {
                $label = "$status $body $lane";
                $call = self::laneCall($lane);
                self::answer($status, $body);
                $got = self::outcome($call);
                $table[] = "$label → $got";
                if ($got !== $expected) {
                    $wrong[] = "$label: $got ≠ $expected";
                }
                $admin = \count(array_filter(self::requestPaths(), static fn (string $p): bool => str_starts_with($p, '/admin/')));
                if ($admin !== ($status === 200 && $lane === 'admin' ? 2 : 0)) {
                    $wrong[] = "$label: $admin admin requests";
                }
                // Nothing was cached — the same provider and the same facade ask the IdP again, and use what a 200 gives.
                if ($status !== 200 && ($lane === 'provider' || $lane === 'admin')) {
                    self::answer(200, 'good');
                    $again = self::outcome($call);
                    $grants = \count(array_filter(self::requestPaths(), static fn (string $p): bool => str_ends_with($p, '/token')));
                    if ($again !== $success || $grants !== 1) {
                        $wrong[] = "$label: then 200 gave $again after $grants token requests";
                    }
                }
            }
        }
        self::assertSame([], $wrong, implode("\n", $table));
    }

    /** The IdP answers the token and introspection requests at `$status` — the good bodies, none, or B1's `error` alone. */
    private static function answer(int $status, string $body): void
    {
        self::state(['status' => $status, 'bodies' => match ($body) {
            'good' => ['token' => self::GOOD_TOKEN, 'introspect' => self::GOOD_INTROSPECT],
            'empty' => ['token' => '', 'introspect' => ''],
            default => ['token' => '{"error":"invalid_grant","error_description":"d"}', 'introspect' => '{"error":"invalid_token"}'],
        }]);
        @unlink(self::$dir . '/requests.log');
    }

    /**
     * A lane on a new client, as a call that can be made again on the same provider or facade. The code exchange sends no
     * nonce, so a token response without an id_token is its success.
     *
     * @return \Closure(): mixed
     */
    private static function laneCall(string $lane): \Closure
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://127.0.0.1:' . self::$port, realm: 'r', clientId: 'c', clientSecret: self::SECRET);
        $kc = KeycloakClient::create($cfg);
        $factory = new HttpFactory();
        $provider = new ClientCredentialsTokenProvider($cfg, new OidcEndpoints($cfg), new \GuzzleHttp\Client(), $factory, $factory);

        return match ($lane) {
            'client_credentials' => static fn (): mixed => $kc->auth()->clientCredentialsToken()->accessToken,
            'provider' => static fn (): mixed => $provider->getToken(),
            'refresh' => static fn (): mixed => $kc->auth()->refresh(self::REFRESH)->accessToken,
            'exchange_code' => static fn (): mixed => $kc->auth()->exchangeCode(self::CODE, self::VERIFIER, null, 'http://localhost/cb')->accessToken,
            'introspect' => static fn (): mixed => $kc->auth()->introspect(self::TOKEN)->active,
            'admin' => static fn (): mixed => $kc->admin()->users()->get('u1')->getUsername(),
            default => throw new \LogicException($lane),
        };
    }

    /**
     * What a call came to, as one line — its value, or the SDK error's class, message and `oauthError`.
     *
     * @param \Closure(): mixed $call
     */
    private static function outcome(\Closure $call): string
    {
        try {
            $value = $call();
        } catch (KeycloakException $e) {
            $code = $e instanceof KeycloakAuthError ? $e->oauthError ?? 'null' : '-';

            return (new \ReflectionClass($e))->getShortName() . '(' . $e->getMessage() . ") code=$code";
        }

        return 'success(' . (\is_bool($value) ? ($value ? 'true' : 'false') : (\is_string($value) ? $value : get_debug_type($value))) . ')';
    }

    /** @return list<string> the path of every request since the last {@see self::answer()} */
    private static function requestPaths(): array
    {
        $out = [];
        $lines = @file(self::$dir . '/requests.log', FILE_IGNORE_NEW_LINES);
        foreach ($lines === false ? [] : $lines as $line) {
            $row = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
            self::assertIsArray($row);
            self::assertIsString($row[0] ?? null);
            $out[] = $row[0];
        }

        return $out;
    }
}
