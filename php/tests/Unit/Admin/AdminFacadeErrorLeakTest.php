<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit\Admin;

use Fschmtt\Keycloak\Builder;
use Fschmtt\Keycloak\Collection\CredentialCollection;
use Fschmtt\Keycloak\Http\Criteria;
use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\OAuth\GrantType;
use Fschmtt\Keycloak\Representation\Client;
use Fschmtt\Keycloak\Representation\Credential;
use Fschmtt\Keycloak\Representation\Group;
use Fschmtt\Keycloak\Representation\Realm;
use Fschmtt\Keycloak\Representation\Role;
use Fschmtt\Keycloak\Representation\User;
use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Exception\ClientException;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Exception\ServerException;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Promise\Create;
use GuzzleHttp\Promise\PromiseInterface;
use GuzzleHttp\Psr7\Response;
use PHPUnit\Framework\TestCase;
use Psr\Http\Message\RequestInterface;
use Xzawed\Keycloak\Admin\AdminClient;
use Xzawed\Keycloak\Exception\KeycloakAdminError;
use Xzawed\Keycloak\Exception\KeycloakConflictError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\Exception\SanitizedCause;

/**
 * admin 파사드가 던지는 오류가 **보낸 것**(client secret · Bearer · representation)과 **받은 오류 본문**을 찍지 않는다 —
 * admin 의 자기 토큰 부여(fschmtt 가 한다)와 admin 요청이 실패할 때.
 *
 * `HostilePathMatrixTest` 는 토큰 **응답** 변형을 계급에 붙이고, 그 칸의 카나리아는 응답 속 값뿐이다. 여기서는 요청 쪽을
 * 잰다: client_credentials 폼의 `client_secret` · admin 요청의 `Authorization: Bearer` · admin REST 오류 본문 · 보낸
 * representation(비밀번호·client secret) · 전송 실패. 실제 스택(fschmtt Builder → Client → Guzzle, 핸들러만 가짜 —
 * `RolesRenameTest` 와 같은 조립)을 태워 Guzzle 이 **미들웨어 안에서** 만든 예외를 그대로 받는다. 손으로 만든
 * `ClientException` 은 트레이스에 Guzzle·fschmtt 프레임이 없어 이 누출을 못 본다(`ErrorTranslationTest` 의 한계).
 *
 * 메서드는 손 목록이 아니다 — `AdminClient` 가 내주는 자원 클래스마다 공개 메서드 전부를 리플렉션으로 뽑고, 인자는 타입으로
 * 합성한다(모르는 타입이면 실패한다). 새 파사드 메서드는 저절로 들어온다.
 *
 * 디버깅 정보는 지운 만큼만 지웠는지 함께 본다(`modes()`): 예외 타입 · `getStatusCode()` · 토큰 부여의 OAuth `error` 코드
 * (`OAuthErrorCode` 모양일 때) · 원인의 원본 클래스명.
 *
 * ⚠️ 하네스 상태는 정적이고, 인자를 넘기는 하네스 프레임(`invoke`)은 `#[\SensitiveParameter]` 로 가린다 — 그래야 찍힌 것이
 * SDK 프레임의 것이다. 트레이스 인자는 `zend.exception_ignore_args=0` 에서 잰다(운영 php.ini 는 1 이라 안 모은다).
 */
final class AdminFacadeErrorLeakTest extends TestCase
{
    private const SERVER = 'http://kc.test';
    private const REALM = 'r';
    private const TOKEN_PATH = '/realms/r/protocol/openid-connect/token';
    // 카나리아 — 앞 10 자가 서로 달라 접두 적중이 어느 것인지 가린다.
    private const SECRET = 'ADMsecret-client-secret-canary';
    private const BODY = 'ADMbody0-echoed-error-body-canary';
    private const INPUT = 'ADMinput-sent-representation-canary';

    private static string $mode = '';
    private static string $bearer = '';
    /** @var list<string> 가짜 IdP 가 받은 요청 `메서드 경로` */
    private static array $sent = [];

    protected function setUp(): void
    {
        ini_set('zend.exception_ignore_args', '0');
        $b64 = static fn (string $v): string => rtrim(strtr(base64_encode($v), '+/', '-_'), '=');
        // fschmtt 는 access_token 을 lcobucci 로 파싱하고(서명은 검증 안 한다) exp 로 만료를 본다 — 형태만 맞춘 JWT.
        self::$bearer = $b64('{"alg":"RS256","typ":"JWT"}') . '.'
            . $b64((string) json_encode(['exp' => time() + 300, 'iat' => time(), 'jti' => 'ADMbearer-jti-canary'])) . '.'
            . $b64('ADMbearer-signature-canary');
    }

