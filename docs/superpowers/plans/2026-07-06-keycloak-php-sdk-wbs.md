# Keycloak PHP SDK Implementation Plan (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 6번째 언어 PHP Keycloak SDK를 다른 5개 언어와 동형(§4 계약)으로 손수 구현 — 자체강화 JWT 검증, 단위 + 실제 Keycloak 26.6 Testcontainers 통합테스트, PHPStan max·PHP-CS-Fixer·composer audit, 커버리지 게이트.

**Architecture:** `php/` 단일 Composer 패키지(`xzawed/keycloak-sdk`, PSR-4 `Xzawed\Keycloak\`). 계층 `config → auth → jwt → admin → client`(동기). admin은 `fschmtt/keycloak-rest-api-client-php` 래핑, auth는 `league/oauth2-client` + `stevenmaguire/oauth2-keycloak` 래핑 + introspection/logout 손수, JWT는 `firebase/php-jwt`(RS256 프리미티브) + 자체 DoS-safe `JwksStore`. 하위 예외는 경계에서 `Keycloak*` 계급으로 변환.

**Tech Stack:** PHP 8.3+ · Composer · PHPUnit 12 · PHPStan(level max)+strict-rules · PHP-CS-Fixer(@PER-CS2.0+@PSR12) · Guzzle 7(PSR-18) · firebase/php-jwt ^7.1 · league/oauth2-client ^2.8 · stevenmaguire/oauth2-keycloak ^6.1 · fschmtt/keycloak-rest-api-client-php 0.42.0 · testcontainers/testcontainers ^1.0.

## Global Constraints

- **설계 스펙**: [docs/superpowers/specs/2026-07-06-keycloak-php-sdk-design.md](../specs/2026-07-06-keycloak-php-sdk-design.md) — 진실 원천(§4 계약 구현).
- **런타임**: PHP **8.3** 하한. CI 매트릭스 8.3·8.4. 배포명 Packagist `xzawed/keycloak-sdk`, 네임스페이스 `Xzawed\Keycloak\`, 태그 `php-v*`.
- **의존성 핀(정확)**: `firebase/php-jwt: ^7.1` · `league/oauth2-client: ^2.8` · `stevenmaguire/oauth2-keycloak: ^6.1` · `fschmtt/keycloak-rest-api-client-php: 0.42.0`(**정확 핀 — pre-1.0**) · `guzzlehttp/guzzle: ^7.9` · `guzzlehttp/psr7: ^2.7` · `psr/http-client: ^1.0` · `psr/http-factory: ^1.1`. dev: `phpunit/phpunit: ^12` · `phpstan/phpstan: ^2.2` + `phpstan/phpstan-strict-rules: ^2.0` + `phpstan/phpstan-phpunit: ^2.0` · `friendsofphp/php-cs-fixer: ^3.95` · `roave/security-advisories: dev-latest` · `testcontainers/testcontainers: ^1.0`.
- **라이선스**: Apache-2.0. groupId analog `io.github.xzawed`.
- **§4 계약**: 계층·명명·예외 계급·값타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`)·보안 불변식을 다른 5개 SDK와 동형으로 매핑. 하위 라이브러리 타입은 파사드 뒤에 숨긴다(문서화된 은닉성 예외: admin representation 노출, raw() 탈출구, 저수준 주입 시임).
- **예외 경계 변환**: 하위 예외(Guzzle·league `IdentityProviderException`·firebase `*Exception`/SPL)를 **항상** 경계에서 `Xzawed\Keycloak\Exception\Keycloak*`로 변환. 하위 타입 공개 API 누출 금지.
- **결합 규칙**: `admin`은 `auth`를 직접 알지 못한다. 접착제는 `TokenProvider`(또는 fschmtt의 독립 client-credentials).
- **보안 불변식**(CI 강제): JWT 자체강화(RS256 핀·`none` 거부·iss 정확·aud 포함·exp 필수·nbf·클록 스큐 30s·DoS-safe JWKS) · 토큰/시크릿 완전 마스킹 `***` · TLS 기본 on · 타임아웃 주입.
- **커버리지 게이트**: 로직 라인 ≥90%, 네트워크 경계(`AuthClient`·`Admin\*`·`KeycloakClient`) omit(phpunit.xml `source` 필터).
- **툴체인**: PHP는 시스템 설치(`php --version`으로 8.3+ 확인). Composer는 `composer`. 명령은 `php/`에서 실행. Docker Desktop은 통합테스트용(Task 11).

### 확정 라이브러리 API (딥리서치 byte-검증 — 아래 태스크 코드의 근거)

- **fschmtt 0.42.0**: `(new Builder())->withBaseUrl($url)->withGrantType(GrantType::clientCredentials($clientId,$clientSecret,$realm,$scope))->withHttpClient($guzzle)->build()`. `$kc->users()/clients()/realms()/roles()/groups()`. `Users::create($realm,User):void`(⚠️void — id는 후속 search로), `Users::get($realm,$id):User`(404→Guzzle `ClientException`), `Users::search($realm,?Criteria):UserCollection`, `Users::delete($realm,$id):void`. `Clients::import($realm,Client):Client`(⚠️create 아님·id 세팅 필요), `Clients::get`, `Clients::delete`. Representation: 마법 `__call`/`__get` — 생성 `new User(username:'x',email:'y',enabled:true)`, 읽기 `$u->getId()/getUsername()`. Collection: `foreach`/`count()`/`first()`. `new Criteria(['username'=>'x','exact'=>true])`. ⚠️첫 resource 접근 시 lazy `/admin/serverinfo` GET. fschmtt는 Guzzle 예외 미변환.
- **league ^2.8 + steven ^6.1**: `new Keycloak(['authServerUrl'=>..,'realm'=>..,'clientId'=>..,'clientSecret'=>..,'redirectUri'=>..,'version'=>'26.0.0'],['httpClient'=>$guzzle])`. ⚠️**`pkceMethod` 옵션은 no-op** → 프로바이더 서브클래스로 `getPkceMethod()` 오버라이드 필요. `getAuthorizationUrl(array):string`·`getState():string`·`getPkceCode():?string`·`setPkceCode($v):self`. `getAccessToken($grant,array):AccessTokenInterface`('authorization_code'['code'=>..],'client_credentials','refresh_token'['refresh_token'=>..]). `AccessToken::getToken():string`·`getRefreshToken():?string`·`getExpires():?int`(⚠️절대 epoch)·`getValues():array`(id_token 등). `getLogoutUrl(['access_token'=>$t]):string`. introspection 미제공 → RFC7662 손수. `IdentityProviderException::getCode()`(HTTP status)·`getResponseBody()`. transport는 Guzzle `ConnectException`.
- **firebase ^7.1**: `JWT::decode(string $jwt, Key|array $key, ?stdClass &$headers=null):stdClass`(⚠️3 파라미터만). `JWT::$leeway`(static)·`JWT::$timestamp`(static, 테스트용). `JWK::parseKey(array $jwk,?string 'RS256'):?Key`. `new Key($pem,'RS256')`. ⚠️`&$headers`는 성공 후에만 읽힘 → alg 핀은 첫 세그먼트를 직접 디코드(`JWT::urlsafeB64Decode`)해 사전 게이트. iss/aud 미검증(우리가). 예외: `SignatureInvalidException`/`ExpiredException`/`BeforeValidException`(전부 `\UnexpectedValueException` 상속) + SPL `\UnexpectedValueException`(unknown alg/kid/malformed)·`\InvalidArgumentException`·`\DomainException` — firebase 서브클래스 먼저 catch.

---

### Task 1: 스캐폴딩 (php/ · composer · 툴 설정)

**Files:**
- Create: `php/composer.json`
- Create: `php/phpunit.xml`
- Create: `php/phpstan.neon`
- Create: `php/.php-cs-fixer.dist.php`
- Create: `php/.gitignore`
- Create: `php/src/.gitkeep`, `php/tests/Unit/.gitkeep`

**Interfaces:**
- Produces: PSR-4 오토로드 `Xzawed\Keycloak\` → `src/`, `Xzawed\Keycloak\Tests\` → `tests/`. `composer`/`phpunit`/`phpstan`/`php-cs-fixer` 실행 가능.

- [ ] **Step 1: `composer.json` 작성**

```json
{
  "name": "xzawed/keycloak-sdk",
  "description": "Keycloak SDK for PHP — OIDC auth + Admin REST, isomorphic with the Java/Python/Node/Go/C# SDKs",
  "license": "Apache-2.0",
  "type": "library",
  "require": {
    "php": "^8.3",
    "firebase/php-jwt": "^7.1",
    "league/oauth2-client": "^2.8",
    "stevenmaguire/oauth2-keycloak": "^6.1",
    "fschmtt/keycloak-rest-api-client-php": "0.42.0",
    "guzzlehttp/guzzle": "^7.9",
    "guzzlehttp/psr7": "^2.7",
    "psr/http-client": "^1.0",
    "psr/http-factory": "^1.1"
  },
  "require-dev": {
    "phpunit/phpunit": "^12",
    "phpstan/phpstan": "^2.2",
    "phpstan/phpstan-strict-rules": "^2.0",
    "phpstan/phpstan-phpunit": "^2.0",
    "friendsofphp/php-cs-fixer": "^3.95",
    "roave/security-advisories": "dev-latest",
    "testcontainers/testcontainers": "^1.0"
  },
  "autoload": { "psr-4": { "Xzawed\\Keycloak\\": "src/" } },
  "autoload-dev": { "psr-4": { "Xzawed\\Keycloak\\Tests\\": "tests/" } },
  "scripts": {
    "test": "phpunit --testsuite unit",
    "test:it": "phpunit --testsuite integration",
    "stan": "phpstan analyse",
    "cs": "php-cs-fixer fix --dry-run --diff",
    "cs:fix": "php-cs-fixer fix"
  },
  "config": { "sort-packages": true, "allow-plugins": { "phpstan/extension-installer": false } }
}
```

- [ ] **Step 2: `phpunit.xml` 작성 (테스트 스위트 + 커버리지 경계 omit)**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<phpunit xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:noNamespaceSchemaLocation="vendor/phpunit/phpunit/phpunit.xsd"
         bootstrap="vendor/autoload.php" colors="true" cacheDirectory=".phpunit.cache"
         failOnWarning="true" failOnRisky="true">
  <testsuites>
    <testsuite name="unit"><directory>tests/Unit</directory></testsuite>
    <testsuite name="integration"><directory>tests/Integration</directory></testsuite>
  </testsuites>
  <source>
    <include><directory>src</directory></include>
    <!-- 네트워크 경계 — 통합테스트로 검증, 커버리지 게이트에서 제외 -->
    <exclude>
      <file>src/AuthClient.php</file>
      <directory>src/Admin</directory>
      <file>src/KeycloakClient.php</file>
    </exclude>
  </source>
</phpunit>
```

- [ ] **Step 3: `phpstan.neon` 작성**

```neon
includes:
  - vendor/phpstan/phpstan-strict-rules/rules.neon
  - vendor/phpstan/phpstan-phpunit/extension.neon
parameters:
  level: max
  paths:
    - src
    - tests
```

- [ ] **Step 4: `.php-cs-fixer.dist.php` 작성**

```php
<?php
$finder = PhpCsFixer\Finder::create()->in([__DIR__ . '/src', __DIR__ . '/tests']);
return (new PhpCsFixer\Config())
    ->setRules(['@PER-CS2.0' => true, '@PSR12' => true, 'declare_strict_types' => true])
    ->setFinder($finder);
```

- [ ] **Step 5: `.gitignore` 작성**

```
/vendor/
/.phpunit.cache/
/.php-cs-fixer.cache
/composer.lock
clover.xml
```

- [ ] **Step 6: 스캐폴딩 검증**

Run:
```bash
cd php && composer install
vendor/bin/phpunit --version && vendor/bin/phpstan --version && vendor/bin/php-cs-fixer --version
```
Expected: 4개 명령 모두 버전 출력(설치 성공). `composer install`이 4개 런타임 + dev 의존성 해석.

- [ ] **Step 7: Commit**

