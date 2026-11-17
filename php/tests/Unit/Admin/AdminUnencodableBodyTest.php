<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit\Admin;

use Fschmtt\Keycloak\Builder;
use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\OAuth\GrantType;
use Fschmtt\Keycloak\Representation\Client;
use Fschmtt\Keycloak\Representation\Group;
use Fschmtt\Keycloak\Representation\Realm;
use Fschmtt\Keycloak\Representation\Role;
use Fschmtt\Keycloak\Representation\User;
use Fschmtt\Keycloak\Type\Map;
use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Promise\Create;
use GuzzleHttp\Promise\PromiseInterface;
use GuzzleHttp\Psr7\Response;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Http\Message\RequestInterface;
use Xzawed\Keycloak\Admin\ClientsResource;
use Xzawed\Keycloak\Admin\GroupsResource;
use Xzawed\Keycloak\Admin\RealmsResource;
use Xzawed\Keycloak\Admin\RolesResource;
use Xzawed\Keycloak\Admin\UsersResource;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\Exception\SanitizedCause;

/**
 * 인코딩 못 하는 representation(잘못된 UTF-8 · NAN · INF)은 **요청 전** `KeycloakTransportError` 다 — node · python 과 같은
 * 문구(등록부 `php-admin-unencodable-body-class`). 전에는 토큰 발급과 serverinfo 를 보낸 뒤 fschmtt 의 직렬화가 던진
 * 예외가 그물 `KeycloakAdminError('admin request failed unexpectedly')`(상태 없음)로 떨어졌다.
 *
 * 실제 fschmtt 스택이고 핸들러만 가짜다 — 보낸 요청을 전부 센다.
 */
final class AdminUnencodableBodyTest extends TestCase
{
    private const MESSAGE = 'admin request failed: the request body could not be encoded as JSON';

    private const TOKEN_PATH = '/realms/r/protocol/openid-connect/token';

    /** @var list<string> */
    private static array $sent = [];

    private static string $bearer = '';

    protected function setUp(): void
    {
        self::$sent = [];
        $b64 = static fn (string $v): string => rtrim(strtr(base64_encode($v), '+/', '-_'), '=');
        // fschmtt 는 access_token 을 lcobucci 로 파싱하고(서명은 검증 안 한다) exp 로 만료를 본다 — 형태만 맞춘 JWT.
        self::$bearer = $b64('{"alg":"RS256","typ":"JWT"}') . '.'
            . $b64((string) json_encode(['exp' => time() + 300, 'iat' => time()])) . '.' . $b64('sig');
    }

    private static function keycloak(): Keycloak
    {
        $handler = static function (RequestInterface $req, array $options): PromiseInterface {
            $path = $req->getUri()->getPath();
            self::$sent[] = $req->getMethod() . ' ' . $path;
            $json = ['Content-Type' => 'application/json'];
            if ($path === self::TOKEN_PATH) {
                return Create::promiseFor(new Response(200, $json, (string) json_encode([
                    'access_token' => self::$bearer, 'expires_in' => 300, 'token_type' => 'Bearer',
                ])));
            }
            if ($path === '/admin/serverinfo') {
                return Create::promiseFor(new Response(200, $json, '{"systemInfo":{"version":"26.0.0"}}'));
            }

            return Create::promiseFor(new Response(204));
        };

        return (new Builder())
            ->withBaseUrl('http://kc.test')
            ->withGrantType(GrantType::clientCredentials(clientId: 'c', clientSecret: 's', realm: 'r'))
            ->withHttpClient(new GuzzleClient(['handler' => HandlerStack::create($handler)]))
            ->build();
    }

    /** @return list<string> 정적 상태를 함수로 읽는다 — 핸들러가 바꾸는 것을 정적 분석이 「항상 빈 배열」로 좁히지 않게. */
    private static function sent(): array
    {
        return self::$sent;
    }

