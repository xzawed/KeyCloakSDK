<?php

declare(strict_types=1);

// measurement only — not for merge (task n3 · registry consumer-http-client-redirect-unmeasured).
//
// The three public ctors that take a consumer client — AuthClient(config, endpoints, validator, GuzzleClientInterface),
// ClientCredentialsTokenProvider(config, endpoints, PSR-18 ClientInterface, …) and JwksStore(jwksUri, PSR-18 ClientInterface,
// …) — are given `new GuzzleHttp\Client()` (what a consumer gets with no options). The public admin resource ctor
// Admin\UsersResource(Fschmtt\Keycloak\Keycloak, realm) is given an fschmtt client the consumer builds with fschmtt's Builder and
// the same default Guzzle client (create · update rows; Authorization there is fschmtt's bearer). Origin A (`php -S`) answers the SDK's
// request with 302 · 303 · 307 · 308 whose Location points at `/moved<same path>` on A itself (same origin) or on a second
// `php -S` B (another port = cross origin). The target answers every request with a usable success body, so `result` shows
// what the SDK does with an answer that came from the redirect target. The JWKS row signs the token with a key only the
// target serves (kid kB): `result=Ok` means the SDK validated against it. Controls: the same cells through
// KeycloakClient::create (the SDK's own client — allow_redirects false).
//
// Run: N3_OUT=<file> OPENSSL_CONF=<php>/extras/ssl/openssl.cnf vendor/bin/phpunit tests/Unit/zz_n3_redirect_measureTest.php

namespace Xzawed\Keycloak\Tests\Unit;

use Composer\InstalledVersions;
use Firebase\JWT\JWT;
use Fschmtt\Keycloak\Builder;
use Fschmtt\Keycloak\OAuth\GrantType;
use Fschmtt\Keycloak\Representation\User;
use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Psr7\HttpFactory;
use GuzzleHttp\RedirectMiddleware;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Admin\UsersResource;
use Xzawed\Keycloak\AuthClient;
use Xzawed\Keycloak\ClientCredentialsTokenProvider;
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\JwtValidator;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\OidcEndpoints;

final class zz_n3_redirect_measureTest extends TestCase
{
    private const REALM = 'it-realm';
    private const CLIENT_ID = 'it-client';
    private const SECRET = 'dummy-secret-MARK';
    private const REFRESH = 'dummy-refresh-MARK';
    private const CODE = 'dummy-code-MARK';
    private const VERIFIER = 'dummy-verifier-MARK';
    private const INTROSPECTED = 'dummy-introspected-MARK';
    private const OIDC = '/realms/' . self::REALM . '/protocol/openid-connect';
    private const STATUSES = [302, 303, 307, 308];

    /** op => [ctor, name, origin path, control name] */
    private const OPS = [
        'auth_cc' => ['AuthClient(GuzzleClientInterface)', 'clientCredentialsToken(POST form)', self::OIDC . '/token', 'auth()->clientCredentialsToken(POST form)'],
        'auth_code' => ['AuthClient(GuzzleClientInterface)', 'exchangeCode(POST form)', self::OIDC . '/token', 'auth()->exchangeCode(POST form)'],
        'auth_refresh' => ['AuthClient(GuzzleClientInterface)', 'refresh(POST form)', self::OIDC . '/token', 'auth()->refresh(POST form)'],
        'auth_introspect' => ['AuthClient(GuzzleClientInterface)', 'introspect(POST form)', self::OIDC . '/token/introspect', 'auth()->introspect(POST form)'],
        'auth_logout' => ['AuthClient(GuzzleClientInterface)', 'logout(POST form)', self::OIDC . '/logout', 'auth()->logout(POST form)'],
        'provider_cc' => ['ClientCredentialsTokenProvider(PSR-18 ClientInterface)', 'getToken(POST form)', self::OIDC . '/token', 'admin()->realms()->get->fschmtt grant(POST form)'],
        'jwks' => ['JwksStore(PSR-18 ClientInterface)', 'validate->JWKS fetch(GET)', self::OIDC . '/certs', 'auth()->validate->JWKS fetch(GET)'],
        // The public admin resource ctor takes an fschmtt client — built here by the consumer with a default Guzzle client.
        'admin_create' => ['Admin\UsersResource(fschmtt Keycloak via Builder::withHttpClient)', 'create(POST json)', self::USERS, 'admin()->users()->create(POST json)'],
        'admin_update' => ['Admin\UsersResource(fschmtt Keycloak via Builder::withHttpClient)', 'update(PUT json)', self::USERS . '/u1', 'admin()->users()->update(PUT json)'],
    ];
    private const ADMIN_OPS = ['admin_create', 'admin_update'];
    private const USERS = '/admin/realms/' . self::REALM . '/users';
    /** The representation's username — a marker for the admin body, not a secret. */
    private const ADMIN_MARK = 'admin-body-mark';
    /** base64url('{"alg":"RS256","typ":"JWT"}') — the header of the dummy JWT the router grants for admin cells. */
    private const ADMIN_JWT_HEAD = 'eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.';