```bash
git add php/composer.json php/phpunit.xml php/phpstan.neon php/.php-cs-fixer.dist.php php/.gitignore php/src/.gitkeep php/tests/Unit/.gitkeep
git commit -m "feat(php): 스캐폴딩 — composer(xzawed/keycloak-sdk)·PHPUnit·PHPStan max·CS-Fixer·PSR-4"
```

---

### Task 2: Masking + 예외 계급

**Files:**
- Create: `php/src/Masking.php`
- Create: `php/src/Exception/` (KeycloakException 및 하위 8종)
- Test: `php/tests/Unit/MaskingTest.php`, `php/tests/Unit/ExceptionHierarchyTest.php`

**Interfaces:**
- Produces: `Xzawed\Keycloak\Masking::mask(?string): string`. 예외 계급 `Xzawed\Keycloak\Exception\{KeycloakException(base), KeycloakConfigError, KeycloakAuthError, KeycloakTransportError, KeycloakAdminError, KeycloakNotFoundError, KeycloakConflictError, KeycloakForbiddenError, TokenValidationError}`. `KeycloakAdminError`는 `getStatusCode(): ?int`.

- [ ] **Step 1: 실패 테스트 — Masking**

`php/tests/Unit/MaskingTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Masking;

final class MaskingTest extends TestCase
{
    public function testMasksNonEmptyFully(): void
    {
        self::assertSame('***', Masking::mask('super-secret-token'));
    }
    public function testEmptyAndNull(): void
    {
        self::assertSame('***', Masking::mask(''));   // 존재 여부도 노출 안 함
        self::assertSame('***', Masking::mask(null));
    }
    public function testNoPrefixLeak(): void
    {
        self::assertStringNotContainsString('super', Masking::mask('super-secret'));
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter MaskingTest`
Expected: FAIL — `Xzawed\Keycloak\Masking` 클래스 없음.

- [ ] **Step 3: Masking 구현**

`php/src/Masking.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

/** 토큰/시크릿을 완전 불투명 마스킹(접두 노출 없음). */
final class Masking
{
    public static function mask(?string $secret): string
    {
        return '***';
    }
}
```

- [ ] **Step 4: 실패 테스트 — 예외 계급**

`php/tests/Unit/ExceptionHierarchyTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Exception\{KeycloakException, KeycloakConfigError, KeycloakAuthError,
    KeycloakTransportError, KeycloakAdminError, KeycloakNotFoundError, KeycloakConflictError,
    KeycloakForbiddenError, TokenValidationError};

final class ExceptionHierarchyTest extends TestCase
{
    public function testAllExtendBase(): void
    {
        foreach ([KeycloakConfigError::class, KeycloakAuthError::class, KeycloakTransportError::class,
                  KeycloakAdminError::class, KeycloakNotFoundError::class, KeycloakConflictError::class,
                  KeycloakForbiddenError::class, TokenValidationError::class] as $cls) {
            self::assertTrue(is_a($cls, KeycloakException::class, true), "$cls should extend KeycloakException");
        }
    }
    public function testAdminSubtypesExtendAdminError(): void
    {
        self::assertTrue(is_a(KeycloakNotFoundError::class, KeycloakAdminError::class, true));
        self::assertTrue(is_a(KeycloakConflictError::class, KeycloakAdminError::class, true));
        self::assertTrue(is_a(KeycloakForbiddenError::class, KeycloakAdminError::class, true));
    }
    public function testAdminErrorCarriesStatus(): void
    {
        $e = new KeycloakNotFoundError('nope', 404);
        self::assertSame(404, $e->getStatusCode());
    }
}
```

- [ ] **Step 5: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter ExceptionHierarchyTest`
Expected: FAIL — 예외 클래스 없음.

- [ ] **Step 6: 예외 계급 구현**

`php/src/Exception/KeycloakException.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;

/** 모든 SDK 예외의 루트. 하위 라이브러리 예외는 경계에서 이 계급으로 변환된다. */
class KeycloakException extends \RuntimeException {}
```
`php/src/Exception/KeycloakConfigError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class KeycloakConfigError extends KeycloakException {}
```
`php/src/Exception/KeycloakAuthError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class KeycloakAuthError extends KeycloakException
{
    public function __construct(string $message, public readonly ?string $oauthError = null, ?\Throwable $previous = null)
    {
        parent::__construct($message, 0, $previous);
    }
}
```
`php/src/Exception/KeycloakTransportError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class KeycloakTransportError extends KeycloakException {}
```
`php/src/Exception/KeycloakAdminError.php` (base for the 3 status subtypes):
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
class KeycloakAdminError extends KeycloakException
{
    public function __construct(string $message, private readonly ?int $statusCode = null, ?\Throwable $previous = null)
    {
        parent::__construct($message, $statusCode ?? 0, $previous);
    }
    public function getStatusCode(): ?int { return $this->statusCode; }
}
```
`php/src/Exception/KeycloakNotFoundError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class KeycloakNotFoundError extends KeycloakAdminError {}
```
`php/src/Exception/KeycloakConflictError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class KeycloakConflictError extends KeycloakAdminError {}
```
`php/src/Exception/KeycloakForbiddenError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class KeycloakForbiddenError extends KeycloakAdminError {}
```
`php/src/Exception/TokenValidationError.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Exception;
final class TokenValidationError extends KeycloakException {}
```

- [ ] **Step 7: 통과 + 정적/포맷 확인**

Run: `cd php && vendor/bin/phpunit --filter 'MaskingTest|ExceptionHierarchyTest' && vendor/bin/phpstan analyse src/Masking.php src/Exception && vendor/bin/php-cs-fixer fix --dry-run --diff src/Masking.php src/Exception`
Expected: PASS(테스트), PHPStan 0 error, CS-Fixer 변경 없음.

- [ ] **Step 8: Commit**

```bash
git add php/src/Masking.php php/src/Exception php/tests/Unit/MaskingTest.php php/tests/Unit/ExceptionHierarchyTest.php
git commit -m "feat(php): Masking(완전 불투명) + KeycloakException 계급(Config/Auth/Transport/Admin→NotFound/Conflict/Forbidden/TokenValidation)"
```

---

### Task 3: KeycloakConfig

**Files:**
- Create: `php/src/KeycloakConfig.php`
- Test: `php/tests/Unit/KeycloakConfigTest.php`

**Interfaces:**
- Consumes: `KeycloakConfigError`.
- Produces: `readonly class KeycloakConfig` — ctor named args `serverUrl, realm, clientId, clientSecret=null, scopes=['openid'], connectTimeout=5.0, readTimeout=10.0, clockSkew=30, redirectUri=null`. 검증(필수 누락→`KeycloakConfigError`), `serverUrl` 후행 슬래시 제거. `__toString()`은 `clientSecret` 마스킹.

- [ ] **Step 1: 실패 테스트**

`php/tests/Unit/KeycloakConfigTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\Exception\KeycloakConfigError;

final class KeycloakConfigTest extends TestCase
{
    public function testValidConfigAndDefaults(): void
    {
        $c = new KeycloakConfig(serverUrl: 'http://kc:8080/', realm: 'it-realm', clientId: 'it-client', clientSecret: 'sec');
        self::assertSame('http://kc:8080', $c->serverUrl);   // 후행 슬래시 제거
        self::assertSame(['openid'], $c->scopes);
        self::assertSame(30, $c->clockSkew);
        self::assertSame(5.0, $c->connectTimeout);
    }
    public function testMissingServerUrlThrows(): void
    {
        $this->expectException(KeycloakConfigError::class);
        new KeycloakConfig(serverUrl: '', realm: 'r', clientId: 'c');
    }
    public function testMissingRealmThrows(): void
    {
        $this->expectException(KeycloakConfigError::class);
        new KeycloakConfig(serverUrl: 'http://kc:8080', realm: '', clientId: 'c');
    }
    public function testToStringMasksSecret(): void
    {
        $c = new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 'super-secret');
        self::assertStringNotContainsString('super-secret', (string) $c);
        self::assertStringContainsString('***', (string) $c);
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter KeycloakConfigTest`
Expected: FAIL — 클래스 없음.

- [ ] **Step 3: 구현**

`php/src/KeycloakConfig.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

use Xzawed\Keycloak\Exception\KeycloakConfigError;

/**
 * 불변 설정. 시크릿은 PHP 관용상 string이며 마스킹으로 심층방어(char[] 소거는 PHP에서 불가 — 과대광고 금지).
 * @param list<string> $scopes
 */
final readonly class KeycloakConfig
{
    /** @var list<string> */
    public array $scopes;

    /** @param list<string> $scopes */
    public function __construct(
        public string $serverUrl,
        public string $realm,
        public string $clientId,
        #[\SensitiveParameter] public ?string $clientSecret = null,
        array $scopes = ['openid'],
        public float $connectTimeout = 5.0,
        public float $readTimeout = 10.0,
        public int $clockSkew = 30,
        public ?string $redirectUri = null,
    ) {
        if (trim($this->serverUrl) === '') {
            throw new KeycloakConfigError('serverUrl is required');
        }
        if (trim($this->realm) === '') {
            throw new KeycloakConfigError('realm is required');
        }
        if (trim($this->clientId) === '') {
            throw new KeycloakConfigError('clientId is required');
        }
        // 후행 슬래시 제거(엔드포인트 조립 규약)
        $this->serverUrl = rtrim($this->serverUrl, '/');   // note: readonly-promoted; reassign in ctor is allowed once
        $this->scopes = array_values($scopes);
    }

    public function __toString(): string
    {
        return sprintf(
            'KeycloakConfig(serverUrl=%s, realm=%s, clientId=%s, clientSecret=%s)',
            $this->serverUrl,
            $this->realm,
            $this->clientId,
            Masking::mask($this->clientSecret),
        );
    }
}
```

> ⚠️ 구현 주의: `readonly` 프로퍼티는 ctor에서 **한 번만** 대입 가능하다. 위 `serverUrl`을 promoted-readonly로 두면 ctor 본문 재대입이 "이미 초기화됨" 에러가 날 수 있으므로, 구현 시 `serverUrl`을 promoted에서 빼고(일반 param) 본문에서 `$this->serverUrl = rtrim(...)`로 1회 대입하도록 조정하라(다른 promoted 프로퍼티는 그대로). 실제 컴파일/실행으로 확인.

- [ ] **Step 4: 통과 + 정적/포맷**

Run: `cd php && vendor/bin/phpunit --filter KeycloakConfigTest && vendor/bin/phpstan analyse src/KeycloakConfig.php`
Expected: PASS, PHPStan 0 error.

- [ ] **Step 5: Commit**

```bash
git add php/src/KeycloakConfig.php php/tests/Unit/KeycloakConfigTest.php
git commit -m "feat(php): KeycloakConfig(readonly·검증·후행슬래시 제거·시크릿 마스킹·기본값)"
```

---

### Task 4: Token 값 타입 + OidcEndpoints

**Files:**
- Create: `php/src/Token/TokenSet.php`, `ValidatedToken.php`, `IntrospectionResult.php`, `AuthorizationRequest.php`
- Create: `php/src/OidcEndpoints.php`
- Test: `php/tests/Unit/Token/TokenSetTest.php`, `ValidatedTokenTest.php`, `IntrospectionResultTest.php`, `php/tests/Unit/OidcEndpointsTest.php`

**Interfaces:**
- Produces:
  - `TokenSet` — `readonly` 값객체: `accessToken, tokenType='Bearer', expiresIn(int, 상대초), refreshToken=null, idToken=null, scope=null, expiresAt=null(절대 epoch)`. `static fromArray(array $r): self`(OAuth 응답 파싱·`expires_in`→expiresIn·issued+expires_in→expiresAt), `isExpired(int $now, int $skew): bool`, `__toString()`(access/refresh 마스킹).
  - `ValidatedToken` — `readonly`: `subject, audience(list<string>), issuer, expiresAt(?int), issuedAt(?int), claims(array<string,mixed>)`.
  - `IntrospectionResult` — `readonly`: `active(bool), username(?string), clientId(?string), claims(array)`. `static fromArray`.
  - `AuthorizationRequest` — `readonly`: `url(string), state(string), codeVerifier(string)`.
  - `OidcEndpoints` — ctor `(KeycloakConfig)`; getters `issuer(): string`, `token()`, `authorization()`, `introspection()`, `endSession()`, `jwks()`(URL 문자열 조립, 네트워크 없음).

