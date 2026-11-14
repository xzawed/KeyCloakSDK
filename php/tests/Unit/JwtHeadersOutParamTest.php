<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Firebase\JWT\SignatureInvalidException;
use PHPUnit\Framework\TestCase;

/**
 * firebase/php-jwt 의 `&$headers` out-parameter 가 **언제** 채워지는지 — `JwtValidator` 가 그것이 아니라 원문 토큰의
 * 첫 세그먼트를 스스로 풀어 alg 를 거르는 이유를 고정한다(등록부 php-jwt-headers-rationale).
 *
 * 세 곳(`JwtValidator` 주석 · `.claude/rules/php.md` · `php/README.md`)이 「디코드가 성공한 뒤에야 채워진다」고 적었는데
 * 핀된 원본(v7.2.1 `src/JWT.php`)은 정반대다 — 헤더 JSON 을 푼 **직후**(본문 검사 · 서명 검증 전에) 채우고, 호출자가
 * null 이 아닌 객체를 넘겼을 때만 채운다. 그래도 사전 게이트가 될 수 없는 것은 그 자리가 `decode` **안**이라서다 —
 * `decode` 는 이미 키를 받으므로, 키를 고르기 전에 alg 를 거르려면 스스로 풀어야 한다. 상류가 이 순서를 바꾸면
 * 여기가 운다 — 그때 세 곳의 근거를 다시 잰다.
 */
final class JwtHeadersOutParamTest extends TestCase
{
    /** HS256 키 — php-jwt 7 은 32 바이트보다 짧은 HMAC 키를 거부한다. */
    private const KEY = 'jwt-headers-out-param-test-key-of-64-bytes-xxxxxxxxxxxxxxxxxxxxx';
    private const OTHER = 'jwt-headers-out-param-other-key-of-64-bytes-yyyyyyyyyyyyyyyyyyyy';

    private static function token(): string
    {
        return JWT::encode(['sub' => 'svc', 'exp' => time() + 60], self::KEY, 'HS256', 'kid-1');
    }

    public function testAPassedObjectIsFilledBeforeTheSignatureIsChecked(): void
    {
        $headers = new \stdClass();
        $failed = false;
        try {
            JWT::decode(self::token(), new Key(self::OTHER, 'HS256'), $headers);
        } catch (SignatureInvalidException) {
            $failed = true;
        }

        self::assertTrue($failed, '다른 키는 서명을 통과하면 안 된다 — 이 칸의 전제');
        self::assertSame('HS256', $headers->alg ?? null, '서명이 틀렸는데도 헤더가 채워졌어야 한다');
        self::assertSame('kid-1', $headers->kid ?? null);
    }

    public function testNullIsNeverFilledEvenOnSuccess(): void
    {
        $headers = null;
        $payload = JWT::decode(self::token(), new Key(self::KEY, 'HS256'), $headers);

        self::assertSame('svc', $payload->sub);
        self::assertNull($headers, 'null 을 넘기면 성공해도 채우지 않는다(`if ($headers !== null)`)');
    }
}
