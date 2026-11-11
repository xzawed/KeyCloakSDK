<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\ClientCredentialsTokenProvider;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakException;
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
    private const SECRET = 'echoedlowersecret';
    private const REFRESH = 'echoedlowerrefresh';
    private const CODE = 'echoedlowercode';
    private const VERIFIER = 'echoedlowerverifierechoedlowerverifierechoedlower';

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
            foreach (['whole', 'truncated', 'extended'] as $form) {
                $rows["$surface · $form"] = [$surface, $form];
            }
        }

        return $rows;
    }

    private static function shape(string $value, string $form): string
    {
        return match ($form) {
            'truncated' => substr($value, 0, 11),
            'extended' => $value . '_x',
            default => $value,
        };
    }

    #[DataProvider('secretEchoes')]
    public function testAnEchoedClientSecretIsNeverCarried(string $surface, string $form): void
    {
        self::state(['echo' => 'client_secret', 'form' => $form]);
        $e = self::fail2($surface);
        self::assertSame(self::SECRET, self::sentForms()[0]['client_secret'] ?? null, 'the secret went out');
        self::assertWithheld($e, self::shape(self::SECRET, $form));
    }

    /** @return array<string, array{string, string, string}> */
    public static function grantEchoes(): array
    {
        $rows = [];
        foreach (['refresh' => ['refresh_token'], 'exchange_code' => ['code', 'code_verifier']] as $surface => $params) {
            foreach ($params as $param) {
                foreach (['whole', 'truncated', 'extended'] as $form) {
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
}
