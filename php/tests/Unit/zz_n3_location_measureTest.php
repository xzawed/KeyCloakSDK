<?php

declare(strict_types=1);

// measurement only — not for merge (task n3 · registry admin-created-id-non-ascii-location).
//
// What does admin()->users()->create return when the 201's Location carries a byte that is not visible ASCII? A `php -S`
// router answers the grant, fschmtt's serverinfo, and the create with 201 +
// `Location: http://127.0.0.1:<port>/admin/realms/it-realm/users/<id bytes>` for `abc` (control), `ab` 0xE9 `cd` (Latin-1
// obs-text) and `ab` 0xC3 0xA9 `cd` (UTF-8 for U+00E9). Per case: the bytes a raw socket reads off the wire (WIRE), what a
// plain Guzzle client hands back as the header (CLIENT), and what the SDK call returns (ID — UsersResource::create is void).
//
// Run: N3_OUT=<file> vendor/bin/phpunit tests/Unit/zz_n3_location_measureTest.php

namespace Xzawed\Keycloak\Tests\Unit;

use Composer\InstalledVersions;
use Fschmtt\Keycloak\Representation\User;
use GuzzleHttp\Client as GuzzleClient;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;

final class zz_n3_location_measureTest extends TestCase
{
    private const USERS = '/admin/realms/it-realm/users';
    private const CASES = [
        'ascii-control' => 'abc',
        'latin1-0xE9' => "ab\xE9cd",
        'utf8-0xC3A9' => "ab\xC3\xA9cd",
    ];

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
        self::$dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'zz-n3-loc-' . bin2hex(random_bytes(6));
        self::assertTrue(mkdir(self::$dir));
        file_put_contents(self::$dir . '/location.hex', '');
        $env = getenv();
        $env['N3_DIR'] = self::$dir;
        $pipes = [];
        $proc = proc_open(
            [PHP_BINARY, '-S', '127.0.0.1:' . self::$port, __DIR__ . '/Fixtures/zz_n3_location_router.php'],
            [0 => ['pipe', 'r'], 1 => ['file', self::$dir . '/server.out', 'a'], 2 => ['file', self::$dir . '/server.err', 'a']],
            $pipes,
            self::$dir,
            $env,
        );
        self::assertIsResource($proc);
        self::$proc = $proc;
        register_shutdown_function(static function (): void {
            self::stop();
        });
        for ($i = 0; $i < 500; $i++) {
            $c = @fsockopen('127.0.0.1', self::$port, $en, $es, 0.2);
            if ($c !== false) {
                fclose($c);

                return;
            }
            usleep(20_000);
        }
        self::fail('php -S did not come up');
    }

    public static function tearDownAfterClass(): void
    {
        self::stop();
    }

    private static function stop(): void
    {
        if (self::$proc !== null) {
            proc_terminate(self::$proc);
            proc_close(self::$proc);
            self::$proc = null;
        }
    }

    private static function base(): string
    {
        return 'http://127.0.0.1:' . self::$port;
    }

    private static function hex(string $bytes): string
    {
        return implode(' ', str_split(strtoupper(bin2hex($bytes)), 2));
    }

    /** The bytes, and — when they are valid UTF-8 — their code points. */
    private static function show(?string $s): string
    {
        if ($s === null) {
            return 'null';
        }
        $out = '"' . preg_replace_callback('/[^\x20-\x7E]/', static fn (array $m): string => sprintf('\\x%02X', ord($m[0])), $s) . '" bytes=[' . self::hex($s) . ']';
        if (mb_check_encoding($s, 'UTF-8')) {
            $out .= ' utf8_cps=[' . implode(',', array_map(static fn (int $c): string => sprintf('U+%04X', $c), mb_str_split($s) === [] ? [] : array_map('mb_ord', mb_str_split($s)))) . ']';
        } else {
            $out .= ' utf8_valid=false';
        }

        return $out;
    }

    private static function tail(string $s): string
    {
        $at = strrpos($s, '/');

        return $at === false ? $s : substr($s, $at + 1);
    }

    private static function wireProbe(): string
    {
        $c = fsockopen('127.0.0.1', self::$port, $en, $es, 2.0);
        self::assertNotFalse($c);
        fwrite($c, 'POST ' . self::USERS . " HTTP/1.1\r\nHost: 127.0.0.1:" . self::$port . "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        $raw = (string) stream_get_contents($c);
        fclose($c);
        foreach (explode("\r\n", $raw) as $line) {
            if (str_starts_with($line, 'Location: ')) {
                return substr($line, strlen('Location: '));
            }
        }

        return 'no Location';
    }

    public function testMeasure(): void
    {
        $out = [
            'ENV|php=' . PHP_VERSION . '|guzzlehttp/guzzle=' . InstalledVersions::getPrettyVersion('guzzlehttp/guzzle') . '|guzzlehttp/psr7='
                . InstalledVersions::getPrettyVersion('guzzlehttp/psr7') . '|fschmtt/keycloak-rest-api-client-php='
                . InstalledVersions::getPrettyVersion('fschmtt/keycloak-rest-api-client-php') . '|create=admin()->users()->create (void)',
            'HEADER|sdk|lane|case|field|value',
        ];
        $config = new KeycloakConfig(self::base(), 'it-realm', 'it-client', 'dummy-secret');
        foreach (self::CASES as $name => $id) {
            $location = self::base() . self::USERS . '/' . $id;
            file_put_contents(self::$dir . '/location.hex', bin2hex($location));
            $probe = self::wireProbe();
            $out[] = "WIRE|php|-|$name|location=<base>/admin/realms/it-realm/users/+[" . self::hex($id) . ']|raw_socket_read_equals_sent='
                . var_export($probe === $location, true) . '|id_bytes_on_wire=' . self::hex(substr($probe, strlen(self::base() . self::USERS . '/')));
            try {
                $resp = (new GuzzleClient(['allow_redirects' => false]))->request('POST', self::base() . self::USERS);
                $client = 'status=' . $resp->getStatusCode() . "|getHeaderLine('Location').after_last_slash=" . self::show(self::tail($resp->getHeaderLine('Location')));
            } catch (\Throwable $e) {
                $client = 'threw ' . $e::class . ': ' . $e->getMessage();
            }
            $out[] = "CLIENT|php|GuzzleHttp\\Client(allow_redirects=false)|$name|$client";
            file_put_contents(self::$dir . '/requests.log', '');
            try {
                $kc = KeycloakClient::create($config);
                $returned = $kc->admin()->users()->create(new User(username: 'n3-user'));
                $result = 'Ok(' . var_export($returned, true) . ' — create returns void)';
            } catch (\Throwable $e) {
                $prev = $e->getPrevious() !== null ? ' previous=' . $e->getPrevious()::class . ': ' . $e->getPrevious()->getMessage() : '';
                $result = str_replace(['|', "\n"], ['/', ' '], 'Err(' . $e::class . ': ' . $e->getMessage() . $prev . ')');
            }
            $seen = implode(',', file(self::$dir . '/requests.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: []);
            $out[] = "ID|php|admin()->users()->create|$name|$result|requests=$seen";
        }
        $path = getenv('N3_OUT');
        self::assertIsString($path, 'set N3_OUT to the output file');
        file_put_contents($path, implode("\n", $out) . "\n");
        self::assertCount(3, array_filter($out, static fn (string $l): bool => str_starts_with($l, 'ID|')));
    }
}