- [ ] **Step 1: 실패 테스트 — TokenSet + OidcEndpoints (대표)**

`php/tests/Unit/Token/TokenSetTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit\Token;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Token\TokenSet;

final class TokenSetTest extends TestCase
{
    public function testFromArrayParsesAndComputesExpiresAt(): void
    {
        $ts = TokenSet::fromArray(['access_token' => 'at', 'token_type' => 'Bearer', 'expires_in' => 300, 'refresh_token' => 'rt'], now: 1000);
        self::assertSame('at', $ts->accessToken);
        self::assertSame(300, $ts->expiresIn);
        self::assertSame(1300, $ts->expiresAt);
    }
    public function testIsExpired(): void
    {
        $ts = TokenSet::fromArray(['access_token' => 'at', 'expires_in' => 300], now: 1000);
        self::assertFalse($ts->isExpired(now: 1200, skew: 30));
        self::assertTrue($ts->isExpired(now: 1290, skew: 30));   // 1290 >= 1300-30
    }
    public function testToStringMasksTokens(): void
    {
        $ts = TokenSet::fromArray(['access_token' => 'secret-at', 'refresh_token' => 'secret-rt', 'expires_in' => 60]);
        $s = (string) $ts;
        self::assertStringNotContainsString('secret-at', $s);
        self::assertStringNotContainsString('secret-rt', $s);
    }
}
```

`php/tests/Unit/OidcEndpointsTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\OidcEndpoints;

final class OidcEndpointsTest extends TestCase
{
    public function testAssembly(): void
    {
        $e = new OidcEndpoints(new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'it-realm', clientId: 'c'));
        self::assertSame('http://kc:8080/realms/it-realm', $e->issuer());
        self::assertSame('http://kc:8080/realms/it-realm/protocol/openid-connect/token', $e->token());
        self::assertSame('http://kc:8080/realms/it-realm/protocol/openid-connect/token/introspect', $e->introspection());
        self::assertSame('http://kc:8080/realms/it-realm/protocol/openid-connect/logout', $e->endSession());
        self::assertSame('http://kc:8080/realms/it-realm/protocol/openid-connect/certs', $e->jwks());
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter 'TokenSetTest|OidcEndpointsTest'`
Expected: FAIL — 클래스 없음.

- [ ] **Step 3: 구현 — TokenSet**

`php/src/Token/TokenSet.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Token;
use Xzawed\Keycloak\Masking;

final readonly class TokenSet
{
    public function __construct(
        #[\SensitiveParameter] public string $accessToken,
        public string $tokenType = 'Bearer',
        public int $expiresIn = 0,
        #[\SensitiveParameter] public ?string $refreshToken = null,
        public ?string $idToken = null,
        public ?string $scope = null,
        public ?int $expiresAt = null,
    ) {}

    /** @param array<string,mixed> $r OAuth 토큰 응답 */
    public static function fromArray(array $r, ?int $now = null): self
    {
        $now ??= \time();
        $expiresIn = isset($r['expires_in']) ? (int) $r['expires_in'] : 0;
        return new self(
            accessToken: (string) $r['access_token'],
            tokenType: isset($r['token_type']) ? (string) $r['token_type'] : 'Bearer',
            expiresIn: $expiresIn,
            refreshToken: isset($r['refresh_token']) ? (string) $r['refresh_token'] : null,
            idToken: isset($r['id_token']) ? (string) $r['id_token'] : null,
            scope: isset($r['scope']) ? (string) $r['scope'] : null,
            expiresAt: $expiresIn > 0 ? $now + $expiresIn : null,
        );
    }

    public function isExpired(?int $now = null, int $skew = 30): bool
    {
        if ($this->expiresAt === null) {
            return false;
        }
        $now ??= \time();
        return $now >= ($this->expiresAt - $skew);
    }

    public function __toString(): string
    {
        return sprintf('TokenSet(tokenType=%s, expiresIn=%d, accessToken=%s, refreshToken=%s)',
            $this->tokenType, $this->expiresIn, Masking::mask($this->accessToken), Masking::mask($this->refreshToken));
    }
}
```

- [ ] **Step 4: 구현 — ValidatedToken, IntrospectionResult, AuthorizationRequest, OidcEndpoints**

`php/src/Token/ValidatedToken.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Token;

final readonly class ValidatedToken
{
    /**
     * @param list<string> $audience
     * @param array<string,mixed> $claims
     */
    public function __construct(
        public string $subject,
        public array $audience,
        public string $issuer,
        public ?int $expiresAt,
        public ?int $issuedAt,
        public array $claims,
    ) {}
}
```
`php/src/Token/IntrospectionResult.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Token;

final readonly class IntrospectionResult
{
    /** @param array<string,mixed> $claims */
    public function __construct(
        public bool $active,
        public ?string $username = null,
        public ?string $clientId = null,
        public array $claims = [],
    ) {}

    /** @param array<string,mixed> $r RFC 7662 introspection 응답 */
    public static function fromArray(array $r): self
    {
        return new self(
            active: (bool) ($r['active'] ?? false),
            username: isset($r['username']) ? (string) $r['username'] : null,
            clientId: isset($r['client_id']) ? (string) $r['client_id'] : null,
            claims: $r,
        );
    }
}
```
`php/src/Token/AuthorizationRequest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Token;

final readonly class AuthorizationRequest
{
    public function __construct(
        public string $url,
        public string $state,
        #[\SensitiveParameter] public string $codeVerifier,
    ) {}
}
```
`php/src/OidcEndpoints.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

final class OidcEndpoints
{
    private string $base;

    public function __construct(KeycloakConfig $config)
    {
        $this->base = $config->serverUrl . '/realms/' . $config->realm;
    }

    public function issuer(): string { return $this->base; }
    public function token(): string { return $this->base . '/protocol/openid-connect/token'; }
    public function authorization(): string { return $this->base . '/protocol/openid-connect/auth'; }
    public function introspection(): string { return $this->base . '/protocol/openid-connect/token/introspect'; }
    public function endSession(): string { return $this->base . '/protocol/openid-connect/logout'; }
    public function jwks(): string { return $this->base . '/protocol/openid-connect/certs'; }
}
```

- [ ] **Step 5: ValidatedToken/IntrospectionResult 테스트 추가 + 전체 통과**

`php/tests/Unit/Token/IntrospectionResultTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit\Token;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Token\IntrospectionResult;

final class IntrospectionResultTest extends TestCase
{
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
    }
}
```
`php/tests/Unit/Token/ValidatedTokenTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit\Token;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\Token\ValidatedToken;

final class ValidatedTokenTest extends TestCase
{
    public function testHoldsClaims(): void
    {
        $vt = new ValidatedToken('sub-1', ['it-client'], 'http://kc:8080/realms/it-realm', 2000, 1000, ['sub' => 'sub-1']);
        self::assertSame('sub-1', $vt->subject);
        self::assertContains('it-client', $vt->audience);
    }
}
```

Run: `cd php && vendor/bin/phpunit --filter 'TokenSetTest|ValidatedTokenTest|IntrospectionResultTest|OidcEndpointsTest' && vendor/bin/phpstan analyse src/Token src/OidcEndpoints.php`
Expected: PASS, PHPStan 0 error.

- [ ] **Step 6: Commit**

```bash
git add php/src/Token php/src/OidcEndpoints.php php/tests/Unit/Token php/tests/Unit/OidcEndpointsTest.php
git commit -m "feat(php): 값타입 TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest + OidcEndpoints(URL 조립)"
```

---

### Task 5: TokenProvider + ClientCredentialsTokenProvider

**Files:**
- Create: `php/src/TokenProvider.php` (interface), `php/src/ClientCredentialsTokenProvider.php`
- Test: `php/tests/Unit/ClientCredentialsTokenProviderTest.php`

**Interfaces:**
- Consumes: `KeycloakConfig`, `OidcEndpoints`, `TokenSet`, `KeycloakAuthError`, `KeycloakTransportError`, PSR-18 `ClientInterface`, PSR-17 `RequestFactoryInterface`+`StreamFactoryInterface`.
- Produces: `interface TokenProvider { public function getToken(): string; }`. `ClientCredentialsTokenProvider implements TokenProvider` — ctor `(KeycloakConfig, OidcEndpoints, ClientInterface, RequestFactoryInterface, StreamFactoryInterface)`. `getToken()` = 캐시된 access_token(만료 전 재사용, single-flight), 만료 시 client-credentials POST. `KeycloakAuthError`(OAuth 오류)·`KeycloakTransportError`(네트워크) 변환.
- 주: 이 컴포넌트는 §4 동형 추상화다. admin(fschmtt)은 자체 client-credentials로 독립 인증하므로 이 클래스를 강제 사용하지 않지만, isomorphic core로 제공·단위테스트한다(Go의 "gocloak client-credentials 기본 = TokenProvider"와 동형).

- [ ] **Step 1: 실패 테스트 (mock PSR-18)**

`php/tests/Unit/ClientCredentialsTokenProviderTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\{RequestInterface, ResponseInterface, StreamInterface};
use GuzzleHttp\Psr7\{HttpFactory, Response};
use Xzawed\Keycloak\{KeycloakConfig, OidcEndpoints, ClientCredentialsTokenProvider};
use Xzawed\Keycloak\Exception\KeycloakAuthError;

final class ClientCredentialsTokenProviderTest extends TestCase
{
    private function config(): KeycloakConfig
    {
        return new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 's');
    }

    public function testFetchesAndCachesToken(): void
    {
        $calls = 0;
        $http = new class($calls) implements ClientInterface {
            public function __construct(public int &$calls) {}
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $this->calls++;
                return new Response(200, ['Content-Type' => 'application/json'],
                    json_encode(['access_token' => 'AT', 'token_type' => 'Bearer', 'expires_in' => 300]));
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        self::assertSame('AT', $p->getToken());
        self::assertSame('AT', $p->getToken());   // 캐시 재사용
        self::assertSame(1, $calls);              // 두 번째는 네트워크 없음
    }

    public function testOauthErrorMapped(): void
    {
        $http = new class implements ClientInterface {
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                return new Response(401, ['Content-Type' => 'application/json'],
                    json_encode(['error' => 'invalid_client', 'error_description' => 'bad']));
            }
        };
        $f = new HttpFactory();
        $p = new ClientCredentialsTokenProvider($this->config(), new OidcEndpoints($this->config()), $http, $f, $f);
        $this->expectException(KeycloakAuthError::class);
        $p->getToken();
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter ClientCredentialsTokenProviderTest`
Expected: FAIL — 클래스 없음.

- [ ] **Step 3: 구현**

`php/src/TokenProvider.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

interface TokenProvider
{
    /** 유효한 bearer access token 문자열(만료 전 재사용). @throws \Xzawed\Keycloak\Exception\KeycloakException */
    public function getToken(): string;
}
```
`php/src/ClientCredentialsTokenProvider.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

use Psr\Http\Client\ClientInterface;
use Psr\Http\Client\ClientExceptionInterface;
use Psr\Http\Client\NetworkExceptionInterface;
use Psr\Http\Message\RequestFactoryInterface;
use Psr\Http\Message\StreamFactoryInterface;
use Xzawed\Keycloak\Token\TokenSet;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;

final class ClientCredentialsTokenProvider implements TokenProvider
{
    private ?TokenSet $cached = null;

    public function __construct(
        private readonly KeycloakConfig $config,
        private readonly OidcEndpoints $endpoints,
        private readonly ClientInterface $http,
        private readonly RequestFactoryInterface $requestFactory,
        private readonly StreamFactoryInterface $streamFactory,
    ) {}

    public function getToken(): string
    {
        if ($this->cached !== null && !$this->cached->isExpired(skew: $this->config->clockSkew)) {
            return $this->cached->accessToken;
        }
        $this->cached = $this->fetch();
        return $this->cached->accessToken;
    }

    private function fetch(): TokenSet
    {
        $body = http_build_query([
            'grant_type' => 'client_credentials',
            'client_id' => $this->config->clientId,
            'client_secret' => $this->config->clientSecret ?? '',
            'scope' => implode(' ', $this->config->scopes),
        ]);
        $request = $this->requestFactory->createRequest('POST', $this->endpoints->token())
            ->withHeader('Content-Type', 'application/x-www-form-urlencoded')
            ->withBody($this->streamFactory->createStream($body));
        try {
            $response = $this->http->sendRequest($request);
        } catch (NetworkExceptionInterface $e) {
            throw new KeycloakTransportError('token endpoint unreachable', previous: $e);
        } catch (ClientExceptionInterface $e) {
            throw new KeycloakTransportError('token request failed', previous: $e);
        }
        $json = json_decode((string) $response->getBody(), true);
        if ($response->getStatusCode() !== 200 || !is_array($json) || !isset($json['access_token'])) {
            $oauth = is_array($json) && isset($json['error']) ? (string) $json['error'] : null;
            throw new KeycloakAuthError('client-credentials failed', oauthError: $oauth);
        }
        return TokenSet::fromArray($json);
    }
}
```

