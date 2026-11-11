<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit\Internal;

use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Internal\OAuthErrorCode;

/**
 * 계약: IdP 가 보낸 `error` 는 **정확히** `[a-z_]{1,64}` 이고 그 요청이 보낸 비밀과 겹치지 않을 때만 코드다 — 앞뒤·가운데 어디에도
 * 제어문자가 없다. 호출부 셋(`AuthClient`·`ClientCredentialsTokenProvider`·`Admin\ErrorTranslation`)은 `OAuthErrorCodeEchoTest`
 * 가 실제 스택으로 잰다(`SanitizedCause` 는 코드를 싣지 않는다).
 *
 * ⚠️ PCRE 의 `$` 는 `D` 없이 쓰면 **끝의 줄바꿈 하나 앞**에서도 맞는다 — `"invalid_client\n"` 이 코드로 통과해 SDK 메시지와
 * `oauthError` 에 줄바꿈째 실렸다(로그 줄이 갈린다, 실측 2026-10-02). `\Z` 도 같은 틈이 있다 — 닫는 닻은 `\z` 다.
 */
final class OAuthErrorCodeTest extends TestCase
{
    /** @return array<string, array{0: mixed, 1: ?string}> */
    public static function values(): array
    {
        return [
            'registered code' => ['invalid_grant', 'invalid_grant'],
            'shortest' => ['a', 'a'],
            'longest (64)' => [str_repeat('a', 64), str_repeat('a', 64)],
            'trailing LF' => ["invalid_client\n", null],
            'trailing CR' => ["invalid_client\r", null],
            'trailing CRLF' => ["invalid_client\r\n", null],
            'leading LF' => ["\ninvalid_client", null],
            'embedded LF' => ["invalid\nclient", null],
            'trailing NUL' => ["invalid_client\0", null],
            'trailing space' => ['invalid_client ', null],
            'empty' => ['', null],
            'too long (65)' => [str_repeat('a', 65), null],
            'capitals and digits (token-shaped)' => ['LKe3ERR-Token-In-Error-Code', null],
            // 바이트가 [a-z_] 라는 조항 — 유니코드 소문자(`\p{Ll}`)로 넓혀도 위 행들은 전부 초록이었다(실측).
            'non-ASCII lowercase (U+00E9)' => ["invalid_client\u{e9}", null],
            'dotless i (U+0131)' => ["\u{131}nvalid_client", null],
            'fullwidth a (U+FF41)' => ["\u{ff41}", null],
            'not a string' => [['invalid_client'], null],
            'null' => [null, null],
        ];
    }

    #[DataProvider('values')]
    public function testAcceptsOnlyAnExactCodeShape(mixed $error, ?string $expected): void
    {
        self::assertSame($expected, OAuthErrorCode::of($error));
    }

    /** @return array<string, array{string, list<?string>, ?string}> */
    public static function overlaps(): array
    {
        return [
            'nothing sent' => ['invalid_grant', [], 'invalid_grant'],
            'unrelated secret' => ['invalid_grant', ['s3cret-Value'], 'invalid_grant'],
            'the secret itself' => ['mysecret', ['mysecret'], null],
            'contains the secret (extended echo)' => ['mysecret_x', ['mysecret'], null],
            'inside the secret (truncated echo)' => ['mysec', ['mysecret'], null],
            'any of several' => ['mysecret', [null, '', 'other', 'mysecret'], null],
            'absent and empty are not compared' => ['invalid_grant', [null, ''], 'invalid_grant'],
            'the price: a secret that is a piece of the code' => ['invalid_client', ['client'], null],
        ];
    }

    /** @param list<?string> $sent */
    #[DataProvider('overlaps')]
    public function testWithholdsAValueThatOverlapsASecretTheRequestSent(string $error, array $sent, ?string $expected): void
    {
        self::assertSame($expected, OAuthErrorCode::carried($error, ...$sent));
    }
}
