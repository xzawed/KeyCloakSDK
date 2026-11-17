<?php

declare(strict_types=1);

namespace Xzawed\Keycloak\Tests\Unit;

use Firebase\JWT\JWT as FbJwt;
use GuzzleHttp\Client;
use GuzzleHttp\Handler\MockHandler;
use GuzzleHttp\HandlerStack;
use GuzzleHttp\Promise\Create;
use GuzzleHttp\Promise\PromiseInterface;
use GuzzleHttp\Psr7\HttpFactory;
use GuzzleHttp\Psr7\Response;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\ResponseInterface;
use Xzawed\Keycloak\AuthClient;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\TokenValidationError;
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\JwtValidator;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\OidcEndpoints;

/**
 * OIDC nonce 재생 방지 — Java AuthClientNonceTest / Ruby auth_client_spec 동형.
 * createAuthorizationRequest는 항상 nonce를 만들어 URL에 싣고, exchangeCode는
 * expectedNonce가 주어지면 id_token을 완전 검증한 뒤 nonce 클레임을 대조한다.
 */
final class AuthClientNonceTest extends TestCase
{
    /** 리소스 서버 audience — client id(`it-client`)가 아닌 재정의 값. */
    private const OVERRIDE = 'my-api';
    private const AUD_REFUSED = 'authorization code exchange failed: invalid id_token: audience does not contain it-client';
    /** id_token 경로가 typ 가 정확히 "ID" 가 아닌 토큰을 거부하는 문구 — 상수다(typ 값을 싣지 않는다). */
    private const NOT_AN_ID_TOKEN = 'not an id_token (typ is not "ID")';
    /** typ 를 싣지 않는 칸의 표지 — JSON null 인 typ 와 「typ 없음」을 가른다. */
    private const NO_TYP = "\0no typ";
    /** 액세스 경로가 Bearer · DPoP 밖의 typ 를 거부하는 문구 — 상수다(다섯 종류는 이름을 단 문구다). */
    private const NOT_BEARER_OR_DPOP = 'not an access token (typ is not Bearer or DPoP)';
    /** 다섯 밖의 typ 를 넣는 칸의 표지 — 거부 문구에 없어야 한다. */
    private const TYP_CANARY = 'x-canary-typ-2H8M';

    /** @var array{priv:string,jwk:array<string,mixed>} */
    private array $key;
    private string $iss = 'https://kc:8080/realms/it-realm';

    protected function setUp(): void
    {
        $res = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($res);
        self::assertTrue(openssl_pkey_export($res, $priv));
        self::assertIsString($priv);
        $details = openssl_pkey_get_details($res);
        self::assertIsArray($details);
        $rsa = $details['rsa'];
        self::assertIsArray($rsa);
        $n = $rsa['n'];
        $e = $rsa['e'];
        self::assertIsString($n);
        self::assertIsString($e);
        $jwk = [
            'kty' => 'RSA', 'kid' => 'test-kid', 'use' => 'sig', 'alg' => 'RS256',
            'n' => rtrim(strtr(base64_encode($n), '+/', '-_'), '='),
            'e' => rtrim(strtr(base64_encode($e), '+/', '-_'), '='),
        ];
        $this->key = ['priv' => $priv, 'jwk' => $jwk];
    }

    public function testCreateAuthorizationRequestPutsNonceOnUrlAndObject(): void
    {
        $auth = $this->authWithTokenBody([]);
        $req = $auth->createAuthorizationRequest();
        self::assertNotSame('', $req->nonce);
        $qs = parse_url($req->url, PHP_URL_QUERY);
        self::assertIsString($qs);
        parse_str($qs, $params);
        self::assertArrayHasKey('nonce', $params);
        self::assertSame($req->nonce, $params['nonce']);
    }

    public function testCreateAuthorizationRequestNonceDiffersPerCall(): void
    {
        $auth = $this->authWithTokenBody([]);
        $a = $auth->createAuthorizationRequest();
        $b = $auth->createAuthorizationRequest();
        self::assertNotSame($a->nonce, $b->nonce);
        self::assertNotSame($a->state, $b->state);
        self::assertNotSame($a->codeVerifier, $b->codeVerifier);
    }

    public function testExchangeCodeAcceptsMatchingNonce(): void
    {
        $hits = new JwksHitCounter();
        $idToken = $this->signIdToken('server-nonce');
        $ts = $this->authWithTokenBody($this->tokenBody($idToken), jwksHits: $hits)
            ->exchangeCode('code', 'verifier', 'server-nonce');
        self::assertSame('AT', $ts->accessToken);
        self::assertSame($idToken, $ts->idToken);
        self::assertGreaterThan(0, $hits->n, 'matching nonce must fully validate id_token (JWKS fetch)');
    }