- [ ] **Step 4: 통과 + 정적**

Run: `cd php && vendor/bin/phpunit --filter ClientCredentialsTokenProviderTest && vendor/bin/phpstan analyse src/TokenProvider.php src/ClientCredentialsTokenProvider.php`
Expected: PASS, PHPStan 0 error.

- [ ] **Step 5: Commit**

```bash
git add php/src/TokenProvider.php php/src/ClientCredentialsTokenProvider.php php/tests/Unit/ClientCredentialsTokenProviderTest.php
git commit -m "feat(php): TokenProvider 인터페이스 + ClientCredentialsTokenProvider(캐시·오류변환, isomorphic core)"
```

---

### Task 6: JwksStore (DoS-safe JWKS)

**Files:**
- Create: `php/src/Jwks/JwksStore.php`
- Test: `php/tests/Unit/Jwks/JwksStoreTest.php`

**Interfaces:**
- Consumes: PSR-18 `ClientInterface`, PSR-17 factories, `KeycloakTransportError`, `TokenValidationError`.
- Produces: `JwksStore` — ctor `(string $jwksUri, ClientInterface, RequestFactoryInterface, int $minRefetchIntervalSeconds = 60)`. `getKeyByKid(string $kid): array` — kid로 캐시 조회, **미해결 kid에만** 재조회(rate-limit: 마지막 재조회 후 `$minRefetchInterval` 이내면 재조회 안 하고 `TokenValidationError` "unknown kid"), single-flight(동시 미스는 1회 fetch). 반환은 선택된 JWK 연관배열. 네트워크 오류→`KeycloakTransportError`.
- **불변식(단위 테스트로 고정)**: (a) 캐시 히트는 네트워크 0회, (b) 미해결 kid는 1회 재조회, (c) 재조회 직후 또다시 미해결 kid는 rate-limit로 재조회 안 함(위조 서명 kid 스팸 방지).

- [ ] **Step 1: 실패 테스트 (mock PSR-18, 호출 카운트)**

`php/tests/Unit/Jwks/JwksStoreTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit\Jwks;
use PHPUnit\Framework\TestCase;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\{RequestInterface, ResponseInterface};
use GuzzleHttp\Psr7\{HttpFactory, Response};
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\Exception\TokenValidationError;

final class JwksStoreTest extends TestCase
{
    /** @param list<array<string,mixed>> $keys */
    private function http(array $keys, int &$calls): ClientInterface
    {
        return new class($keys, $calls) implements ClientInterface {
            /** @param list<array<string,mixed>> $keys */
            public function __construct(private array $keys, public int &$calls) {}
            public function sendRequest(RequestInterface $request): ResponseInterface
            {
                $this->calls++;
                return new Response(200, [], json_encode(['keys' => $this->keys]));
            }
        };
    }

    public function testCacheHitNoNetworkAfterFirst(): void
    {
        $calls = 0;
        $f = new HttpFactory();
        $store = new JwksStore('http://kc/certs', $this->http([['kid' => 'k1', 'kty' => 'RSA']], $calls), $f);
        self::assertSame('k1', $store->getKeyByKid('k1')['kid']);
        self::assertSame('k1', $store->getKeyByKid('k1')['kid']);
        self::assertSame(1, $calls);   // 두 번째는 캐시
    }

    public function testUnresolvedKidRefetchesOnceThenRateLimited(): void
    {
        $calls = 0;
        $f = new HttpFactory();
        $store = new JwksStore('http://kc/certs', $this->http([['kid' => 'k1', 'kty' => 'RSA']], $calls), $f, minRefetchIntervalSeconds: 60);
        $store->getKeyByKid('k1');            // fetch #1
        try { $store->getKeyByKid('k2'); } catch (TokenValidationError) {}  // unresolved → refetch #2
        try { $store->getKeyByKid('k3'); } catch (TokenValidationError) {}  // rate-limited → NO refetch
        self::assertSame(2, $calls);          // 위조 kid 스팸이 IdP를 때리지 않음
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter JwksStoreTest`
Expected: FAIL — 클래스 없음.

- [ ] **Step 3: 구현**

`php/src/Jwks/JwksStore.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Jwks;

use Psr\Http\Client\ClientInterface;
use Psr\Http\Client\ClientExceptionInterface;
use Psr\Http\Message\RequestFactoryInterface;
use Xzawed\Keycloak\Exception\KeycloakTransportError;
use Xzawed\Keycloak\Exception\TokenValidationError;

/**
 * DoS-safe JWKS 스토어: kid로 캐시, 미해결 kid에만 재조회, 재조회는 rate-limit.
 * 위조 서명(잘못된 kid) 스팸이 IdP를 때리는 미인증 DoS 증폭을 차단한다.
 */
final class JwksStore
{
    /** @var array<string,array<string,mixed>> kid → JWK */
    private array $keys = [];
    private bool $loadedOnce = false;
    private ?int $lastRefetchAt = null;

    public function __construct(
        private readonly string $jwksUri,
        private readonly ClientInterface $http,
        private readonly RequestFactoryInterface $requestFactory,
        private readonly int $minRefetchIntervalSeconds = 60,
    ) {}

    /**
     * @return array<string,mixed> 선택된 JWK
     * @throws TokenValidationError kid 미해결(재조회 후에도) / @throws KeycloakTransportError 네트워크
     */
    public function getKeyByKid(string $kid): array
    {
        if (!$this->loadedOnce) {
            $this->fetch();   // 초기 로드는 rate-limit 소모하지 않음(첫 키회전 허용)
        }
        if (isset($this->keys[$kid])) {
            return $this->keys[$kid];
        }
        // 미해결 kid → 조건부 재조회(rate-limit)
        $now = \time();
        if ($this->lastRefetchAt !== null && ($now - $this->lastRefetchAt) < $this->minRefetchIntervalSeconds) {
            throw new TokenValidationError(sprintf('unknown kid "%s" (refetch rate-limited)', $kid));
        }
        $this->fetch();
        $this->lastRefetchAt = $now;
        if (isset($this->keys[$kid])) {
            return $this->keys[$kid];
        }
        throw new TokenValidationError(sprintf('unknown kid "%s"', $kid));
    }

    private function fetch(): void
    {
        $request = $this->requestFactory->createRequest('GET', $this->jwksUri);
        try {
            $response = $this->http->sendRequest($request);
        } catch (ClientExceptionInterface $e) {
            throw new KeycloakTransportError('JWKS fetch failed', previous: $e);
        }
        $json = json_decode((string) $response->getBody(), true);
        if ($response->getStatusCode() !== 200 || !is_array($json) || !isset($json['keys']) || !is_array($json['keys'])) {
            throw new KeycloakTransportError('JWKS response invalid');
        }
        $map = [];
        /** @var array<string,mixed> $key */
        foreach ($json['keys'] as $key) {
            if (is_array($key) && isset($key['kid']) && is_string($key['kid'])) {
                $map[$key['kid']] = $key;
            }
        }
        $this->keys = $map;
        $this->loadedOnce = true;
    }
}
```

> 주(single-flight): PHP 요청-스코프는 단일 스레드라 프로세스 내 동시 미스가 사실상 없다(요청당 1 프로세스). 진짜 병렬 걱정은 다중 요청이지만 그건 프로세스 간이라 공유 캐시가 아니면 무의미 — 여기선 인스턴스 내 rate-limit로 미인증 DoS 증폭을 막는 것이 핵심 불변식이다(Go singleflight의 요청-내 수렴과 동형 목적).

- [ ] **Step 4: 통과 + 정적**

Run: `cd php && vendor/bin/phpunit --filter JwksStoreTest && vendor/bin/phpstan analyse src/Jwks`
Expected: PASS(3 불변식), PHPStan 0 error.

- [ ] **Step 5: Commit**

```bash
git add php/src/Jwks php/tests/Unit/Jwks
git commit -m "feat(php): JwksStore — DoS-safe JWKS(kid 캐시·미해결만 재조회·rate-limit)"
```

---

### Task 7: JwtValidator (자체강화 — 🔴 보안 핵심)

**Files:**
- Create: `php/src/JwtValidator.php`
- Test: `php/tests/Unit/JwtValidatorTest.php`

**Interfaces:**
- Consumes: firebase `JWT`/`JWK`/`Key`, `JwksStore`, `KeycloakConfig`, `OidcEndpoints`, `ValidatedToken`, `TokenValidationError`.
- Produces: `JwtValidator` — ctor `(KeycloakConfig, OidcEndpoints, JwksStore)`. `validate(string $jwt): ValidatedToken` — (1) 첫 세그먼트 자체 디코드로 **`header.alg === 'RS256'` 사전 게이트**(none/미서명/다른 alg 즉시 거부), kid 추출; (2) `JwksStore::getKeyByKid` → `JWK::parseKey($jwk, 'RS256')` → `JWT::$leeway = clockSkew` → `JWT::decode($jwt, $key, $headers)`(서명·exp·nbf 검증); (3) payload에서 **iss 정확일치**·**aud 포함**(string→list 정규화) 강제; (4) `ValidatedToken` 매핑. firebase 예외(서브클래스 먼저)·SPL·JwksStore 예외를 `TokenValidationError`로 변환. **테스트에 RSA 키쌍을 생성**해 실제 서명/검증.

- [ ] **Step 1: 실패 테스트 (RSA 키로 실제 토큰 서명 — 강화 불변식 전부)**

