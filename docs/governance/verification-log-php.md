# 검증 로그 — PHP SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 PHP SDK(`xzawed/keycloak-sdk`) 태스크별 정량 검증 기록. 브랜치 `feature/php-sdk`.

**툴체인**: 포터블 설치 `C:\Users\dirtc\tools\php`(PHP 8.3.32 NTS x64 — ext: openssl/curl/mbstring/fileinfo/sodium/zip/json, 리포지토리 미커밋) + Composer 2.10(`composer.phar` + bash shim) + Xdebug 3.5.3(zend_extension, 기본 mode off — 커버리지는 `XDEBUG_MODE=coverage`). 프리픽스: `export PATH="/c/Users/dirtc/tools/php:$PATH" OPENSSL_CONF="C:\Users\dirtc\tools\php\extras\ssl\openssl.cnf"`(RSA 키 생성에 로컬 openssl.cnf 필요 — `JwtValidatorTest`). 명령은 `php/`에서: `composer install` / `vendor/bin/phpunit --testsuite unit|integration` / `vendor/bin/phpstan analyse` / `vendor/bin/php-cs-fixer fix --dry-run --allow-risky=yes`.

**게이트**: G1 정적분석/스타일(`phpstan analyse` level max·`php-cs-fixer --dry-run --allow-risky=yes`) · G2 단위테스트(PHPUnit 12) · G3 커버리지(`phpunit.xml` source exclude로 네트워크 경계 `AuthClient`/`Admin/**`/`KeycloakClient` omit, 집계 로직 라인 ≥90%) · G4 스펙리뷰(§4 언어중립 계약과의 동형성) · G5 교차검증(태스크별 리뷰 루프 + 최종 어드버서리얼) · G6 보안(JWT 강화·JWKS DoS-safe·마스킹·경계 예외변환).

> **실행 방식**: 승인된 WBS(12태스크: scaffold → masking/exc → config → tokens/oidc → tokenprovider → jwks → jwt → auth → admin → client → integration → CI/docs) → 태스크별 TDD(실패 테스트 → 구현 → 통과) + 계층별 커밋 + 태스크 직후 소규모 리뷰 루프(Loops). Task 7(JwtValidator, 보안핵심)은 OPUS 어드버서리얼 보안리뷰(20+ 공격 프로브)로 별도 강화.

---

## 딥리서치 (착수 전) — 라이브러리 API 확정

4개 웹검증 에이전트로 유지보수·라이선스·API를 재검증해 아래를 **확정**(설계 스펙 §2, 구현 중 재확인 불필요):