    public function testExchangeCodeRejectsMismatchedNonce(): void
    {
        $idToken = $this->signIdToken('server-nonce');
        $this->expectException(KeycloakAuthError::class);
        $this->expectExceptionMessageMatches('/nonce/');
        $this->authWithTokenBody($this->tokenBody($idToken))
            ->exchangeCode('code', 'verifier', 'attacker-nonce');
    }

    public function testExchangeCodeRejectsMissingIdTokenWhenNonceExpected(): void
    {
        $this->expectException(KeycloakAuthError::class);
        $this->expectExceptionMessageMatches('/id_token/');
        $this->authWithTokenBody($this->tokenBody(null))
            ->exchangeCode('code', 'verifier', 'server-nonce');
    }

    public function testExchangeCodeRejectsUntrustedIdToken(): void
    {
        $attacker = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($attacker);
        self::assertTrue(openssl_pkey_export($attacker, $attackerPriv));
        self::assertIsString($attackerPriv);
        $forged = $this->signIdToken('server-nonce', $attackerPriv);
        $this->expectException(KeycloakAuthError::class);
        $this->authWithTokenBody($this->tokenBody($forged))
            ->exchangeCode('code', 'verifier', 'server-nonce');
    }

    public function testExchangeCodeSkipsIdTokenValidationWithoutNonce(): void
    {
        $idToken = $this->signIdToken('server-nonce');
        $ts = $this->authWithTokenBody($this->tokenBody($idToken), forbidJwks: true)
            ->exchangeCode('code', 'verifier');
        self::assertSame('AT', $ts->accessToken);
        self::assertSame($idToken, $ts->idToken);
    }

    // ── id_token 의 aud 는 client id 다(OIDC Core §2·§3.1.3.7) — expectedAudience 는 액세스 토큰의 것이다 ──

    /** @return iterable<string, array{string|list<string>}> */
    public static function idTokenAudiencesNamingTheClient(): iterable
    {
        yield 'the client id alone' => ['it-client'];
        yield 'the client id in a list' => [['it-client']];
        yield 'the client id beside the override' => [[self::OVERRIDE, 'it-client']];
    }

    /**
     * (A1) 재정의해도 aud 에 client id 를 담은 id_token 의 교환은 통과한다 — 예전에는 재정의 값을 찾아 거부했다.
     * azp 는 Keycloak 이 늘 적는 그대로 client id 다(aud 가 여럿인 id_token 은 그것이 있어야 한다 — OIDC Core §3.1.3.7).
     *
     * @param string|list<string> $aud
     */
    #[DataProvider('idTokenAudiencesNamingTheClient')]
    public function testExchangeCodeUnderAnAudienceOverrideAcceptsAnIdTokenIssuedToTheClient(string|array $aud): void
    {
        $hits = new JwksHitCounter();
        $idToken = $this->sign($this->idTokenClaims('server-nonce', ['aud' => $aud, 'azp' => 'it-client']));
        $ts = $this->authWithTokenBody($this->tokenBody($idToken), jwksHits: $hits, expectedAudience: self::OVERRIDE)
            ->exchangeCode('code', 'verifier', 'server-nonce');
        self::assertSame($idToken, $ts->idToken);
        self::assertSame(1, $hits->n, 'the id_token must still be fully validated (one JWKS fetch)');
    }

    /** @return iterable<string, array{string|list<string>|null}> */
    public static function idTokenAudiencesWithoutTheClient(): iterable
    {
        yield 'only the override' => [self::OVERRIDE];
        yield 'only the override, in a list' => [[self::OVERRIDE]];
        yield 'another client' => [['account']];
        yield 'no aud claim' => [null];
    }

    /**
     * (A2) aud 에 client id 가 없는 id_token 은 거부한다 — 재정의 값과 같아도.
     *
     * @param string|list<string>|null $aud
     */
    #[DataProvider('idTokenAudiencesWithoutTheClient')]
    public function testExchangeCodeRejectsAnIdTokenNotIssuedToTheClientEvenUnderAnOverride(string|array|null $aud): void
    {
        $idToken = $this->sign($this->idTokenClaims('server-nonce', ['aud' => $aud]));
        try {
            $this->authWithTokenBody($this->tokenBody($idToken), expectedAudience: self::OVERRIDE)
                ->exchangeCode('code', 'verifier', 'server-nonce');
            self::fail('an id_token whose aud lacks the client id must be refused');
        } catch (KeycloakAuthError $refused) {
        }
        self::assertSame(self::AUD_REFUSED, $refused->getMessage());
        self::assertInstanceOf(TokenValidationError::class, $refused->getPrevious());
    }