    /**
     * 실패 방식 => 기대. `status` 는 `KeycloakAdminError::getStatusCode()`, `cause` 는 첫 원인의 [원본 클래스, 메시지 머리,
     * 메시지 꼬리] — 원인은 하위 예외 원본이 아니라 `SanitizedCause` 사본이다. `reach` 는 실패가 난 자리(공허성 검사).
     *
     * @return array<string, array{class: class-string<\Throwable>, status: ?int, message: string, cause: array{0: class-string<\Throwable>, 1: string, 2: string}, reach: string}>
     */
    private static function modes(): array
    {
        $tokenUrl = self::SERVER . self::TOKEN_PATH;
        $withheld = '(message withheld: thrown outside the audited libraries)';

        return [
            // 오류 본문이 토큰·설명을 되울린다 — 메시지에는 상태와 코드 모양의 error 만.
            'token 401 · error body echoes' => ['class' => KeycloakAdminError::class, 'status' => 401,
                'message' => 'admin token request failed: HTTP 401 (invalid_client)',
                'cause' => [ClientException::class, "HTTP 401 from POST $tokenUrl (response body withheld)", ''], 'reach' => 'token'],
            // 200 인데 JSON 이 아니다 — fschmtt 의 json_decode 가 본문을 인자로 쥔 채 던진다.
            'token 200 · non-JSON body' => ['class' => KeycloakAdminError::class, 'status' => null,
                'message' => 'admin request failed unexpectedly',
                'cause' => [\JsonException::class, $withheld, ''], 'reach' => 'token'],
            'token unreachable' => ['class' => KeycloakTransportError::class, 'status' => null,
                'message' => 'admin request unreachable',
                'cause' => [ConnectException::class, $withheld, ''], 'reach' => 'token'],
            // admin REST 의 오류 본문은 OAuth 응답이 아니다 — 코드 모양의 error 가 있어도 싣지 않는다.
            'admin 409 · error body echoes' => ['class' => KeycloakConflictError::class, 'status' => 409,
                'message' => 'admin request failed: HTTP 409',
                'cause' => [ClientException::class, 'HTTP 409 from ', ' (response body withheld)'], 'reach' => 'admin'],
            'admin 500 · HTML body' => ['class' => KeycloakAdminError::class, 'status' => 500,
                'message' => 'admin request failed: HTTP 500',
                'cause' => [ServerException::class, 'HTTP 500 from ', ' (response body withheld)'], 'reach' => 'admin'],
            'admin unreachable' => ['class' => KeycloakTransportError::class, 'status' => null,
                'message' => 'admin request unreachable',
                'cause' => [ConnectException::class, $withheld, ''], 'reach' => 'admin'],
        ];
    }

    /** 실제 fschmtt 스택 — 핸들러만 가짜다. ⚠️ 핸들러는 아무것도 캡처하지 않는다(정적 상태와 상수만 읽는다). */
    private static function keycloak(): Keycloak
    {
        $handler = static function (RequestInterface $req): PromiseInterface {
            $path = $req->getUri()->getPath();
            self::$sent[] = $req->getMethod() . ' ' . $path;
            $json = ['Content-Type' => 'application/json'];
            if ($path === self::TOKEN_PATH) {
                return match (self::$mode) {
                    'token 401 · error body echoes' => Create::promiseFor(new Response(401, $json, (string) json_encode([
                        'error' => 'invalid_client', 'error_description' => self::BODY, 'access_token' => self::BODY,
                    ]))),
                    'token 200 · non-JSON body' => Create::promiseFor(new Response(200, $json, self::BODY)),
                    'token unreachable' => Create::rejectionFor(new ConnectException('connection refused', $req)),
                    default => Create::promiseFor(new Response(200, $json, (string) json_encode([
                        'access_token' => self::$bearer, 'expires_in' => 300, 'token_type' => 'Bearer',
                    ]))),
                };
            }
            if ($path === '/admin/serverinfo') {
                // fschmtt 는 첫 자원 접근 전에 서버 버전을 묻는다 — 여기서 실패하면 자원 엔드포인트에 못 닿는다.
                return Create::promiseFor(new Response(200, $json, '{"systemInfo":{"version":"26.0.0"}}'));
            }

            return match (self::$mode) {
                'admin 409 · error body echoes' => Create::promiseFor(new Response(409, $json, (string) json_encode([
                    'error' => 'conflict_code', 'errorMessage' => self::BODY,
                ]))),
                'admin 500 · HTML body' => Create::promiseFor(new Response(500, ['Content-Type' => 'text/html'], '<p>' . self::BODY . '</p>')),
                'admin unreachable' => Create::rejectionFor(new ConnectException('connection refused', $req)),
                default => Create::promiseFor(new Response(204)),
            };
        };

        return (new Builder())
            ->withBaseUrl(self::SERVER)
            ->withGrantType(GrantType::clientCredentials(clientId: 'c', clientSecret: self::SECRET, realm: self::REALM))
            ->withHttpClient(new GuzzleClient(['handler' => HandlerStack::create($handler)]))
            ->build();
    }

