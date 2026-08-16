---
paths:
  - "php/**"
  - "harness/apps/php/**"
  - "harness/install/consume/php*"
  - ".github/workflows/php-*.yml"
---

# PHP 규칙

## 툴체인 (빌드 명령)

PHP는 포터블 설치(NTS x64 — ext: openssl/curl/mbstring/fileinfo/sodium/zip/json, 리포지토리 미커밋)를 사용하며 Composer(`composer.phar` + bash shim)가 같은 경로에 있다. **디렉터리 이름은 버전 접미가 붙는다**(다른 포터블 툴과 같은 관용 — `gradle-9.5.0`·`jdk-21…`). 프리픽스를 인라인 지정하고 명령은 `php/`에서 실행한다:
```bash
export KCSDK_PHP="${KCSDK_PHP:-${KCSDK_TOOLS:-$HOME/tools}/php-8.3}"
export PATH="$KCSDK_PHP:$PATH" OPENSSL_CONF="${KCSDK_OPENSSL_CNF:-$KCSDK_PHP/extras/ssl/openssl.cnf}"
cd php && composer install                                    # 의존성 설치
cd php && vendor/bin/phpunit --testsuite unit                  # 단위테스트. Docker 불필요
cd php && vendor/bin/phpunit --testsuite integration           # 통합테스트(Docker 필요 — docker CLI 셸아웃, 실제 Keycloak 26.6)
cd php && vendor/bin/phpstan analyse                           # 정적분석(level max + strict-rules + phpunit 확장)
cd php && vendor/bin/php-cs-fixer fix --dry-run --allow-risky=yes   # 스타일 검사(--allow-risky는 declare_strict_types risky rule에 필요)
```
> 다른 PC에서는 `KCSDK_PHP`(PHP 디렉터리 통째로)·`KCSDK_TOOLS`(포터블 툴 상위, 기본 `$HOME/tools`)·`KCSDK_OPENSSL_CNF`를 덮어쓰거나, 이미 PATH에 있으면 프리픽스를 생략한다. 설치·진단은 [development-setup.md](../../docs/guides/development-setup.md)(`node scripts/doctor.mjs php`). ⚠️ **정확한 패치 버전을 여기 적지 않는다** — 실측 원천은 `php -v`와 doctor다. 예전에는 `8.3.32`라고 박혀 있었는데 실제 설치는 `8.3.31`이었고, 경로도 `…/php`라고 적혀 있었지만 실제 디렉터리는 `php-8.3`이라 **문서를 그대로 따라 하면 PHP를 못 찾았다**(2026-08-12 문서 감사 H9).
- 단일 테스트: `vendor/bin/phpunit --filter <TestName> tests/Unit/<Path>Test.php`
- 커버리지 게이트(로직 라인 ≥90%, 네트워크 경계 omit): `XDEBUG_MODE=coverage vendor/bin/phpunit --testsuite unit --coverage-clover clover.xml` → `phpunit.xml`의 `<source><exclude>`가 `AuthClient`/`Admin/**`/`KeycloakClient`를 이미 제외하므로 clover의 `project.metrics`를 그대로 집계(실측 100.00%)
- ⚠️ `OPENSSL_CONF`는 로컬 RSA 키 생성(`JwtValidatorTest`)에 필요 — 없으면 openssl 확장이 시스템 기본 cnf를 못 찾아 키 생성이 실패한다.
- 포터블 PHP·Composer는 머신 전용 경로(리포지토리에 커밋 안 함, CI는 `shivammathur/setup-php` 사용). 버전은 `php -v`/`composer -V`로 확인한다.
- ⚠️ **이 포터블 설치에는 커버리지 드라이버가 없다** — 실측: `php -m | grep -ciE 'xdebug|pcov'` → `0`, `ext/`에도 xdebug 바이너리가 없다. 따라서 위 커버리지 게이트 명령(`XDEBUG_MODE=coverage …`)은 **이 PC에서 그대로는 실행되지 않는다**(PHPUnit이 "No code coverage driver available"로 끝난다). 로컬에서 커버리지를 재려면 Xdebug나 PCOV를 먼저 설치해야 하고, 게이트의 실제 집행 지점은 CI(`shivammathur/setup-php`가 드라이버를 제공)다. 문서가 "Xdebug 3.5.3이 같은 경로에 있다"고 적고 있었으나 사실이 아니었다(2026-08-12 문서 감사 H9).
- 배포명 `xzawed/keycloak-sdk`. 실제 배포는 로컬에서 실행하지 않는다 — `php-v*` 태그 push 시 `.github/workflows/php-release.yml`이 verify(`composer audit`+`phpstan`+단위테스트) → split 잡(`git subtree split --prefix=php` → 미러 저장소 `xzawed/keycloak-sdk-php`의 `main`에 force-push → 접두어 없는 `vX.Y.Z` 태그를 그 저장소에 push) 순으로 돌고, GitHub Release는 미러 push가 **성공한 뒤에만** 생성된다(사람 승인 게이트). 상세: [DEPLOY.md §2-D](../../DEPLOY.md).