`php/tests/Unit/JwtValidatorTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Firebase\JWT\JWT as FbJwt;
use Psr\Http\Client\ClientInterface;
use Psr\Http\Message\{RequestInterface, ResponseInterface};
use GuzzleHttp\Psr7\{HttpFactory, Response};
use Xzawed\Keycloak\{KeycloakConfig, OidcEndpoints, JwtValidator};
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\Exception\TokenValidationError;

final class JwtValidatorTest extends TestCase
{
    /** @var array{priv:string,jwk:array<string,mixed>} */
    private array $key;
    private string $iss = 'http://kc:8080/realms/it-realm';

    protected function setUp(): void
    {
        // RSA 키쌍 생성 + JWKS 엔트리(n,e) 구성
        $res = openssl_pkey_new(['private_key_bits' => 2048, 'private_key_type' => OPENSSL_KEYTYPE_RSA]);
        self::assertNotFalse($res);
        openssl_pkey_export($res, $priv);
        $details = openssl_pkey_get_details($res);
        $jwk = [
            'kty' => 'RSA', 'kid' => 'test-kid', 'use' => 'sig', 'alg' => 'RS256',
            'n' => rtrim(strtr(base64_encode($details['rsa']['n']), '+/', '-_'), '='),
            'e' => rtrim(strtr(base64_encode($details['rsa']['e']), '+/', '-_'), '='),
        ];
        $this->key = ['priv' => $priv, 'jwk' => $jwk];
    }

    private function validator(): JwtValidator
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'it-realm', clientId: 'it-client');
        $f = new HttpFactory();
        $jwk = $this->key['jwk'];
        $http = new class($jwk) implements ClientInterface {
            /** @param array<string,mixed> $jwk */
            public function __construct(private array $jwk) {}
            public function sendRequest(RequestInterface $r): ResponseInterface
            {
                return new Response(200, [], json_encode(['keys' => [$this->jwk]]));
            }
        };
        $store = new JwksStore('http://kc:8080/realms/it-realm/protocol/openid-connect/certs', $http, $f);
        return new JwtValidator($cfg, new OidcEndpoints($cfg), $store);
    }

    /** @param array<string,mixed> $claims */
    private function sign(array $claims, string $alg = 'RS256', ?string $kid = 'test-kid'): string
    {
        return FbJwt::encode($claims, $this->key['priv'], $alg, $kid);
    }

    /** @return array<string,mixed> */
    private function goodClaims(): array
    {
        return ['sub' => 's1', 'iss' => $this->iss, 'aud' => ['it-client', 'account'], 'exp' => time() + 300, 'iat' => time()];
    }

    public function testValidTokenPasses(): void
    {
        $vt = $this->validator()->validate($this->sign($this->goodClaims()));
        self::assertSame('s1', $vt->subject);
        self::assertContains('it-client', $vt->audience);
        self::assertSame($this->iss, $vt->issuer);
    }
    public function testRejectsNoneAlg(): void
    {
        // alg=none 토큰을 수동 구성(header.alg=none, 서명 빈값)
        $h = rtrim(strtr(base64_encode(json_encode(['alg' => 'none', 'typ' => 'JWT'])), '+/', '-_'), '=');
        $p = rtrim(strtr(base64_encode(json_encode($this->goodClaims())), '+/', '-_'), '=');
        $this->expectException(TokenValidationError::class);
        $this->validator()->validate("$h.$p.");
    }
    public function testRejectsWrongIssuer(): void
    {
        $c = $this->goodClaims(); $c['iss'] = 'http://evil/realms/it-realm';
        $this->expectException(TokenValidationError::class);
        $this->validator()->validate($this->sign($c));
    }
    public function testRejectsAudienceNotContainingClient(): void
    {
        $c = $this->goodClaims(); $c['aud'] = ['other-client'];
        $this->expectException(TokenValidationError::class);
        $this->validator()->validate($this->sign($c));
    }
    public function testRejectsExpired(): void
    {
        $c = $this->goodClaims(); $c['exp'] = time() - 100;
        $this->expectException(TokenValidationError::class);
        $this->validator()->validate($this->sign($c));
    }
    public function testRejectsMissingExp(): void
    {
        $c = $this->goodClaims(); unset($c['exp']);
        $this->expectException(TokenValidationError::class);   // exp 필수
        $this->validator()->validate($this->sign($c));
    }
    public function testRejectsUnknownKid(): void
    {
        $this->expectException(TokenValidationError::class);
        $this->validator()->validate($this->sign($this->goodClaims(), kid: 'other-kid'));
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter JwtValidatorTest`
Expected: FAIL — `JwtValidator` 없음.

- [ ] **Step 3: 구현**

`php/src/JwtValidator.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

use Firebase\JWT\JWT as FbJwt;
use Firebase\JWT\JWK;
use Firebase\JWT\Key;
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\Token\ValidatedToken;
use Xzawed\Keycloak\Exception\TokenValidationError;

/**
 * 자체강화 JWT 검증: RS256 핀(헤더 불신)·none 거부·iss 정확·aud 포함·exp 필수·nbf·클록 스큐·DoS-safe JWKS.
 * firebase/php-jwt는 서명/exp/nbf 검증 프리미티브로만 쓰고, alg 핀·iss·aud는 이 클래스가 강제한다.
 */
final class JwtValidator
{
    private const PINNED_ALG = 'RS256';

    public function __construct(
        private readonly KeycloakConfig $config,
        private readonly OidcEndpoints $endpoints,
        private readonly JwksStore $jwks,
    ) {}

    public function validate(string $jwt): ValidatedToken
    {
        // (1) 헤더 사전 게이트 — alg를 신뢰하지 않고 우리가 RS256로 핀, none/미서명 즉시 거부, kid 추출
        $header = $this->decodeHeader($jwt);
        $alg = isset($header['alg']) && is_string($header['alg']) ? $header['alg'] : null;
        if ($alg !== self::PINNED_ALG) {
            throw new TokenValidationError(sprintf('algorithm not allowed: %s', $alg ?? '(none)'));
        }
        $kid = isset($header['kid']) && is_string($header['kid']) ? $header['kid'] : null;
        if ($kid === null) {
            throw new TokenValidationError('missing kid');
        }

        // (2) JWKS에서 kid로 키 → firebase Key → 서명/exp/nbf 검증(스큐 적용)
        $jwk = $this->jwks->getKeyByKid($kid);
        $key = JWK::parseKey($jwk, self::PINNED_ALG);
        if ($key === null) {
            throw new TokenValidationError('unusable JWKS key');
        }
        FbJwt::$leeway = $this->config->clockSkew;
        try {
            /** @var \stdClass $payload */
            $payload = FbJwt::decode($jwt, $key);
        } catch (\UnexpectedValueException | \InvalidArgumentException | \DomainException $e) {
            // firebase SignatureInvalid/Expired/BeforeValid(모두 \UnexpectedValueException 상속) + SPL 전부 포함
            throw new TokenValidationError('token verification failed: ' . $e->getMessage(), previous: $e);
        }

        // (3) exp 필수 + iss 정확 + aud 포함(firebase는 iss/aud 미검증)
        $claims = (array) $payload;
        if (!isset($claims['exp'])) {
            throw new TokenValidationError('exp claim is required');
        }
        $iss = isset($claims['iss']) ? (string) $claims['iss'] : '';
        if ($iss !== $this->endpoints->issuer()) {
            throw new TokenValidationError(sprintf('issuer mismatch: %s', $iss));
        }
        $aud = $this->normalizeAudience($claims['aud'] ?? []);
        if (!in_array($this->config->clientId, $aud, true)) {
            throw new TokenValidationError('audience does not contain clientId');
        }

        // (4) 매핑
        return new ValidatedToken(
            subject: isset($claims['sub']) ? (string) $claims['sub'] : '',
            audience: $aud,
            issuer: $iss,
            expiresAt: isset($claims['exp']) ? (int) $claims['exp'] : null,
            issuedAt: isset($claims['iat']) ? (int) $claims['iat'] : null,
            claims: $claims,
        );
    }

    /** @return array<string,mixed> */
    private function decodeHeader(string $jwt): array
    {
        $parts = explode('.', $jwt);
        if (count($parts) !== 3) {
            throw new TokenValidationError('malformed JWT');
        }
        $decoded = json_decode(FbJwt::urlsafeB64Decode($parts[0]), true);
        if (!is_array($decoded)) {
            throw new TokenValidationError('invalid JWT header');
        }
        return $decoded;
    }

    /**
     * @param mixed $aud
     * @return list<string>
     */
    private function normalizeAudience($aud): array
    {
        if (is_string($aud)) {
            return [$aud];
        }
        if (is_array($aud)) {
            return array_values(array_map(static fn ($a): string => (string) $a, $aud));
        }
        return [];
    }
}
```

- [ ] **Step 4: 통과(강화 불변식 전부) + 정적**

Run: `cd php && vendor/bin/phpunit --filter JwtValidatorTest && vendor/bin/phpstan analyse src/JwtValidator.php`
Expected: PASS(valid·none·iss·aud·expired·missing-exp·unknown-kid 전부), PHPStan 0 error.

- [ ] **Step 5: Commit**

```bash
git add php/src/JwtValidator.php php/tests/Unit/JwtValidatorTest.php
git commit -m "feat(php): JwtValidator 자체강화 — RS256 핀·none 거부·iss 정확·aud 포함·exp 필수·JwksStore(보안 핵심)"
```

---

### Task 8: AuthClient (league+steven 래핑 + introspect/logout 손수)

**Files:**
- Create: `php/src/AuthClient.php`, `php/src/Internal/PkceKeycloakProvider.php`
- Test: `php/tests/Unit/AuthMappingTest.php` (매핑 헬퍼만 단위; 실제 흐름은 통합 Task 11)

**Interfaces:**
- Consumes: `stevenmaguire\...\Keycloak`, `league\...\AccessToken`, `IdentityProviderException`, Guzzle `Client`+`ConnectException`, PSR-18/17, `KeycloakConfig`, `OidcEndpoints`, `TokenSet`, `IntrospectionResult`, `AuthorizationRequest`, `JwtValidator`, 예외들.
- Produces: `AuthClient` — ctor `(KeycloakConfig, OidcEndpoints, JwtValidator, GuzzleHttp\ClientInterface)`. 메서드: `createAuthorizationRequest(): AuthorizationRequest`, `exchangeCode(string $code, string $state, string $codeVerifier): TokenSet`, `clientCredentialsToken(): TokenSet`, `refresh(string $refreshToken): TokenSet`, `validate(string $accessToken): ValidatedToken`(→JwtValidator), `introspect(string $token): IntrospectionResult`(손수 RFC7662 POST), `logoutUrl(TokenSet $tokens): string`, `logout(string $refreshToken): void`(백채널 POST). 예외 경계 변환.
- **핵심 게차**: stevenmaguire 프로바이더의 `pkceMethod`는 **no-op** → `PkceKeycloakProvider extends Keycloak`로 `getPkceMethod()`를 오버라이드해 `PKCE_METHOD_S256` 반환. `version: '26.0.0'`을 옵션으로 줘 `openid` 스코프·logout id_token_hint 활성화.

- [ ] **Step 1: PkceKeycloakProvider 구현**

`php/src/Internal/PkceKeycloakProvider.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Internal;

use Stevenmaguire\OAuth2\Client\Provider\Keycloak;

/**
 * stevenmaguire Keycloak 프로바이더는 pkceMethod 옵션을 무시한다(getPkceMethod()가 null 반환).
 * 이 서브클래스가 S256 PKCE를 강제한다. @internal
 */
final class PkceKeycloakProvider extends Keycloak
{
    protected function getPkceMethod(): ?string
    {
        return self::PKCE_METHOD_S256;
    }
}
```

- [ ] **Step 2: AuthClient 구현**

