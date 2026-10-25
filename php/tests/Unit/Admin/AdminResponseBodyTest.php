<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit\Admin;

use Fschmtt\Keycloak\Http\CommandExecutor;
use Fschmtt\Keycloak\Http\Method;
use Fschmtt\Keycloak\Http\Query;
use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\Representation\Client;
use Fschmtt\Keycloak\Representation\Group;
use Fschmtt\Keycloak\Representation\Realm;
use Fschmtt\Keycloak\Representation\Role;
use Fschmtt\Keycloak\Representation\User;
use GuzzleHttp\Exception\ClientException;
use GuzzleHttp\Handler\CurlVersion;
use GuzzleHttp\Handler\StreamHandler;
use GuzzleHttp\Utils as GuzzleUtils;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Admin\AdminClient;
use Xzawed\Keycloak\Exception\KeycloakAdminError;
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;

/**
 * admin 이 쓰지 않는 응답 본문과 오류 본문을 끝까지 읽지 않는다 — 등록부 admin-response-body-unbounded(php). fschmtt 가 읽지 않는
 * 본문(GET 이 아닌 요청의 2xx)은 받지 않고, 오류 본문(300 이상)은 1,048,576 바이트에서 자른다 — `raw()` 의 요청도. GET 의 2xx 는
 * 지금처럼 끝까지 읽는다.
 *
 * 가짜 Keycloak 은 원시 소켓 서버(`Fixtures/admin-body-server.php`)다 — 본문 중간에서 멈춘 응답과 서버가 써 보낸 바이트를 잴 수 있어야 해서.
 * 전송은 curl 과 스트림 처리기(ext-curl 없는 설치) 둘 다 돈다(`TokenResponseCapTest` 와 같은 `useTransport`).
 */
final class AdminResponseBodyTest extends TestCase
{
    /** 시험의 신탁 — SDK 상수와 따로 쓴다. */
    private const CAP = 1048576;
    /** 소켓 버퍼가 다 담지 못하는 본문. */
    private const HUGE = 64 * 1048576;
    /** 재스캔(2026-10-25)의 읽기 타임아웃. */
    private const STALL_TIMEOUT = 4.0;
    private const BASE = '/admin/realms/r';
    private const ERROR_HEAD = '{"error":"HTTP 404 Not Found"}';

    private static string $dir = '';
    private static int $port = 0;
    private static string $nonce = '';
    /** @var resource|null */
    private static $proc = null;
    /** @var array{0: \ReflectionProperty, 1: mixed}|null */
    private ?array $curlInfo = null;

    public static function setUpBeforeClass(): void
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
        self::assertNotFalse($sock, "빈 포트를 못 얻었다: $errstr");
        $name = (string) stream_socket_get_name($sock, false);
        fclose($sock);
        self::$port = (int) substr($name, (int) strrpos($name, ':') + 1);
        self::$dir = sys_get_temp_dir() . DIRECTORY_SEPARATOR . 'arb-' . bin2hex(random_bytes(6));
        self::assertTrue(mkdir(self::$dir));
        self::route([]);
        $pipes = [];
        $proc = proc_open(
            [PHP_BINARY, __DIR__ . '/../Fixtures/admin-body-server.php', (string) self::$port, self::$dir],
            [0 => ['pipe', 'r'], 1 => ['file', self::$dir . '/server.out', 'a'], 2 => ['file', self::$dir . '/server.err', 'a']],
            $pipes,
        );
        self::assertIsResource($proc, '가짜 Keycloak 프로세스를 못 띄웠다');
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
        self::fail('가짜 Keycloak 이 뜨지 않았다');
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

    protected function tearDown(): void
    {
        if ($this->curlInfo !== null) {
            [$property, $before] = $this->curlInfo;
            $property->setValue(null, $before);
            $this->curlInfo = null;
        }
        gc_collect_cycles();   // 끊긴 응답의 소켓을 놓는다 — 한 번에 연결 하나를 받는 가짜 서버가 다음 시험에서 기다리지 않게
    }

    /**
     * 경로마다의 응답 명세 — `"METHOD /path" => [status, head, pad, stall?, extra]`. 기록(sent.log)을 비우고 새 nonce 를 둔다.
     *
     * @param array<string, array<string, mixed>> $routes
     */
    private static function route(array $routes): void
    {
        self::$nonce = bin2hex(random_bytes(6));
        file_put_contents(self::$dir . '/state.json', json_encode(['nonce' => self::$nonce, 'routes' => $routes === [] ? new \stdClass() : $routes], JSON_THROW_ON_ERROR));
        @unlink(self::$dir . '/sent.log');
    }

