<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Integration;

use Fschmtt\Keycloak\Representation\Client as ClientRepresentation;
use Fschmtt\Keycloak\Representation\Group;
use Fschmtt\Keycloak\Representation\Realm;
use Fschmtt\Keycloak\Representation\Role;
use Fschmtt\Keycloak\Representation\User;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;
use Xzawed\Keycloak\KeycloakClient;
use Xzawed\Keycloak\KeycloakConfig;

/**
 * E2E — 실제 Keycloak 26.6 컨테이너(realm import)로 전 흐름 검증:
 * client-credentials 토큰 → validate(다중 aud) → introspect → user CRUD → delete 후 NotFound →
 * admin 다섯 자원(users·clients·realms·roles·groups)의 create/get/list/update/delete 성공 경로 → raw() 탈출구 스모크.
 *
 * users 는 testFullFlow 가 돈다(list = `search` — `findIdByUsername`). 나머지 넷은 자원마다 기록 하나의 생명주기다 —
 * 무작위 접미 이름으로 만들고 · 조회해 설정한 필드를 단언하고 · 목록에 드는지 보고 · 고친 뒤 다시 조회해 새 값을
 * 단언하고 · 지운 뒤 조회가 `KeycloakNotFoundError` 인지 본다. 단언이 실패해도 기록이 남지 않게 정리는 `finally` 가 한다.
 * realm 생성은 master 전용이라 realm 생명주기만 master 서비스계정으로 돈다({@see KeycloakContainerTrait} 의 상수).
 *
 * 컨테이너 라이프사이클은 {@see KeycloakContainerTrait}(docker CLI 폴백) 참고.
 */
final class FullFlowIT extends TestCase
{
    use KeycloakContainerTrait;

    private static KeycloakClient $client;

    public static function setUpBeforeClass(): void
    {
        self::startKeycloak();
        self::$client = KeycloakClient::create(new KeycloakConfig(
            serverUrl: self::$baseUrl,
            realm: 'it-realm',
            clientId: 'it-client',
            clientSecret: 'it-secret',
        ));
    }

    public static function tearDownAfterClass(): void
    {
        self::stopKeycloak();
    }

    public function testFullFlow(): void
    {
        // 1) client-credentials 토큰
        $token = self::$client->auth()->clientCredentialsToken();
        self::assertNotSame('', $token->accessToken);
        self::assertGreaterThan(0, $token->expiresIn);

        // 2) validate(자체강화 RS256 검증 — 실제 KC JWKS 조회, 다중 aud 수용, it-client 포함)
        $validated = self::$client->auth()->validate($token->accessToken);
        self::assertContains('it-client', $validated->audience);
        self::assertStringEndsWith('/realms/it-realm', $validated->issuer);

        // 3) introspect(RFC 7662)
        $introspected = self::$client->auth()->introspect($token->accessToken);
        self::assertTrue($introspected->active);

        // 4) user CRUD
        $users = self::$client->admin()->users();
        $username = 'php-it-' . bin2hex(random_bytes(4));
        $users->create(new User(username: $username, email: "{$username}@example.com", enabled: true));

        $userId = $users->findIdByUsername($username);
        self::assertNotNull($userId);
        self::assertSame($username, $users->get($userId)->getUsername());

        $updatedEmail = "upd-{$username}@example.com";
        $users->update($userId, $users->get($userId)->withEmail($updatedEmail));
        self::assertSame($updatedEmail, $users->get($userId)->getEmail());

        $users->delete($userId);

        // 5) delete 후 조회 → NotFound
        $this->expectException(KeycloakNotFoundError::class);
        $users->get($userId);
    }

