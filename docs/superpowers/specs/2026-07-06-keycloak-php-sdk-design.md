# Keycloak PHP SDK 설계 (Design) — 6번째 언어

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

- **날짜**: 2026-07-06
- **브랜치**: `feature/php-sdk` (main 기준)
- **선행 정독**: [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md) — **진실 원천** · [새 언어 추가 플레이북](../../guides/add-a-language-playbook.md) · 워크드 예제 [Python WBS](../plans/2026-07-03-keycloak-python-sdk-wbs.md)·[Go WBS](../plans/2026-07-04-keycloak-go-sdk-wbs.md)

## 1. 배경과 목표

폴리글랏 Keycloak SDK의 **6번째 언어 = PHP**(로드맵 rank 4). 기존 5개 언어(Java·Python·Node·Go·C#)와 **동형(isomorphic)**: 어떤 언어를 열어도 `config → auth → jwt → admin → client` 같은 계층, 같은 예외 계급, 같은 보안 불변식, 같은 테스트 시나리오를 만난다. PHP는 **동기(sync)** 언어이므로 async 미러가 없다(Go·Java와 동일하게 단순).

**목표**: Java(123)·Python(235)와 **동일 품질**의 PHP SDK — 자체강화 JWT 검증, 단위 + 실제 Keycloak 26.6 Testcontainers 통합테스트, strict 정적분석, CI, 커버리지 게이트. 실배포만 human-gated로 남긴다.

**비목표**: async 미러(PHP는 동기), 새 API 설계(§4 계약을 *구현*), 실배포 실행.

## 2. 기반 라이브러리 (딥리서치 확정 — 2026-07 웹검증)

착수 전 딥리서치(4개 웹검증 에이전트)로 유지보수·라이선스·보안·API를 재검증해 확정했다. 로드맵의 후보 표는 시점 스냅샷이었고, 아래가 확정값이다.

| 계층 | 확정 라이브러리 | 버전(핀) | 라이선스 | 근거 |
|---|---|---|---|---|
| **admin** | `fschmtt/keycloak-rest-api-client-php` 래핑 | **0.42.0**(정확 핀) | MIT | 유일한 활발-유지 범용 PHP Keycloak admin 클라이언트. PHP 8.2+. Users/Clients/Realms/Roles/Groups 전체 CRUD + 타입드 representation. **프로젝트 전략(성숙 클라이언트 래핑)과 정합** — 5개 SDK 전부 admin을 래핑 |
| **auth** | `league/oauth2-client` + `stevenmaguire/oauth2-keycloak` 래핑 | **^2.8** / **^6.1** | MIT / MIT | 성숙·활발(steven 6.1.1, 2026-03). Auth Code+PKCE(S256)·client-credentials·refresh·logout URL. **id_token 검증 안 함(우리가 자체강화)** |
| **jwt(보안핵심)** | `firebase/php-jwt`(RS256 프리미티브) + 자체 JWKS 스토어 | **^7.1** | BSD-3 | Google 유지·PHP 8.0+. RS256 검증 + `none` 부재-거부. **내장 `CachedKeySet`는 미사용**(rate-limit 버그 #543) |
| **HTTP(손수 호출)** | `guzzlehttp/guzzle`(PSR-18) + `guzzlehttp/psr7`(PSR-17) | **^7.9** / **^2.7** | MIT | introspection·logout·JWKS 조회용. 타임아웃/TLS 주입점 |

**기각**: auth의 `jumbojett/openid-connect-php`(세션 슈퍼글로벌·`header()` 리다이렉트를 스스로 소유 → 결정적·테스트가능 파사드와 상충; id_token 검증이 핵심 메서드에 박혀 우회 필수; JWT 검증 이력 우려 — **문서화된 폴백**으로만). jose의 `web-token/jwt-framework`(무겁고 JWKS는 TTL캐시만), `lcobucci/jwt`(JWKS 미지원).

**전체 의존성 트리**: guzzle·psr7·psr/http-* + firebase/php-jwt + league/oauth2-client + stevenmaguire/oauth2-keycloak + fschmtt(→ guzzle·lcobucci/jwt·symfony/serializer 전이). 전부 MIT/BSD-3(Apache-2.0 호환).

## 3. 아키텍처

모노레포에 `php/` 추가(Java `java/`, Python `python/`, Node `node/`, Go `go/`, C# `dotnet/`와 병렬). Composer PSR-4, Python `src/` 레이아웃과 유사.

```
php/
├─ composer.json              # xzawed/keycloak-sdk · Apache-2.0 · require php ^8.3 · PSR-4 Xzawed\Keycloak\
├─ src/
│  ├─ KeycloakConfig.php       # readonly 설정 + 검증 + 마스킹
│  ├─ Masking.php              # mask() 완전 불투명
│  ├─ Exception/               # KeycloakException(base) → Config·Auth·Transport·Admin(→NotFound/Conflict/Forbidden)·TokenValidation
│  ├─ Token/                   # TokenSet · ValidatedToken · IntrospectionResult · AuthorizationRequest (readonly value objects)
│  ├─ TokenProvider.php        # TokenProvider 인터페이스 + ClientCredentialsTokenProvider(single-flight)
│  ├─ OidcEndpoints.php        # {serverUrl}/realms/{realm} 규약 URL 조립(네트워크 없음)
│  ├─ Jwks/JwksStore.php       # 자체 DoS-safe JWKS(fetch-by-kid·cache·unresolved-kid만 재조회·rate-limit·single-flight)
│  ├─ JwtValidator.php         # 🔴 firebase/php-jwt RS256 + JwksStore + alg핀·none거부·iss·aud·exp/nbf(보안 핵심)
│  ├─ AuthClient.php           # league+stevenmaguire 래핑 + introspect/logout 손수(PSR-18)
│  ├─ Admin/
│  │  ├─ AdminClient.php        # fschmtt Keycloak 래핑 진입점 + raw() + 경계 예외 변환
│  │  └─ {Users,Clients,Realms,Roles,Groups}Resource.php  # 리소스 파사드
│  └─ KeycloakClient.php       # 통합 진입점(auth 즉시·admin 지연·close)
├─ tests/{Unit,Integration}/   # Integration: testcontainers-php + testdata/it-realm-realm.json 재사용
├─ examples/quickstart.php
├─ phpunit.xml · phpstan.neon · .php-cs-fixer.dist.php · composer.json
```

**계층별 책임:**

- **config** — `readonly class KeycloakConfig`. 필수값(`serverUrl`/`realm`/`clientId`) 누락 → `KeycloakConfigError`. 시크릿은 PHP 관용상 불변 `string` + **마스킹**(`__toString`/`var_export` 노출 방지 — PHP는 char[] 소거 불가, Java와 달리 심층방어 한계 문서화). 타임아웃(connect/read)·클록 스큐(30s)·스코프(`openid`) 기본값 고정.
- **oidc** — `OidcEndpoints`: issuer·token·authorization·introspection·end_session·jwks URL 조립(네트워크 없음, 단위 테스트 대상).
- **jwt(자체강화, 🔴 최우선 정확도)** — `JwtValidator` + `JwksStore`. firebase/php-jwt를 **RS256 서명 검증 프리미티브로만** 쓰고, 나머지 불변식은 우리가 강제(§5). JWKS는 **firebase `CachedKeySet` 미사용** — 자체 `JwksStore`(kid→키 캐시, 미해결 kid만 재조회, 재조회 rate-limit + single-flight)로 Go/Python과 동형.
- **auth(OIDC 래핑 + 손수 글루)** — `AuthClient`: `stevenmaguire` Keycloak 프로바이더(`league` 위)로 Auth Code+PKCE(S256)·client-credentials·refresh·logout URL. **introspection(RFC 7662)·백채널 logout은 PSR-18로 손수 POST**(각 ~10줄) — Go/C# "grant 래핑 + introspect/logout 손수"와 동형. league `AccessToken` → 우리 `TokenSet` 매핑(하위 타입 미노출). PKCE verifier 상태는 파사드가 명시 관리(Node nonce 교훈).
- **admin(파사드 + raw())** — `AdminClient`: fschmtt `Keycloak`를 `Builder`로 구성(주입한 Guzzle에 config 타임아웃/TLS 배선), `users()/clients()/realms()/roles()/groups()` 리소스 파사드. **Guzzle 예외를 경계에서 변환**(§4). ~~fschmtt `TokenStorageInterface`에 우리 `ClientCredentialsTokenProvider` 배선(토큰 재사용)~~ **[2026-08-13 정정 — 이 배선은 구현되지 않았다.** `Admin/AdminClient.php`의 유일한 생성자는 `KeycloakConfig`만 받고 `php/src/Admin` 전체에 `TokenProvider` 참조가 **0건**이다(`grep -rl TokenProvider php/src/Admin`). fschmtt가 자체 client-credentials로 독립 인증하므로 admin이 auth를 모른다는 §4 불변식 자체는 성립하지만, **그 독립을 이루는 방법이 provider 주입이 아니라 admin의 토큰 자체 소유**다 — Java·Kotlin·Python과 같은 부류이고 소비자가 토큰 소스를 주입할 수단이 없다. 원문은 이력이라 지우지 않고 취소선으로 남긴다(Task D4)**]. `raw()` 탈출구는 fschmtt `Keycloak::resource(커스텀 Resource)` 기반(하위 Guzzle 클라이언트가 private이라 직접 핸들 없음).
- **client(통합 진입점)** — `KeycloakClient`: `auth`는 **즉시**(공개 클라이언트가 secret 없이 auth만 사용 가능), `admin`은 **지연**. `close()`로 auth·admin·JWKS의 HTTP 자원 정리(미정리=FD/커넥션 누수).

**결합 규칙(§4)**: `admin`은 `auth`를 직접 알지 못한다 — fschmtt가 자체 client-credentials로 독립 인증하고, 접착제는 `TokenProvider`뿐. JWT만 자체강화(하위 라이브러리 토큰 디코더 미사용).

**문서화된 은닉성 예외**: (a) admin 파사드가 fschmtt representation 타입(`Fschmtt\Keycloak\Representation\{User,Client,Realm,Role,Group,...}` + `Collection\*`)을 데이터 모델로 노출(Java/Node/Go/C#과 동일 — 안정적 Keycloak 타입 재사용). (b) `AdminClient::raw()`(커스텀 Resource), `JwtValidator`의 PSR-18 클라이언트 주입 시임 — 정상 소비 경로(`KeycloakClient::auth()/admin()`)는 노출하지 않는다.

## 4. 예외 경계 변환

모든 하위 라이브러리 예외는 **경계에서** `Xzawed\Keycloak\Exception\Keycloak*` 계급으로 변환(공개 API로 누출 금지):

- **admin(fschmtt/Guzzle)**: fschmtt는 자체 HTTP 오류 계층이 없어 Guzzle이 그대로 전파된다(`http_errors=true`). `GuzzleHttp\Exception\ClientException`(4xx) → 상태별 404 `KeycloakNotFoundError`·409 `KeycloakConflictError`·403 `KeycloakForbiddenError`·기타 4xx `KeycloakAdminError`; `ServerException`(5xx) → `KeycloakAdminError`; `ConnectException`·타임아웃(cURL 28) → `KeycloakTransportError`. fschmtt 내부: `BuilderException` → `KeycloakConfigError`; `SerializerException`/JSON류 → `KeycloakAdminError`.
- **auth(league)**: `League\OAuth2\Client\Provider\Exception\IdentityProviderException`(invalid_client/invalid_grant 등) → `KeycloakAuthError`; 네트워크/타임아웃(`Psr\Http\Client\NetworkExceptionInterface`) → `KeycloakTransportError`.
- **jwt(firebase)**: `SignatureInvalidException`·`ExpiredException`·`BeforeValidException`·`UnexpectedValueException`·`OutOfBoundsException`(미해결 kid) → `TokenValidationError`; JWKS 조회 네트워크 오류 → `KeycloakTransportError`.

## 5. 보안 불변식 (CI 강제)

- **JWT 자체강화**(플레이북 3단계 전부):
  - **알고리즘 핀닝** — 허용 `RS256`만. **토큰 헤더 `alg`를 신뢰하지 않는다**(firebase는 alg를 Key에 바인딩할 뿐 allowlist를 안 받으므로, 검증 전 `header.alg === 'RS256'` 명시 가드 + `CachedKeySet` 미사용).
  - **`none`/미서명 거부**(firebase `$supported_algs`에 없어 부재-거부 + 명시 방어).
  - **issuer 정확 일치**(`===`) · **audience 포함 검사**(`aud` string이면 동등, array면 포함 — 정규화 후 검사).
  - **exp 필수** + nbf + **클록 스큐 30s**(firebase `JWT::$leeway`는 전역 static이라 검증기에서 자체 강제).
  - **DoS-안전 JWKS** — 서명 위조는 재조회 유발 안 함, **kid 미해결에만** 재조회, 재조회는 **rate-limit + single-flight**(위조 Bearer마다 IdP를 때리는 미인증 DoS 증폭 차단). Go `singleflight`·Python 커스텀 스토어와 동형.
- **마스킹** — 토큰/시크릿은 로그·`__toString`·예외 메시지에 **완전 불투명 `***`**(접두 노출 없음). 단위 테스트로 강제(원문이 문자열 표현에 미포함).
- **TLS 기본 on** — Guzzle `verify=true`. no-op insecure 옵션 금지(저장만 하고 미연결이면 제거).
- **admin/auth/jwt 타임아웃 주입** — config connect/read 타임아웃이 실제 Guzzle 클라이언트(들)에 전달되는지 검증(미주입=hung IdP 무한대기·스레드 고갈 DoS).
- **정적/보안 게이트** — PHPStan level max(10)+strict; `composer audit` + `roave/security-advisories`로 의존성 CVE 하드 블록.

## 6. 툴체인·테스트·CI

- **런타임**: PHP **8.3** 하한(fschmtt 8.2+·league/steven 8.0+·firebase 8.0+ 모두 충족). CI 매트릭스 **8.3·8.4**. 배포명 Packagist **`xzawed/keycloak-sdk`**, 네임스페이스 `Xzawed\Keycloak\`, 릴리스 태그 **`php-v*`**.
- **정적/린트/포맷**: PHPStan **^2.2 level max** + `phpstan-strict-rules` + `phpstan-phpunit` · PHP-CS-Fixer **^3.95**(@PER-CS2.0 + @PSR12, CI `--dry-run --diff`) · 보안 `composer audit` + `roave/security-advisories`(dev).
- **테스트**: PHPUnit **^12**(8.3 호환 라인 — 13.x는 8.4.1+ 요구라 8.3 하한에선 12 핀). **커버리지 게이트**: PCOV + clover 임계 체커로 **로직 라인 ≥90%**, 네트워크 경계(`AuthClient`·`Admin\*`·`KeycloakClient`) omit(다른 5개 SDK와 동일). 브랜치는 Xdebug 별도 잡(best-effort).
- **통합(Testcontainers)**: `testcontainers/testcontainers` **^1.0** `GenericContainer`(`quay.io/keycloak/keycloak:26.6`, `start-dev --import-realm`, `/health/ready` 대기). **전용 Keycloak 모듈 없음** → GenericContainer(Go와 동일 포지션). **`docker-compose` 폴백을 테스트 부트스트랩에 문서화**(1.0 최근 성숙 → readiness 레이스 방지 wait 전략 명시).
- **realm 재사용**: 다른 언어의 `it-realm-realm.json`(confidential client + service account + audience 매퍼)을 `php/tests/Integration/testdata/`로 복사(파일명 `<realm>-realm.json` import 규약).
- **CI**: `.github/workflows/php-ci.yml`(매트릭스 빌드+단위+PHPStan+CS-Fixer+audit) + `php-release.yml`(`php-v*` 태그 → Packagist 웹훅, human-gated). Composer/Packagist는 스테이징 게이트 없음 → 태그 push가 즉시 게시라 **human-gated 유지**.

## 7. 테스트 패리티 매트릭스 (§4단계)

| 층위 | 시나리오(다른 언어와 동형) |
|---|---|
| **단위** | PKCE(S256) 생성 · 설정 검증/기본값 · 토큰 응답 파싱(`TokenSet::fromResponse`) · 만료·클록 스큐 판정 · JWT 강화(alg 핀·`none` 거부·iss 정확·aud 포함[다중 aud]·exp 필수·nbf·스큐) · **예외 경계 매핑**(404→`KeycloakNotFoundError` 등) · 마스킹(토큰/시크릿 불투명) · JWKS DoS-안전(위조 서명 재조회 안 함·미해결 kid만·rate-limit) |
| **통합(Testcontainers, 실제 KC 26.6)** | client-credentials 토큰 발급 · `validate`(다중 aud 수용) · introspect · user/client CRUD · `raw()` 탈출구 · delete 후 조회 → `KeycloakNotFoundError` |

## 8. 게차(Gotchas) — 딥리서치 확정

- ⚠️ **fschmtt는 pre-1.0** — minor 범프(0.42→0.43)가 API를 깰 수 있다. **정확 핀**(`0.42.0`)하고 업그레이드는 CHANGELOG 리뷰로 게이트.
- ⚠️ **fschmtt는 HTTP 오류 변환이 없다** — 404/409/403이 raw `GuzzleHttp\Exception\ClientException`로 온다. 경계 catch를 잊으면 Guzzle 타입이 공개 API로 누출(§4 위반). **최대 통합 위험지점**.
- ⚠️ **fschmtt는 Guzzle 바인딩**(PSR-18 아님) — `withHttpClient(GuzzleHttp\ClientInterface)`. 타임아웃/TLS는 주입 Guzzle의 `connect_timeout`/`timeout`/`verify`로만(빌더에 개별 세터 없음). raw()는 private Guzzle라 커스텀 Resource로.
- ⚠️ **firebase `CachedKeySet` rate-limit 버그(#543)** — TTL이 무제한으로 덮일 수 있어 DoS-안전을 위임하면 안 된다. 자체 `JwksStore`로 rate-limit·미해결-kid-only 재조회 구현.
- ⚠️ **firebase는 iss/aud를 검증하지 않고 alg allowlist를 안 받는다** — 검증기에서 iss 정확·aud 포함·`header.alg==='RS256'`을 직접 강제(누락 시 조용한 authz 구멍).
- ⚠️ **firebase `JWT::$leeway`는 전역 static** — 검증기에서 스큐를 자체 강제(전역 상태 의존 금지).
- ⚠️ **league PKCE는 상태 유지** — code_verifier를 authorize↔token 교환 사이에 파사드가 명시 보존(Node nonce 교훈 동형).
- ⚠️ **admin-client 버전 ≠ 서버 버전** — fschmtt 0.42 representation 필드가 KC 26.6와 완전 일치하지 않을 수 있다. 의존 필드는 통합테스트(실제 26.6)로 검증.
- ⚠️ **PHPUnit 버전이 PHP 하한과 결합** — 13.x는 8.4.1+ 요구. 8.3 하한이면 12 핀(CI drift 방지).
- ⚠️ **PHP 시크릿 위생 한계** — Java `char[]` 소거와 달리 PHP는 불변 `string`이라 사용 후 소거 불가. 마스킹은 심층방어일 뿐 end-to-end 소거 보장 아님(과대광고 금지).

## 9. 완료 기준 (DoD)

- [ ] `php/` 전 계층(config→auth→jwt→admin→client) 구현 + §4 동형(명명·계층·예외·값타입·보안 불변식)
- [ ] 단위 테스트(§7 시나리오 전부) + 실제 KC 26.6 Testcontainers 통합테스트 GREEN
- [ ] 커버리지 게이트(로직 라인 ≥90%, 경계 omit) 통과 · PHPStan max+strict · PHP-CS-Fixer · `composer audit` 통과
- [ ] 자체강화 JWT 불변식 전부(alg핀·none·iss·aud·exp/nbf·DoS-safe JWKS) 단위 테스트로 고정 · 마스킹·TLS·타임아웃 강제
- [ ] `php-ci.yml`(매트릭스 GREEN) + `php-release.yml`(준비, human-gated) · 문서(getting-started PHP 섹션·README·CLAUDE.md·로드맵·verification-log-php) 갱신
- [ ] 로컬 설치 경로(`composer require xzawed/keycloak-sdk` 전 단계로 path repo/`composer install` + `examples/quickstart.php` 실행) 동작