    /**
     * 이 nonce 의 `METHOD path` 요청 기록 — 응답이 끝나거나 클라이언트가 닫은 뒤 남는다(필드는 `Fixtures/admin-body-server.php` 머리말).
     *
     * @return array{written: int, got: int, declared: int, continued: bool, conn: int}|null
     */
    private static function record(string $method, string $path): ?array
    {
        for ($i = 0; $i < 500; $i++) {
            $lines = @file(self::$dir . '/sent.log', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($lines === false ? [] : $lines as $line) {
                $r = json_decode($line, true);
                if (!is_array($r) || ($r['method'] ?? null) !== $method || ($r['path'] ?? null) !== $path || ($r['nonce'] ?? null) !== self::$nonce) {
                    continue;
                }
                $int = static fn (string $key): int => is_int($r[$key] ?? null) ? $r[$key] : -1;

                return ['written' => $int('written'), 'got' => $int('got'), 'declared' => $int('declared'),
                    'continued' => ($r['continued'] ?? null) === true, 'conn' => $int('conn')];
            }
            usleep(20_000);
        }

        return null;
    }

    /** 이 nonce 의 응답에서 서버가 `METHOD path` 에 써 보낸 본문 바이트. */
    private static function sent(string $method, string $path): ?int
    {
        return self::record($method, $path)['written'] ?? null;
    }

    private static function config(float $readTimeout = 30.0): KeycloakConfig
    {
        return new KeycloakConfig('http://127.0.0.1:' . self::$port, 'r', 'c', 'arb-client-secret', readTimeout: $readTimeout);
    }

    /**
     * 호출 하나 — 결과(값 또는 예외)와 걸린 ms.
     *
     * @return array{0: mixed, 1: int}
     */
    private static function timed(\Closure $call): array
    {
        $t = hrtime(true);
        try {
            $result = $call();
        } catch (\Throwable $e) {
            $result = $e;
        }
        $ms = intdiv(hrtime(true) - $t, 1_000_000);

        return [$result, $ms];
    }

    private static function note(string $line): void
    {
        if (getenv('TC_PRINT') === '1') {   // 재는 명령: TC_PRINT=1 vendor/bin/phpunit --filter AdminResponseBodyTest
            fwrite(STDERR, $line . "\n");
        }
    }

    private static function describe(mixed $result): string
    {
        if ($result instanceof \Throwable) {
            $status = $result instanceof KeycloakAdminError ? ' ' . var_export($result->getStatusCode(), true) : '';

            return $result::class . $status . ': ' . substr($result->getMessage(), 0, 60);
        }

        return 'ok';
    }

    /** `TokenResponseCapTest::useTransport` 와 같다 — 수신자를 만들기 전에 부른다. */
    private function useTransport(string $transport): void
    {
        if ($transport === 'stream') {
            $property = new \ReflectionProperty(CurlVersion::class, 'versionInfo');
            $this->curlInfo = [$property, $property->getValue()];
            $property->setValue(null, false);
        }
        $chosen = GuzzleUtils::chooseHandler();
        if ($transport === 'stream') {
            self::assertInstanceOf(StreamHandler::class, $chosen, 'ext-curl 없는 설치를 흉내 내지 못했다');
        } else {
            self::assertNotInstanceOf(StreamHandler::class, $chosen, 'curl 칸인데 Guzzle 이 StreamHandler 를 골랐다');
        }
    }

    /**
     * 파사드 쓰기 열다섯 — [메서드, 경로, 부르는 법, 뒤따르는 GET(fschmtt 가 되읽는 것) 의 경로와 본문].
     *
     * @return array<string, array{0: string, 1: string, 2: \Closure(AdminClient): mixed, 3: array<string, string>}>
     */
    private static function writes(): array
    {
        $clientBack = ['GET ' . self::BASE . '/clients/c1' => '{"id":"c1","clientId":"c"}'];
        $realmBack = ['GET /admin/realms/x' => '{"realm":"x"}'];

        return [
            'users.create' => ['POST', self::BASE . '/users', static fn (AdminClient $a) => $a->users()->create(new User(username: 'u')), []],
            'users.update' => ['PUT', self::BASE . '/users/u1', static fn (AdminClient $a) => $a->users()->update('u1', new User(username: 'u')), []],
            'users.delete' => ['DELETE', self::BASE . '/users/u1', static fn (AdminClient $a) => $a->users()->delete('u1'), []],
            'clients.import' => ['POST', self::BASE . '/clients', static fn (AdminClient $a) => $a->clients()->import(new Client(id: 'c1', clientId: 'c')), $clientBack],
            'clients.update' => ['PUT', self::BASE . '/clients/c1', static fn (AdminClient $a) => $a->clients()->update('c1', new Client(id: 'c1', clientId: 'c')), $clientBack],
            'clients.delete' => ['DELETE', self::BASE . '/clients/c1', static fn (AdminClient $a) => $a->clients()->delete('c1'), []],
            'realms.import' => ['POST', '/admin/realms', static fn (AdminClient $a) => $a->realms()->import(new Realm(realm: 'x')), $realmBack],
            'realms.update' => ['PUT', '/admin/realms/x', static fn (AdminClient $a) => $a->realms()->update('x', new Realm(realm: 'x')), $realmBack],
            'realms.delete' => ['DELETE', '/admin/realms/x', static fn (AdminClient $a) => $a->realms()->delete('x'), []],
            'roles.create' => ['POST', self::BASE . '/roles', static fn (AdminClient $a) => $a->roles()->create(new Role(name: 'n')), []],
            'roles.update' => ['PUT', self::BASE . '/roles/n', static fn (AdminClient $a) => $a->roles()->update('n', new Role(name: 'n')), []],
            'roles.delete' => ['DELETE', self::BASE . '/roles/n', static fn (AdminClient $a) => $a->roles()->delete('n'), []],
            'groups.create' => ['POST', self::BASE . '/groups', static fn (AdminClient $a) => $a->groups()->create(new Group(name: 'g')), []],
            'groups.update' => ['PUT', self::BASE . '/groups/g1', static fn (AdminClient $a) => $a->groups()->update('g1', new Group(name: 'g')), []],
            'groups.delete' => ['DELETE', self::BASE . '/groups/g1', static fn (AdminClient $a) => $a->groups()->delete('g1'), []],
        ];
    }

    /** @return array<string, array{string, string}> 쓰기 × 전송 */
    public static function writeRows(): array
    {
        $rows = [];
        foreach (array_keys(self::writes()) as $name) {
            foreach (['curl', 'stream'] as $transport) {
                $rows[$transport === 'curl' ? $name : "$name · stream"] = [$name, $transport];
            }
        }

        return $rows;
    }

    /**
     * 오류 본문을 저마다 읽는 호출 — 조회(GET) · 쓰기(PUT) · 가져오기(POST).
     *
     * @return array<string, array{0: string, 1: string, 2: \Closure(AdminClient): mixed}>
     */
    private static function errorCalls(): array
    {
        return [
            'users.get' => ['GET', self::BASE . '/users/u1', static fn (AdminClient $a) => $a->users()->get('u1')],
            'users.update' => ['PUT', self::BASE . '/users/u1', static fn (AdminClient $a) => $a->users()->update('u1', new User(username: 'u'))],
            'clients.import' => ['POST', self::BASE . '/clients', static fn (AdminClient $a) => $a->clients()->import(new Client(id: 'c1', clientId: 'c'))],
        ];
    }

    /** @return array<string, array{string, int, string}> 호출 × 상태 × 전송 */
    public static function errorRows(): array
    {
        $rows = [];
        foreach (array_keys(self::errorCalls()) as $name) {
            foreach ([404, 500] as $status) {
                foreach (['curl', 'stream'] as $transport) {
                    $rows["$name $status" . ($transport === 'curl' ? '' : ' · stream')] = [$name, $status, $transport];
                }
            }
        }

        return $rows;
    }

    /** @return array<string, array{string, string}> 오류 호출 × 전송 */
    public static function errorCallRows(): array
    {
        $rows = [];
        foreach (array_keys(self::errorCalls()) as $name) {
            foreach (['curl', 'stream'] as $transport) {
                $rows[$transport === 'curl' ? $name : "$name · stream"] = [$name, $transport];
            }
        }

        return $rows;
    }

    /** @return array<string, array{string}> */
    public static function transports(): array
    {
        return ['curl' => ['curl'], 'stream' => ['stream']];
    }

    /** 쓰기의 2xx 와 그 본문 — 받지 않는다: 서버는 64 MiB 를 다 쓰지 못한다. */
    #[DataProvider('writeRows')]
    public function testAWritesSuccessBodyIsNotRead(string $name, string $transport): void
    {
        [$method, $path, $call, $back] = self::writes()[$name];
        $routes = [$method . ' ' . $path => ['status' => $method === 'POST' ? 201 : 200, 'head' => '{}', 'pad' => self::HUGE - 2]];
        foreach ($back as $key => $body) {
            $routes[$key] = ['head' => $body];
        }
        self::route($routes);
        $this->useTransport($transport);
        $admin = new AdminClient(self::config());

        [$result, $ms] = self::timed(static fn () => $call($admin));
        $sent = self::sent($method, $path);

        self::note(sprintf('[%s] %s: %d ms · server wrote %s · %s', $transport, $name, $ms, var_export($sent, true), self::describe($result)));
        self::assertNotInstanceOf(\Throwable::class, $result, "$name: " . self::describe($result));
        self::assertNotNull($sent, "$name: 서버 기록이 없다");
        self::assertLessThan(self::HUGE, $sent, "$name: 서버가 $sent 바이트를 다 썼다 — 쓰지 않는 본문을 읽었다");
    }

    /** 2xx 의 머리 뒤에서 멈춘 본문이 쓰기를 붙들지 않는다 — 곧바로 돌아온다. */
    #[DataProvider('writeRows')]
    public function testAWriteReturnsWithoutWaitingForAStalledBody(string $name, string $transport): void
    {
        [$method, $path, $call, $back] = self::writes()[$name];
        $routes = [$method . ' ' . $path => ['status' => $method === 'POST' ? 201 : 200, 'head' => '{}', 'pad' => self::CAP - 2, 'stall' => 2]];
        foreach ($back as $key => $body) {
            $routes[$key] = ['head' => $body];
        }
        self::route($routes);
        $this->useTransport($transport);
        $admin = new AdminClient(self::config(self::STALL_TIMEOUT));

        [$result, $ms] = self::timed(static fn () => $call($admin));

        self::note(sprintf('[%s] %s stalled: %d ms · %s', $transport, $name, $ms, self::describe($result)));
        self::assertNotInstanceOf(\Throwable::class, $result, "$name: " . self::describe($result));
    }

    /**
     * 1 MiB 이상인 요청 본문에는 Guzzle 이 `Expect: 100-Continue` 를 단다 — curl 은 그 중간 응답에도 `on_headers` 를 부른다. 그것을
     * 최종 응답으로 보면 요청 본문을 보내기도 전에 끝내고 쓰기가 성공한 듯 돌아온다. 서버가 본문을 다 받아야 한다. 스트림 처리기는
     * `Expect` 를 떼고 보내므로(`StreamHandler::__invoke`) 그 칸은 큰 본문이 그대로 가는지만 잰다.
     */
    #[DataProvider('transports')]
    public function testALargeWriteIsSentWhole(string $transport): void
    {
        self::route(['POST /admin/realms' => ['status' => 201], 'GET /admin/realms/x' => ['head' => '{"realm":"x"}']]);
        $this->useTransport($transport);
        $admin = new AdminClient(self::config());

        [$result, $ms] = self::timed(static fn () => $admin->realms()->import(new Realm(realm: 'x', displayName: str_repeat('d', self::CAP))));
        $record = self::record('POST', '/admin/realms');

        self::note(sprintf('[%s] large write: %d ms · %s · %s', $transport, $ms, json_encode($record), self::describe($result)));
        self::assertNotInstanceOf(\Throwable::class, $result, self::describe($result));
        self::assertNotNull($record);
        self::assertSame($transport === 'curl', $record['continued'], 'curl 칸이 100-continue 를 청하지 않았다면 이 시험이 뜻을 갖지 못한다');
        self::assertGreaterThan(self::CAP, $record['declared']);
        self::assertSame($record['declared'], $record['got'], '서버가 요청 본문을 다 받지 못했다');
    }

    /**
     * 본문 없는 2xx(Keycloak 의 쓰기 응답 — 204 · `Content-Length: 0`)는 끊지 않는다: 다음 요청이 같은 연결로 간다. 대조 — 본문 있는
     * 2xx 는 끊으므로 다음 요청이 새 연결로 간다(이 시험이 연결이 바뀌는 것을 본다는 증거). 스트림 처리기는 요청마다 연결을 닫으므로
     * curl 만 잰다.
     */
    public function testAnEmptyWriteResponseKeepsTheConnection(): void
    {
        $this->useTransport('curl');
        $user = self::BASE . '/users/u1';
        $conns = [];
        foreach (['empty' => ['status' => 204, 'keep' => true], 'body' => ['status' => 200, 'head' => '{}', 'pad' => 1022, 'keep' => true]] as $case => $put) {
            self::route(["PUT $user" => $put, "DELETE $user" => ['status' => 204, 'keep' => true]]);
            $admin = new AdminClient(self::config());

            $admin->users()->update('u1', new User(username: 'u'));
            $admin->users()->delete('u1');
            $conns[$case] = [self::record('PUT', $user)['conn'] ?? null, self::record('DELETE', $user)['conn'] ?? null];
            unset($admin);
            gc_collect_cycles();
        }

        self::note('keep-alive: ' . json_encode($conns));
        self::assertNotNull($conns['empty'][0]);
        self::assertSame($conns['empty'][0], $conns['empty'][1], '본문 없는 204 뒤에 연결을 잃었다');
        self::assertNotSame($conns['body'][0], $conns['body'][1], '대조: 본문 있는 2xx 를 끊었다면 다음 요청은 새 연결이어야 한다');
    }

    /** 오류 본문은 상한에서 잘린다 — 클래스와 상태는 그대로, 서버는 64 MiB 를 다 쓰지 못한다. */
    #[DataProvider('errorRows')]
    public function testAnErrorBodyIsCutAtTheCap(string $name, int $status, string $transport): void
    {
        [$method, $path, $call] = self::errorCalls()[$name];
        self::route([$method . ' ' . $path => ['status' => $status, 'head' => self::ERROR_HEAD, 'pad' => self::HUGE - strlen(self::ERROR_HEAD)]]);
        $this->useTransport($transport);
        $admin = new AdminClient(self::config());

        gc_collect_cycles();
        memory_reset_peak_usage();
        $before = memory_get_usage();
        [$result, $ms] = self::timed(static fn () => $call($admin));
        $peak = memory_get_peak_usage() - $before;
        $sent = self::sent($method, $path);

        self::note(sprintf('[%s] %s %d: %d ms · peak %d · server wrote %s · %s', $transport, $name, $status, $ms, $peak, var_export($sent, true), self::describe($result)));
        self::assertInstanceOf($status === 404 ? KeycloakNotFoundError::class : KeycloakAdminError::class, $result, self::describe($result));
        self::assertSame($status, $result->getStatusCode());
        self::assertNotNull($sent);
        self::assertLessThan(self::HUGE, $sent, "서버가 $sent 바이트를 다 썼다 — 오류 본문을 끝까지 읽었다");
    }

    /** 상한을 넘긴 뒤 멈춘 오류 본문 — 나머지를 기다리지 않고 그 상태로 끝난다. */
    #[DataProvider('errorCallRows')]
    public function testAnErrorBodyPastTheCapThatStallsEndsWithoutWaiting(string $name, string $transport): void
    {
        [$method, $path, $call] = self::errorCalls()[$name];
        self::route([$method . ' ' . $path => ['status' => 404, 'head' => self::ERROR_HEAD, 'pad' => 2 * self::CAP, 'stall' => self::CAP + 1]]);
        $this->useTransport($transport);
        $admin = new AdminClient(self::config(self::STALL_TIMEOUT));

        [$result, $ms] = self::timed(static fn () => $call($admin));

        self::note(sprintf('[%s] %s past the cap, stalled: %d ms · %s', $transport, $name, $ms, self::describe($result)));
        self::assertInstanceOf(KeycloakNotFoundError::class, $result, self::describe($result));
    }

    /**
     * 본문 중간에 끊긴 전송 — 미들웨어는 자기가 끊지 않은 거부를 그대로 넘긴다(`KeycloakTransportError`). 상한 아래에서 끊긴 오류
     * 본문도 그렇다(curl). 스트림 처리기는 Content-Length 보다 일찍 끝난 본문을 끝으로 받으므로(Guzzle `StreamHandler::drain`) 그 칸은
     * 상태로 고른다. 쓰기의 2xx 는 본문을 받지 않으므로 끊겨도 성공이다 — 예전에는 curl 칸만 전송 오류였다.
     *
     * @return array<string, array{string, int, string, class-string<\Throwable>|null}>
     */
    public static function brokenRows(): array
    {
        return [
            'users.get 200' => ['users.get', 200, 'curl', KeycloakTransportError::class],
            'users.get 404' => ['users.get', 404, 'curl', KeycloakTransportError::class],
            'users.get 404 · stream' => ['users.get', 404, 'stream', KeycloakNotFoundError::class],
            'users.update 404' => ['users.update', 404, 'curl', KeycloakTransportError::class],
            'users.update 404 · stream' => ['users.update', 404, 'stream', KeycloakNotFoundError::class],
            'users.update 200' => ['users.update', 200, 'curl', null],
            'users.update 200 · stream' => ['users.update', 200, 'stream', null],
        ];
    }

    /** @param class-string<\Throwable>|null $want */
    #[DataProvider('brokenRows')]
    public function testATransferThatBreaksMidBodyKeepsItsClass(string $name, int $status, string $transport, ?string $want): void
    {
        [$method, $path, $call] = self::errorCalls()[$name];
        $head = $status === 200 ? '{"id":"u1","username":"u"' : self::ERROR_HEAD;
        self::route([$method . ' ' . $path => ['status' => $status, 'head' => $head, 'pad' => 4096, 'stall' => 100, 'close' => true]]);
        $this->useTransport($transport);
        $admin = new AdminClient(self::config());

        [$result, $ms] = self::timed(static fn () => $call($admin));

        self::note(sprintf('[%s] %s %d broken mid-body: %d ms · %s', $transport, $name, $status, $ms, self::describe($result)));
        if ($want === null) {
            self::assertNotInstanceOf(\Throwable::class, $result, self::describe($result));
        } else {
            self::assertInstanceOf($want, $result, self::describe($result));
        }
    }

    /** `raw()` 의 오류 본문도 상한에서 잘린다 — 탈출구는 Guzzle 의 예외를 그대로 넘기고, 그 응답의 본문이 상한이다. */
    public function testARawErrorBodyIsCutAtTheCap(): void
    {
        self::route(['GET ' . self::BASE . '/users/u1' => ['status' => 404, 'head' => self::ERROR_HEAD, 'pad' => self::HUGE - strlen(self::ERROR_HEAD)]]);
        $raw = (new AdminClient(self::config()))->raw();

        try {
            $raw->users()->get('r', 'u1');
            self::fail('404 인데 돌아왔다');
        } catch (ClientException $e) {
            self::assertSame(404, $e->getResponse()->getStatusCode());
            self::assertSame(self::CAP, strlen((string) $e->getResponse()->getBody()));
        }
        self::assertLessThan(self::HUGE, self::sent('GET', self::BASE . '/users/u1'));
    }

    /**
     * gzip 오류 본문도 **푼** 바이트로 상한에서 잘린다 — 푸는 것은 싱크 아래(curl · psr7 `InflateStream`)다. 소비자는 Accept-Encoding 을
     * 정할 수 없다(fschmtt 가 요청 머리를 받지 않는다). 64 MiB 공백을 압축한 본문.
     */
    #[DataProvider('transports')]
    public function testAGzipErrorBodyIsCutAtTheCapDecoded(string $transport): void
    {
        self::route(['GET ' . self::BASE . '/users/u1' => ['status' => 404, 'head' => self::ERROR_HEAD, 'pad' => self::HUGE - strlen(self::ERROR_HEAD), 'gzip' => true]]);
        $this->useTransport($transport);
        $raw = (new AdminClient(self::config()))->raw();

        gc_collect_cycles();
        memory_reset_peak_usage();
        $before = memory_get_usage();
        [$result, $ms] = self::timed(static fn () => $raw->users()->get('r', 'u1'));
        $peak = memory_get_peak_usage() - $before;

        $body = $result instanceof ClientException ? (string) $result->getResponse()->getBody() : '';
        self::note(sprintf('[%s] gzip 404: %d ms · peak %d · body %d · %s', $transport, $ms, $peak, strlen($body), self::describe($result)));
        self::assertInstanceOf(ClientException::class, $result, self::describe($result));
        self::assertSame(404, $result->getResponse()->getStatusCode());
        self::assertSame(self::CAP, strlen($body));
        self::assertStringStartsWith(self::ERROR_HEAD, $body, '푼 바이트가 아니다');
    }

    /** GET 의 2xx 는 상한 없이 끝까지 읽는다 — 사용자 목록은 정당하게 크다. */
    public function testASuccessBodyAGetUsesIsReadWhole(): void
    {
        $users = [];
        for ($i = 0; strlen((string) json_encode($users)) <= self::CAP + 4096; $i++) {
            $users[] = ['id' => sprintf('%012d', $i), 'username' => sprintf('user-%012d', $i)];
        }
        self::route(['GET ' . self::BASE . '/users' => ['head' => (string) json_encode($users)]]);

        $found = (new AdminClient(self::config()))->users()->search();

        self::assertGreaterThan(self::CAP, strlen((string) json_encode($users)), '본문이 상한을 넘어야 이 시험이 뜻을 갖는다');
        self::assertCount(count($users), $found);
    }

    /**
     * 토큰 응답이 상한 + 1 바이트를 보내고 멈추면 곧바로 거부한다 — 그 바이트를 담은 쓰기에서 전송을 끊는다(등록부 T2 · php 만 읽기
     * 타임아웃까지 기다렸다).
     *
     * @return array<string, array{string, string}>
     */
    public static function tokenLanes(): array
    {
        $rows = [];
        foreach (['client credentials', 'admin token'] as $lane) {
            foreach (['curl', 'stream'] as $transport) {
                $rows[$transport === 'curl' ? $lane : "$lane · stream"] = [$lane, $transport];
            }
        }

        return $rows;
    }

    #[DataProvider('tokenLanes')]
    public function testATokenResponsePastTheCapThatStallsIsRefusedAtOnce(string $lane, string $transport): void
    {
        $token = '/realms/r/protocol/openid-connect/token';
        self::route(['POST ' . $token => ['head' => '{"access_token":"x","token_type":"Bearer","expires_in":300}', 'pad' => 2 * self::CAP, 'stall' => self::CAP + 1]]);
        $this->useTransport($transport);
        $cfg = self::config(self::STALL_TIMEOUT);
        $call = $lane === 'admin token'
            ? static fn () => (new AdminClient($cfg))->users()->search()
            : static fn () => KeycloakClient::create($cfg)->auth()->clientCredentialsToken();

        [$result, $ms] = self::timed($call);

        self::note(sprintf('[%s] %s past the cap, stalled: %d ms · %s', $transport, $lane, $ms, self::describe($result)));
        self::assertInstanceOf(KeycloakTransportError::class, $result, self::describe($result));
        self::assertLessThan(2000, $ms, "$lane: 상한을 넘은 뒤에도 {$ms} ms 를 기다렸다 — 읽기 타임아웃까지 붙들렸다");
    }

    /**
     * fschmtt 가 GET 이 아닌 요청의 응답 본문을 읽지 않는다는 전제 — 이 SDK 가 그 본문을 받지 않는 근거다(파사드 표시 없이 HTTP 층에서
     * 고른다). 명령은 응답을 버리고(`CommandExecutor::executeCommand(): void`), 조회는 GET 뿐이며, `Keycloak` 은 HTTP 클라이언트를
     * 내보이지 않는다(`raw()` 소비자도 그 본문에 닿지 못한다). ⚠️ fschmtt 핀(composer.json)이 움직이면 이 시험이 먼저 본다.
     */
    public function testFschmttNeverReadsTheBodyOfARequestThatIsNotAGet(): void
    {
        $execute = new \ReflectionMethod(CommandExecutor::class, 'executeCommand');
        self::assertSame('void', (string) $execute->getReturnType());
        self::assertSame(Method::GET, (new \ReflectionClass(Query::class))->newInstanceWithoutConstructor()->getMethod());
        foreach ((new \ReflectionClass(Keycloak::class))->getMethods(\ReflectionMethod::IS_PUBLIC) as $m) {
            $type = (string) $m->getReturnType();
            self::assertStringNotContainsString('Http\\Client', $type, "Keycloak::{$m->getName()} 가 HTTP 클라이언트를 내보인다");
            self::assertStringNotContainsString('ClientInterface', $type, "Keycloak::{$m->getName()} 가 HTTP 클라이언트를 내보인다");
        }
    }
}