    /**
     * `AdminClient` 가 내주는 자원 클래스의 공개 메서드 전부 — `짧은클래스::메서드 => [클래스, 메서드]`.
     *
     * @return array<string, array{0: class-string, 1: string}>
     */
    private static function facadeMethods(): array
    {
        $out = [];
        foreach ((new \ReflectionClass(AdminClient::class))->getMethods(\ReflectionMethod::IS_PUBLIC) as $accessor) {
            $type = $accessor->getReturnType();
            if (!$type instanceof \ReflectionNamedType || !str_starts_with($type->getName(), 'Xzawed\\Keycloak\\Admin\\')) {
                continue;   // raw() 는 fschmtt 를 그대로 내준다(§4(b) 탈출구) — 파사드가 아니다.
            }
            $class = $type->getName();
            self::assertTrue(class_exists($class));
            $rc = new \ReflectionClass($class);
            foreach ($rc->getMethods(\ReflectionMethod::IS_PUBLIC) as $m) {
                if (!$m->isStatic() && !str_starts_with($m->getName(), '__') && $m->getDeclaringClass()->getName() === $class) {
                    $out[$rc->getShortName() . '::' . $m->getName()] = [$class, $m->getName()];
                }
            }
        }
        ksort($out);

        return $out;
    }

    /**
     * 타입으로 합성한 인자 — representation 은 카나리아를 품는다(소비자가 보내는 비밀번호·client secret 자리).
     * `$str` 는 문자열 자리의 값이다(생성자는 realm, 메서드는 식별자).
     */
    private static function arg(\ReflectionParameter $p, Keycloak $kc, string $str): mixed
    {
        $type = $p->getType();
        $name = $type instanceof \ReflectionNamedType ? $type->getName() : '(union)';

        return match ($name) {
            Keycloak::class => $kc,
            'string' => $str,
            Criteria::class => null,
            User::class => new User(username: 'u1', credentials: new CredentialCollection([new Credential(type: 'password', value: self::INPUT)])),
            Client::class => new Client(id: 'c-uuid', clientId: 'c2', secret: self::INPUT),
            Realm::class => new Realm(realm: 'r2', displayName: self::INPUT),
            Group::class => new Group(name: self::INPUT),
            Role::class => new Role(name: 'role-1', description: self::INPUT),
            default => self::fail("{$p->getDeclaringClass()?->getName()}::{$p->getDeclaringFunction()->getName()} 의 인자 \${$p->getName()}: 합성할 줄 모르는 타입 $name — 여기 더하라"),
        };
    }