    public function testAdminClientCrud(): void
    {
        $clients = self::$client->admin()->clients();
        $clientUuid = self::uuidV4();
        $clientId = 'php-it-client-' . bin2hex(random_bytes(4));

        try {
            // fschmtt의 import()는 POST 후 $client->getId()로 재-GET한다(Location 헤더 미사용) —
            // 따라서 id를 미리 생성해 넘겨야 한다(ClientsResource 문서화된 제약, Task 9와 동형).
            $imported = $clients->import(new ClientRepresentation(
                id: $clientUuid,
                clientId: $clientId,
                enabled: true,
                publicClient: true,
                protocol: 'openid-connect',
            ));
            self::assertSame($clientUuid, $imported->getId());
            self::assertSame($clientId, $imported->getClientId());

            $fetched = $clients->get($clientUuid);
            self::assertSame($clientId, $fetched->getClientId());

            // list — 방금 만든 client 의 uuid 가 목록에 든다.
            $listed = array_map(static fn (ClientRepresentation $c): ?string => $c->getId(), $clients->all()->all());
            self::assertContains($clientUuid, $listed);

            $clients->update($clientUuid, $fetched->withDescription('updated-by-it'));
            self::assertSame('updated-by-it', $clients->get($clientUuid)->getDescription());

            $clients->delete($clientUuid);

            $this->expectException(KeycloakNotFoundError::class);
            $clients->get($clientUuid);
        } finally {
            self::deleteIfPresent(static fn () => $clients->delete($clientUuid));
        }
    }

    public function testRoleLifecycle(): void
    {
        $roles = self::$client->admin()->roles();
        $roleName = 'php-it-role-' . bin2hex(random_bytes(4));
        $renamed = "{$roleName}-renamed";

        try {
            // create 는 void(fschmtt) — role 은 이름이 키라 만든 이름으로 바로 조회한다.
            $roles->create(new Role(description: 'created-by-it', name: $roleName));
            $created = $roles->get($roleName);
            self::assertSame($roleName, $created->getName());
            self::assertSame('created-by-it', $created->getDescription());

            $listed = array_map(static fn (Role $r): ?string => $r->getName(), $roles->all()->all());
            self::assertContains($roleName, $listed);

            // update = 이름과 설명을 함께 바꾼다. 경로는 현재 이름 · body 는 새 이름이다(RenamableRoles — fschmtt
            // Roles::update 는 둘을 한 값에서 만들어 rename 을 못 낸다). 그래서 실서버에서 옛 이름이 사라졌는지도 본다.
            $roles->update($roleName, new Role(description: 'updated-by-it', name: $renamed));
            $updated = $roles->get($renamed);
            self::assertSame($renamed, $updated->getName());
            self::assertSame('updated-by-it', $updated->getDescription());
            self::assertNotFound(static fn () => $roles->get($roleName), 'the role under its old name after the rename');

            $roles->delete($renamed);
            self::assertNotFound(static fn () => $roles->get($renamed), 'a deleted role');
        } finally {
            self::deleteIfPresent(static fn () => $roles->delete($roleName));
            self::deleteIfPresent(static fn () => $roles->delete($renamed));
        }
    }

    public function testGroupLifecycle(): void
    {
        $groups = self::$client->admin()->groups();
        $groupName = 'php-it-group-' . bin2hex(random_bytes(4));
        $renamed = "{$groupName}-renamed";
        $groupId = null;

        try {
            // create 는 void 이고 group 의 키는 서버가 매기는 id 다 — 그래서 list 가 get 보다 앞선다(만든 이름으로 id 를 찾는다).
            $groups->create(new Group(name: $groupName));
            $listed = array_values(array_filter(
                $groups->all()->all(),
                static fn (Group $g): bool => $g->getName() === $groupName,
            ));
            self::assertCount(1, $listed);
            $groupId = $listed[0]->getId();
            self::assertNotNull($groupId);

            self::assertSame($groupName, $groups->get($groupId)->getName());

            // rename — 경로는 id, body 에 새 이름.
            $groups->update($groupId, new Group(name: $renamed));
            self::assertSame($renamed, $groups->get($groupId)->getName());

            $groups->delete($groupId);
            self::assertNotFound(static fn () => $groups->get($groupId), 'a deleted group');
        } finally {
            if ($groupId !== null) {
                self::deleteIfPresent(static fn () => $groups->delete($groupId));
            }
        }
    }