    /** (A3) 액세스 토큰 검증은 재정의를 계속 쓴다 — client id 만 담은 액세스 토큰은 거부한다. */
    public function testValidateKeepsCheckingAccessTokensAgainstTheOverride(): void
    {
        $auth = $this->authWithTokenBody([], expectedAudience: self::OVERRIDE);
        $vt = $auth->validate($this->sign($this->accessTokenClaims([self::OVERRIDE, 'account'])));
        self::assertSame([self::OVERRIDE, 'account'], $vt->audience);
        try {
            $auth->validate($this->sign($this->accessTokenClaims(['it-client'])));
            self::fail('an access token without the overriding audience must be refused');
        } catch (TokenValidationError $refused) {
        }
        self::assertSame('audience does not contain ' . self::OVERRIDE, $refused->getMessage());
    }

    // ── 액세스 경로의 허용 목록 — validate() 는 payload typ 가 ASCII 대소문자를 무시하고 Bearer 나 DPoP 일 때만 받는다(Keycloak
    // 자신의 TokenVerifier.TokenTypeCheck). 다섯 종류의 문구는 JwtValidatorTest 가 잰다. ──

    /**
     * 이 규칙이 닫는 구멍 — Keycloak 의 JARM 인가 응답 JWT(response_mode=query.jwt): realm 이 서명하고 iss 가 realm · aud 가
     * client id(기대 audience 의 기본값) · exp 가 있고 typ 가 없다(sub · azp 도 없다). 액세스 토큰이 아니다.
     */
    public function testValidateRefusesAJarmAuthorizationResponse(): void
    {
        $jarm = $this->sign(['iss' => $this->iss, 'aud' => 'it-client', 'exp' => time() + 60, 'code' => 'c0de', 'state' => 'st4te']);
        try {
            $this->authWithTokenBody([])->validate($jarm);
            self::fail('a JARM authorization response is not an access token');
        } catch (TokenValidationError $refused) {
        }
        self::assertSame(self::NOT_BEARER_OR_DPOP, $refused->getMessage());
        self::assertNull($refused->getPrevious());
    }

    /** @return iterable<string, array{mixed}> */
    public static function typsOtherThanBearerOrDPoP(): iterable
    {
        yield 'no typ' => [self::NO_TYP];
        yield 'typ a number' => [1];
        yield 'typ null' => [null];
        yield 'typ a list' => [['Bearer']];
        yield 'typ at+jwt' => ['at+jwt'];
        yield 'typ an arbitrary value' => [self::TYP_CANARY];
    }

    /** 상수 문구 하나로 거부하고 typ 를 싣지 않는다 — 다섯 밖의 typ 는 토큰을 만든 쪽이 고른 값이다. */
    #[DataProvider('typsOtherThanBearerOrDPoP')]
    public function testValidateRefusesAnAccessTokenNotTypedBearerOrDPoP(mixed $typ): void
    {
        $claims = $this->accessTokenClaims(['it-client']);
        unset($claims['typ']);
        if ($typ !== self::NO_TYP) {
            $claims['typ'] = $typ;
        }
        try {
            $this->authWithTokenBody([])->validate($this->sign($claims));
            self::fail('only typ Bearer or DPoP is an access token');
        } catch (TokenValidationError $refused) {
        }
        self::assertSame(self::NOT_BEARER_OR_DPOP, $refused->getMessage());
        self::assertNull($refused->getPrevious());
        self::assertFalse(str_contains($refused->getMessage(), self::TYP_CANARY), 'the refusal quotes the token\'s typ');
    }

    /** @return iterable<string, array{string}> */
    public static function bearerOrDPoP(): iterable
    {
        yield 'Bearer' => ['Bearer'];
        yield 'bearer (the lower-case client option)' => ['bearer'];
        yield 'DPoP' => ['DPoP'];
        yield 'dpop' => ['dpop'];
    }

    #[DataProvider('bearerOrDPoP')]
    public function testValidateAcceptsAnAccessTokenTypedBearerOrDPoP(string $typ): void
    {
        $claims = $this->accessTokenClaims(['it-client']);
        $claims['typ'] = $typ;
        self::assertSame(['it-client'], $this->authWithTokenBody([])->validate($this->sign($claims))->audience);
    }