    /**
     * ⚠️ 인자를 가린다 — 가리지 않으면 이 프레임이 representation 을 쥐고 SDK 와 무관한 누출이 잡힌다. `$call` 은
     * `ReflectionMethod::getClosure()` 라 그 호출 프레임이 곧 파사드 메서드의 프레임이다(사이에 리플렉션 프레임이 없다).
     *
     * @param list<mixed> $args
     */
    private static function invoke(\Closure $call, #[\SensitiveParameter] array $args): ?\Throwable
    {
        try {
            $call(...$args);
        } catch (\Throwable $e) {
            return $e;
        }

        return null;
    }

    /** @return list<string> 정적 상태를 함수로 읽는다 — 핸들러가 바꾸는 것을 정적 분석이 「항상 빈 배열」로 좁히지 않게. */
    private static function sent(): array
    {
        return self::$sent;
    }

    /** @return array<string, string> 찍는 길 => 출력. `(string)` 은 원인 사슬 전부의 메시지·트레이스를 담는다. */
    private static function renderings(\Throwable $e): array
    {
        ob_start();
        var_dump($e);
        $out = ['getMessage' => $e->getMessage(), '(string)' => (string) $e, 'getTraceAsString' => $e->getTraceAsString(),
            'var_dump' => (string) ob_get_clean(), 'print_r' => print_r($e, true)];
        for ($l = $e->getPrevious(), $i = 1; $l !== null; $l = $l->getPrevious(), $i++) {
            $out["cause[$i]"] = $l::class . ': ' . $l->getMessage() . "\n" . $l->getTraceAsString();
        }

        return $out;
    }

    /**
     * 한 칸(메서드 × 실패 방식)의 위반 — 비면 통과.
     *
     * @param array{0: class-string, 1: string} $target
     * @param array{class: class-string<\Throwable>, status: ?int, message: string, cause: array{0: class-string<\Throwable>, 1: string, 2: string}, reach: string} $want
     * @return list<string>
     */
    private static function cell(array $target, string $mode, array $want): array
    {
        [$class, $method] = $target;
        self::$mode = $mode;
        self::$sent = [];
        $kc = self::keycloak();
        $ctor = (new \ReflectionClass($class))->getConstructor();
        $receiver = new $class(...array_map(static fn (\ReflectionParameter $p): mixed => self::arg($p, $kc, self::REALM), $ctor?->getParameters() ?? []));
        $m = new \ReflectionMethod($class, $method);
        $args = array_map(static fn (\ReflectionParameter $p): mixed => self::arg($p, $kc, 'id-1'), $m->getParameters());
        $e = self::invoke($m->getClosure($receiver), $args);

        $why = [];
        $reached = array_filter(self::sent(), static fn (string $s): bool => $want['reach'] === 'token'
            ? $s === 'POST ' . self::TOKEN_PATH
            : !str_ends_with($s, self::TOKEN_PATH) && $s !== 'GET /admin/serverinfo');
        if ($reached === []) {
            $why[] = '실패를 낼 자리에 안 닿았다(공허): ' . implode(', ', self::sent());
        }
        if ($e === null) {
            return [...$why, '오류 없이 끝났다'];
        }
        if ($e::class !== $want['class']) {
            $why[] = 'SDK 타입이 ' . $e::class . " — 기대 {$want['class']}";
        }
        if ($e instanceof KeycloakAdminError && $e->getStatusCode() !== $want['status']) {
            $why[] = 'getStatusCode() ' . var_export($e->getStatusCode(), true) . ' — 기대 ' . var_export($want['status'], true);
        }
        if ($e->getMessage() !== $want['message']) {
            $why[] = 'getMessage() ' . json_encode($e->getMessage()) . ' — 기대 ' . json_encode($want['message']);
        }
        for ($l = $e, $d = 0; $l !== null; $l = $l->getPrevious(), $d++) {
            if (!str_starts_with($l::class, 'Xzawed\\Keycloak\\')) {
                $why[] = "원인 사슬 [$d] 이 하위 예외 원본 " . $l::class . '(§4)';
            }
        }
        $cause = $e->getPrevious();
        [$origin, $head, $tail] = $want['cause'];
        if (!$cause instanceof SanitizedCause || $cause->originalClass !== $origin) {
            $why[] = '첫 원인이 ' . ($cause === null ? 'null' : $cause::class) . " — 기대 $origin 의 SanitizedCause";
        } elseif (!str_starts_with($cause->getMessage(), "$origin: $head") || !str_ends_with($cause->getMessage(), $tail)) {
            $why[] = '원인 메시지 ' . json_encode($cause->getMessage()) . ' — 기대 ' . json_encode("{$origin}: {$head}…{$tail}");
        }
        $canaries = ['SECRET' => [self::SECRET, true], 'BODY' => [self::BODY, true], 'INPUT' => [self::INPUT, true], 'BEARER' => [self::$bearer, false]];
        foreach (self::renderings($e) as $how => $out) {
            foreach ($canaries as $name => [$value, $prefix]) {
                if (str_contains($out, $value)) {
                    $why[] = "$name 가 $how 에 원문으로 찍혔다";
                } elseif ($prefix && str_contains($out, substr($value, 0, 10))) {
                    $why[] = "$name 가 $how 에 앞 10 자로 찍혔다";
                }
            }
        }

        return $why;
    }

    public function testAdminFailuresDoNotPrintSecretsBearerBodiesOrInputs(): void
    {
        $methods = self::facadeMethods();
        // 공허성 — 걷기가 다섯 자원을 다 찾았는가(0 이면 아래 루프는 아무것도 안 재며 통과한다).
        self::assertGreaterThanOrEqual(5, count(array_unique(array_column($methods, 0))), '자원 클래스를 못 찾았다');
        $fails = [];
        $cells = 0;
        foreach ($methods as $label => $target) {
            foreach (self::modes() as $mode => $want) {
                $cells++;
                foreach (self::cell($target, $mode, $want) as $why) {
                    $fails[] = "$label / $mode: $why";
                }
            }
        }
        self::assertGreaterThan(0, $cells);
        self::assertSame([], $fails, sprintf("admin 오류 %d 칸 중 위반 %d 건:\n%s", $cells, count($fails), implode("\n", $fails)));
    }
}
