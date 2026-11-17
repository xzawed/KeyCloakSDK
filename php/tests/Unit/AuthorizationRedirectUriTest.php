<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use GuzzleHttp\Client;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Psr7\HttpFactory;
use League\OAuth2\Client\Provider\AbstractProvider;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Xzawed\Keycloak\AuthClient;
use Xzawed\Keycloak\Exception\KeycloakConfigError;
use Xzawed\Keycloak\Internal\PkceKeycloakProvider;
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\JwtValidator;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\OidcEndpoints;

/**
 * 인가 요청의 redirect_uri — RFC 6749 §3.1.2 가 금하는 값은 URL 에 싣지 않는다(등록부 `authz-request-redirect-unvalidated`).
 *
 * 예전에는 `createAuthorizationRequest()` 가 어떤 문자열이든 실었다(`cb` · `not a url` · `https://app/cb#f`). 규칙은
 * 순서대로 셋이다 — R1 절대 URI(scheme 과 `:`) · R2 fragment 없음(`#` 가 어디에도 없다 — 빈 fragment 도) · R3 Keycloak 이
 * 읽는 URI(서버의 `java.net.URI.create` 가 던지는 값 — RFC 3986 §2. 잘못된 UTF-8 도 R3). 인자가 null 이면 검사하지 않는다 —
 * 그때 실리는 것은 config 값이고, 그 값은 `KeycloakConfig` 생성자가 같은 규칙으로 본다.
 *
 * 위반은 KeycloakConfigError 이고 메시지는 입력을 인용하지 않는다. 받은 값은 고쳐 쓰지 않는다 — 교환이 같은 문자열을
 * 그대로 보낸다(고쳐 쓰면 두 요청이 갈린다).
 */
final class AuthorizationRedirectUriTest extends TestCase
{
    private const NOT_ABSOLUTE = 'invalid redirect_uri: not an absolute URI (RFC 6749 §3.1.2)';
    private const FRAGMENT = 'invalid redirect_uri: a fragment is not allowed (RFC 6749 §3.1.2)';
    private const NOT_VALID = 'invalid redirect_uri: not a valid URI (RFC 3986 §2)';

    /** @return iterable<string, array{string}> */
    public static function notAbsolute(): iterable
    {
        yield 'empty' => [''];
        yield 'cb' => ['cb'];
        yield '/cb' => ['/cb'];
        yield '//app/cb' => ['//app/cb'];
        yield 'not a url' => ['not a url'];
        yield 'cb#f (R1 before R2)' => ['cb#f'];
        yield 'cb + invalid UTF-8 (R1 before R3)' => ["cb\xFF"];
    }

    /** @return iterable<string, array{string}> */
    public static function withFragment(): iterable
    {
        yield 'empty fragment' => ['https://app/cb#'];
        yield 'fragment' => ['https://app/cb#f'];
        yield 'space + fragment (R2 before R3)' => ['https://app/c b#f'];
        yield 'invalid UTF-8 + fragment (R2 before R3)' => ["https://app/c\xFF#f"];
    }

    /** @return iterable<string, array{string}> */
    public static function unreadable(): iterable
    {
        yield 'space' => ['https://app/c b'];
        yield 'trailing LF' => ["https://app/cb\n"];
        yield 'backslash' => ['https://app/c\\b'];
        yield '%zz' => ['https://app/c%zz'];
        yield 'NBSP' => ["https://app/c\u{00A0}b"];
        yield 'trailing %2' => ['https://app/c%2'];
        yield 'trailing %' => ['https://app/c%'];
        yield '%g0' => ['https://app/c%g0'];
        yield 'invalid UTF-8' => ["https://app/c\xFFb"];
        yield 'truncated UTF-8 sequence' => ["https://app/c\xC3"];
        yield 'U+3000 ideographic space' => ["https://app/c\u{3000}b"];
        yield 'U+2028 line separator' => ["https://app/c\u{2028}b"];
    }

    /** @return iterable<string, array{string}> */
    public static function accepted(): iterable
    {
        foreach ([
            'https://app/cb', 'https://app/cb?x=1', 'myapp:/cb', 'com.example.app:/oauth2redirect', 'HTTP://LOCALHOST/cb',
            'https://app/c%20b', "https://app/c\u{00FC}b", 'https://app/cb?x=[1]', "https://app/c'b", 'https://app/c+*!b',
            'https://app/c~b', "https://app/c\u{00A1}b", 'https://app/c%2Fb', "https://app/c\u{200B}b", "https://app/c\u{3001}b",
        ] as $value) {
            yield $value => [$value];
        }
    }