`php/src/AuthClient.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

use GuzzleHttp\ClientInterface as GuzzleClientInterface;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Exception\GuzzleException;
use League\OAuth2\Client\Token\AccessToken;
use League\OAuth2\Client\Provider\Exception\IdentityProviderException;
use Xzawed\Keycloak\Internal\PkceKeycloakProvider;
use Xzawed\Keycloak\Token\AuthorizationRequest;
use Xzawed\Keycloak\Token\IntrospectionResult;
use Xzawed\Keycloak\Token\TokenSet;
use Xzawed\Keycloak\Token\ValidatedToken;
use Xzawed\Keycloak\Exception\KeycloakAuthError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;

final class AuthClient
{
    private PkceKeycloakProvider $provider;

    public function __construct(
        private readonly KeycloakConfig $config,
        private readonly OidcEndpoints $endpoints,
        private readonly JwtValidator $validator,
        private readonly GuzzleClientInterface $http,
    ) {
        $this->provider = new PkceKeycloakProvider([
            'authServerUrl' => $config->serverUrl,
            'realm' => $config->realm,
            'clientId' => $config->clientId,
            'clientSecret' => $config->clientSecret ?? '',
            'redirectUri' => $config->redirectUri ?? '',
            'version' => '26.0.0',   // >=20 → openid 스코프, >=18 → logout id_token_hint
        ], ['httpClient' => $http]);
    }

    public function createAuthorizationRequest(): AuthorizationRequest
    {
        $url = $this->provider->getAuthorizationUrl(['scope' => implode(' ', $this->config->scopes)]);
        $verifier = $this->provider->getPkceCode();
        return new AuthorizationRequest(url: $url, state: $this->provider->getState(), codeVerifier: (string) $verifier);
    }

    public function exchangeCode(string $code, string $state, string $codeVerifier): TokenSet
    {
        $this->provider->setPkceCode($codeVerifier);
        return $this->toTokenSet($this->getAccessToken('authorization_code', ['code' => $code]));
    }

    public function clientCredentialsToken(): TokenSet
    {
        return $this->toTokenSet($this->getAccessToken('client_credentials'));
    }

    public function refresh(string $refreshToken): TokenSet
    {
        return $this->toTokenSet($this->getAccessToken('refresh_token', ['refresh_token' => $refreshToken]));
    }

    public function validate(string $accessToken): ValidatedToken
    {
        return $this->validator->validate($accessToken);
    }

    public function introspect(string $token): IntrospectionResult
    {
        // RFC 7662 — league 미제공, 손수 POST(client_secret_basic)
        $basic = base64_encode($this->config->clientId . ':' . ($this->config->clientSecret ?? ''));
        try {
            $response = $this->http->request('POST', $this->endpoints->introspection(), [
                'headers' => ['Authorization' => 'Basic ' . $basic, 'Content-Type' => 'application/x-www-form-urlencoded'],
                'form_params' => ['token' => $token, 'token_type_hint' => 'access_token'],
            ]);
        } catch (ConnectException $e) {
            throw new KeycloakTransportError('introspection unreachable', previous: $e);
        } catch (GuzzleException $e) {
            throw new KeycloakAuthError('introspection failed', previous: $e);
        }
        $json = json_decode((string) $response->getBody(), true);
        if (!is_array($json)) {
            throw new KeycloakAuthError('introspection returned non-JSON');
        }
        return IntrospectionResult::fromArray($json);
    }

    public function logoutUrl(TokenSet $tokens): string
    {
        $token = new AccessToken(['access_token' => $tokens->accessToken, 'id_token' => $tokens->idToken]);
        return $this->provider->getLogoutUrl(['access_token' => $token]);
    }

    public function logout(string $refreshToken): void
    {
        // 백채널 end_session POST(refresh_token + client creds)
        try {
            $this->http->request('POST', $this->endpoints->endSession(), [
                'form_params' => [
                    'client_id' => $this->config->clientId,
                    'client_secret' => $this->config->clientSecret ?? '',
                    'refresh_token' => $refreshToken,
                ],
            ]);
        } catch (ConnectException $e) {
            throw new KeycloakTransportError('logout unreachable', previous: $e);
        } catch (GuzzleException $e) {
            throw new KeycloakAuthError('logout failed', previous: $e);
        }
    }

    /** @param array<string,mixed> $options */
    private function getAccessToken(string $grant, array $options = []): AccessToken
    {
        try {
            $token = $this->provider->getAccessToken($grant, $options);
        } catch (IdentityProviderException $e) {
            $body = $e->getResponseBody();
            $oauth = is_array($body) && isset($body['error']) ? (string) $body['error'] : null;
            throw new KeycloakAuthError('token request rejected: ' . $e->getMessage(), oauthError: $oauth, previous: $e);
        } catch (ConnectException $e) {
            throw new KeycloakTransportError('token endpoint unreachable', previous: $e);
        } catch (GuzzleException $e) {
            throw new KeycloakTransportError('token request failed', previous: $e);
        }
        /** @var AccessToken $token */
        return $token;
    }

    private function toTokenSet(AccessToken $t): TokenSet
    {
        $values = $t->getValues();
        return new TokenSet(
            accessToken: $t->getToken(),
            tokenType: isset($values['token_type']) ? (string) $values['token_type'] : 'Bearer',
            expiresIn: $t->getExpires() !== null ? max(0, $t->getExpires() - \time()) : 0,
            refreshToken: $t->getRefreshToken(),
            idToken: isset($values['id_token']) ? (string) $values['id_token'] : null,
            scope: isset($values['scope']) ? (string) $values['scope'] : null,
            expiresAt: $t->getExpires(),
        );
    }
}
```

- [ ] **Step 3: 단위 테스트 — introspect 매핑(mock Guzzle)**

`php/tests/Unit/AuthMappingTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use GuzzleHttp\{Client, HandlerStack};
use GuzzleHttp\Handler\MockHandler;
use GuzzleHttp\Psr7\Response;
use Xzawed\Keycloak\{KeycloakConfig, OidcEndpoints, AuthClient, JwtValidator};
use Xzawed\Keycloak\Jwks\JwksStore;
use Xzawed\Keycloak\Token\IntrospectionResult;

final class AuthMappingTest extends TestCase
{
    public function testIntrospectMapsActive(): void
    {
        $cfg = new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 's');
        $mock = new MockHandler([new Response(200, [], json_encode(['active' => true, 'username' => 'alice', 'client_id' => 'c']))]);
        $guzzle = new Client(['handler' => HandlerStack::create($mock)]);
        $endpoints = new OidcEndpoints($cfg);
        // JwtValidator는 introspect에 미사용 — 최소 구성
        $validator = new JwtValidator($cfg, $endpoints, new JwksStore($endpoints->jwks(), $guzzle, new \GuzzleHttp\Psr7\HttpFactory()));
        $auth = new AuthClient($cfg, $endpoints, $validator, $guzzle);
        $ir = $auth->introspect('some-token');
        self::assertInstanceOf(IntrospectionResult::class, $ir);
        self::assertTrue($ir->active);
        self::assertSame('alice', $ir->username);
    }
}
```

> 주: `AuthClient`는 커버리지 게이트 omit(네트워크 경계) — 이 테스트는 introspect 매핑 스모크. 전 흐름(auth-code/PKCE·client-credentials·refresh·logout)은 Task 11 통합테스트로 검증.

- [ ] **Step 4: 통과 + 정적**

Run: `cd php && vendor/bin/phpunit --filter AuthMappingTest && vendor/bin/phpstan analyse src/AuthClient.php src/Internal`
Expected: PASS, PHPStan 0 error.

- [ ] **Step 5: Commit**

```bash
git add php/src/AuthClient.php php/src/Internal php/tests/Unit/AuthMappingTest.php
git commit -m "feat(php): AuthClient — league+steven 래핑(PKCE 오버라이드) + introspect/logout 손수 + 예외 경계 변환"
```

---

### Task 9: Admin (fschmtt 래핑 + 경계 예외 변환 + raw())

**Files:**
- Create: `php/src/Admin/AdminClient.php`, `php/src/Admin/ErrorTranslation.php`
- Create: `php/src/Admin/{Users,Clients,Realms,Roles,Groups}Resource.php`
- Test: `php/tests/Unit/Admin/ErrorTranslationTest.php`

**Interfaces:**
- Consumes: fschmtt `Builder`/`Keycloak`/`GrantType`/`Resource\*`/`Representation\*`/`Collection\*`/`Http\Criteria`, Guzzle 예외, `KeycloakConfig`, admin 예외들.
- Produces: `AdminClient` — ctor `(KeycloakConfig)`(내부에서 config 타임아웃/TLS를 Guzzle에 배선 → fschmtt Builder). `users(): UsersResource`, `clients(): ClientsResource`, `realms(): RealmsResource`, `roles(): RolesResource`, `groups(): GroupsResource`, `raw(): Fschmtt\Keycloak\Keycloak`(탈출구). 각 리소스는 fschmtt 호출을 감싸고 `ErrorTranslation::call(callable)`로 Guzzle→Keycloak 변환. representation 타입은 그대로 노출(문서화된 은닉성 예외).
- `ErrorTranslation::call(callable $fn): mixed` — Guzzle `ClientException`(4xx: 404→NotFound·409→Conflict·403→Forbidden·기타→AdminError)·`ServerException`(5xx→AdminError)·`ConnectException`(→Transport)·fschmtt `BuilderException`(→Config) 변환.

- [ ] **Step 1: 실패 테스트 — 예외 변환 (mock Guzzle 예외)**

`php/tests/Unit/Admin/ErrorTranslationTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit\Admin;
use PHPUnit\Framework\TestCase;
use GuzzleHttp\Exception\{ClientException, ConnectException, ServerException};
use GuzzleHttp\Psr7\{Request, Response};
use Xzawed\Keycloak\Admin\ErrorTranslation;
use Xzawed\Keycloak\Exception\{KeycloakNotFoundError, KeycloakConflictError, KeycloakForbiddenError, KeycloakAdminError, KeycloakTransportError};

final class ErrorTranslationTest extends TestCase
{
    private function clientEx(int $status): ClientException
    {
        return new ClientException("HTTP $status", new Request('GET', '/'), new Response($status));
    }

    public function testMaps404(): void
    {
        $this->expectException(KeycloakNotFoundError::class);
        ErrorTranslation::call(fn () => throw $this->clientEx(404));
    }
    public function testMaps409(): void
    {
        $this->expectException(KeycloakConflictError::class);
        ErrorTranslation::call(fn () => throw $this->clientEx(409));
    }
    public function testMaps403(): void
    {
        $this->expectException(KeycloakForbiddenError::class);
        ErrorTranslation::call(fn () => throw $this->clientEx(403));
    }
    public function testMaps5xx(): void
    {
        $this->expectException(KeycloakAdminError::class);
        ErrorTranslation::call(fn () => throw new ServerException('boom', new Request('GET', '/'), new Response(500)));
    }
    public function testMapsConnect(): void
    {
        $this->expectException(KeycloakTransportError::class);
        ErrorTranslation::call(fn () => throw new ConnectException('refused', new Request('GET', '/')));
    }
    public function testPassesThroughReturn(): void
    {
        self::assertSame('ok', ErrorTranslation::call(fn () => 'ok'));
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter ErrorTranslationTest`
Expected: FAIL — 클래스 없음.

- [ ] **Step 3: ErrorTranslation 구현**

`php/src/Admin/ErrorTranslation.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Exception\BuilderException;
use GuzzleHttp\Exception\ClientException;
use GuzzleHttp\Exception\ConnectException;
use GuzzleHttp\Exception\ServerException;
use Xzawed\Keycloak\Exception\KeycloakAdminError;
use Xzawed\Keycloak\Exception\KeycloakConfigError;
use Xzawed\Keycloak\Exception\KeycloakConflictError;
use Xzawed\Keycloak\Exception\KeycloakForbiddenError;
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;
use Xzawed\Keycloak\Exception\KeycloakTransportError;

/**
 * fschmtt는 Guzzle 예외를 변환하지 않으므로(404/409/403 전부 raw ClientException) 경계에서 여기로 변환한다.
 */
final class ErrorTranslation
{
    /**
     * @template T
     * @param callable():T $fn
     * @return T
     */
    public static function call(callable $fn): mixed
    {
        try {
            return $fn();
        } catch (ClientException $e) {
            $status = $e->getResponse()->getStatusCode();
            throw match ($status) {
                404 => new KeycloakNotFoundError($e->getMessage(), 404, $e),
                409 => new KeycloakConflictError($e->getMessage(), 409, $e),
                403 => new KeycloakForbiddenError($e->getMessage(), 403, $e),
                default => new KeycloakAdminError($e->getMessage(), $status, $e),
            };
        } catch (ServerException $e) {
            throw new KeycloakAdminError($e->getMessage(), $e->getResponse()->getStatusCode(), $e);
        } catch (ConnectException $e) {
            throw new KeycloakTransportError('admin request unreachable', previous: $e);
        } catch (BuilderException $e) {
            throw new KeycloakConfigError($e->getMessage(), previous: $e);
        }
    }
}
```

- [ ] **Step 4: AdminClient + 리소스 구현**