    private static string $dir = '';
    /** @var array<string, int> */
    private static array $ports = [];
    /** @var list<resource> */
    private static array $procs = [];
    private static string $privatePem = '';
    private static string $jwks = '';

    public static function setUpBeforeClass(): void
    {
        $key = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($key, 'openssl_pkey_new failed (OPENSSL_CONF?)');
        openssl_pkey_export($key, $pem);
        self::$privatePem = (string) $pem;
        $rsa = openssl_pkey_get_details($key)['rsa'];
        $b64u = static fn (string $b): string => rtrim(strtr(base64_encode($b), '+/', '-_'), '=');
        self::$jwks = json_encode(['keys' => [[
            'kty' => 'RSA', 'kid' => 'kB', 'use' => 'sig', 'alg' => 'RS256', 'n' => $b64u($rsa['n']), 'e' => $b64u($rsa['e']),
        ]]], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
        self::$dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'zz-n3-' . bin2hex(random_bytes(6));
        self::assertTrue(mkdir(self::$dir));
        // Both sockets stay open until both ports are read — two distinct free ports (a collision would turn every cross-origin
        // cell into a same-origin one, silently).
        $socks = [];
        foreach (['A', 'B'] as $origin) {
            $sock = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
            self::assertNotFalse($sock, "no free port: $errstr");
            $socks[] = $sock;
            $name = (string) stream_socket_get_name($sock, false);
            self::$ports[$origin] = (int) substr($name, (int) strrpos($name, ':') + 1);
        }
        foreach ($socks as $sock) {
            fclose($sock);
        }
        self::assertNotSame(self::$ports['A'], self::$ports['B'], 'origins A and B must listen on different ports');
        self::state(null, false);
        foreach (['A', 'B'] as $origin) {
            $env = getenv();
            $env['N3_ORIGIN'] = $origin;
            $env['N3_DIR'] = self::$dir;
            $pipes = [];
            $proc = proc_open(
                [PHP_BINARY, '-S', '127.0.0.1:' . self::$ports[$origin], __DIR__ . '/Fixtures/zz_n3_router.php'],
                [0 => ['pipe', 'r'], 1 => ['file', self::$dir . "/server-$origin.out", 'a'], 2 => ['file', self::$dir . "/server-$origin.err", 'a']],
                $pipes,
                self::$dir,
                $env,
            );
            self::assertIsResource($proc);
            self::$procs[] = $proc;
        }
        register_shutdown_function(static function (): void {
            self::stop();
        });
        foreach (self::$ports as $port) {
            $up = false;
            for ($i = 0; $i < 500 && !$up; $i++) {
                $c = @fsockopen('127.0.0.1', $port, $en, $es, 0.2);
                if ($c !== false) {
                    fclose($c);
                    $up = true;
                } else {
                    usleep(20_000);
                }
            }
            self::assertTrue($up, "php -S on $port did not come up");
        }
        // A `php -S` that could not bind exits — whatever answered the probe above would then be another process.
        foreach (self::$procs as $i => $proc) {
            self::assertTrue(proc_get_status($proc)['running'], "php -S #$i is not running after startup");
        }
    }

    public static function tearDownAfterClass(): void
    {
        self::stop();
    }

    private static function stop(): void
    {
        foreach (self::$procs as $proc) {
            proc_terminate($proc);
            proc_close($proc);
        }
        self::$procs = [];
    }

    private static function url(string $origin): string
    {
        return 'http://127.0.0.1:' . self::$ports[$origin];
    }

    /** @param array<string, mixed>|null $cell */
    private static function state(?array $cell, bool $bounce): void
    {
        file_put_contents(self::$dir . '/state.json', json_encode([
            'cell' => $cell, 'bounce' => $bounce, 'jwks' => self::$jwks, 'a' => self::$ports === [] ? '' : self::url('A'), 'b' => self::$ports === [] ? '' : self::url('B'),
        ], JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES));
        @unlink(self::$dir . '/bounce.count');
    }

    private static function resetLog(): void
    {
        file_put_contents(self::$dir . '/requests.log', '');
    }

    /** @return list<array<string, mixed>> */
    private static function requests(string $origin, callable $keep): array
    {
        $rows = [];
        foreach (file(self::$dir . '/requests.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $line) {
            $row = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
            if ($row['origin'] === $origin && $keep($row['path'])) {
                $rows[] = $row;
            }
        }

        return $rows;
    }

    private static function clean(string $s): string
    {
        return str_replace(['|', "\r", "\n"], ['/', ' ', ' '], $s);
    }

    /** @param array<string, mixed> $r */
    private static function authOf(array $r): string
    {
        $v = $r['authorization'];
        if (!is_string($v)) {
            return 'none';
        }
        if (str_starts_with($v, 'Basic ')) {
            $decoded = (string) base64_decode(substr($v, 6));

            return $decoded === self::CLIENT_ID . ':' . self::SECRET ? 'Basic(client_id:client_secret)' : "Basic($decoded)";
        }
        if (str_starts_with($v, 'Bearer ' . self::ADMIN_JWT_HEAD)) {
            return 'Bearer(admin-jwt)';
        }

        return "other($v)";
    }

    /** @param array<string, mixed> $r */
    private static function bodySecretOf(array $r): string
    {
        $b = (string) $r['body'];
        if ($b === '') {
            return 'no-body';
        }
        $marks = [];
        foreach (['client_secret' => 'client_secret=' . self::SECRET, 'refresh_token' => 'refresh_token=' . self::REFRESH, 'code' => 'code=' . self::CODE, 'code_verifier' => 'code_verifier=' . self::VERIFIER, 'introspected_token' => 'token=' . self::INTROSPECTED] as $mark => $needle) {
            if (str_contains($b, $needle)) {
                $marks[] = $mark;
            }
        }
        if (str_contains($b, self::ADMIN_MARK)) {
            $marks[] = 'admin_body';   // the user representation — not a secret
        }

        return $marks === [] ? 'none' : implode('+', $marks);
    }

    /** @param array<string, mixed> $r */
    private static function bodyOf(array $r): string
    {
        $b = (string) $r['body'];
        if ($b === '') {
            return '0B';
        }
        if (str_starts_with($b, '{')) {
            return strlen($b) . 'B[json]';
        }

        return strlen($b) . 'B[' . implode(',', array_map(static fn (string $kv): string => explode('=', $kv)[0], explode('&', $b))) . ']';
    }

    /** @param array<string, mixed> $r */
    private static function hopOf(array $r): string
    {
        return $r['method'] . ' auth=' . self::authOf($r) . ' body_secret=' . self::bodySecretOf($r);
    }

    /** @param list<array<string, mixed>> $rows */
    private static function each(array $rows, callable $f): string
    {
        return $rows === [] ? '-' : implode(',', array_map($f, $rows));
    }

    private static function label(string $s): string
    {
        return str_replace([self::url('A'), self::url('B')], ['{A}', '{B}'], $s);
    }

    private static function err(\Throwable $e): string
    {
        $extra = $e instanceof \Xzawed\Keycloak\Exception\KeycloakAuthError ? ' oauthError=' . var_export($e->oauthError, true) : '';
        $short = substr((string) strrchr('\\' . $e::class, '\\'), 1);

        return self::clean("Err($short: {$e->getMessage()}$extra)");
    }

    private static function targetToken(): string
    {
        return JWT::encode([
            'iss' => self::url('A') . '/realms/' . self::REALM, 'sub' => 'signed-by-target-key', 'aud' => self::CLIENT_ID,
            'typ' => 'Bearer', 'exp' => time() + 300,
        ], self::$privatePem, 'RS256', 'kB');
    }

    private static function config(): KeycloakConfig
    {
        return new KeycloakConfig(self::url('A'), self::REALM, self::CLIENT_ID, self::SECRET, redirectUri: 'https://app.example/cb');
    }

    private static function call(string $op, AuthClient $auth, callable $provider, callable $validate): string
    {
        try {
            return match ($op) {
                'auth_cc' => 'Ok(access_token=' . $auth->clientCredentialsToken()->accessToken . ')',
                'auth_code' => 'Ok(access_token=' . $auth->exchangeCode(self::CODE, self::VERIFIER)->accessToken . ')',
                'auth_refresh' => 'Ok(access_token=' . $auth->refresh(self::REFRESH)->accessToken . ')',
                'auth_introspect' => (static function () use ($auth): string {
                    $r = $auth->introspect(self::INTROSPECTED);

                    return 'Ok(active=' . var_export($r->active, true) . ' username=' . $r->username . ')';
                })(),
                'auth_logout' => (static function () use ($auth): string {
                    $auth->logout(self::REFRESH);

                    return 'Ok(null)';
                })(),
                'provider_cc' => 'Ok(' . $provider() . ')',
                default => 'Ok(validated sub=' . $validate(self::targetToken())->subject . ')',
            };
        } catch (\Throwable $e) {
            return self::err($e);
        }
    }

    private static function adminCall(string $op, UsersResource $users): string
    {
        try {
            if ($op === 'admin_create') {
                $returned = $users->create(new User(username: self::ADMIN_MARK));

                return 'Ok(' . var_export($returned, true) . ' — create returns void)';
            }
            $users->update('u1', new User(username: self::ADMIN_MARK));

            return 'Ok(null)';
        } catch (\Throwable $e) {
            return self::err($e);
        }
    }

    private static function lowLevel(string $op): string
    {
        if (\in_array($op, self::ADMIN_OPS, true)) {
            // What a consumer builds to hand UsersResource an fschmtt client: fschmtt's Builder, with a default Guzzle client
            // (the Builder's own default is the same `new GuzzleClient()` — API line).
            $kc = (new Builder())
                ->withBaseUrl(self::url('A'))
                ->withGrantType(GrantType::clientCredentials(clientId: self::CLIENT_ID, clientSecret: self::SECRET, realm: self::REALM))
                ->withHttpClient(new GuzzleClient())
                ->build();

            return self::adminCall($op, new UsersResource($kc, self::REALM));
        }
        $config = self::config();
        $endpoints = new OidcEndpoints($config);
        $http = new GuzzleClient();   // the default a consumer gets with no options
        $factory = new HttpFactory();
        $validator = new JwtValidator($config, $endpoints, new JwksStore($endpoints->jwks(), $http, $factory));
        $auth = new AuthClient($config, $endpoints, $validator, $http);
        $provider = new ClientCredentialsTokenProvider($config, $endpoints, $http, $factory, $factory);

        return self::call($op, $auth, static fn (): string => 'access_token=' . $provider->getToken(), static fn (string $t) => $validator->validate($t));
    }

    private static function control(string $op): string
    {
        $kc = KeycloakClient::create(self::config());
        if (\in_array($op, self::ADMIN_OPS, true)) {
            try {
                $users = $kc->admin()->users();
            } catch (\Throwable $e) {
                return self::err($e);
            }

            return self::adminCall($op, $users);
        }

        return self::call(
            $op,
            $kc->auth(),
            static fn (): string => 'realm=' . ($kc->admin()->realms()->get(self::REALM)->getRealm() ?? 'null'),
            static fn (string $t) => $kc->auth()->validate($t),
        );
    }

    public function testMeasure(): void
    {
        $out = [];
        $out[] = 'ENV|php=' . PHP_VERSION . '|guzzlehttp/guzzle=' . InstalledVersions::getPrettyVersion('guzzlehttp/guzzle')
            . '|guzzlehttp/psr7=' . InstalledVersions::getPrettyVersion('guzzlehttp/psr7')
            . '|league/oauth2-client=' . InstalledVersions::getPrettyVersion('league/oauth2-client')
            . '|stevenmaguire/oauth2-keycloak=' . InstalledVersions::getPrettyVersion('stevenmaguire/oauth2-keycloak')
            . '|fschmtt/keycloak-rest-api-client-php=' . InstalledVersions::getPrettyVersion('fschmtt/keycloak-rest-api-client-php')
            . '|curl=' . (curl_version()['version'] ?? '?');
        $out[] = 'API|(new GuzzleHttp\Client())->getConfig(\'allow_redirects\')=' . json_encode((new GuzzleClient())->getConfig('allow_redirects'), JSON_UNESCAPED_SLASHES);
        $out[] = 'API|GuzzleHttp\RedirectMiddleware::$defaultSettings=' . json_encode(RedirectMiddleware::$defaultSettings, JSON_UNESCAPED_SLASHES);
        $builderDefault = (new \ReflectionProperty(Builder::class, 'httpClient'))->getValue(new Builder());
        $out[] = 'API|fschmtt (new Builder()) default httpClient=' . $builderDefault::class . '|allow_redirects='
            . json_encode($builderDefault instanceof GuzzleClient ? $builderDefault->getConfig('allow_redirects') : null, JSON_UNESCAPED_SLASHES);
        $out[] = 'HEADER|ctor|op|status|target|followed|method@target|body_secret@target|auth@target|result|body@target|content-type@target|referer@target|paths@target|origin_hop|hits';
        $totals = [];
        foreach (['new GuzzleHttp\Client()', 'KeycloakClient::create(control)'] as $variant) {
            $totals[$variant] = [0, 0];
            foreach (self::OPS as $op => [$ctor, $name, $opath, $controlName]) {
                foreach (self::STATUSES as $status) {
                    foreach ([false, true] as $cross) {
                        $target = $cross ? 'B' : 'A';
                        self::state(['origin_path' => $opath, 'status' => $status, 'location' => self::url($target) . '/moved' . $opath, 'target' => $target, 'admin' => \in_array($op, self::ADMIN_OPS, true)], false);
                        self::resetLog();
                        $result = $variant === 'new GuzzleHttp\Client()' ? self::lowLevel($op) : self::control($op);
                        $first = self::requests('A', static fn (string $p): bool => $p === $opath);
                        $moved = self::requests($target, static fn (string $p): bool => str_starts_with($p, '/moved/'));
                        self::state(null, false);
                        $totals[$variant][1]++;
                        $totals[$variant][0] += $moved === [] ? 0 : 1;
                        $out[] = implode('|', [
                            'CELL',
                            $variant === 'new GuzzleHttp\Client()' ? "$ctor<-$variant" : $variant,
                            $variant === 'new GuzzleHttp\Client()' ? $name : $controlName,
                            (string) $status,
                            $cross ? 'cross-origin' : 'same-origin',
                            'followed=' . ($moved === [] ? 'no' : 'yes'),
                            'method=' . self::each($moved, static fn (array $r): string => (string) $r['method']),
                            'body_secret=' . self::each($moved, self::bodySecretOf(...)),
                            'auth=' . self::each($moved, self::authOf(...)),
                            'result=' . $result,
                            'body=' . self::each($moved, self::bodyOf(...)),
                            'ctype=' . self::each($moved, static fn (array $r): string => (string) ($r['content_type'] ?? 'none')),
                            'referer=' . self::each($moved, static fn (array $r): string => self::label((string) ($r['referer'] ?? 'none'))),
                            'paths=' . self::each($moved, static fn (array $r): string => (string) $r['path']),
                            'origin_hop=' . self::each($first, self::hopOf(...)),
                            'hits=origin:' . count($first) . '/target:' . count($moved),
                        ]);
                    }
                }
            }
        }
        $out[] = 'SUMMARY|' . implode('|', array_map(static fn (string $k, array $v): string => "$k followed {$v[0]}/{$v[1]} cells", array_keys($totals), $totals));

        // After the fact — does anything on the returned response show the redirect? Default request() · and with
        // track_redirects (a per-request Guzzle option) · and through PSR-18 sendRequest().
        $basic = 'Basic ' . base64_encode(self::CLIENT_ID . ':' . self::SECRET);
        foreach (self::STATUSES as $status) {
            self::state(['origin_path' => '/start', 'status' => $status, 'location' => self::url('B') . '/moved/start', 'target' => 'B'], false);
            foreach (['request()' => [], 'request(track_redirects)' => ['allow_redirects' => ['track_redirects' => true]]] as $how => $extra) {
                self::resetLog();
                $resp = (new GuzzleClient())->request('POST', self::url('A') . '/start', ['form_params' => ['client_secret' => self::SECRET], 'headers' => ['Authorization' => $basic], 'http_errors' => false] + $extra);
                $bGot = self::requests('B', static fn (string $p): bool => $p === '/moved/start');
                $out[] = "DETECT|new GuzzleHttp\\Client()->$how|single hop $status A->B|status=" . $resp->getStatusCode()
                    . '|X-Guzzle-Redirect-History=' . self::label(implode(',', $resp->getHeader('X-Guzzle-Redirect-History')) ?: 'absent')
                    . '|B_got=' . self::each($bGot, self::hopOf(...));
            }
            self::resetLog();
            $factory = new HttpFactory();
            $req = $factory->createRequest('POST', self::url('A') . '/start')
                ->withHeader('Content-Type', 'application/x-www-form-urlencoded')->withHeader('Authorization', $basic)
                ->withBody($factory->createStream('client_secret=' . self::SECRET));
            $resp = (new GuzzleClient())->sendRequest($req);
            $bGot = self::requests('B', static fn (string $p): bool => $p === '/moved/start');
            $out[] = "DETECT|new GuzzleHttp\\Client()->sendRequest()|single hop $status A->B|status=" . $resp->getStatusCode()
                . '|Location=' . self::label($resp->getHeaderLine('Location')) . '|B_got=' . self::each($bGot, self::hopOf(...));
        }
        foreach (['request()' => [], 'request(track_redirects)' => ['allow_redirects' => ['track_redirects' => true]]] as $how => $extra) {
            self::state(null, true);
            self::resetLog();
            $resp = (new GuzzleClient())->request('POST', self::url('A') . '/token', ['form_params' => ['client_secret' => self::SECRET], 'headers' => ['Authorization' => $basic], 'http_errors' => false] + $extra);
            $hop = self::requests('B', static fn (string $p): bool => $p === '/hop');
            $aHits = self::requests('A', static fn (string $p): bool => $p === '/token');
            $out[] = "DETECT|new GuzzleHttp\\Client()->$how|bounce A-307->B-307->A|status=" . $resp->getStatusCode()
                . '|X-Guzzle-Redirect-History=' . self::label(implode(',', $resp->getHeader('X-Guzzle-Redirect-History')) ?: 'absent')
                . '|B_got=' . self::each($hop, self::hopOf(...)) . '|A_hits=' . count($aHits) . '|A_hops=' . self::each($aHits, self::hopOf(...));
        }
        self::state(null, false);

        $path = getenv('N3_OUT');
        self::assertIsString($path, 'set N3_OUT to the output file');
        file_put_contents($path, implode("\n", $out) . "\n");
        self::assertSame(2 * 9 * 4 * 2, count(array_filter($out, static fn (string $l): bool => str_starts_with($l, 'CELL|'))));
    }
}