    #[DataProvider('notAbsolute')]
    public function testANonAbsoluteValueIsRefused(string $value): void
    {
        self::assertSame(self::NOT_ABSOLUTE, self::refusal(fn () => self::auth()->createAuthorizationRequest($value)));
    }

    #[DataProvider('withFragment')]
    public function testAFragmentIsRefused(string $value): void
    {
        self::assertSame(self::FRAGMENT, self::refusal(fn () => self::auth()->createAuthorizationRequest($value)));
    }

    #[DataProvider('unreadable')]
    public function testAValueKeycloakCannotParseIsRefused(string $value): void
    {
        self::assertSame(self::NOT_VALID, self::refusal(fn () => self::auth()->createAuthorizationRequest($value)));
    }

    /**
     * R3 의 글자 전부를 하나씩 — U+0000-U+0020, U+007F-U+00A0, java.net.URI 가 거부하는 유니코드 공백 구분자 열일곱,
     * 그리고 아홉 개. 범위의 양 끝이 빠지지 않게.
     */
    public function testEveryCharacterKeycloakRefusesIsRefused(): void
    {
        $chars = [];
        $spaces = [0x1680, ...range(0x2000, 0x200A), 0x2028, 0x2029, 0x202F, 0x205F, 0x3000];
        foreach ([...range(0x00, 0x20), ...range(0x7F, 0xA0), ...$spaces] as $cp) {
            $chars[] = self::utf8($cp);
        }
        $chars = [...$chars, '"', '<', '>', '\\', '^', '`', '{', '|', '}'];
        self::assertCount(93, $chars);   // 빈 집합이면 아래 단언이 공허하게 통과한다
        $missed = [];
        foreach ($chars as $ch) {
            if (self::refusal(fn () => self::auth()->createAuthorizationRequest("https://app/c{$ch}b")) !== self::NOT_VALID) {
                $missed[] = bin2hex($ch);
            }
        }
        self::assertSame([], $missed);
    }

    public function testTheMessageDoesNotQuoteTheValue(): void
    {
        foreach (['cb-CANARY-7d1f' => self::NOT_ABSOLUTE, 'https://app/CANARY#f' => self::FRAGMENT, 'https://app/CANARY b' => self::NOT_VALID] as $value => $message) {
            try {
                self::auth()->createAuthorizationRequest($value);
                self::fail("$value was not refused");
            } catch (KeycloakConfigError $e) {
                // 메시지만 잰다 — 트레이스의 인자 칸은 PHP 가 모든 비-SensitiveParameter 인자에 찍는다(redirect_uri 는 비밀이 아니다).
                self::assertSame($message, $e->getMessage());
                self::assertStringNotContainsString('CANARY', $e->getMessage());
            }
        }
    }

    #[DataProvider('accepted')]
    public function testAnAbsoluteUriIsCarriedExactlyAsGiven(string $value): void
    {
        $url = self::auth()->createAuthorizationRequest($value)->url;
        self::assertSame([$value], self::queryValues($url, 'redirect_uri'));
    }

    /** 거부는 state·PKCE 를 만들기 전이다 — league 프로바이더는 그 둘을 자기 상태로 쥔다(만들었다면 남는다). */
    public function testTheCheckRunsBeforeStateOrPkceIsGenerated(): void
    {
        $auth = self::auth();
        self::assertSame(self::NOT_ABSOLUTE, self::refusal(fn () => $auth->createAuthorizationRequest('cb')));
        self::assertNull(self::providerField($auth, 'state'));
        self::assertNull(self::providerField($auth, 'pkceCode'));
        // 대조 — 받아들인 요청은 둘을 남긴다(위 null 이 「읽는 법이 틀렸다」가 아니다).
        $auth->createAuthorizationRequest('https://app/cb');
        self::assertIsString(self::providerField($auth, 'state'));
        self::assertIsString(self::providerField($auth, 'pkceCode'));
    }

    /** null 은 config 값이다 — 그 값도 같은 규칙으로 본다(생성자가 이미 봤다). */
    public function testNullSendsTheConfigValue(): void
    {
        self::assertSame(['https://app/cb'], self::queryValues(self::auth()->createAuthorizationRequest()->url, 'redirect_uri'));
    }

    /**
     * 인자도 config 도 null 이면 실을 redirect_uri 가 없다 — league 프로바이더가 빈 `redirect_uri=` 를 실었다(실측), Keycloak 은
     * 그것을 모든 등록에서 거부한다. state·PKCE 를 만들기 전에 R1 이다.
     */
    public function testNoRedirectUriAnywhereIsRefused(): void
    {
        $auth = self::auth(configRedirectUri: null);
        self::assertSame(self::NOT_ABSOLUTE, self::refusal(fn () => $auth->createAuthorizationRequest()));
        self::assertNull(self::providerField($auth, 'state'));
        self::assertNull(self::providerField($auth, 'pkceCode'));
    }