    public function testRealmLifecycle(): void
    {
        // `POST /admin/realms` 는 master 전용 — it-realm 의 it-client 로는 403 이다. 그래서 이 생명주기만 컨테이너가
        // 부트스트랩한 master 서비스계정으로 같은 파사드(`KeycloakClient::create()->admin()`)를 만든다. it-realm 은 건드리지 않는다.
        $realms = KeycloakClient::create(new KeycloakConfig(
            serverUrl: self::$baseUrl,
            realm: 'master',
            clientId: self::MASTER_ADMIN_CLIENT_ID,
            clientSecret: self::MASTER_ADMIN_CLIENT_SECRET,
        ))->admin()->realms();
        $realmName = 'php-it-realm-' . bin2hex(random_bytes(4));

        try {
            // import 가 create 다 — POST 뒤 realm 이름으로 재-GET 한 표현을 돌려준다.
            $imported = $realms->import(new Realm(displayName: 'PHP IT realm', enabled: true, realm: $realmName));
            self::assertSame($realmName, $imported->getRealm());

            $fetched = $realms->get($realmName);
            self::assertSame($realmName, $fetched->getRealm());
            self::assertSame('PHP IT realm', $fetched->getDisplayName());
            self::assertTrue($fetched->getEnabled());

            $listed = array_map(static fn (Realm $r): ?string => $r->getRealm(), $realms->all()->all());
            self::assertContains($realmName, $listed);

            $realms->update($realmName, new Realm(displayName: 'PHP IT realm (updated)', realm: $realmName));
            self::assertSame('PHP IT realm (updated)', $realms->get($realmName)->getDisplayName());

            $realms->delete($realmName);
            self::assertNotFound(static fn () => $realms->get($realmName), 'a deleted realm');
        } finally {
            self::deleteIfPresent(static fn () => $realms->delete($realmName));
        }
    }

    public function testRawEscapeHatch(): void
    {
        // raw() 탈출구 스모크 — 하위 fschmtt 클라이언트가 실제로 살아있는지 확인
        self::assertNotSame('', self::$client->admin()->raw()->getBaseUrl());
    }

    private static function uuidV4(): string
    {
        $data = random_bytes(16);
        $data[6] = chr((ord($data[6]) & 0x0f) | 0x40);
        $data[8] = chr((ord($data[8]) & 0x3f) | 0x80);
        $hex = bin2hex($data);

        return sprintf(
            '%s-%s-%s-%s-%s',
            substr($hex, 0, 8),
            substr($hex, 8, 4),
            substr($hex, 12, 4),
            substr($hex, 16, 4),
            substr($hex, 20, 12),
        );
    }

    /**
     * 조회가 SDK 의 NotFound 형으로 떨어지는가. 다른 예외(403 · 전송 실패)는 잡지 않고 그대로 올려 원인을 가리지 않는다.
     *
     * @param callable(): mixed $read
     */
    private static function assertNotFound(callable $read, string $what): void
    {
        $caught = null;
        try {
            $read();
        } catch (KeycloakNotFoundError $e) {
            $caught = $e;
        }
        self::assertInstanceOf(KeycloakNotFoundError::class, $caught, "{$what} must read as KeycloakNotFoundError");
    }

    /**
     * `finally` 정리 — 성공 경로는 이미 지웠으므로 NotFound 가 정상 종착이다. 그 밖의 실패는 삼키지 않는다.
     *
     * @param callable(): mixed $delete
     */
    private static function deleteIfPresent(callable $delete): void
    {
        try {
            $delete();
        } catch (KeycloakNotFoundError) {
            // 이미 없다 — 생명주기가 지웠다.
        }
    }
}