- **`fschmtt/keycloak-rest-api-client-php` `0.42.0`**(MIT, 정확 핀): PHP 8.3+ 유일의 활발-유지 범용 Keycloak admin 클라이언트. Users/Clients/Realms/Roles/Groups 전체 CRUD + 타입드 representation. **`Users::create()`는 void 반환**(생성된 id는 `search()`로 후속 조회해야 함) — `Clients`/`Realms`는 `create`가 아니라 **`import`**이고 대상 representation에 `id`/`realm`을 미리 세팅해야 내부 재조회(re-GET)가 성립한다. Guzzle 예외를 SDK 타입으로 변환하지 않으므로 경계에서 전부 흡수해야 한다.
- **`league/oauth2-client` `^2.8`** + **`stevenmaguire/oauth2-keycloak` `^6.1`**(MIT/MIT): Auth Code+PKCE(S256)·client-credentials·refresh·logout URL 제공, **id_token 자체 검증은 안 함**(우리가 자체 강화). ⚠️ `stevenmaguire`의 `pkceMethod` 생성자 옵션은 **no-op**(내부에서 다시 계산돼 무시됨) — `PkceKeycloakProvider::getPkceMethod()`를 오버라이드해야 S256이 실제로 강제된다. `exchangeCode()`는 무상태라 OAuth `state` 파라미터를 검증하지 않는다(호출자 책임 — Node/Go/C# SDK와 동형).
- **`firebase/php-jwt` `^7.1`**(BSD-3, Google 유지): RS256 검증 프리미티브. `&$headers` out-파라미터는 **성공적으로 디코드된 후에만** 채워지므로, 헤더 alg를 사전 신뢰해 검증에 쓰면 위조 방지가 안 된다 — 원본 토큰의 **첫 세그먼트를 직접 base64url 디코드**해 alg를 사전 게이트해야 한다. 내장 `CachedKeySet`은 rate-limit 버그(GitHub #543)로 **미사용**, 자체 `JwksStore`로 대체.
- **`guzzlehttp/guzzle` `^7.9`** + **`guzzlehttp/psr7` `^2.7`**(MIT): introspection·logout·JWKS 조회의 손수 HTTP 호출 + fschmtt/JwksStore의 주입 HTTP 클라이언트. 타임아웃(`connect_timeout`/`timeout`)·TLS(`verify`) 주입점.
- **기각**: `jumbojett/openid-connect-php`(세션 슈퍼글로벌·`header()` 리다이렉트를 자체 소유해 결정적 파사드와 상충, JWT 검증 이력 우려), `web-token/jwt-framework`(무겁고 JWKS TTL캐시뿐), `lcobucci/jwt`(JWKS 미지원).

## 계층별 구현 (Task 1~11)

각 태스크 TDD(실패 테스트 → 구현 → 통과) 후 계층별 커밋. G1(정적분석/스타일)·G2(테스트)·G3(커버) 각 태스크 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 0 | `d0ba3ca`, `1adfe6b` | 설계 스펙 + WBS(12태스크) | — | — | — |
| 1 | `86cb797` + `80ba569` | 스캐폴딩(composer `xzawed/keycloak-sdk`·PSR-4·`fschmtt` 정확 핀·phpunit 경계 exclude·phpstan max·cs-fixer) | ✅ | — | — |
| 2 | `44362ae` | Masking(완전 불투명 `***`) + 예외 계급 9종(`KeycloakException`→Config/Auth[`oauthError`]/Transport/TokenValidation·`KeycloakAdminError`[`getStatusCode`]→NotFound/Conflict/Forbidden) | ✅ | ✅ (6) | ✅ |
| 3 | `2e185f3` + `a62234d` | `KeycloakConfig`(`final readonly`·검증·후행슬래시 제거·`__toString` 마스킹·`scopes` 런타임 정규화) | ✅ | ✅ (6) | ✅ |
| 4 | `9479d58` (+ 크로스태스크 `de50bc5`) | 값타입 `TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest` + `OidcEndpoints` | ✅ | ✅ (7 new, 누적 19) | ✅ |
| 5 | `9906424` + `aca40ee` | `TokenProvider` 인터페이스 + `ClientCredentialsTokenProvider`(캐시·오류변환) | ✅ | ✅ (4, 커버리지 100%) | ✅ |
| 6 | `e6a592f` | `JwksStore` — DoS-safe JWKS(kid 캐시·미해결만 재조회·rate-limit) | ✅ | ✅ (7, 커버리지 100%) | ✅ |
| 7 | `1df0aff` + `79e853d` | `JwtValidator` 자체강화(RS256 핀·`none` 거부·iss 정확·aud 포함·exp 필수·nbf·클록 스큐) | ✅ | ✅ (16, 커버리지 100%) | ✅ |
| 8 | `c2bd246` + `4b69e50` | `AuthClient`(league+steven 래핑, PKCE S256 오버라이드) + introspect/logout 손수 | ✅ | ✅ (48, omit — 네트워크 경계) | — |
| 9 | `a233d0a` + `4544331` | `AdminClient` + 5 리소스(Users/Clients/Realms/Roles/Groups) + `raw()` + `ErrorTranslation` | ✅ | ✅ (56, omit — 네트워크 경계) | — |
| 10 | `10a4f50` | `KeycloakClient` 통합 진입점(auth 즉시·admin 지연캐시·close) | ✅ | ✅ (57, omit — 네트워크 경계) | — |
| 11 | `1fb0fd3` | 통합 E2E(docker CLI 셸아웃, 실제 Keycloak 26.6) | ✅ | ✅ IT(3) | — |
| 12 | (본 커밋) | php-ci(매트릭스·phpstan·audit·커버리지 게이트)·php-release(Packagist human-gated)·문서 | ✅ | ✅ | ✅ |

### 태스크별 리뷰 루프 (Loops)

- **Task 1**(`80ba569`): `composer.json`의 `allow-plugins`에 `php-http/discovery: false` 누락 — 결정적 install을 위해 추가.
- **Task 3**(`a62234d`): `readonly` 프로퍼티(`scopes`)에 생성자 프로모션을 쓰면 재대입 불가 — 프로모션 제외 + 본문 1회 대입(`array_values`로 `list` 보장) + 입력 타입 docblock(`array<int,string>`)으로 phpstan level max 정합.
- **Task 4 크로스태스크**(`de50bc5`): `ExceptionHierarchyTest`가 정적 타입 단언(`instanceof` 좁히기 후 재검사)이라 phpstan `alreadyNarrowedType` 4건 발생 — `class_parents()` 기반 런타임 계층 검증으로 재작성(런타임 검증력은 유지, 정적 오탐 제거). 이후 모든 태스크는 scoped가 아닌 **전체** `vendor/bin/phpstan analyse`(src+tests)를 실행하는 관례로 전환.
- **Task 5**(`aca40ee`): 리뷰어가 `ClientCredentialsTokenProvider`의 transport-error 경로(Guzzle `NetworkException`/`ClientException`→`KeycloakTransportError`)가 미테스트임을 포착 — 회귀 테스트 추가로 파일 커버리지 87.10%→100%.
- **Task 7**(`79e853d`): OPUS 어드버서리얼 보안리뷰(20+ 공격 프로브: alg-confusion HS256/RS256-spoofed-HMAC, `none`/빈/배열 alg, 위조 서명, iss 트레일링슬래시/상위문자열/누락, aud 부분일치/누락, exp 누락, 미래 nbf, unknown/빈 kid, 악성 JWKS `n`(배열))로 **Critical 결함 발견**: `firebase/php-jwt`가 악성 JWKS 모듈러스(`n`이 배열)에 `\TypeError`(`\Error`의 서브클래스 — `\Exception` 아님)를 던지는데 기존 catch가 `\Exception` 계열만 잡고 있어 **미변환 예외가 공개 API로 누출** — `catch(\Throwable)`로 전면화 + 회귀테스트. 부수 수정: `Firebase\JWT\JWT::$leeway` 전역 static을 `try/finally`로 저장/복원(테스트 간 오염 방지).
- **Task 8**(`4b69e50`): 리뷰어가 `exchangeCode()`가 받은 `state` 파라미터를 실제로는 아무 데도 쓰지 않음(무의미한 매개변수, 오도적)을 포착 — 제거 + "state 대조는 호출자 책임"으로 문서화(Node/Go/C# SDK와 동형인 무상태 설계). PKCE S256 강제(`PkceKeycloakProvider::getPkceMethod()` 오버라이드)를 직접 검증하는 단위테스트 추가.
- **Task 9**(`4544331`): 리뷰어가 `ErrorTranslation`이 fschmtt/Guzzle의 4xx(`RequestException` 서브클래스)만 변환하고 **base `RequestException`**(TLS 인증서 검증 실패·malformed URI 등 non-HTTP 전송 실패)은 그대로 누출됨을 포착 — base catch 추가로 `KeycloakTransportError`로 통일 변환 + `BuilderException`/`RequestException` 매핑 회귀테스트.
- **Task 10**(`10a4f50`): `instanceof` 정적 단언이 Task 4와 동일한 phpstan `alreadyNarrowedType` 패턴을 유발 — `ReflectionObject::getName()` 기반 런타임 타입 검증으로 우회(de50bc5 선례 재사용).
- **Task 11**(`1fb0fd3`): 테스트 인프라 결함 2건(SDK 소스는 무변경) 발견 — (1) `phpunit.xml`의 integration testsuite에 `suffix="IT.php"`가 누락돼 기본 패턴(`*Test.php`)으로 인해 IT가 무음으로("No tests") 스킵되던 Task 1 스캐폴딩 갭 수정, (2) fschmtt `Clients::import()`가 대상 representation에 UUID `id`를 미리 세팅해야 함을 재확인.

## G6 — 보안 불변식 (실증)

- **JWT 강화**(`JwtValidator`): RS256 alg 핀(헤더 신뢰 대신 **첫 세그먼트 자체 디코드**로 사전 게이트) · `none`/미서명 거부 · `iss` 정확일치(`===`, 트레일링슬래시/상위문자열 거부) · `aud` 포함검사(string→list 정규화) · `exp` 필수 · `nbf` · 클록 스큐(기본 30s) · 악성 JWKS(`n` 배열 등)의 `\TypeError`까지 `\Throwable` 경계 전면화. 20+ 공격 토큰 전부 거부 실증(OPUS 어드버서리얼).
- **JWKS DoS-safe**(`JwksStore`): kid→JWK 캐시(캐시 히트=네트워크 호출 0) · 미해결 kid에만 재조회(정확히 1회) · rate-limit(연속 미해결 재조회 억제) — 위조 kid 스팸에 의한 미인증 DoS 증폭 차단을 call-count로 실증. **⚠️ rate-limit은 per-instance 메모리 상태** — 장수명 워커(Swoole/RoadRunner)에서는 요청 간 유효하지만, 클래식 per-request PHP-FPM은 요청마다 fresh store가 생성되어 DoS 보호가 **요청 내에서만** 유효하다(배포모델 의존성을 정직히 문서화, `KeycloakClient::create()`가 클라이언트 수명당 JwksStore 1개를 유지함은 확인함).
- **마스킹**: `TokenSet`/`KeycloakConfig`의 `__toString()`이 access/refresh 토큰·clientSecret을 완전 불투명(`***`, 접두 노출 없음)하게 마스킹. PHP는 문자열 소거가 언어 차원에서 불가능(char[] 불가) — 마스킹은 **심층방어**일 뿐 end-to-end 소거 보장이 아님을 명시(다른 4개 언어의 동일 한계와 동형).
- **경계 예외 변환**: Guzzle(`RequestException`/`ConnectException`/base `RequestException`)·league(`IdentityProviderException`)·fschmtt(변환 없음, 전부 흡수) 전부 `KeycloakException` 계급으로 변환 — 하위 라이브러리 타입이 공개 API로 새지 않음. `AdminClient::raw()`가 유일한 의도적 탈출구.
- **타임아웃/TLS**: `KeycloakConfig::$connectTimeout`/`$readTimeout`을 auth(Guzzle)·admin(fschmtt 주입 Guzzle)·JwksStore 모두에 전파. `verify: true`(TLS 검증) 기본 on.

## 최종 상태 (G1~G6 종합)

- **G1**: ✅ `phpstan analyse`(level max, strict-rules + phpunit 확장) 0 error · `php-cs-fixer fix --dry-run --allow-risky=yes` 0 file(변경 없음) — Task 12 시점 재검증.
- **G2**: ✅ 단위 **57** GREEN(224 assertions) + 통합 **3**(`FullFlowIT`: `testFullFlow`·`testAdminClientCrud`·`testRawEscapeHatch`, 실제 Keycloak 26.6, docker CLI 셸아웃) = **총 60**.
- **G3**: ✅ 집계 로직 라인 커버리지 **96.94%**(게이트 ≥90%, `phpunit.xml` source exclude로 `AuthClient`/`Admin/**`/`KeycloakClient` 네트워크 경계 omit). 참고: 값타입 3개(`TokenSet` 86.67%·`OidcEndpoints` 85.71%·`IntrospectionResult` 90%/methods 66.67%)는 개별로는 90% 미만이나 **집계 게이트는 통과**(다른 5개 SDK와 동일 관례 — 라인 단위 집계로 게이트).
- **통합**: ✅ Testcontainers 대체 경로(docker CLI 셸아웃, `KeycloakContainerTrait`) E2E **3** GREEN(client-credentials→validate[실 JWKS·RS256 강화검증]→introspect→user CRUD→delete→`KeycloakNotFoundError` + client CRUD[import, UUID id] + `raw()` 탈출구). **SDK 버그 0건**(6번째 언어 — 선행 5개 언어의 강화 설계·게차 학습이 선반영됨).
- **G4**: ✅ 설계 스펙 §4 언어중립 계약과 동형(계층: config→auth/jwt→admin→client, `admin`이 `auth`를 직접 모름·`TokenProvider`만 접착제, 예외 계급, 값타입 필드명 camelCase). PHP 관용 편차(예외 기반·`readonly class`·완전 은닉 admin representation 재노출은 문서화된 예외로 허용)는 §4 허용.
- **G5**: ✅ 태스크별 소규모 리뷰 루프(위 Loops, Task 1/3/4/5/7/8/9/10/11) + Task 7 OPUS 어드버서리얼 보안리뷰(20+ 공격 프로브, Critical 1건 확정 수정).
- **G6**: ✅ 위 "G6 — 보안 불변식" 절 참조.
- **배포**: 🔒 Packagist(`xzawed/keycloak-sdk`, GitHub 웹훅 자동감지 — 저장 시크릿 없음), `php-v*` 태그 push 대기(human-gated, 미실행). Packagist 저장소 등록(1회 수동 선행)도 미실행.

## 언어 간 비교 메모 (5개 선행 SDK 대비)

PHP는 Java/Python/Node/Go/C# 다음의 **6번째** 언어로, 앞선 언어들의 게차가 설계 단계에 선반영되어 통합테스트에서 **신규 SDK 버그가 0건**이었다(C#까지는 매 언어 통합테스트에서 최소 1건의 실제 버그가 나왔던 것과 대비). 결합 규칙(`admin`이 `auth`를 모름, `TokenProvider`만 접착제)·JWT 자체강화(알고리즘 핀·`none` 거부·iss/aud/exp·DoS-safe JWKS)·마스킹·경계 예외변환이 5개 선행 SDK와 동형이다. PHP 고유의 실질적 편차는 (1) `readonly class`(불변성을 언어 기능으로 강제, Go/C#의 값타입과 유사한 효과), (2) admin representation을 그대로 노출(Java/Node/Go/C#과 동일한 문서화된 은닉성 예외, Python만 plain dict), (3) JWKS rate-limit이 PHP 배포모델(per-request FPM vs 장수명 워커)에 따라 실효 범위가 달라진다는 점 — 이는 다른 언어에는 없는 PHP 고유의 정직한 한계다.
