<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit\Admin;

use Fschmtt\Keycloak\Representation\Client;
use Fschmtt\Keycloak\Representation\Group;
use Fschmtt\Keycloak\Representation\Realm;
use Fschmtt\Keycloak\Representation\Role;
use Fschmtt\Keycloak\Representation\User;
use GuzzleHttp\Handler\CurlVersion;
use GuzzleHttp\Handler\StreamHandler;
use GuzzleHttp\Utils as GuzzleUtils;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Admin\AdminClient;
use Xzawed\Keycloak\Exception\KeycloakAdminError;
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;
use Xzawed\Keycloak\KeycloakConfig;

/**
 * A 3xx answer to an admin facade call is an admin error carrying that status, never a success (registry
 * `go-admin-3xx-read-as-success`, php).
 *
 * Guzzle's `http_errors` raises only from 400 up and the SDK follows no redirect (`HttpOptions`), so a 3xx came back to
 * fschmtt as an answer: a lookup deserialized its body into a representation and a command discarded it. Each cell below
 * answers one facade call with 300, 302 (no `Location`) or 399 and a body that is that call's success body — the control
 * test proves the same body under 200 is read as the call's success, so a 3xx that returns is indistinguishable from one.
 * A cell passes only on `KeycloakAdminError` itself (the class a 4xx without its own class gets — not a not-found,
 * conflict or forbidden subclass) carrying exactly the 3xx status: a transport, JSON or hydration error fails the cell.
 *
 * The 25 calls are the five resources × create · get · list · update · delete, the same 25 the integration lane runs
 * (`FullFlowIT`). The fake Keycloak is the raw-socket server of `AdminResponseBodyTest` (`Fixtures/admin-body-server.php`);
 * it answers the token grant and the version lookup normally. Both transports run (curl and the stream handler of an
 * install without ext-curl — `AdminResponseBodyTest::useTransport`).
 *
 * The same 25 calls guard two more cases (measured 2026-11-14, curl: A 300/300 · control 50/50 · B 25/25 — already right,
 * no SDK change). Each runs every cell under one transport, collects the wrong ones and asserts once.
 *  (A) A non-object JSON error body — the class rescan of registry `python-admin-list-error-array-body` (there python's
 *      five list calls end an array-bodied 4xx · 5xx as a status-less transport error). 404 · 500 × seven bodies (the
 *      object control `{"error":"x"}`, then `[]` · `"boom"` · `42` · `true` · `null` · a 100000-deep array of 200,000
 *      bytes): 404 ends as `KeycloakNotFoundError`, 500 as `KeycloakAdminError` itself, carrying that status, after exactly
 *      one admin request — the call's own; `GET /admin/serverinfo` is fschmtt's version lookup, not the call's.
 *  (B) A followable redirect — registry `admin-followable-redirect-class-divergent` (go diverges as `*TransportError`). A
 *      302 carries `Location: <server>/redirected-target`, which answers 200 with the call's success body, so a follow
 *      would read as success: the call must end as `KeycloakAdminError` itself carrying 302, after exactly one admin
 *      request and none to the target.
 * Their request counts wait for a sentinel request's own log line (`requestsOfThisCell`).
 */
final class AdminRedirectStatusTest extends TestCase
{
    private const BASE = '/admin/realms/r';
    private const STATUSES = [300, 302, 399];
    /** (A)'s statuses — the bodies are `errorBodies()`. */
    private const ERROR_STATUSES = [404, 500];
    /** Where (B)'s 302 points — not an admin path, so it is counted apart. */
    private const TARGET = '/redirected-target';
    private const USER = '{"id":"u1","username":"u"}';
    private const CLIENT = '{"id":"c1","clientId":"c"}';
    private const REALM = '{"realm":"x"}';
    private const ROLE = '{"name":"n"}';
    private const GROUP = '{"id":"g1","name":"g"}';
    /** Proxy variables — cleared for each test and restored (`AdminResponseBodyTest` does the same). */
    private const PROXY_ENV = ['http_proxy', 'HTTP_PROXY', 'https_proxy', 'HTTPS_PROXY', 'all_proxy', 'ALL_PROXY'];

    private static string $dir = '';
    private static int $port = 0;
    private static string $nonce = '';
    /** @var resource|null */
    private static $proc = null;
    /** @var array{0: \ReflectionProperty, 1: mixed}|null */
    private ?array $curlInfo = null;
    /** @var array<string, string|false> */
    private array $proxyEnv = [];