    /**
     * (A4) 재정의 아래서도 id_token 의 나머지 검사(iss·alg 핀·exp·kid·서명)와 nonce 대조는 그대로다.
     *
     * @return iterable<string, array{array<string,mixed>, string, string, non-empty-string}>
     */
    public static function idTokenDefectsUnderAnOverride(): iterable
    {
        // [바꿀 클레임(null 은 제거 · exp 는 지금부터의 초), 서명 방식, 넘기는 nonce, 거부 메시지]
        $invalid = 'authorization code exchange failed: invalid id_token: ';
        yield 'a foreign issuer' => [['iss' => 'https://evil/realms/it-realm'], 'rs256', 'server-nonce', $invalid . 'issuer mismatch: https://evil/realms/it-realm'];
        yield 'expired beyond the skew' => [['exp' => -60], 'rs256', 'server-nonce', $invalid . 'token verification failed: Expired token'];
        yield 'no exp' => [['exp' => null], 'rs256', 'server-nonce', $invalid . 'exp claim is required'];
        yield 'an algorithm outside the pin' => [[], 'hs256', 'server-nonce', $invalid . 'algorithm not allowed: HS256'];
        yield 'a key outside the JWKS' => [[], 'foreign-key', 'server-nonce', $invalid . 'token verification failed: Signature verification failed'];
        yield 'another nonce' => [[], 'rs256', 'attacker-nonce', 'authorization code exchange failed: unexpected nonce'];
    }

    /** @param array<string,mixed> $changes */
    #[DataProvider('idTokenDefectsUnderAnOverride')]
    public function testExchangeCodeUnderAnAudienceOverrideKeepsTheOtherIdTokenChecks(array $changes, string $signer, string $nonce, string $message): void
    {
        $idToken = $this->signAs($signer, $this->idTokenClaims('server-nonce', $changes));
        try {
            $this->authWithTokenBody($this->tokenBody($idToken), expectedAudience: self::OVERRIDE)
                ->exchangeCode('code', 'verifier', $nonce);
            self::fail('a defective id_token must be refused under an audience override too');
        } catch (KeycloakAuthError $refused) {
        }
        self::assertSame($message, $refused->getMessage());
    }

    /** (A4) 클록 스큐 쌍의 안쪽 — 위 「expired beyond the skew」와 짝이라 스큐가 0 이어도 무한이어도 하나가 빨개진다. */
    public function testExchangeCodeUnderAnAudienceOverrideAllowsTheClockSkew(): void
    {
        $idToken = $this->sign($this->idTokenClaims('server-nonce', ['exp' => -10]));
        $ts = $this->authWithTokenBody($this->tokenBody($idToken), expectedAudience: self::OVERRIDE)
            ->exchangeCode('code', 'verifier', 'server-nonce');
        self::assertSame($idToken, $ts->idToken);
    }

    // ── id_token 의 종류와 권한 부여 당사자 — validate() 는 액세스 토큰이 아닌 종류(typ)를 거부한다(JwtValidatorTest). 교환은
    // id_token 을 검증하고 Keycloak 은 그것을 "ID" 로 적으므로 종류는 정확히 "ID" 여야 한다(아래 validateIdToken() 시험) — 그리고
    // azp 를 client id 로 대조한다(OIDC Core §3.1.3.7 4–5 단계). ──

    /** Keycloak 이 내는 id_token — typ "ID", aud 와 azp 가 client id 다. */
    public function testExchangeCodeAcceptsAnIdTokenTypedId(): void
    {
        $idToken = $this->sign($this->idTokenClaims('server-nonce', ['typ' => 'ID', 'azp' => 'it-client']));
        $ts = $this->authWithTokenBody($this->tokenBody($idToken))->exchangeCode('code', 'verifier', 'server-nonce');
        self::assertSame($idToken, $ts->idToken);
    }

    /** @return iterable<string, array{array<string,mixed>}> */
    public static function idTokenPartiesNamingTheClient(): iterable
    {
        yield 'one audience, no azp' => [[]];
        yield 'several audiences, azp the client' => [['aud' => ['it-client', 'other-client'], 'azp' => 'it-client']];
    }

    /** @param array<string,mixed> $changes */
    #[DataProvider('idTokenPartiesNamingTheClient')]
    public function testExchangeCodeAcceptsAnIdTokenWhoseAuthorizedPartyIsTheClient(array $changes): void
    {
        $idToken = $this->sign($this->idTokenClaims('server-nonce', $changes));
        $ts = $this->authWithTokenBody($this->tokenBody($idToken))->exchangeCode('code', 'verifier', 'server-nonce');
        self::assertSame($idToken, $ts->idToken);
    }

    /**
     * aud 에 이 클라이언트를 담았지만 다른 당사자에게 발급된 id_token — 둘째 칸은 python 재현이 통과시킨 모양이다
     * (aud ["web","evil"] · azp "evil").
     *
     * @return iterable<string, array{array<string,mixed>, string}>
     */
    public static function idTokenPartiesOtherThanTheClient(): iterable
    {
        yield 'one audience, azp another client' => [['azp' => 'evil'], 'azp does not match the client id'];
        yield 'several audiences, azp another client' => [['aud' => ['it-client', 'evil'], 'azp' => 'evil'], 'azp does not match the client id'];
        yield 'several audiences, no azp' => [['aud' => ['it-client', 'evil']], 'azp is required when aud has more than one value'];
    }