`php/src/Admin/AdminClient.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Builder;
use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\OAuth\GrantType;
use GuzzleHttp\Client as GuzzleClient;
use Xzawed\Keycloak\KeycloakConfig;
use Xzawed\Keycloak\Exception\KeycloakConfigError;

final class AdminClient
{
    private readonly Keycloak $kc;
    private readonly string $realm;

    public function __construct(KeycloakConfig $config)
    {
        if ($config->clientSecret === null || $config->clientSecret === '') {
            throw new KeycloakConfigError('admin requires clientSecret (client-credentials)');
        }
        $this->realm = $config->realm;
        $guzzle = new GuzzleClient([
            'connect_timeout' => $config->connectTimeout,
            'timeout' => $config->readTimeout,
            'verify' => true,
            'http_errors' => true,
        ]);
        $this->kc = ErrorTranslation::call(fn (): Keycloak => (new Builder())
            ->withBaseUrl($config->serverUrl)
            ->withGrantType(GrantType::clientCredentials(
                clientId: $config->clientId,
                clientSecret: $config->clientSecret,
                realm: $config->realm,
            ))
            ->withHttpClient($guzzle)
            ->build());
    }

    public function users(): UsersResource { return new UsersResource($this->kc, $this->realm); }
    public function clients(): ClientsResource { return new ClientsResource($this->kc, $this->realm); }
    public function realms(): RealmsResource { return new RealmsResource($this->kc); }
    public function roles(): RolesResource { return new RolesResource($this->kc, $this->realm); }
    public function groups(): GroupsResource { return new GroupsResource($this->kc, $this->realm); }

    /** 탈출구 — 하위 fschmtt 클라이언트(문서화된 은닉성 예외). */
    public function raw(): Keycloak { return $this->kc; }
}
```
`php/src/Admin/UsersResource.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\Http\Criteria;
use Fschmtt\Keycloak\Representation\User;
use Fschmtt\Keycloak\Collection\UserCollection;

final class UsersResource
{
    public function __construct(private readonly Keycloak $kc, private readonly string $realm) {}

    /** 생성 후 id를 얻으려면 search 후속(fschmtt create는 void). */
    public function create(User $user): void
    {
        ErrorTranslation::call(fn () => $this->kc->users()->create($this->realm, $user));
    }

    public function get(string $userId): User
    {
        return ErrorTranslation::call(fn (): User => $this->kc->users()->get($this->realm, $userId));
    }

    public function search(?Criteria $criteria = null): UserCollection
    {
        return ErrorTranslation::call(fn (): UserCollection => $this->kc->users()->search($this->realm, $criteria));
    }

    public function delete(string $userId): void
    {
        ErrorTranslation::call(fn () => $this->kc->users()->delete($this->realm, $userId));
    }

    /** 편의: username으로 생성된 사용자 id 조회(create가 void라 필요). */
    public function findIdByUsername(string $username): ?string
    {
        $found = $this->search(new Criteria(['username' => $username, 'exact' => true]));
        return $found->first()?->getId();
    }
}
```
`php/src/Admin/ClientsResource.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\Http\Criteria;
use Fschmtt\Keycloak\Representation\Client;
use Fschmtt\Keycloak\Collection\ClientCollection;

final class ClientsResource
{
    public function __construct(private readonly Keycloak $kc, private readonly string $realm) {}

    /** fschmtt는 import(create 아님) — id를 세팅해야 내부 re-GET이 성립. */
    public function import(Client $client): Client
    {
        return ErrorTranslation::call(fn (): Client => $this->kc->clients()->import($this->realm, $client));
    }

    public function get(string $clientUuid): Client
    {
        return ErrorTranslation::call(fn (): Client => $this->kc->clients()->get($this->realm, $clientUuid));
    }

    public function all(?Criteria $criteria = null): ClientCollection
    {
        return ErrorTranslation::call(fn (): ClientCollection => $this->kc->clients()->all($this->realm, $criteria));
    }

    public function delete(string $clientUuid): void
    {
        ErrorTranslation::call(fn () => $this->kc->clients()->delete($this->realm, $clientUuid));
    }
}
```
`php/src/Admin/RealmsResource.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\Representation\Realm;

final class RealmsResource
{
    public function __construct(private readonly Keycloak $kc) {}

    public function get(string $realm): Realm
    {
        return ErrorTranslation::call(fn (): Realm => $this->kc->realms()->get($realm));
    }

    /** import(create 아님) — realm 이름으로 내부 re-GET. */
    public function import(Realm $realm): Realm
    {
        return ErrorTranslation::call(fn (): Realm => $this->kc->realms()->import($realm));
    }

    public function delete(string $realm): void
    {
        ErrorTranslation::call(fn () => $this->kc->realms()->delete($realm));
    }
}
```
`php/src/Admin/RolesResource.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\Representation\Role;
use Fschmtt\Keycloak\Collection\RoleCollection;

final class RolesResource
{
    public function __construct(private readonly Keycloak $kc, private readonly string $realm) {}

    public function create(Role $role): void
    {
        ErrorTranslation::call(fn () => $this->kc->roles()->create($this->realm, $role));
    }

    public function get(string $roleName): Role
    {
        return ErrorTranslation::call(fn (): Role => $this->kc->roles()->get($this->realm, $roleName));
    }

    public function all(): RoleCollection
    {
        return ErrorTranslation::call(fn (): RoleCollection => $this->kc->roles()->all($this->realm));
    }

    public function delete(string $roleName): void
    {
        ErrorTranslation::call(fn () => $this->kc->roles()->delete($this->realm, $roleName));
    }
}
```
`php/src/Admin/GroupsResource.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Admin;

use Fschmtt\Keycloak\Keycloak;
use Fschmtt\Keycloak\Representation\Group;
use Fschmtt\Keycloak\Collection\GroupCollection;

final class GroupsResource
{
    public function __construct(private readonly Keycloak $kc, private readonly string $realm) {}

    public function create(Group $group): void
    {
        ErrorTranslation::call(fn () => $this->kc->groups()->create($this->realm, $group));
    }

    public function get(string $groupId): Group
    {
        return ErrorTranslation::call(fn (): Group => $this->kc->groups()->get($this->realm, $groupId));
    }

    public function all(): GroupCollection
    {
        return ErrorTranslation::call(fn (): GroupCollection => $this->kc->groups()->all($this->realm));
    }

    public function delete(string $groupId): void
    {
        ErrorTranslation::call(fn () => $this->kc->groups()->delete($this->realm, $groupId));
    }
}
```

- [ ] **Step 5: 통과 + 정적**

Run: `cd php && vendor/bin/phpunit --filter ErrorTranslationTest && vendor/bin/phpstan analyse src/Admin`
Expected: PASS, PHPStan 0 error. (⚠️ fschmtt representation은 마법 `__call`이라 PHPStan이 `@method` docblock에 의존 — error 발생 시 해당 호출에 `@phpstan-ignore` 대신 반환 타입 명시로 해결; 실제 실행으로 확인.)

- [ ] **Step 6: Commit**

```bash
git add php/src/Admin php/tests/Unit/Admin
git commit -m "feat(php): AdminClient — fschmtt 래핑(Users/Clients/Realms/Roles/Groups) + Guzzle→Keycloak 경계 변환 + raw()"
```

---

### Task 10: KeycloakClient (통합 진입점)

**Files:**
- Create: `php/src/KeycloakClient.php`
- Test: `php/tests/Unit/KeycloakClientTest.php`

**Interfaces:**
- Consumes: `KeycloakConfig`, `OidcEndpoints`, `JwksStore`, `JwtValidator`, `AuthClient`, `Admin\AdminClient`, Guzzle `Client`, PSR-17 `HttpFactory`.
- Produces: `KeycloakClient` — `static create(KeycloakConfig): self`. `auth(): AuthClient`(즉시), `admin(): AdminClient`(지연·캐시), `close(): void`. auth는 생성 시 즉시 조립(네트워크 없음), admin은 첫 `admin()` 호출 시 생성(secret 필요).

- [ ] **Step 1: 실패 테스트**

`php/tests/Unit/KeycloakClientTest.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Unit;
use PHPUnit\Framework\TestCase;
use Xzawed\Keycloak\{KeycloakClient, KeycloakConfig, AuthClient};
use Xzawed\Keycloak\Admin\AdminClient;

final class KeycloakClientTest extends TestCase
{
    private function cfg(): KeycloakConfig
    {
        return new KeycloakConfig(serverUrl: 'http://kc:8080', realm: 'r', clientId: 'c', clientSecret: 's');
    }

    public function testAuthEagerAdminLazyCached(): void
    {
        $client = KeycloakClient::create($this->cfg());
        self::assertInstanceOf(AuthClient::class, $client->auth());
        $a1 = $client->admin();
        $a2 = $client->admin();
        self::assertInstanceOf(AdminClient::class, $a1);
        self::assertSame($a1, $a2);   // 캐시
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `cd php && vendor/bin/phpunit --filter KeycloakClientTest`
Expected: FAIL — 클래스 없음.

- [ ] **Step 3: 구현**

`php/src/KeycloakClient.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak;

use GuzzleHttp\Client as GuzzleClient;
use GuzzleHttp\Psr7\HttpFactory;
use Xzawed\Keycloak\Admin\AdminClient;
use Xzawed\Keycloak\Jwks\JwksStore;

/** 통합 진입점: auth 즉시, admin 지연. */
final class KeycloakClient
{
    private ?AdminClient $adminClient = null;

    private function __construct(
        private readonly KeycloakConfig $config,
        private readonly AuthClient $authClient,
    ) {}

    public static function create(KeycloakConfig $config): self
    {
        $endpoints = new OidcEndpoints($config);
        $guzzle = new GuzzleClient([
            'connect_timeout' => $config->connectTimeout,
            'timeout' => $config->readTimeout,
            'verify' => true,
        ]);
        $factory = new HttpFactory();
        $jwks = new JwksStore($endpoints->jwks(), $guzzle, $factory);
        $validator = new JwtValidator($config, $endpoints, $jwks);
        $auth = new AuthClient($config, $endpoints, $validator, $guzzle);
        return new self($config, $auth);
    }

    public function auth(): AuthClient
    {
        return $this->authClient;
    }

    public function admin(): AdminClient
    {
        return $this->adminClient ??= new AdminClient($this->config);
    }

    public function close(): void
    {
        // Guzzle/PSR-18은 명시적 커넥션 풀 close가 필요 없다(소켓은 GC/keep-alive 관리).
        // 대칭성/미래대비로 제공 — admin 캐시 해제.
        $this->adminClient = null;
    }
}
```

- [ ] **Step 4: 통과 + 정적 + 전체 단위 스위트**

Run: `cd php && vendor/bin/phpunit --testsuite unit && vendor/bin/phpstan analyse`
Expected: 전체 단위테스트 PASS, PHPStan 0 error(src+tests 전체).

- [ ] **Step 5: 커버리지 게이트 확인**

Run: `cd php && XDEBUG_MODE=coverage vendor/bin/phpunit --testsuite unit --coverage-text`
Expected: 로직 모듈(경계 omit 제외) 라인 커버리지 ≥90%. (PCOV 사용 시 `php -d pcov.enabled=1`.)

- [ ] **Step 6: Commit**

```bash
git add php/src/KeycloakClient.php php/tests/Unit/KeycloakClientTest.php
git commit -m "feat(php): KeycloakClient 통합 진입점(auth 즉시·admin 지연·close)"
```

---

### Task 11: 통합 테스트 (Testcontainers, 실제 Keycloak 26.6)

**Files:**
- Create: `php/tests/Integration/FullFlowIT.php`
- Create: `php/tests/Integration/testdata/it-realm-realm.json` (다른 언어에서 복사)
- Create: `php/tests/Integration/KeycloakContainerTrait.php`

**Interfaces:**
- Consumes: `testcontainers/testcontainers` `GenericContainer`, `KeycloakClient`, fschmtt `Representation\User`/`Client`.
- Produces: E2E 테스트 — 실제 KC 26.6 컨테이너(realm import) 대상: client-credentials 토큰 → validate(다중 aud) → introspect → user create/find/get/delete → delete 후 get→`KeycloakNotFoundError` → client import/get/delete → `raw()` 스모크.

- [ ] **Step 1: realm JSON 복사**

Run:
```bash
cp go/testdata/it-realm-realm.json php/tests/Integration/testdata/it-realm-realm.json
```
Expected: 파일 존재(confidential client `it-client` + service account + audience 매퍼). (없으면 `java/keycloak-sdk/src/test/resources/` 등에서 탐색.)

- [ ] **Step 2: 컨테이너 트레이트 작성**

`php/tests/Integration/KeycloakContainerTrait.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Integration;

use Testcontainers\Container\GenericContainer;
use Testcontainers\Wait\WaitForHttp;

trait KeycloakContainerTrait
{
    private static ?GenericContainer $container = null;
    private static string $baseUrl = '';

