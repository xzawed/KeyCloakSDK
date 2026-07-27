---
paths:
  - "php/**"
  - "harness/apps/php/**"
  - "harness/install/consume/php*"
  - ".github/workflows/php-*.yml"
---

# PHP 규칙

## 툴체인 (빌드 명령)

PHP는 포터블 설치 `${KCSDK_TOOLS:-$HOME/tools}/php`(8.3.32 NTS x64 — ext: openssl/curl/mbstring/fileinfo/sodium/zip/json, 리포지토리 미커밋)를 사용한다. Composer(`composer.phar` + bash shim)와 Xdebug 3.5.3(zend_extension, 기본 mode off)도 같은 경로에 있다. 프리픽스를 인라인 지정하고 명령은 `php/`에서 실행한다:
```bash
export PATH="${KCSDK_TOOLS:-$HOME/tools}/php:$PATH" OPENSSL_CONF="${KCSDK_OPENSSL_CNF:-C:\Users\dirtc\tools\php\extras\ssl\openssl.cnf}"
cd php && composer install                                    # 의존성 설치
cd php && vendor/bin/phpunit --testsuite unit                  # 단위테스트 64개. Docker 불필요
cd php && vendor/bin/phpunit --testsuite integration           # 통합테스트 3개(Docker 필요 — docker CLI 셸아웃, 실제 Keycloak 26.6)
cd php && vendor/bin/phpstan analyse                           # 정적분석(level max + strict-rules + phpunit 확장)
cd php && vendor/bin/php-cs-fixer fix --dry-run --allow-risky=yes   # 스타일 검사(--allow-risky는 declare_strict_types risky rule에 필요)
```
> 다른 PC에서는 `KCSDK_TOOLS`(포터블 툴 상위 디렉터리, 기본 `$HOME/tools`)·`KCSDK_OPENSSL_CNF`를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs php`).
- 단일 테스트: `vendor/bin/phpunit --filter <TestName> tests/Unit/<Path>Test.php`
- 커버리지 게이트(로직 라인 ≥90%, 네트워크 경계 omit): `XDEBUG_MODE=coverage vendor/bin/phpunit --testsuite unit --coverage-clover clover.xml` → `phpunit.xml`의 `<source><exclude>`가 `AuthClient`/`Admin/**`/`KeycloakClient`를 이미 제외하므로 clover의 `project.metrics`를 그대로 집계(실측 100.00%)
- ⚠️ `OPENSSL_CONF`는 로컬 RSA 키 생성(`JwtValidatorTest`)에 필요 — 없으면 openssl 확장이 시스템 기본 cnf를 못 찾아 키 생성이 실패한다.
- PHP 8.3.32 NTS · Composer 2.10 · Xdebug 3.5.3은 머신 전용 경로(리포지토리에 커밋 안 함, CI는 `shivammathur/setup-php` 사용).
- 배포명 `xzawed/keycloak-sdk`. Packagist는 레지스트리 업로드가 아니라 GitHub 웹훅으로 태그를 자동감지해 게시하므로 실제 배포는 로컬에서 실행하지 않는다 — `php-v*` 태그 push 시 `.github/workflows/php-release.yml`이 verify(`composer audit`+`phpstan`+단위테스트) 후 GitHub Release를 생성한다(사람 승인 게이트; Packagist에 `xzawed/keycloak-sdk` 저장소 등록은 1회 수동 선행).

## 게차

- ⚠️ **(PHP) fschmtt `Users::create()`는 void 반환** — 생성 id는 `findIdByUsername()`으로 후속조회. `Clients`/`Realms`는 `create`가 아니라 `import`(대상 representation에 id/realm 사전세팅 필요). fschmtt는 Guzzle 예외를 변환 안 하므로 `ErrorTranslation`이 404/409/403뿐 아니라 base `RequestException`(TLS 실패 등)까지 흡수해야 함.
- ⚠️ **(PHP) league/stevenmaguire의 `pkceMethod` 생성자 옵션은 no-op**(내부 재계산으로 무시) — `PkceKeycloakProvider::getPkceMethod()` 오버라이드 필요. `exchangeCode()`는 무상태라 OAuth `state` 미검증(호출자 책임 — Node/Go/C#과 동형).
- ⚠️ **(PHP) firebase/php-jwt의 `&$headers` out-파라미터는 성공 디코드 후에만 채워진다.** alg를 사전 신뢰해 검증에 쓰면 위조방지가 안 되므로 원본 토큰의 **첫 세그먼트를 직접 base64url 디코드**해 alg를 사전 게이트해야 한다. 내장 `CachedKeySet`은 rate-limit 버그(#543)로 미사용(자체 `JwksStore`). 악성 JWKS 모듈러스(`n`이 배열)가 던지는 `\TypeError`(`\Error`의 서브클래스 — `\Exception` 아님)까지 `catch(\Throwable)`로 잡아야 미변환 예외 누출을 막는다.
- ⚠️ **(PHP) `JwksStore`의 rate-limit은 per-instance 메모리 상태** — 장수명 워커(Swoole/RoadRunner)는 요청간 유효하나 classic PHP-FPM은 요청마다 fresh store라 DoS 보호가 요청 내에서만 유효. 배포모델 의존 한계를 과대광고 금지.
- ⚠️ **(PHP) 시크릿 메모리 위생은 언어 차원에서 불가능** — char[] 같은 소거가능 타입이 없어 `clientSecret`은 항상 `string`. 마스킹(`__toString()`의 `***`)은 심층방어일 뿐(다른 5개 언어와 동일한 근본 한계).
- ⚠️ **(PHP) 통합테스트는 Testcontainers 아닌 docker CLI 셸아웃** — Windows native PHP는 `unix://` 트랜스포트 미지원, Docker Desktop 기본도 named pipe. `KeycloakContainerTrait`가 `docker run`/`port`/`rm`을 직접 구동. `phpunit.xml` integration testsuite는 `suffix="IT.php"` 명시 필요(누락 시 기본 패턴 `*Test.php`로 IT가 무음 스킵 — Task 1에서 실제 발현).