    /** 대조 — config 에 값이 없어도 호출당 값이 있으면 그것이 실린다. */
    public function testAPerCallValueNeedsNoConfigValue(): void
    {
        $url = self::auth(configRedirectUri: null)->createAuthorizationRequest('https://app/per-call')->url;
        self::assertSame(['https://app/per-call'], self::queryValues($url, 'redirect_uri'));
    }

    public function testConfigRefusesANonAbsoluteRedirectUri(): void
    {
        self::assertSame(self::NOT_ABSOLUTE, self::refusal(fn () => self::config('cb')));
    }

    public function testConfigRefusesAFragment(): void
    {
        self::assertSame(self::FRAGMENT, self::refusal(fn () => self::config('https://app/cb#f')));
    }

    public function testConfigRefusesAValueKeycloakCannotParse(): void
    {
        self::assertSame(self::NOT_VALID, self::refusal(fn () => self::config('https://app/c b')));
        self::assertSame(self::NOT_VALID, self::refusal(fn () => self::config("https://app/c\xFFb")));
    }

    public function testConfigKeepsNullAndAnAbsoluteRedirectUriAsGiven(): void
    {
        self::assertNull(self::config(null)->redirectUri);
        self::assertSame('HTTP://LOCALHOST/c%20b', self::config('HTTP://LOCALHOST/c%20b')->redirectUri);
    }

    /** BMP 코드 포인트 하나의 UTF-8 — 확장(mbstring·intl)에 기대지 않는다. */
    private static function utf8(int $cp): string
    {
        return match (true) {
            $cp < 0x80 => \chr($cp),
            $cp < 0x800 => \chr(0xC0 | $cp >> 6) . \chr(0x80 | $cp & 0x3F),
            default => \chr(0xE0 | $cp >> 12) . \chr(0x80 | $cp >> 6 & 0x3F) . \chr(0x80 | $cp & 0x3F),
        };
    }

    /** 던져진 KeycloakConfigError 의 메시지, 던지지 않았으면 null. */
    private static function refusal(\Closure $call): ?string
    {
        try {
            $call();
        } catch (KeycloakConfigError $e) {
            return $e->getMessage();
        }

        return null;
    }

    /**
     * 쿼리에서 그 키의 값 전부(디코드) — `parse_str` 은 같은 키가 둘이면 뒤만 남겨 중복을 못 본다.
     *
     * @return list<string>
     */
    private static function queryValues(string $url, string $name): array
    {
        $query = parse_url($url, PHP_URL_QUERY);
        self::assertIsString($query);
        $values = [];
        foreach (explode('&', $query) as $pair) {
            [$key, $value] = explode('=', $pair, 2) + [1 => ''];
            if (rawurldecode($key) === $name) {
                $values[] = rawurldecode($value);
            }
        }

        return $values;
    }

    private static function config(?string $redirectUri): KeycloakConfig
    {
        return new KeycloakConfig(
            serverUrl: 'https://kc.example.com',
            realm: 'r',
            clientId: 'app',
            clientSecret: 's',
            redirectUri: $redirectUri,
        );
    }

    private static function auth(?string $configRedirectUri = 'https://app/cb'): AuthClient
    {
        $cfg = self::config($configRedirectUri);
        $endpoints = new OidcEndpoints($cfg);
        $noHttp = static function (RequestInterface $request): never {
            throw new \LogicException('the authorization URL needs no request');
        };
        $jwksHttp = new class () implements ClientInterface {
            public function sendRequest(RequestInterface $r): ResponseInterface
            {
                throw new \LogicException('JWKS must not be fetched here');
            }
        };
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $jwksHttp, new HttpFactory()));

        return new AuthClient($cfg, $endpoints, $validator, new Client(['handler' => HandlerStack::create($noHttp)]));
    }

    /**
     * league 프로바이더가 쥔 값 — 리플렉션으로 읽는다. `getState()` 의 PHPDoc 은 `string` 이지만 만들기 전에는 null 이다.
     */
    private static function providerField(AuthClient $auth, string $field): mixed
    {
        $provider = (new \ReflectionProperty(AuthClient::class, 'provider'))->getValue($auth);
        self::assertInstanceOf(PkceKeycloakProvider::class, $provider);

        return (new \ReflectionProperty(AbstractProvider::class, $field))->getValue($provider);
    }
}