    /**
     * 쓰기 열 자리 — 각 representation 의 문자열 필드 하나에 잘못된 UTF-8, users 는 속성 Map 에 NAN · INF 도.
     *
     * @return array<string, array{\Closure(Keycloak): mixed}>
     */
    public static function unencodable(): array
    {
        $bad = "x\xff";

        return [
            'users.create · invalid UTF-8' => [static fn (Keycloak $kc) => (new UsersResource($kc, 'r'))->create(new User(username: $bad))],
            'users.update · invalid UTF-8' => [static fn (Keycloak $kc) => (new UsersResource($kc, 'r'))->update('u-id', new User(username: $bad))],
            'users.create · NAN attribute' => [static fn (Keycloak $kc) => (new UsersResource($kc, 'r'))->create(new User(username: 'u', attributes: new Map(['k' => [\NAN]])))],
            'users.update · INF attribute' => [static fn (Keycloak $kc) => (new UsersResource($kc, 'r'))->update('u-id', new User(username: 'u', attributes: new Map(['k' => [\INF]])))],
            'clients.import · invalid UTF-8' => [static fn (Keycloak $kc) => (new ClientsResource($kc, 'r'))->import(new Client(id: 'c-uuid', clientId: $bad))],
            'clients.update · invalid UTF-8' => [static fn (Keycloak $kc) => (new ClientsResource($kc, 'r'))->update('c-uuid', new Client(clientId: $bad))],
            'realms.import · invalid UTF-8' => [static fn (Keycloak $kc) => (new RealmsResource($kc))->import(new Realm(realm: 'r2', displayName: $bad))],
            'realms.update · invalid UTF-8' => [static fn (Keycloak $kc) => (new RealmsResource($kc))->update('r2', new Realm(displayName: $bad))],
            'roles.create · invalid UTF-8' => [static fn (Keycloak $kc) => (new RolesResource($kc, 'r'))->create(new Role(name: 'role-1', description: $bad))],
            'roles.update · invalid UTF-8' => [static fn (Keycloak $kc) => (new RolesResource($kc, 'r'))->update('role-1', new Role(name: 'role-2', description: $bad))],
            'groups.create · invalid UTF-8' => [static fn (Keycloak $kc) => (new GroupsResource($kc, 'r'))->create(new Group(name: $bad))],
            'groups.update · invalid UTF-8' => [static fn (Keycloak $kc) => (new GroupsResource($kc, 'r'))->update('g-id', new Group(name: $bad))],
        ];
    }

    /** @param \Closure(Keycloak): mixed $call */
    #[DataProvider('unencodable')]
    public function testAnUnencodableRepresentationIsATransportErrorBeforeAnyRequest(\Closure $call): void
    {
        $kc = self::keycloak();
        try {
            $call($kc);
            self::fail('no exception');
        } catch (KeycloakTransportError $e) {
            self::assertSame(self::MESSAGE, $e->getMessage());
            // 원인은 정화한 사본이다 — 원본의 트레이스 인자는 보내려던 representation 을 쥔다(비밀 자리).
            self::assertInstanceOf(SanitizedCause::class, $e->getPrevious());
        }
        self::assertSame([], self::sent(), '토큰 발급 · serverinfo 도 나가지 않는다');
    }

    /**
     * 대조군 — 같은 자리에 인코딩되는 값이면 요청이 나간다(위 거부가 쓰기 전부를 막는 것이 아님을 보인다). 결과(성공 ·
     * 응답 해석 실패)는 보지 않고 admin 경로로 요청이 갔는지만 본다.
     */
    public function testAnEncodableRepresentationStillReachesTheAdminApi(): void
    {
        $kc = self::keycloak();
        try {
            (new UsersResource($kc, 'r'))->create(new User(username: 'x-ok', attributes: new Map(['k' => [1.5]])));
        } catch (\Throwable) {
            // 결과는 대조의 관심 밖이다.
        }
        self::assertContains('POST /admin/realms/r/users', self::sent());
    }
}