    /**
     * 두 진입점이 **한** 검사를 부른다 — 같은 id_token 을 validateIdToken() 에 직접 넣으면 교환 접두 없이 같은 이유다.
     *
     * @param array<string,mixed> $changes
     */
    #[DataProvider('idTokenPartiesOtherThanTheClient')]
    public function testExchangeCodeRefusesAnIdTokenIssuedToAnotherParty(array $changes, string $reason): void
    {
        $idToken = $this->sign($this->idTokenClaims('server-nonce', $changes));
        try {
            $this->authWithTokenBody($this->tokenBody($idToken))->exchangeCode('code', 'verifier', 'server-nonce');
            self::fail('an id_token issued to another party must be refused');
        } catch (KeycloakAuthError $refused) {
        }
        self::assertSame('authorization code exchange failed: invalid id_token: ' . $reason, $refused->getMessage());
        $cause = $refused->getPrevious();
        self::assertInstanceOf(TokenValidationError::class, $cause);
        self::assertSame($reason, $cause->getMessage());
        try {
            $this->authWithTokenBody([])->validateIdToken($idToken);
            self::fail('validateIdToken() runs the check the exchange runs');
        } catch (TokenValidationError $direct) {
        }
        self::assertSame($reason, $direct->getMessage());
    }

    /** 파사드의 validate() 는 위 교환이 받는 그 id_token 을 거부한다. */
    public function testValidateRefusesAnIdToken(): void
    {
        $idToken = $this->sign($this->idTokenClaims('server-nonce', ['typ' => 'ID', 'azp' => 'it-client']));
        try {
            $this->authWithTokenBody([])->validate($idToken);
            self::fail('validate() checks access tokens — an id_token must be refused');
        } catch (TokenValidationError $refused) {
        }
        self::assertSame('not an access token (typ "ID")', $refused->getMessage());
    }

    // ── validateIdToken() — 교환이 nonce 를 대조하기 전에 하는 그 id_token 검사를 파사드에 연다(등록부
    // id-token-validator-not-public). `JwtValidator::validateIdToken()` 은 공개였지만 `KeycloakClient` 가 그 검증기를 안에서
    // 만들어, 소비자는 두 번째 검증기 · 두 번째 JWKS 저장소를 세워야 했다. nonce 는 받지 않고, typ 는 "ID" 만 받는다(검증기
    // 칸은 JwtValidatorTest::testValidateIdTokenAcceptsOnlyTypId). ──

    /** Keycloak 이 내는 id_token(typ "ID" · aud 와 azp 가 client id)은 그것을 담지 않은 재정의 아래서도 통과하고 클레임을 돌려준다. */
    public function testValidateIdTokenAcceptsAKeycloakIdToken(): void
    {
        $hits = new JwksHitCounter();
        $idToken = $this->sign($this->idTokenClaims('n', ['typ' => 'ID', 'azp' => 'it-client', 'sid' => 's1']));
        $vt = $this->authWithTokenBody([], jwksHits: $hits, expectedAudience: self::OVERRIDE)->validateIdToken($idToken);
        self::assertSame('u', $vt->subject);
        self::assertSame($this->iss, $vt->issuer);
        self::assertSame(['it-client'], $vt->audience);
        foreach (['typ' => 'ID', 'azp' => 'it-client', 'nonce' => 'n', 'sid' => 's1'] as $claim => $value) {
            self::assertSame($value, $vt->claims[$claim] ?? null, $claim);
        }
        self::assertSame(1, $hits->n, 'the id_token is verified against the JWKS');
    }

    /**
     * typ 가 정확히 "ID" 가 아닌 토큰은 나머지가 다 맞아도 상수 문구로 거부한다. 첫 칸이 이 규칙이 닫는 구멍이다 — 이 클라이언트가
     * 받은 액세스 토큰(audience 매퍼가 aud 에 client id 를 싣고 azp 가 이 클라이언트다)은 다른 id_token 검사를 전부 지난다.
     * 마지막 칸은 백채널 로그아웃 토큰이다(aud 가 client id · azp 없음 · exp 있음).
     *
     * @return iterable<string, array{mixed, array<string,mixed>}>
     */
    public static function tokensNotTypedId(): iterable
    {
        yield 'an access token, typ Bearer' => ['Bearer', ['azp' => 'it-client', 'scope' => 'openid', 'nonce' => null]];
        yield 'no typ' => [self::NO_TYP, ['azp' => 'it-client']];
        yield 'typ bearer in lower case' => ['bearer', ['azp' => 'it-client']];
        yield 'typ null' => [null, ['azp' => 'it-client']];
        yield 'typ a number' => [1, ['azp' => 'it-client']];
        yield 'typ a list holding ID' => [['ID'], ['azp' => 'it-client']];
        yield 'a back-channel logout token' => ['Logout', ['nonce' => null, 'sid' => 's1', 'events' => ['http://schemas.openid.net/event/backchannel-logout' => new \stdClass()]]];
    }