## 게차

- ⚠️ **(PHP) fschmtt `Users::create()`는 void 반환** — 생성 id는 `findIdByUsername()`으로 후속조회. `Clients`/`Realms`는 `create`가 아니라 `import`(대상 representation에 id/realm 사전세팅 필요). fschmtt는 Guzzle 예외를 변환 안 하므로 `ErrorTranslation`이 404/409/403뿐 아니라 base `RequestException`(TLS 실패 등)까지 흡수해야 함.
- ⚠️ **(PHP) 파사드 `update()`는 다섯 리소스 전부 void다.** fschmtt `Clients::update`/`Realms::update`는 representation을 재-GET 해 돌려주지만, 자매 언어는 전부 값을 안 돌린다(Java `void` · Kotlin `Unit` · Python `None` · Node `Promise<void>` · Go `error` · Ruby `nil` · .NET `Task`) — §4 동형이라 파사드가 버린다. `import`는 POST+재조회(생성)라 이름을 유지하고, `update`는 PUT이라 fschmtt 그대로다. `Roles::update`는 이름을 `$role->getName()`에서 읽는다(별도 id 인자 없음). `Users::all()`은 `search()`와 같은 `GET /users`라 노출하지 않는다.
- ⚠️ **(PHP) league/stevenmaguire의 `pkceMethod` 생성자 옵션은 no-op**(내부 재계산으로 무시) — `PkceKeycloakProvider::getPkceMethod()` 오버라이드 필요. `exchangeCode()`는 무상태라 OAuth `state` 미검증(호출자 책임 — Node/Go/C#과 동형).
- ⚠️ **(PHP) `getAuthorizationUrl(['nonce' => $n])`는 passthrough다** — 실측(2026-08-15) `HAS_NONCE_KEY=yes MATCHES=yes`. `pkceMethod` no-op과 같은 부류로 가정하지 말 것. `createAuthorizationRequest()`는 `random_bytes`+base64url로 nonce를 **항상** 만들어 URL에 싣고 `AuthorizationRequest::$nonce`에 담는다. `exchangeCode(..., ?string $expectedNonce = null)`는 주어졌을 때만 id_token을 `JwtValidator`로 완전 검증한 뒤 nonce 클레임을 대조한다(불일치·부재·검증실패 → `KeycloakAuthError`, 자매 언어의 Auth 계급). 필수로 만들지 않는다(여덟과 갈린다). nonce는 인가 URL에 실리는 재생 방지 값이라 `#[\SensitiveParameter]`를 붙이지 않는다(`codeVerifier`만).
- ⚠️ **(PHP) firebase/php-jwt의 `&$headers` out-파라미터는 성공 디코드 후에만 채워진다.** alg를 사전 신뢰해 검증에 쓰면 위조방지가 안 되므로 원본 토큰의 **첫 세그먼트를 직접 base64url 디코드**해 alg를 사전 게이트해야 한다. 내장 `CachedKeySet`은 rate-limit 버그(#543)로 미사용(자체 `JwksStore`). 악성 JWKS 모듈러스(`n`이 배열)가 던지는 `\TypeError`(`\Error`의 서브클래스 — `\Exception` 아님)까지 `catch(\Throwable)`로 잡아야 미변환 예외 누출을 막는다.
- ⚠️ **(PHP) `JwksStore`의 rate-limit은 per-instance 메모리 상태** — 장수명 워커(Swoole/RoadRunner)는 요청간 유효하나 classic PHP-FPM은 요청마다 fresh store라 DoS 보호가 요청 내에서만 유효. 배포모델 의존 한계를 과대광고 금지.
- ⚠️ **(PHP) 시크릿 메모리 위생은 언어 차원에서 불가능** — char[] 같은 소거가능 타입이 없어 `clientSecret`은 항상 `string`. 마스킹(`__toString()`의 `***`)은 심층방어일 뿐(다른 5개 언어와 동일한 근본 한계).
- ⚠️ **(PHP) Packagist 게시 경로는 웹훅이 아니라 미러 저장소다 — 웹훅은 애초에 성립할 수 없었다.** Composer의 VCS 드라이버는 저장소 **루트**의 composer.json만 읽고 하위 디렉터리를 패키지 루트로 지정할 수단이 없다(Packagist도 서브디렉터리 미지원). 이 모노레포 루트엔 composer.json이 아예 없어(`php/composer.json` 하나뿐) Packagist가 이 저장소를 추적할 수 없다. 그래서 `php-release.yml`의 split 잡이 `php/` 하위트리만 떼어 읽기전용 미러 `xzawed/keycloak-sdk-php`로 push하고 Packagist가 등록·감시하는 대상은 **그 미러**다(패키지명은 split이 함께 옮기는 `php/composer.json`에서 오므로 `xzawed/keycloak-sdk` 그대로). 미러 태그는 접두어 없는 `vX.Y.Z`여야 한다(`php-vX.Y.Z`는 Composer가 버전으로 파싱 못 함) — 미러 `main`은 매 릴리스 force-push지만 **태그는 강제하지 않는다**(중복 버전이면 push가 실패해야 태워버린 버전을 사람이 알아챈다). ✅ **미러 생성·`PHP_SPLIT_TOKEN` 등록·Packagist 등록은 전부 끝났다** — `php-v0.1.0-rc.1`이 split→미러 push→bare `v0.1.0-rc.1` 태그 경로를 통과해 미러를 채웠고, 이어 Packagist 등록이 완료돼 `xzawed/keycloak-sdk` 0.1.0-rc.1이 라이브다. ⚠️ **순서는 뒤집을 수 없었다**: Packagist는 제출한 저장소의 기본 브랜치에서 composer.json을 읽는데 갓 만든 미러엔 그게 없으므로, 가능한 순서는 생성 → 토큰 → 첫 릴리스(미러를 채움) → 등록뿐이다(DEPLOY.md §2-D).
- ⚠️ **(PHP) `PHP_SPLIT_TOKEN` 미설정은 fail-closed** — split 잡이 `::error::` 후 exit 1로 중단해 미러 push도 GitHub Release도 일어나지 않는다(green인데 미게시인 false-positive 차단). 값은 미러에 write 권한이 있는 fine-grained PAT(대상 `xzawed/keycloak-sdk-php`, Contents: read and write). 반대로 이 시크릿이 **있어도** `scripts/release-readiness.sh`는 php를 초록(`✅ 저장소측 OK`)으로 두지 않는다 — 미러·Packagist 상태는 API로 확인 불가라 `ℹ️ 수동 확인`으로 다운그레이드한다(`df_auth php`=`split-token` 분기). ⚠️ 그 초록 문구는 예전에 `✅ 준비완료`였는데, "게시해도 된다"로 읽혀 rust가 계정 미비 상태에서 태그를 태웠다 — 지금은 저장소측만 확인했다는 뜻으로 문구를 좁혔다(DEPLOY.md §5).
- ⚠️ **(PHP) 통합테스트는 Testcontainers 아닌 docker CLI 셸아웃** — Windows native PHP는 `unix://` 트랜스포트 미지원, Docker Desktop 기본도 named pipe. `KeycloakContainerTrait`가 `docker run`/`port`/`rm`을 직접 구동. `phpunit.xml` integration testsuite는 `suffix="IT.php"` 명시 필요(누락 시 기본 패턴 `*Test.php`로 IT가 무음 스킵 — Task 1에서 실제 발현).
- ⚠️ **(PHP) `jumbojett/openid-connect-php`는 기각됐다** — 세션 슈퍼글로벌과 `header()` 리다이렉트를 **자체 소유**해 결정적 파사드와 상충하고(호출자가 흐름을 제어할 수 없다), JWT 검증 이력에도 우려가 있었다. 그래서 `league/oauth2-client` + Keycloak 프로바이더 조합을 쓴다.