    public static function setUpBeforeClass(): void
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
        self::assertNotFalse($sock, "no free port: $errstr");
        $name = (string) stream_socket_get_name($sock, false);
        fclose($sock);
        self::$port = (int) substr($name, (int) strrpos($name, ':') + 1);
        self::$dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'a3x-' . bin2hex(random_bytes(6));
        self::assertTrue(mkdir(self::$dir));
        self::route([]);
        $pipes = [];
        $proc = proc_open(
            [PHP_BINARY, __DIR__ . '/../Fixtures/admin-body-server.php', (string) self::$port, self::$dir],
            [0 => ['pipe', 'r'], 1 => ['file', self::$dir . '/server.out', 'a'], 2 => ['file', self::$dir . '/server.err', 'a']],
            $pipes,
        );
        self::assertIsResource($proc, 'the fake Keycloak did not start');
        self::$proc = $proc;
        register_shutdown_function(static function (): void {
            self::stopServer();
        });
        for ($i = 0; $i < 500; $i++) {
            $c = @fsockopen('127.0.0.1', self::$port, $en, $es, 0.2);
            if ($c !== false) {
                fclose($c);

                return;
            }
            usleep(20_000);
        }
        self::fail('the fake Keycloak is not listening');
    }

    public static function tearDownAfterClass(): void
    {
        self::stopServer();
    }

    private static function stopServer(): void
    {
        if (self::$proc !== null) {
            proc_terminate(self::$proc);
            proc_close(self::$proc);
            self::$proc = null;
        }
        foreach (['state.json', 'sent.log', 'server.out', 'server.err'] as $f) {
            @unlink(self::$dir . '/' . $f);
        }
        @rmdir(self::$dir);
    }

    protected function setUp(): void
    {
        foreach (self::PROXY_ENV as $name) {
            $this->proxyEnv[$name] = getenv($name);
            putenv($name);
        }
    }

    protected function tearDown(): void
    {
        if ($this->curlInfo !== null) {
            [$property, $before] = $this->curlInfo;
            $property->setValue(null, $before);
            $this->curlInfo = null;
        }
        foreach ($this->proxyEnv as $name => $value) {
            putenv($value === false ? $name : "$name=$value");
        }
        $this->proxyEnv = [];
        gc_collect_cycles();
    }

    /**
     * The answer to each `METHOD /path` (the server fixture's header lists the fields) — clears the request log and sets a
     * new nonce.
     *
     * @param array<string, array<string, mixed>> $routes
     */
    private static function route(array $routes): void
    {
        self::$nonce = bin2hex(random_bytes(6));
        file_put_contents(self::$dir . '/state.json', json_encode(['nonce' => self::$nonce, 'routes' => $routes === [] ? new \stdClass() : $routes], JSON_THROW_ON_ERROR));
        @unlink(self::$dir . '/sent.log');
    }

    /** Whether the server answered `METHOD path` under this nonce — the log line lands once the response is over. */
    private static function served(string $method, string $path): bool
    {
        for ($i = 0; $i < 250; $i++) {
            $lines = @file(self::$dir . '/sent.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($lines === false ? [] : $lines as $line) {
                $r = json_decode($line, true);
                if (\is_array($r) && ($r['method'] ?? null) === $method && ($r['path'] ?? null) === $path && ($r['nonce'] ?? null) === self::$nonce) {
                    return true;
                }
            }
            usleep(20_000);
        }

        return false;
    }

    private static function config(): KeycloakConfig
    {
        return new KeycloakConfig('http://127.0.0.1:' . self::$port, 'r', 'c', 'a3x-client-secret');
    }

    /** What the call did — its return value, or what it threw. */
    private static function outcome(\Closure $call): mixed
    {
        try {
            return $call();
        } catch (\Throwable $e) {
            return $e;
        }
    }

    private static function describe(mixed $result): string
    {
        if ($result instanceof \Throwable) {
            $status = $result instanceof KeycloakAdminError ? ' ' . var_export($result->getStatusCode(), true) : '';

            return $result::class . $status . ': ' . substr($result->getMessage(), 0, 80);
        }

        // Only the fields that came back — a representation serializes every property, most of them null.
        $set = static fn (mixed $v): mixed => \is_array($v) ? array_filter($v, static fn (mixed $f): bool => $f !== null) : $v;
        $shown = json_decode((string) json_encode($result), true);
        $shown = \is_array($shown) && array_is_list($shown) ? array_map($set, $shown) : $set($shown);

        return 'returned ' . get_debug_type($result) . ($result === null ? '' : ' ' . substr((string) json_encode($shown), 0, 80));
    }

    private static function note(string $line): void
    {
        if (getenv('TC_PRINT') === '1') {   // the measuring command: TC_PRINT=1 vendor/bin/phpunit --filter AdminRedirectStatusTest
            fwrite(STDERR, $line . "\n");
        }
    }

    /** `AdminResponseBodyTest::useTransport` — called before the client is built. */
    private function useTransport(string $transport): void
    {
        if ($transport === 'stream') {
            $property = new \ReflectionProperty(CurlVersion::class, 'versionInfo');
            $this->curlInfo = [$property, $property->getValue()];
            $property->setValue(null, false);
        }
        $chosen = GuzzleUtils::chooseHandler();
        if ($transport === 'stream') {
            self::assertInstanceOf(StreamHandler::class, $chosen, 'could not stand in for an install without ext-curl');
        } else {
            self::assertNotInstanceOf(StreamHandler::class, $chosen, 'a curl cell, yet Guzzle chose the StreamHandler');
        }
    }

    /**
     * The 25 facade calls — [method and path of the call's own request, the call, that request's success body, fschmtt's
     * re-GET after the write (route => body), what the call returns on success (JSON; null = nothing)].
     *
     * @return array<string, array{0: string, 1: string, 2: \Closure(AdminClient): mixed, 3: string, 4: array<string, string>, 5: string|null}>
     */
    private static function calls(): array
    {
        $users = self::BASE . '/users';
        $clients = self::BASE . '/clients';
        $roles = self::BASE . '/roles';
        $groups = self::BASE . '/groups';
        $clientBack = ["GET $clients/c1" => self::CLIENT];
        $realmBack = ['GET /admin/realms/x' => self::REALM];

        return [
            'users.create' => ['POST', $users, static fn (AdminClient $a) => $a->users()->create(new User(username: 'u')), self::USER, [], null],
            'users.get' => ['GET', "$users/u1", static fn (AdminClient $a) => $a->users()->get('u1'), self::USER, [], self::USER],
            'users.search' => ['GET', $users, static fn (AdminClient $a) => $a->users()->search(), '[' . self::USER . ']', [], '[' . self::USER . ']'],
            'users.update' => ['PUT', "$users/u1", static fn (AdminClient $a) => $a->users()->update('u1', new User(username: 'u')), self::USER, [], null],
            'users.delete' => ['DELETE', "$users/u1", static fn (AdminClient $a) => $a->users()->delete('u1'), self::USER, [], null],
            'clients.import' => ['POST', $clients, static fn (AdminClient $a) => $a->clients()->import(new Client(id: 'c1', clientId: 'c')), self::CLIENT, $clientBack, self::CLIENT],
            'clients.get' => ['GET', "$clients/c1", static fn (AdminClient $a) => $a->clients()->get('c1'), self::CLIENT, [], self::CLIENT],
            'clients.all' => ['GET', $clients, static fn (AdminClient $a) => $a->clients()->all(), '[' . self::CLIENT . ']', [], '[' . self::CLIENT . ']'],
            'clients.update' => ['PUT', "$clients/c1", static fn (AdminClient $a) => $a->clients()->update('c1', new Client(id: 'c1', clientId: 'c')), self::CLIENT, $clientBack, null],
            'clients.delete' => ['DELETE', "$clients/c1", static fn (AdminClient $a) => $a->clients()->delete('c1'), self::CLIENT, [], null],
            'realms.import' => ['POST', '/admin/realms', static fn (AdminClient $a) => $a->realms()->import(new Realm(realm: 'x')), self::REALM, $realmBack, self::REALM],
            'realms.get' => ['GET', '/admin/realms/x', static fn (AdminClient $a) => $a->realms()->get('x'), self::REALM, [], self::REALM],
            'realms.all' => ['GET', '/admin/realms', static fn (AdminClient $a) => $a->realms()->all(), '[' . self::REALM . ']', [], '[' . self::REALM . ']'],
            'realms.update' => ['PUT', '/admin/realms/x', static fn (AdminClient $a) => $a->realms()->update('x', new Realm(realm: 'x')), self::REALM, $realmBack, null],
            'realms.delete' => ['DELETE', '/admin/realms/x', static fn (AdminClient $a) => $a->realms()->delete('x'), self::REALM, [], null],
            'roles.create' => ['POST', $roles, static fn (AdminClient $a) => $a->roles()->create(new Role(name: 'n')), self::ROLE, [], null],
            'roles.get' => ['GET', "$roles/n", static fn (AdminClient $a) => $a->roles()->get('n'), self::ROLE, [], self::ROLE],
            'roles.all' => ['GET', $roles, static fn (AdminClient $a) => $a->roles()->all(), '[' . self::ROLE . ']', [], '[' . self::ROLE . ']'],
            'roles.update' => ['PUT', "$roles/n", static fn (AdminClient $a) => $a->roles()->update('n', new Role(name: 'n')), self::ROLE, [], null],
            'roles.delete' => ['DELETE', "$roles/n", static fn (AdminClient $a) => $a->roles()->delete('n'), self::ROLE, [], null],
            'groups.create' => ['POST', $groups, static fn (AdminClient $a) => $a->groups()->create(new Group(name: 'g')), self::GROUP, [], null],
            'groups.get' => ['GET', "$groups/g1", static fn (AdminClient $a) => $a->groups()->get('g1'), self::GROUP, [], self::GROUP],
            'groups.all' => ['GET', $groups, static fn (AdminClient $a) => $a->groups()->all(), '[' . self::GROUP . ']', [], '[' . self::GROUP . ']'],
            'groups.update' => ['PUT', "$groups/g1", static fn (AdminClient $a) => $a->groups()->update('g1', new Group(name: 'g')), self::GROUP, [], null],
            'groups.delete' => ['DELETE', "$groups/g1", static fn (AdminClient $a) => $a->groups()->delete('g1'), self::GROUP, [], null],
        ];
    }

    /** @return array<string, array{string, int, string}> call × status × transport */
    public static function redirectRows(): array
    {
        $rows = [];
        foreach (['curl', 'stream'] as $transport) {
            foreach (array_keys(self::calls()) as $name) {
                foreach (self::STATUSES as $status) {
                    $rows["$name $status" . ($transport === 'curl' ? '' : ' · stream')] = [$name, $status, $transport];
                }
            }
        }

        return $rows;
    }

    /** @return array<string, array{string}> */
    public static function callRows(): array
    {
        $rows = [];
        foreach (array_keys(self::calls()) as $name) {
            $rows[$name] = [$name];
        }

        return $rows;
    }

    /** @return array<string, array{int}> */
    public static function statusRows(): array
    {
        $rows = [];
        foreach (self::STATUSES as $status) {
            $rows["HTTP $status"] = [$status];   // a numeric string key would become an int key
        }

        return $rows;
    }

    /** @return array<string, array{string, int}> the calls fschmtt ends with a re-GET × status */
    public static function reGetRows(): array
    {
        $rows = [];
        foreach (self::calls() as $name => [, , , , $back]) {
            foreach ($back === [] ? [] : self::STATUSES as $status) {
                $rows["$name $status"] = [$name, $status];
            }
        }

        return $rows;
    }

    /**
     * The routes of one call — its own request answered with `$status` (with `$head` in place of its success body when
     * given, and `$headers` added), fschmtt's re-GET (if any) with `$backStatus`.
     *
     * @param array<string, string> $headers
     * @return array<string, array<string, mixed>>
     */
    private static function routesOf(string $name, int $status, int $backStatus = 200, ?string $head = null, array $headers = []): array
    {
        [$method, $path, , $body, $back] = self::calls()[$name];
        $routes = [$method . ' ' . $path => ['status' => $status, 'head' => $head ?? $body] + ($headers === [] ? [] : ['headers' => $headers])];
        foreach ($back as $key => $backBody) {
            $routes[$key] = ['status' => $backStatus, 'head' => $backBody];
        }

        return $routes;
    }

    /** The cell: `KeycloakAdminError` itself, carrying exactly the 3xx status. */
    private static function assertAdminErrorWithStatus(int $status, mixed $result, string $cell): void
    {
        self::assertInstanceOf(KeycloakAdminError::class, $result, "$cell: " . self::describe($result));
        self::assertSame(KeycloakAdminError::class, $result::class, "$cell: a 3xx is not a 404/409/403 — " . self::describe($result));
        self::assertSame($status, $result->getStatusCode(), "$cell: " . self::describe($result));
    }

    /** The call's own request answered 3xx with its success body — the call fails with that status. */
    #[DataProvider('redirectRows')]
    public function testA3xxAnswerIsAnAdminErrorCarryingItsStatus(string $name, int $status, string $transport): void
    {
        [$method, $path, $call] = self::calls()[$name];
        self::route(self::routesOf($name, $status));
        $this->useTransport($transport);
        $admin = new AdminClient(self::config());

        $result = self::outcome(static fn () => $call($admin));

        self::note(sprintf('[%s] %s %d: %s', $transport, $name, $status, self::describe($result)));
        self::assertTrue(self::served($method, $path), "$name: the call's request never reached the server");
        self::assertAdminErrorWithStatus($status, $result, "$name $status [$transport]");
    }

    /**
     * Control — the same bodies under 200 are the calls' successes: lookups return them hydrated, commands return
     * nothing. Without this a body that does not hydrate would make a 3xx cell look like a refusal it is not.
     */
    #[DataProvider('callRows')]
    public function testTheSameBodyUnder200IsTheCallsSuccess(string $name): void
    {
        $call = self::calls()[$name][2];
        $returns = self::calls()[$name][5];
        self::route(self::routesOf($name, 200));
        $admin = new AdminClient(self::config());

        $result = self::outcome(static fn () => $call($admin));

        self::note(sprintf('[curl] %s 200: %s', $name, self::describe($result)));
        self::assertNotInstanceOf(\Throwable::class, $result, "$name: " . self::describe($result));
        if ($returns === null) {
            self::assertNull($result, "$name returns nothing");

            return;
        }
        $want = json_decode($returns, true, 512, JSON_THROW_ON_ERROR);
        $got = json_decode((string) json_encode($result), true, 512, JSON_THROW_ON_ERROR);
        self::assertIsArray($want);
        self::assertIsArray($got);
        $pairs = array_is_list($want) ? array_map(null, $want, $got) : [[$want, $got]];
        self::assertCount(\count($want === [] || !array_is_list($want) ? [$want] : $want), $pairs);
        foreach ($pairs as [$fields, $hydrated]) {
            self::assertIsArray($fields);
            self::assertIsArray($hydrated, "$name: fewer items than the body");
            foreach ($fields as $field => $value) {
                self::assertSame($value, $hydrated[$field] ?? null, "$name: $field did not hydrate");
            }
        }
    }

    /**
     * A write fschmtt follows with a re-GET (clients and realms import and update) — the 3xx is on that GET. It is a response
     * of the same call, so the call fails the same way.
     */
    #[DataProvider('reGetRows')]
    public function testA3xxOnTheReGetFailsTheCallToo(string $name, int $status): void
    {
        [$method, $path, $call] = self::calls()[$name];
        self::route(self::routesOf($name, $method === 'POST' ? 201 : 204, $status));
        $admin = new AdminClient(self::config());

        $result = self::outcome(static fn () => $call($admin));

        self::note(sprintf('[curl] %s re-GET %d: %s', $name, $status, self::describe($result)));
        self::assertTrue(self::served($method, $path), "$name: the write never reached the server");
        self::assertAdminErrorWithStatus($status, $result, "$name re-GET $status");
    }

    /**
     * `raw()` is left as it was — a call through the escape hatch is not a facade call, so fschmtt keeps its own reading of
     * a 3xx (a lookup deserializes the body, a command drops it). The facade on the same client refuses it in between, and
     * the raw command after that refused call still is not refused (the count of running facade calls went back down).
     */
    #[DataProvider('statusRows')]
    public function testRawKeepsFschmttsReadingOfA3xx(int $status): void
    {
        $user = self::BASE . '/users/u1';
        self::route(["GET $user" => ['status' => $status, 'head' => self::USER], "DELETE $user" => ['status' => $status, 'head' => self::USER]]);
        $admin = new AdminClient(self::config());
        $raw = $admin->raw();

        $got = self::outcome(static fn () => $raw->users()->get('r', 'u1'));
        $facade = self::outcome(static fn () => $admin->users()->get('u1'));
        $gone = self::outcome(static fn () => $raw->users()->delete('r', 'u1'));

        self::note(sprintf('[curl] raw users.get %d: %s · facade: %s · raw users.delete: %s', $status, self::describe($got), self::describe($facade), self::describe($gone)));
        self::assertInstanceOf(User::class, $got, self::describe($got));
        self::assertSame('u1', $got->getId());
        self::assertAdminErrorWithStatus($status, $facade, "facade users.get $status");
        self::assertNull($gone, self::describe($gone));
    }

    /** @return array<string, array{string}> */
    public static function transportRows(): array
    {
        return ['curl' => ['curl'], 'stream' => ['stream']];
    }

    /**
     * (A)'s error bodies — the object control first, then six non-object JSON values (the deep one is 200,000 bytes).
     *
     * @return array<string, string>
     */
    private static function errorBodies(): array
    {
        return [
            'object' => '{"error":"x"}',
            'array' => '[]',
            'string' => '"boom"',
            'number' => '42',
            'boolean' => 'true',
            'null' => 'null',
            'deep' => str_repeat('[', 100_000) . str_repeat(']', 100_000),
        ];
    }

    /**
     * The redirect target, answering 200 with `$body` to every method a facade call sends (a follow keeps it or turns GET).
     *
     * @return array<string, array{status: int, head: string}>
     */
    private static function targetRoutes(string $body): array
    {
        $routes = [];
        foreach (['GET', 'POST', 'PUT', 'DELETE'] as $method) {
            $routes["$method " . self::TARGET] = ['status' => 200, 'head' => $body];
        }

        return $routes;
    }

    /**
     * A plain GET on its own connection, following nothing — `[status, headers (lower-cased names), body]`.
     *
     * @return array{0: int, 1: array<string, string>, 2: string}
     */
    private static function rawGet(string $path): array
    {
        $conn = @fsockopen('127.0.0.1', self::$port, $errno, $errstr, 5.0);
        self::assertNotFalse($conn, "the fake Keycloak is not listening: $errstr");
        stream_set_timeout($conn, 10);
        fwrite($conn, "GET $path HTTP/1.1\r\nHost: 127.0.0.1:" . self::$port . "\r\nConnection: close\r\n\r\n");
        $raw = (string) stream_get_contents($conn);
        fclose($conn);
        [$head, $body] = array_pad(explode("\r\n\r\n", $raw, 2), 2, '');
        $lines = explode("\r\n", $head);
        $status = (int) (explode(' ', array_shift($lines))[1] ?? 0);
        $headers = [];
        foreach ($lines as $line) {
            [$name, $value] = array_pad(explode(':', $line, 2), 2, '');
            $headers[strtolower(trim($name))] = trim($value);
        }

        return [$status, $headers, $body];
    }

    /**
     * Every request the server answered under this nonce, as `METHOD /path` — read once a sentinel request's own line is in
     * the log. The fixture serves one connection at a time and logs each request (under `LOCK_EX`) after closing it, so the
     * sentinel's line comes after every line of the cell; a read made right after the sentinel's response came back empty
     * in 41 of 375 cells (measured 2026-11-14, Windows) — hence the poll.
     *
     * @return list<string>
     */
    private static function requestsOfThisCell(): array
    {
        $sentinel = '/sentinel-' . self::$nonce;
        self::rawGet($sentinel);
        for ($i = 0; $i < 250; $i++) {
            $seen = [];
            $done = false;
            $lines = @file(self::$dir . '/sent.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($lines === false ? [] : $lines as $line) {
                $r = json_decode($line, true);
                $method = \is_array($r) ? ($r['method'] ?? null) : null;
                $path = \is_array($r) ? ($r['path'] ?? null) : null;
                if (!\is_array($r) || ($r['nonce'] ?? null) !== self::$nonce || !\is_string($method) || !\is_string($path)) {
                    continue;
                }
                if ($path === $sentinel) {
                    $done = true;
                } else {
                    $seen[] = "$method $path";
                }
            }
            if ($done) {
                return $seen;
            }
            usleep(20_000);
        }
        self::fail("the sentinel request $sentinel was never logged");
    }

    /**
     * A body-shape or followable-302 cell — null when it is right: the facade's admin error for `$status` (404 is
     * `KeycloakNotFoundError`, anything else `KeycloakAdminError` itself) carrying it, after exactly one admin request, the
     * call's own `$request` (fschmtt's version lookup is not the call's), and no request to the redirect target.
     *
     * @param list<string> $seen
     */
    private static function wrongCell(string $cell, mixed $result, array $seen, int $status, string $request): ?string
    {
        $admin = array_values(array_filter($seen, static fn (string $r): bool => str_contains($r, ' /admin/') && !str_ends_with($r, ' /admin/serverinfo')));
        $followed = \count(array_filter($seen, static fn (string $r): bool => str_ends_with($r, ' ' . self::TARGET)));
        $class = $status === 404 ? KeycloakNotFoundError::class : KeycloakAdminError::class;
        if ($result instanceof KeycloakAdminError && $result::class === $class && $result->getStatusCode() === $status && $admin === [$request] && $followed === 0) {
            return null;
        }

        return "$cell: " . self::describe($result) . ' · admin requests ' . json_encode($admin) . " · target requests $followed";
    }

    /**
     * (A) A 404 or 500 whose JSON body is not an object ends each call as the admin error of that status — the same as the
     * object control does.
     */
    #[DataProvider('transportRows')]
    public function testANonObjectJsonErrorBodyEndsAsTheErrorOfItsStatus(string $transport): void
    {
        $this->useTransport($transport);
        $wrong = [];
        foreach (self::ERROR_STATUSES as $status) {
            foreach (self::errorBodies() as $shape => $body) {
                // The premise — the server sends this status with exactly this body, as JSON.
                self::route(['GET ' . self::BASE . '/users/u1' => ['status' => $status, 'head' => $body]]);
                [$answered, $headers, $sent] = self::rawGet(self::BASE . '/users/u1');
                if ($answered !== $status || ($headers['content-type'] ?? null) !== 'application/json' || $sent !== $body) {
                    $wrong[] = "$status $shape premise: the server answered $answered · " . ($headers['content-type'] ?? 'no content-type') . ' · ' . \strlen($sent) . ' bytes';
                }
                foreach (self::calls() as $name => [$method, $path, $call]) {
                    self::route(self::routesOf($name, $status, head: $body));
                    $admin = new AdminClient(self::config());
                    $result = self::outcome(static fn () => $call($admin));
                    self::note(sprintf('[%s] %s %d %s: %s', $transport, $name, $status, $shape, self::describe($result)));
                    $wrong[] = self::wrongCell("$status $shape $name [$transport]", $result, self::requestsOfThisCell(), $status, "$method $path");
                }
            }
        }
        $wrong = array_values(array_filter($wrong, static fn (?string $w): bool => $w !== null));
        self::assertSame([], $wrong, \count($wrong) . " cell(s) wrong:\n" . implode("\n", $wrong));
    }

    /**
     * (B) A 302 whose `Location` points at a target that would answer the call's success is not followed: each call ends as
     * `KeycloakAdminError` itself carrying 302.
     */
    #[DataProvider('transportRows')]
    public function testAFollowable302IsNotFollowedAndEndsAsAnAdminError302(string $transport): void
    {
        $this->useTransport($transport);
        $location = 'http://127.0.0.1:' . self::$port . self::TARGET;
        $wrong = [];
        // The premise — the 302 carries that Location, and the target answers 200 (what a follow would read as success).
        self::route(['GET ' . self::BASE . '/users' => ['status' => 302, 'headers' => ['Location' => $location], 'head' => '{}']] + self::targetRoutes('[' . self::USER . ']'));
        [$answered, $headers] = self::rawGet(self::BASE . '/users');
        [$targetAnswered] = self::rawGet(self::TARGET);
        if ($answered !== 302 || ($headers['location'] ?? null) !== $location || $targetAnswered !== 200) {
            $wrong[] = "premise: the server answered $answered with Location " . ($headers['location'] ?? 'none') . " · the target $targetAnswered";
        }
        foreach (self::calls() as $name => [$method, $path, $call, $body]) {
            self::route(self::routesOf($name, 302, head: '{}', headers: ['Location' => $location]) + self::targetRoutes($body));
            $admin = new AdminClient(self::config());
            $result = self::outcome(static fn () => $call($admin));
            self::note(sprintf('[%s] %s 302 followable: %s', $transport, $name, self::describe($result)));
            $wrong[] = self::wrongCell("302 $name [$transport]", $result, self::requestsOfThisCell(), 302, "$method $path");
        }
        $wrong = array_values(array_filter($wrong, static fn (?string $w): bool => $w !== null));
        self::assertSame([], $wrong, \count($wrong) . " cell(s) wrong:\n" . implode("\n", $wrong));
    }
}