    /** @param array<string,mixed> $changes */
    #[DataProvider('tokensNotTypedId')]
    public function testValidateIdTokenRefusesATokenNotTypedId(mixed $typ, array $changes): void
    {
        $claims = $this->idTokenClaims('n', $changes);
        unset($claims['typ']);
        if ($typ !== self::NO_TYP) {
            $claims['typ'] = $typ;
        }
        try {
            $this->authWithTokenBody([])->validateIdToken($this->sign($claims));
            self::fail('a token not typed "ID" must be refused as an id_token');
        } catch (TokenValidationError $refused) {
        }
        self::assertSame(self::NOT_AN_ID_TOKEN, $refused->getMessage());
        self::assertNull($refused->getPrevious());
    }

    /** aud 는 client id 를 담아야 한다 — 재정의 값(validate() 가 찾는 aud)만 담은 id_token 은 aud 검사에서 거부된다. */
    public function testValidateIdTokenAudienceIsTheClientIdUnderAnOverride(): void
    {
        $idToken = $this->sign($this->idTokenClaims('n', ['typ' => 'ID', 'aud' => self::OVERRIDE, 'azp' => 'it-client']));
        $this->expectException(TokenValidationError::class);
        $this->expectExceptionMessage('audience does not contain it-client');
        $this->authWithTokenBody([], expectedAudience: self::OVERRIDE)->validateIdToken($idToken);
    }

    /** validateIdToken() 도 validate() 와 **한** JWKS 저장소를 쓴다 — 콜드 로드 하나 · 재조회 게이트 하나(아래 A5 의 대조군이 둘째 저장소를 센다). */
    public function testValidateIdTokenAndValidateShareOneJwksStore(): void
    {
        $hits = new JwksHitCounter();
        [$auth] = $this->authOverOneClient($hits, self::OVERRIDE);
        $auth->validateIdToken($this->sign($this->idTokenClaims('n', ['typ' => 'ID'])));
        self::assertSame(1, $hits->n, 'validateIdToken() loads the key set on a cold cache');
        $auth->validate($this->sign($this->accessTokenClaims([self::OVERRIDE])));
        self::assertSame(1, $hits->n, 'validate() after validateIdToken() must reuse its key set');
        try {
            $auth->validate($this->sign($this->accessTokenClaims([self::OVERRIDE]), kid: 'rotated-a'));
            self::fail('an unresolved kid must be refused');
        } catch (TokenValidationError) {
        }
        self::assertSame(2, $hits->n, 'the first unresolved kid spends the refetch');
        try {
            $auth->validateIdToken($this->sign($this->idTokenClaims('n', ['typ' => 'ID']), kid: 'rotated-b'));
            self::fail('an unresolved kid inside the refetch window must be refused');
        } catch (TokenValidationError $limited) {
        }
        self::assertSame('unknown kid "rotated-b" (refetch rate-limited)', $limited->getMessage());
        self::assertSame(2, $hits->n, 'validateIdToken() must see the refetch validate() already spent');
    }

    /** 교환은 id_token 을 validateIdToken() 으로 검사한다 — typ 규칙이 교환에도 걸리고, 거부는 nonce 대조 전에 교환 자신의 모양이다. */
    public function testExchangeCodeRefusesAnIdTokenNotTypedId(): void
    {
        foreach ([self::NO_TYP, 'Bearer'] as $typ) {
            $claims = $this->idTokenClaims('server-nonce', ['azp' => 'it-client']);
            unset($claims['typ']);
            if ($typ !== self::NO_TYP) {
                $claims['typ'] = $typ;
            }
            try {
                $this->authWithTokenBody($this->tokenBody($this->sign($claims)))->exchangeCode('code', 'verifier', 'server-nonce');
                self::fail('an id_token not typed "ID" must be refused by the exchange');
            } catch (KeycloakAuthError $refused) {
            }
            self::assertSame('authorization code exchange failed: invalid id_token: ' . self::NOT_AN_ID_TOKEN, $refused->getMessage());
            $cause = $refused->getPrevious();
            self::assertInstanceOf(TokenValidationError::class, $cause);
            self::assertSame(self::NOT_AN_ID_TOKEN, $cause->getMessage());
        }
    }

