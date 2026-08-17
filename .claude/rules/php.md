---
paths:
  - "php/**"
  - "harness/apps/php/**"
  - "harness/install/consume/php*"
  - ".github/workflows/php-*.yml"
---

# PHP 규칙

## 툴체인

포터블 PHP 8.3 + Composer(리포지토리 미커밋). **디렉터리 이름에 버전 접미가 붙는다**(`php-8.3`).

```bash
export KCSDK_PHP="${KCSDK_PHP:-${KCSDK_TOOLS:-$HOME/tools}/php-8.3}"
export PATH="$KCSDK_PHP:$PATH" OPENSSL_CONF="${KCSDK_OPENSSL_CNF:-$KCSDK_PHP/extras/ssl/openssl.cnf}"
cd php && composer install
cd php && vendor/bin/phpunit --testsuite unit          # Docker 불필요
cd php && vendor/bin/phpunit --testsuite integration   # Docker 필요(docker CLI 셸아웃, KC 26.6)
cd php && vendor/bin/phpstan analyse                   # level max + strict-rules
cd php && vendor/bin/php-cs-fixer fix --dry-run --allow-risky=yes
```

- 단일 테스트: `vendor/bin/phpunit --filter <TestName> tests/Unit/<Path>Test.php`
- ⚠️ **정확한 패치 버전을 여기 적지 않는다** — 실측 원천은 `php -v`와 `node scripts/doctor.mjs php`다.
- ⚠️ `OPENSSL_CONF`는 로컬 RSA 키 생성(`JwtValidatorTest`)에 필요하다 — 없으면 키 생성이 실패한다.
- ⚠️ **이 포터블 설치에는 커버리지 드라이버가 없다**(`php -m | grep -ciE 'xdebug|pcov'` → 0). 커버리지 게이트(로직 라인 ≥90%, 실측 100.00%)의 실제 집행 지점은 CI이고, 로컬에서 재려면 Xdebug/PCOV를 먼저 설치해야 한다.
- ⚠️ **통합테스트는 Testcontainers가 아니라 docker CLI 셸아웃이다**(Windows native PHP는 `unix://` 미지원). `phpunit.xml`의 integration testsuite에 `suffix="IT.php"`를 명시해야 한다 — 빠뜨리면 기본 패턴 `*Test.php` 때문에 IT가 **무음 스킵**된다.

## 게시 (미러 저장소 경로)

⚠️ **Packagist 게시는 웹훅이 아니라 미러 저장소를 거친다 — 웹훅은 애초에 성립할 수 없다.** Composer의 VCS 드라이버는 저장소 **루트**의 composer.json만 읽고 서브디렉터리를 패키지 루트로 지정할 수단이 없는데, 이 모노레포 루트에는 composer.json이 없다. 그래서 `php-release.yml`의 split 잡이 `php/` 하위트리를 읽기전용 미러 `xzawed/keycloak-sdk-php`로 push하고 **Packagist가 보는 것은 그 미러**다(패키지명은 함께 옮겨가는 `php/composer.json`에서 오므로 `xzawed/keycloak-sdk` 그대로).

- 미러 태그는 **접두어 없는 `vX.Y.Z`**여야 한다(`php-vX.Y.Z`는 Composer가 파싱하지 못한다). 미러 `main`은 매 릴리스 force-push지만 **태그는 강제하지 않는다** — 중복이면 push가 실패해야 태워버린 버전을 사람이 알아챈다.
- ⚠️ **`PHP_SPLIT_TOKEN` 미설정은 fail-closed**(미러 push도 GitHub Release도 일어나지 않는다). 값은 미러에 Contents write 권한이 있는 fine-grained PAT다.
- ⚠️ **시크릿이 있어도 `release-readiness.sh`는 php를 초록으로 두지 않는다** — 미러·Packagist 상태는 API로 확인할 수 없어 `ℹ️ 수동 확인`으로 내린다. 절차: [DEPLOY.md §2-D](../../DEPLOY.md).

## 라이브러리 게차

- ⚠️ **fschmtt `Users::create()`는 void를 반환한다** — 생성된 id는 `findIdByUsername()`으로 후속 조회한다. `Clients`/`Realms`는 `create`가 아니라 `import`(representation에 id/realm을 미리 세팅해야 한다). fschmtt는 Guzzle 예외를 변환하지 않으므로 `ErrorTranslation`이 404/409/403뿐 아니라 base `RequestException`(TLS 실패 등)까지 흡수해야 한다.
- **파사드 `update()`는 다섯 리소스 전부 void다** — fschmtt는 representation을 재-GET해 돌려주지만 자매 언어 여덟이 전부 값을 안 돌리므로 §4 동형을 위해 버린다. `Roles::update`는 id 인자 없이 `$role->getName()`에서 이름을 읽는다. `Users::all()`은 `search()`와 같은 엔드포인트라 노출하지 않는다.
- ⚠️ **league/stevenmaguire의 `pkceMethod` 생성자 옵션은 no-op이다**(내부 재계산으로 무시) — `PkceKeycloakProvider::getPkceMethod()`를 오버라이드해야 한다. `exchangeCode()`는 무상태라 OAuth `state`를 검증하지 않는다(호출자 책임 — Node·Go·C#과 동형).
- ⚠️ **반면 `getAuthorizationUrl(['nonce' => $n])`는 passthrough다** — `pkceMethod`와 같은 부류로 가정하지 말 것. `createAuthorizationRequest()`가 nonce를 **항상** 만들어 URL에 싣고, `exchangeCode(..., ?string $expectedNonce = null)`는 주어졌을 때만 id_token을 완전 검증한 뒤 nonce를 대조한다.
- ⚠️ **firebase/php-jwt의 `&$headers` out-파라미터는 성공 디코드 후에만 채워진다** — alg를 사전 신뢰하면 위조 방지가 되지 않으므로 **원본 토큰의 첫 세그먼트를 직접 base64url 디코드**해 alg를 사전 게이트한다. 내장 `CachedKeySet`은 rate-limit 버그(#543)로 쓰지 않는다(자체 `JwksStore`). 악성 JWKS 모듈러스가 던지는 `\TypeError`는 `\Error`의 서브클래스라 `\Exception`으로 잡히지 않는다 — `catch(\Throwable)`이 필요하다.
- ⚠️ **`JwksStore`의 rate-limit은 per-instance 메모리 상태다** — 장수명 워커(Swoole/RoadRunner)에서는 요청 간 유효하지만 classic PHP-FPM은 요청마다 새 store라 보호가 요청 내에서만 유효하다. **배포 모델 의존 한계를 과대광고하지 않는다.**
- **시크릿 메모리 위생은 언어 차원에서 불가능하다** — 소거 가능한 타입이 없어 `clientSecret`은 항상 `string`이고 마스킹은 심층방어일 뿐이다.
- **`jumbojett/openid-connect-php`는 기각됐다** — 세션 슈퍼글로벌과 `header()` 리다이렉트를 자체 소유해 결정적 파사드와 상충한다. 그래서 `league/oauth2-client` + Keycloak 프로바이더 조합을 쓴다.
