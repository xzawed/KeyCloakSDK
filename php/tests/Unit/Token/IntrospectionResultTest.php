<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit\Token;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Token\IntrospectionResult;

final class IntrospectionResultTest extends TestCase
{
    /** @return iterable<string, array{array<string, mixed>}> */
    public static function responsesWithoutABooleanActive(): iterable
    {
        yield 'missing' => [['username' => 'alice']];
        yield 'null' => [['active' => null]];
        yield 'string "false"' => [['active' => 'false']];
        yield 'string "true"' => [['active' => 'true']];
        yield 'string "0"' => [['active' => '0']];
        yield 'int 1' => [['active' => 1]];
        yield 'int 0' => [['active' => 0]];
        yield 'array' => [['active' => [true]]];
    }

    /**
     * RFC 7662 §2.2 — `active` 는 REQUIRED 인 boolean 이다. 수정 전(게시본 1.0.0–1.5.2)에는 `(bool)` 캐스트라 `"false"` 와 `1` 이
     * **활성**, 없는 것은 비활성이었다(2026-11-10 실측). `introspect()` 만이 아니라 공개 파서 자체가 거부해야 한다.
     *
     * @param array<string, mixed> $response
     */
    #[DataProvider('responsesWithoutABooleanActive')]
    public function testAResponseWithoutABooleanActiveIsRefused(array $response): void
    {
        $this->expectException(KeycloakAuthError::class);
        $this->expectExceptionMessage('introspection response has no boolean active member');
        IntrospectionResult::fromArray($response);
    }

    public function testFromArrayActive(): void
    {
        $ir = IntrospectionResult::fromArray(['active' => true, 'username' => 'alice', 'client_id' => 'it-client']);
        self::assertTrue($ir->active);
        self::assertSame('alice', $ir->username);
        self::assertSame('it-client', $ir->clientId);
    }

    public function testInactiveDefaults(): void
    {
        $ir = IntrospectionResult::fromArray(['active' => false]);
        self::assertFalse($ir->active);
        self::assertNull($ir->username);
        self::assertNull($ir->clientId);
    }

    public function testDirectConstructorDefaults(): void
    {
        // fromArray()가 아닌 직접 생성자 경로 — username/clientId/claims 기본값(null/[])을 검증한다.
        $ir = new IntrospectionResult(active: true);
        self::assertTrue($ir->active);
        self::assertNull($ir->username);
        self::assertNull($ir->clientId);
        self::assertSame([], $ir->claims);
    }

    public function testFromArrayCoercesNonStringScalarUsername(): void
    {
        // toStr()의 int/float/bool 분기 노출 — 일부 IdP는 username/client_id를 문자열이 아닌
        // 그대로 내려보낼 수 있다(신뢰된 응답이라도 스칼라 타입 전제가 항상 문자열은 아님).
        $ir = IntrospectionResult::fromArray(['active' => true, 'username' => 42]);
        self::assertSame('42', $ir->username);
    }
}