    /**
     * (A5) 교환의 id_token 검증과 액세스 토큰 검증은 **한** JWKS 저장소를 쓴다 — 캐시·재조회 게이트·백오프가 하나다.
     *
     * 토큰 엔드포인트와 JWKS 가 **한** HTTP 클라이언트를 쓴다(`KeycloakClient::create` 와 같은 배선) — 그래서 id_token
     * 쪽이 제 저장소를 따로 만들면, 그것이 어느 http 로 조회하든 이 카운터나 교환 자체가 그것을 본다.
     */
    public function testExchangeCodeAndValidateShareOneJwksStore(): void
    {
        $hits = new JwksHitCounter();
        [$auth, $cfg, $endpoints, $http] = $this->authOverOneClient(
            $hits,
            self::OVERRIDE,
            $this->signIdToken('server-nonce'),
            $this->sign($this->idTokenClaims('server-nonce'), kid: 'rotated-b'),
        );
        $auth->exchangeCode('code', 'verifier', 'server-nonce');
        self::assertSame(1, $hits->n, 'the exchange validates the id_token on a cold cache (one fetch)');
        $access = $this->sign($this->accessTokenClaims([self::OVERRIDE]));
        $auth->validate($access);
        self::assertSame(1, $hits->n, 'validate() after the exchange must reuse the key store the exchange warmed');

        // 재조회 게이트도 하나다 — validate() 가 미해결 kid 로 재조회를 쓰면, 곧이은 교환의 미해결 kid 는 조회 없이 막힌다.
        try {
            $auth->validate($this->sign($this->accessTokenClaims([self::OVERRIDE]), kid: 'rotated-a'));
            self::fail('an unresolved kid must be refused');
        } catch (TokenValidationError $unknown) {
        }
        self::assertSame('unknown kid "rotated-a"', $unknown->getMessage());
        self::assertSame(2, $hits->n, 'the first unresolved kid spends the refetch');
        try {
            $auth->exchangeCode('code', 'verifier', 'server-nonce');   // 토큰 응답 둘째 — kid 가 rotated-b 인 id_token
            self::fail('an unresolved kid inside the refetch window must be refused');
        } catch (KeycloakAuthError $limited) {
        }
        self::assertSame('authorization code exchange failed: invalid id_token: unknown kid "rotated-b" (refetch rate-limited)', $limited->getMessage());
        self::assertSame(2, $hits->n, 'the exchange must see the refetch validate() already spent');

        // 대조군: 저장소를 하나 더 만들면 같은 http 위에서 이 카운터가 그것을 센다 — 위의 1·2 는 공허하지 않다.
        (new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $http, new HttpFactory())))->validate($access);
        self::assertSame(3, $hits->n, 'a second key store fetches again, and this counter sees it');
    }

    /**
     * 토큰 엔드포인트와 JWKS 를 **한** Guzzle 클라이언트로 — `KeycloakClient::create` 의 배선과 같다.
     * 토큰 응답은 교환마다 `$idTokens` 를 차례로 싣는다.
     *
     * @return array{AuthClient, KeycloakConfig, OidcEndpoints, Client}
     */
    private function authOverOneClient(JwksHitCounter $hits, ?string $expectedAudience, string ...$idTokens): array
    {
        $cfg = $this->config($expectedAudience);
        $endpoints = new OidcEndpoints($cfg);
        $jwks = json_encode(['keys' => [$this->key['jwk']]], JSON_THROW_ON_ERROR);
        $tokens = array_map(fn (string $t): string => json_encode($this->tokenBody($t), JSON_THROW_ON_ERROR), $idTokens);
        $route = static function (RequestInterface $r) use ($hits, $jwks, &$tokens): PromiseInterface {
            if (str_ends_with($r->getUri()->getPath(), '/protocol/openid-connect/certs')) {
                ++$hits->n;

                return Create::promiseFor(new Response(200, ['Content-Type' => 'application/json'], $jwks));
            }
            $body = array_shift($tokens);
            self::assertIsString($body, 'more token requests than queued token responses');

            return Create::promiseFor(new Response(200, ['Content-Type' => 'application/json'], $body));
        };
        $http = new Client(['handler' => HandlerStack::create($route)]);
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $http, new HttpFactory()));

        return [new AuthClient($cfg, $endpoints, $validator, $http), $cfg, $endpoints, $http];
    }

    private function config(?string $expectedAudience = null): KeycloakConfig
    {
        return new KeycloakConfig(
            serverUrl: 'https://kc:8080',
            realm: 'it-realm',
            clientId: 'it-client',
            clientSecret: 's',
            redirectUri: 'https://app/cb',
            expectedAudience: $expectedAudience,
        );
    }

    /** @param array<string,mixed> $body */
    private function authWithTokenBody(array $body, bool $forbidJwks = false, ?JwksHitCounter $jwksHits = null, ?string $expectedAudience = null): AuthClient
    {
        $cfg = $this->config($expectedAudience);
        $endpoints = new OidcEndpoints($cfg);
        $tokenHttp = $body === []
            ? new Client()
            : new Client(['handler' => HandlerStack::create(new MockHandler([
                new Response(200, ['Content-Type' => 'application/json'], json_encode($body, JSON_THROW_ON_ERROR)),
            ]))]);
        $jwk = $this->key['jwk'];
        $jwksHttp = $forbidJwks
            ? new class () implements ClientInterface {
                public function sendRequest(RequestInterface $r): ResponseInterface
                {
                    throw new \RuntimeException('JWKS must not be fetched when expectedNonce is omitted');
                }
            }
        : new class ($jwk, $jwksHits) implements ClientInterface {
            /** @param array<string,mixed> $jwk */
            public function __construct(private array $jwk, private ?JwksHitCounter $hits) {}

            public function sendRequest(RequestInterface $r): ResponseInterface
            {
                if ($this->hits !== null) {
                    ++$this->hits->n;
                }

                return new Response(200, [], json_encode(['keys' => [$this->jwk]], JSON_THROW_ON_ERROR));
            }
        };
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $jwksHttp, new HttpFactory()));

        return new AuthClient($cfg, $endpoints, $validator, $tokenHttp);
    }

    /** @return array<string,mixed> */
    private function tokenBody(?string $idToken): array
    {
        $body = [
            'access_token' => 'AT',
            'token_type' => 'Bearer',
            'expires_in' => 300,
            'refresh_token' => 'RT',
            'scope' => 'openid',
        ];
        if ($idToken !== null) {
            $body['id_token'] = $idToken;
        }

        return $body;
    }

    private function signIdToken(string $nonce, ?string $priv = null): string
    {
        return $this->sign($this->idTokenClaims($nonce), $priv);
    }

    /**
     * Keycloak 이 내는 모양의 id_token 클레임 — typ "ID" 를 싣는다(id_token 검사가 그 밖을 거부한다). `$changes` 의 null 은
     * 그 클레임을 빼고, `exp` 는 지금부터의 초다.
     *
     * @param array<string,mixed> $changes
     * @return array<string,mixed>
     */
    private function idTokenClaims(string $nonce, array $changes = []): array
    {
        $claims = ['sub' => 'u', 'iss' => $this->iss, 'aud' => 'it-client', 'nonce' => $nonce, 'typ' => 'ID', 'exp' => time() + 300, 'iat' => time()];
        foreach ($changes as $name => $value) {
            if ($value === null) {
                unset($claims[$name]);
            } else {
                $claims[$name] = $name === 'exp' && \is_int($value) ? time() + $value : $value;
            }
        }

        return $claims;
    }

    /**
     * @param list<string> $aud
     * @return array<string,mixed>
     */
    private function accessTokenClaims(array $aud): array
    {
        // typ 는 Keycloak 이 액세스 토큰에 쓰는 `Bearer` 다(validate() 는 Bearer · DPoP 만 받는다).
        return ['sub' => 'u', 'iss' => $this->iss, 'aud' => $aud, 'azp' => 'it-client', 'typ' => 'Bearer', 'exp' => time() + 300, 'iat' => time()];
    }

    /** @param array<string,mixed> $claims */
    private function sign(array $claims, ?string $priv = null, string $kid = 'test-kid'): string
    {
        return FbJwt::encode($claims, $priv ?? $this->key['priv'], 'RS256', $kid);
    }

    /** @param array<string,mixed> $claims */
    private function signAs(string $signer, array $claims): string
    {
        return match ($signer) {
            'rs256' => $this->sign($claims),
            // 핀 밖 알고리즘 — 헤더 게이트가 먼저 거부하므로 키는 무엇이든 된다.
            'hs256' => FbJwt::encode($claims, str_repeat('k', 64), 'HS256', 'test-kid'),
            // JWKS 의 kid 를 사칭한 다른 키쌍 — 서명 검증이 거부한다.
            'foreign-key' => $this->sign($claims, self::foreignKey()),
            default => throw new \LogicException("unknown signer {$signer}"),
        };
    }

    private static function foreignKey(): string
    {
        $other = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($other);
        self::assertTrue(openssl_pkey_export($other, $priv));
        self::assertIsString($priv);

        return $priv;
    }
}

final class JwksHitCounter
{
    public int $n = 0;
}