    public static function startKeycloak(): void
    {
        $realm = __DIR__ . '/testdata/it-realm-realm.json';
        self::$container = (new GenericContainer('quay.io/keycloak/keycloak:26.6'))
            ->withExposedPorts(8080)
            ->withEnvironment(['KC_BOOTSTRAP_ADMIN_USERNAME' => 'admin', 'KC_BOOTSTRAP_ADMIN_PASSWORD' => 'admin', 'KC_HEALTH_ENABLED' => 'true'])
            ->withMount($realm, '/opt/keycloak/data/import/it-realm-realm.json')
            ->withCommand(['start-dev', '--import-realm'])
            ->withWait(new WaitForHttp(8080, '/realms/it-realm/.well-known/openid-configuration'));
        self::$container->start();
        $host = self::$container->getHost();
        $port = self::$container->getMappedPort(8080);
        self::$baseUrl = "http://$host:$port";
    }

    public static function stopKeycloak(): void
    {
        self::$container?->stop();
        self::$container = null;
    }
}
```

> ⚠️ 구현 주의: `testcontainers/testcontainers` ^1.0의 정확한 API(클래스명·`withMount`/`withWait`/`getMappedPort` 시그니처)를 `vendor/testcontainers/` 소스로 확인해 조정하라(1.0 최근 성숙 — API가 위와 다를 수 있음). readiness는 `/realms/it-realm/.well-known/openid-configuration` 200 대기(realm import 완료 신호). **폴백**: testcontainers 부팅이 불안정하면 `docker compose`(별도 compose.it.yml)로 KC를 띄우고 `KC_IT_BASE_URL` env로 baseUrl을 주입하는 경로를 `setUpBeforeClass`에 분기.

- [ ] **Step 3: E2E 테스트 작성**

`php/tests/Integration/FullFlowIT.php`:
```php
<?php
declare(strict_types=1);
namespace Xzawed\Keycloak\Tests\Integration;

use PHPUnit\Framework\TestCase;
use Fschmtt\Keycloak\Representation\User;
use Fschmtt\Keycloak\Http\Criteria;
use Xzawed\Keycloak\{KeycloakClient, KeycloakConfig};
use Xzawed\Keycloak\Exception\KeycloakNotFoundError;

final class FullFlowIT extends TestCase
{
    use KeycloakContainerTrait;

    private static KeycloakClient $client;

    public static function setUpBeforeClass(): void
    {
        self::startKeycloak();
        self::$client = KeycloakClient::create(new KeycloakConfig(
            serverUrl: self::$baseUrl, realm: 'it-realm', clientId: 'it-client', clientSecret: 'it-secret',
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

        // 2) validate(자체강화, 다중 aud 수용 — it-client 포함)
        $vt = self::$client->auth()->validate($token->accessToken);
        self::assertContains('it-client', $vt->audience);
        self::assertStringEndsWith('/realms/it-realm', $vt->issuer);

        // 3) introspect
        $ir = self::$client->auth()->introspect($token->accessToken);
        self::assertTrue($ir->active);

        // 4) user CRUD
        $users = self::$client->admin()->users();
        $uname = 'php-it-' . bin2hex(random_bytes(4));
        $users->create(new User(username: $uname, email: "$uname@e.com", enabled: true));
        $id = $users->findIdByUsername($uname);
        self::assertNotNull($id);
        self::assertSame($uname, $users->get($id)->getUsername());
        $users->delete($id);

        // 5) delete 후 조회 → NotFound
        $this->expectException(KeycloakNotFoundError::class);
        $users->get($id);
    }

    public function testRawEscapeHatch(): void
    {
        // raw() 탈출구 스모크
        self::assertNotSame('', self::$client->admin()->raw()->getBaseUrl());
    }
}
```

- [ ] **Step 4: 통합 실행(Docker 필요)**

Run: `cd php && vendor/bin/phpunit --testsuite integration`
Expected: PASS — 실제 KC 26.6 컨테이너로 전 흐름 GREEN. (Docker Desktop 실행 필요. 첫 실행은 이미지 pull로 수 분.)

- [ ] **Step 5: Commit**

```bash
git add php/tests/Integration
git commit -m "feat(php): 통합테스트 — testcontainers 실제 KC 26.6 E2E(토큰·validate·introspect·user/client CRUD·raw·delete→NotFound)"
```

---

### Task 12: CI · 릴리스 · 문서

**Files:**
- Create: `.github/workflows/php-ci.yml`, `.github/workflows/php-release.yml`
- Create: `php/examples/quickstart.php`
- Create: `docs/governance/verification-log-php.md`
- Modify: `docs/guides/getting-started.md`, `README.md`, `CLAUDE.md`, `docs/roadmap/language-support.md`

- [ ] **Step 1: `php-ci.yml` 작성**

```yaml
name: php-ci
on:
  push: { paths: ['php/**', '.github/workflows/php-ci.yml'] }
  pull_request: { paths: ['php/**', '.github/workflows/php-ci.yml'] }
permissions: { contents: read }
jobs:
  build-test:
    runs-on: ubuntu-latest
    strategy: { matrix: { php: ['8.3', '8.4'] } }
    defaults: { run: { working-directory: php } }
    steps:
      - uses: actions/checkout@v4
      - uses: shivammathur/setup-php@v2
        with: { php-version: '${{ matrix.php }}', coverage: pcov, tools: composer }
      - run: composer install --no-interaction --prefer-dist
      - run: composer audit
      - run: vendor/bin/phpstan analyse
      - run: vendor/bin/php-cs-fixer fix --dry-run --diff
      - run: vendor/bin/phpunit --testsuite unit --coverage-clover clover.xml
      # 커버리지 게이트: 로직 라인 ≥90%(경계는 phpunit.xml source exclude)
      - name: coverage gate
        run: |
          php -r '$x=simplexml_load_file("clover.xml");$m=$x->project->metrics;$c=(int)$m["coveredstatements"];$t=(int)$m["statements"];$p=$t? $c/$t*100:100;printf("line coverage: %.2f%%\n",$p);exit($p>=90?0:1);'
  integration:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: php } }
    steps:
      - uses: actions/checkout@v4
      - uses: shivammathur/setup-php@v2
        with: { php-version: '8.3', tools: composer }
      - run: composer install --no-interaction --prefer-dist
      - run: vendor/bin/phpunit --testsuite integration
```

- [ ] **Step 2: `php-release.yml` 작성 (human-gated)**

```yaml
name: php-release
on:
  push: { tags: ['php-v*'] }
permissions: { contents: write }
jobs:
  verify:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: php } }
    steps:
      - uses: actions/checkout@v4
      - uses: shivammathur/setup-php@v2
        with: { php-version: '8.3', coverage: pcov, tools: composer }
      - run: composer install --no-interaction --prefer-dist
      - run: composer audit && vendor/bin/phpstan analyse && vendor/bin/phpunit --testsuite unit
      - name: GitHub Release
        run: gh release create "${GITHUB_REF_NAME}" --title "${GITHUB_REF_NAME}" --notes "PHP SDK ${GITHUB_REF_NAME}. Packagist auto-updates via webhook."
        env: { GITHUB_TOKEN: '${{ secrets.GITHUB_TOKEN }}' }
```

> 주: Composer/Packagist는 레지스트리 업로드가 아니라 **Packagist가 GitHub 웹훅으로 태그를 감지**해 자동 게시한다(별도 시크릿 없음). human-gated = 사람이 `php-v*` 태그 push. Packagist에 `xzawed/keycloak-sdk` 저장소 등록은 1회 수동 선행.

- [ ] **Step 3: `examples/quickstart.php` 작성**

```php
<?php
declare(strict_types=1);
require __DIR__ . '/../vendor/autoload.php';

use Xzawed\Keycloak\{KeycloakClient, KeycloakConfig};
use Fschmtt\Keycloak\Representation\User;

$client = KeycloakClient::create(new KeycloakConfig(
    serverUrl: getenv('KC_SERVER_URL') ?: 'http://localhost:8080',
    realm: getenv('KC_REALM') ?: 'it-realm',
    clientId: getenv('KC_CLIENT_ID') ?: 'it-client',
    clientSecret: getenv('KC_CLIENT_SECRET') ?: 'it-secret',
));

$token = $client->auth()->clientCredentialsToken();
echo "token type: {$token->tokenType}, expires in: {$token->expiresIn}s\n";

$validated = $client->auth()->validate($token->accessToken);
echo "subject: {$validated->subject}, issuer: {$validated->issuer}\n";

$client->admin()->users()->create(new User(username: 'demo-user', email: 'demo@example.com', enabled: true));
echo "created demo-user\n";
```

- [ ] **Step 4: 로컬 설치 경로 검증**

Run:
```bash
cd php && composer install && php -l examples/quickstart.php
```
Expected: `composer install` 성공, `php -l`(lint) "No syntax errors". (실행은 KC 필요 — 통합테스트가 커버.)

- [ ] **Step 5: 문서 갱신**

- `docs/guides/getting-started.md`: PHP 섹션 추가(설치 `composer require xzawed/keycloak-sdk`[미게시—로컬 path repo], QuickStart, 언어 간 매핑표에 PHP 열).
- `README.md`: 지원 언어에 PHP 추가(6번째), 매트릭스에 PHP 행.
- `CLAUDE.md`: "6번째 언어: PHP 8.3+ · fschmtt 래핑 + league/steven + firebase 자체 JWT 검증" · 프로젝트 구조에 `php/` 트리 · 툴체인 섹션(PHP 빌드/테스트 명령) · 게차(fschmtt void-create·league PKCE no-op·firebase 헤더 순서 등) · 테스트 수 · 배포명 `xzawed/keycloak-sdk`.
- `docs/roadmap/language-support.md`: PHP 행 계획→완료, 현황 매트릭스 6열 채움.
- `docs/governance/verification-log-php.md`: 태스크별 게이트 통과 이력(신규).

- [ ] **Step 6: 최종 검증(전체)**

Run:
```bash
cd php && composer audit && vendor/bin/phpstan analyse && vendor/bin/php-cs-fixer fix --dry-run --diff && vendor/bin/phpunit --testsuite unit && vendor/bin/phpunit --testsuite integration
```
Expected: audit 클린, PHPStan 0 error, CS-Fixer 변경 없음, 단위+통합 GREEN.

- [ ] **Step 7: Commit**

```bash
git add .github/workflows/php-ci.yml .github/workflows/php-release.yml php/examples docs/guides/getting-started.md README.md CLAUDE.md docs/roadmap/language-support.md docs/governance/verification-log-php.md
git commit -m "ci+docs(php): php-ci(매트릭스·phpstan·audit·커버리지 게이트)·php-release(Packagist human-gated)·getting-started·README·CLAUDE·로드맵·verification-log"
```

---

## Self-Review (작성자 체크)

**Spec coverage(스펙 §별 대응):**
- §2 라이브러리 → Task 1 composer + 전 태스크 사용. ✅
- §3 아키텍처/계층 → Task 2(masking/exc)·3(config)·4(tokens/oidc)·5(tokenprovider)·6(jwks)·7(jwt)·8(auth)·9(admin)·10(client). ✅
- §4 예외 경계 변환 → Task 2(계급)·5·6·7·8·9(변환). ✅
- §5 보안 불변식 → Task 6(JWKS DoS)·7(alg핀·none·iss·aud·exp/nbf)·3(마스킹)·8/9(타임아웃·TLS). ✅
- §6 툴체인/테스트/CI → Task 1(설정)·11(통합)·12(CI/release). ✅
- §7 테스트 패리티 매트릭스 → Task 7(강화 전부)·11(통합 시나리오). ✅
- §8 게차 → Task 8(league PKCE no-op)·9(fschmtt void-create/Guzzle 미변환)·7(firebase 헤더 순서/CachedKeySet 미사용). ✅
- §9 DoD → Task 12 최종검증 + 문서. ✅

**Placeholder scan:** 전 구현 코드 실제. 두 지점의 "구현 시 확인" 주석(Task 3 readonly 재대입·Task 11 testcontainers API)은 외부 라이브러리 정확 시그니처 검증 지시(placeholder 아님 — 실코드 + 검증 단계). ✅

**Type consistency:** 예외 클래스명 일관(`Keycloak*Error`), `TokenSet`/`ValidatedToken`/`IntrospectionResult` 필드 일관, `AdminClient`/리소스 메서드 일관, `JwksStore::getKeyByKid`·`JwtValidator::validate`·`AuthClient` 메서드 시그니처가 태스크 간 일치. firebase/league/fschmtt API는 딥리서치 byte-검증값 사용. ✅
