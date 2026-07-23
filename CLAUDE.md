# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Keycloak을 위한 **다국어(polyglot) SDK** — "다국어"는 **여러 프로그래밍 언어**(Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin·향후 확장)를 뜻하며 자연어 현지화(i18n)와 무관하다. Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다룬다. 언어마다 관용적이되 개념·계층·흐름은 **동형(isomorphic)** 이도록 설계한다.

- **기준 언어**: Java 21 · Maven (첫 구현; 초기 Java 17 → 21 LTS 런타임 업그레이드 반영)
- **2번째 언어**: Python 3.10+ · `python-keycloak` 래핑 + `joserfc` 자체 JWT 검증 (`feature/python-sdk`)
- **3번째 언어**: Node.js 22+ · TypeScript(ESM·async-only) · `@keycloak/keycloak-admin-client` + `openid-client` v6 래핑 + `jose` 자체 JWT 검증 (`feature/node-sdk`)
- **4번째 언어**: Go 1.25+ · sync + `context.Context` · `Nerzal/gocloak/v13` + `golang.org/x/oauth2` 래핑 + `go-jose/v4` 자체 JWT 검증 (`feature/go-sdk`)
- **5번째 언어**: C# / .NET 8+ · async-first(`Task<T>`+`CancellationToken`) · `Keycloak.AuthServices.Sdk` 2.7.0 + `Duende.IdentityModel` 래핑 + `Microsoft.IdentityModel.JsonWebTokens` 자체 JWT 검증 (`main` 병합, PR #14)
- **6번째 언어**: PHP 8.3+ · `final readonly class` 값타입 · `fschmtt/keycloak-rest-api-client-php` 래핑(admin) + `league/oauth2-client`+`stevenmaguire/oauth2-keycloak` 래핑(auth, PKCE S256 오버라이드) + `firebase/php-jwt` 자체 JWT 검증 (`feature/php-sdk`)
- **7번째 언어**: Rust 1.88+(edition 2024) · async-only(tokio) · `keycloak` crate 래핑(admin, `reqwest12` feature로 reqwest 0.12 정렬) + `openidconnect` 래핑(auth, 수동 EndpointSet typestate) + `jsonwebtoken` 자체 JWT 검증 (`main` 병합, PR #18)
- **8번째 언어**: Ruby 3.2+ · sync-only · gem 없이 `faraday`로 Admin REST 직접 래핑(admin) + `rack-oauth2` 래핑(auth, PKCE S256 손수) + `jwt`(ruby-jwt) 자체 JWT 검증 (`feature/ruby-sdk`)
- **9번째 언어**: Kotlin 2.4.10 · JDK 21 · 단일 Gradle 모듈 · coroutines(`suspend`+`runInterruptible(Dispatchers.IO)`) · JVM 자매 Java SDK 라이브러리 스택(`keycloak-admin-client` 26.0.11 + `oauth2-oidc-sdk` 11.38.2) 재사용 래핑 + `nimbus-jose-jwt` 자체 JWT 검증 (`main` 병합, PR #23)
- **라이선스**: Apache-2.0 · **groupId**: `io.github.xzawed` · Python 배포명: `keycloak-sdk` · npm 배포명: `@xzawed/keycloak-sdk` · Go 모듈: `github.com/xzawed/KeyCloakSDK/go` · NuGet 배포명: `Xzawed.Keycloak.Sdk` · Packagist 배포명: `xzawed/keycloak-sdk` · crates.io 배포명: `keycloak-sdk` · RubyGems 배포명: `keycloak-sdk` · Maven Central 좌표(Kotlin): `io.github.xzawed:keycloak-sdk-kotlin`

**핵심 전략**: 언어마다 가장 좋은 기반을 사용한다 — 공식/성숙 클라이언트가 있으면 감싼다(Java는 `keycloak-admin-client`, Python은 `python-keycloak`, Node는 공식 `@keycloak/keycloak-admin-client` + `openid-client`, Go는 `gocloak` + `x/oauth2`, C#은 `Keycloak.AuthServices.Sdk` + `Duende.IdentityModel`, PHP는 `fschmtt/keycloak-rest-api-client-php` + `league/oauth2-client`, Rust는 `keycloak` crate + `openidconnect`, Ruby는 성숙한 admin gem이 없어 `faraday`로 직접 래핑 + `rack-oauth2`, Kotlin은 JVM 자매 Java SDK의 검증된 스택(`keycloak-admin-client` + `oauth2-oidc-sdk` + `nimbus-jose-jwt`)을 코루틴 관용으로 재래핑) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다. JWT 검증은 아홉 언어 모두 자체 강화 구현(algorithm pinning·iss 정확일치·aud 포함검사·`exp` 필수·클록 스큐·DoS-안전 JWKS 재조회)이다.

## 현재 상태

9개 언어 SDK 모두 `main` 병합 완료. 어떤 언어도 아직 레지스트리에 게시되지 않았다(전부 사람 승인 게이트).

| 언어 | 배포명 | 태그 접두 | 배포 |
|---|---|---|---|
| Java | `io.github.xzawed:keycloak-sdk` | `v*` | 미실행 |
| Python | `keycloak-sdk` | `py-v*` | 미실행 |
| Node | `@xzawed/keycloak-sdk` | `node-v*` | 미실행 |
| Go | `github.com/xzawed/KeyCloakSDK/go` | `go/v*` | 미실행 |
| C#/.NET | `Xzawed.Keycloak.Sdk` | `dotnet-v*` | 미실행 |
| PHP | `xzawed/keycloak-sdk` | `php-v*` | 미실행 |
| Rust | `keycloak-sdk` | `rust-v*` | 미실행 |
| Ruby | `keycloak-sdk` | `ruby-v*` | 미실행 |
| Kotlin | `io.github.xzawed:keycloak-sdk-kotlin` | `kotlin-v*` | 미실행 |

구현 경위·PR 이력: [docs/governance/history.md](docs/governance/history.md) · 배포 절차: [DEPLOY.md](DEPLOY.md)

## 툴체인 (빌드 명령)

언어별 전체 빌드/테스트/린트/배포 명령(머신 전용 절대경로·단일 테스트 실행 포함)은 `.claude/rules/<lang>.md`에 있다(해당 언어 경로 작업 시 자동 로드). 아래는 언어별 핵심 진입 명령 하나씩만 남긴 표다.

| 언어 | 핵심 진입 명령 | 상세 |
|---|---|---|
| Java | `mvn -f java/pom.xml verify` | `.claude/rules/java.md` |
| Python | `cd python && .venv/Scripts/python.exe -m pytest -m "not integration" --cov=keycloak_sdk` | `.claude/rules/python.md` |
| Node | `cd node && npm test` | `.claude/rules/node.md` |
| Go | `go -C go test ./...` | `.claude/rules/go.md` |
| C#/.NET | `cd dotnet && dotnet test --filter "Category!=Integration"` | `.claude/rules/dotnet.md` |
| PHP | `cd php && vendor/bin/phpunit --testsuite unit` | `.claude/rules/php.md` |
| Rust | `cd rust && cargo test` | `.claude/rules/rust.md` |
| Ruby | `cd ruby && bundle exec rspec` | `.claude/rules/ruby.md` |
| Kotlin | `gradle -p kotlin test` | `.claude/rules/kotlin.md` |

## 아키텍처

폴리글랏 모노레포. Java 구현이 `java/`에서, Python 구현이 `python/`에서, Node 구현이 `node/`에서, Go 구현이 `go/`에서, C#/.NET 구현이 `dotnet/`에서, PHP 구현이 `php/`에서, Rust 구현이 `rust/`에서, Ruby 구현이 `ruby/`에서, Kotlin 구현이 `kotlin/`에서 완료됐다(각각 독립 빌드).

### 공통 모듈 구조

모든 언어가 같은 모양이다 — 파일명·확장자·모듈 물리 배치만 언어 관용을 따른다.

```
config · errors/masking · tokens · oidc(엔드포인트 조립, 네트워크 없음)
token_provider(캐시·single-flight) · jwks(DoS-safe) · jwt(자체 강화 검증)
auth(하위 OIDC 라이브러리 래핑) · admin/(5리소스: users·clients·realms·roles·groups + raw 탈출구) · client(통합 진입점)
```

`client`는 `auth`를 즉시 조립하고 `admin`은 최초 접근 시 지연 생성한다(언어별 세부는 각 SDK — Rust는 예외, 아래 결합 규칙 참고). close/dispose 계열은 실제 생성된 리소스만 정리한다.

### 언어별 차이

| 언어 | 차이 |
|---|---|
| Java | 6개 Maven 모듈로 물리 분리(`keycloak-sdk-{bom,core,auth,admin}` + `keycloak-sdk` + `-examples`, reactor 빌드) |
| Python | 단일 패키지 `keycloak_sdk`(`src/` 레이아웃) + `aio/` 비동기 미러 추가(`AsyncKeycloakClient` 등, python-keycloak `a_*` 래핑) |
| Go | 전체가 단일 `package keycloak` — admin을 서브패키지로 두면 `Client.Admin`이 `*AdminClient`를 반환해 import 순환이 생기므로 `admin_*.go`로 같은 패키지 |
| Ruby | 단일 gem `keycloak-sdk`(모듈 `KeycloakSdk`) — admin 성숙한 gem 부재로 Faraday raw-REST를 직접 구현 |
| Kotlin | 단일 Gradle 모듈 `keycloak-sdk-kotlin` — 네트워크 메서드 전부 `suspend`, JVM 자매 Java SDK 스택(`keycloak-admin-client`·`oauth2-oidc-sdk`) 재사용 |

Node·C#/.NET·PHP·Rust는 공통 모양과 차이가 없다(단일 패키지/크레이트·표준 파일 배치 — 표 생략).

### 언어별 결합 규칙

`admin`↔`auth` 결합 방식과 경계 변환의 언어별 사실이다(§4 계약·§4(b) 은닉성 예외에 이미 있는 내용은 반복하지 않는다 — 특히 각 언어의 `raw`/`Raw` 탈출구 타입은 아래 §4(b)에 전부 있다).

- **Java**: `admin`은 `auth`를 직접 알지 못한다. 유일한 접착제는 `core`의 `TokenProvider` 인터페이스다 — auth 없이도 admin을 자체 토큰 소스로 쓸 수 있고, 내부 라이브러리 교체가 소비자에게 파급되지 않는다.
- **Python**: `admin`은 `auth`에 의존하지 않는다(각자 독립적으로 client-credentials 인증). 예외는 경계에서 `keycloak_sdk.exceptions.*`로 변환되어 `keycloak.exceptions.*` 타입이 공개 API에 노출되지 않는다.
- **Node**: `admin`은 `auth`에 의존하지 않는다(각자 독립 client-credentials 인증) — `TokenProvider` 인터페이스가 유일 접착제. 예외는 경계에서 `KeycloakError` 계급으로 변환되어 하위 라이브러리 에러(`NetworkError` 등)가 새지 않는다. `admin.raw()`가 탈출구. **admin은 파사드가 주입한 캐싱 `ClientCredentialsTokenProvider`를 `registerTokenProvider`로 배선하고 `kc.auth()`는 호출하지 않는다(PR #63)** — admin-client 내장 TokenManager는 만료 시 refresh만 시도해 client_credentials에서 영구 실패하므로, 자체 provider가 만료 시 재인증하게 한다(Rust `79ecf76`와 동형 결정).
- **Go**: **전체가 단일 `package keycloak`**(admin을 서브패키지로 두면 `Client.Admin`이 `*AdminClient` 반환 시 admin↔root import 순환이 생기므로 `admin_*.go`로 같은 패키지). `admin`은 `auth`에 의존하지 않고 `TokenProvider`(gocloak client-credentials 기본)가 유일 접착제. 오류는 경계에서 타입드 구조체(`*AdminError` 등)로 변환. **⚠️ gocloak은 네트워크 실패도 `*APIError{Code:0}`로 감싸므로** `toSDKError`는 `Code==0`→`*TransportError`, `>0`→`*AdminError`로 나눈다(그러지 않으면 전부 `AdminError{HTTP 0}`로 오분류).
- **C#/.NET**: `admin`은 `auth`에 의존하지 않는다 — `ITokenProvider`가 유일 접착제(`AuthClient : ITokenSource`가 기본 소스). 예외는 경계에서 `KeycloakException` 계급으로 변환. **⚠️ admin 타입드 클라이언트는 users/groups/realm-get만 커버**하므로 clients/roles/realm-CRUD는 같은 bearer-authed `HttpClient`로 raw Admin REST(representation 재사용).
- **PHP**: `admin`은 `auth`에 의존하지 않는다(각자 독립 client-credentials 인증) — `TokenProvider` 인터페이스가 유일 접착제. 예외는 경계에서 `KeycloakException` 계급으로 변환(`ErrorTranslation`이 fschmtt/Guzzle 예외를, `AuthClient`가 league 예외를 흡수). **⚠️ fschmtt `Users::create()`는 void 반환**(생성된 id는 `findIdByUsername()`로 후속 조회), `Clients`/`Realms`는 `create`가 아니라 **`import`**(대상 representation에 id/realm 사전 세팅 필요).
- **Rust**: `admin`은 `auth`를 직접 알지 못한다 — `TokenProvider` trait(async)가 유일 접착제(`AuthClient`가 이를 구현, `SdkTokenSupplier`가 이를 `keycloak` crate의 `KeycloakTokenSupplier`로 어댑트). 하위 오류(`keycloak::KeycloakError`)는 경계(`map_admin`)에서 SDK `KeycloakError`로 변환. **예외적으로 `admin`도 `KeycloakClient::new`에서 즉시 조립된다**(공유 `http`·전용 캐싱 provider 재사용) — 다른 8개 언어와 달리 최초 접근 시 지연 생성이 아니다.
- **Ruby**: `admin`은 `auth`에 의존하지 않는다 — `TokenProvider` 덕 인터페이스가 유일 접착제(admin은 전용 `ClientCredentialsTokenProvider`를 주입받는다, `AuthClient`도 `TokenProvider`를 구현하나 admin에 직접 주입되지 않음 — Rust가 최종리뷰로 배웠던 캐시 불변식을 Ruby는 처음부터 준수). 하위 오류(`Faraday::TimeoutError`/`ConnectionFailed`·`Rack::OAuth2::Client::Error`)는 경계에서 `KeycloakSdk::*Error`로 변환. 공유 Faraday 커넥션 팩토리(`http.rb`)는 `follow_redirects` 미들웨어를 미장착해 SSRF를 하드닝한다(Rust `redirect::Policy::none()`과 동형 결정).
- **Kotlin**: `admin`은 `auth`를 직접 알지 못한다(§4·Java 동형) — `KeycloakClient`는 admin에 provider를 배선하지 않고, `AdminClient`가 `KeycloakBuilder` 내장 client-credentials 그랜트로 토큰을 자체 소유한다(내부 `TokenManager`가 자동 획득·갱신). `ClientCredentialsTokenProvider`(`fun interface TokenProvider`)는 §4 접착 유틸이자 파사드 레벨 시임일 뿐 admin이 실사용하지는 않는다 — Java SDK가 커스텀 RESTEasy 필터 충돌로 내린 동일 결정을 상속. 하위 예외는 경계에서 sealed `KeycloakException` 계급으로 변환. JWT 검증은 `com.nimbusds:nimbus-jose-jwt` + 자체 강화이며 Java의 `JWKSourceBuilder` 캐시+RateLimited DoS-safe JWKS를 상속한다.

**언어 중립 계약(§4)**: Java(손수 래핑)·Python(`python-keycloak` 래핑)·Node(`openid-client`+admin-client 래핑)·Go(`gocloak`+`x/oauth2` 래핑)·C#(`Keycloak.AuthServices.Sdk`+`Duende.IdentityModel` 래핑)·PHP(`fschmtt`+`league/oauth2-client` 래핑)·Rust(`keycloak` crate+`openidconnect` 래핑)·Ruby(`rack-oauth2` 래핑+`faraday` 손수 admin)·Kotlin(JVM 자매 Java SDK 스택 `keycloak-admin-client`+`oauth2-oidc-sdk` 재사용 래핑)의 출발점이 다르므로, 언어 중립 API 계약을 진실 원천으로 두고 각 언어가 구현한다. 아홉 언어 모두 하위 라이브러리 타입을 **주 소비 경로(파사드) 뒤에 숨긴다**(camelCase ↔ snake_case ↔ Go/C# PascalCase만 다르고 개념·계층은 동형 — 예: `TokenSet`/`ValidatedToken`/`IntrospectionResult`·오류 계급·`Client.auth/admin`). **예외/오류 계층은 항상 경계에서 SDK 타입으로 변환**되어 `keycloak.exceptions.*`·`jakarta.ws.rs.*`·`NetworkError`·`gocloak.APIError`·`KeycloakHttpClientException`·Guzzle `RequestException`·`keycloak::KeycloakError`·`Faraday::Error`가 공개 API로 새지 않는다. Go/Rust는 예외 대신 **error 값**(Go: 센티넬 `errors.Is`/`errors.As`, Rust: `thiserror` 기반 `Result<T, KeycloakError>`) 관용을 쓴다(§4 허용). Ruby·Kotlin은 예외 기반 관용(Java/Python/Node/C#/PHP 동형 — Kotlin은 sealed class로 exhaustive `when` 강제).

**문서화된 은닉성 예외(의도적, 2026-07-03 보안감사 반영)**: 완전 은닉이 아니라 아래 지점은 하위 타입을 노출한다 — 재래핑 비용이 과다하거나 보조 표면이기 때문이다. (a) **Java·Node·Go·C#·PHP·Rust·Kotlin admin 파사드**는 representation 타입을 데이터 모델로 그대로 노출한다(Java `org.keycloak.representations.idm.*`, Node `@keycloak/keycloak-admin-client/lib/defs/*`, Go `gocloak.User`/`Client`/`Role`/`Group`/`RealmRepresentation`, C# `Keycloak.AuthServices.Sdk.Admin.Models.*Representation`, PHP `Fschmtt\Keycloak\Representation\*`, Rust `keycloak::types::{UserRepresentation, ClientRepresentation, RealmRepresentation, RoleRepresentation, GroupRepresentation}`, **Kotlin `org.keycloak.representations.idm.*`(Java와 동일 좌표 재사용)** — 안정적 Keycloak 타입 재사용, SDK 자체 DTO 재래핑은 범위 밖). Python admin은 plain `dict[str, Any]`로 통과(누출 아님), **Ruby admin도 plain `Hash`로 통과**(Python과 동형 — 성숙한 admin gem이 없어 애초에 노출할 하위 representation 타입 자체가 없음). (b) **저수준 주입/구성 지점** — Java `JwtValidator.forRealm`의 Nimbus `JWSAlgorithm`, Python `JwtValidator.validate`의 joserfc `KeySet`, Node `new JwtValidator(keys, opts)`의 jose `JWTVerifyGetKey`, Go `admin.Raw()`의 `*gocloak.GoCloak`·테스트 주입용 파라미터, C# `AdminClient.Raw`의 `IKeycloakClient`·`JwtValidator`의 내부 `TokenValidationParameters` 시임 ctor, PHP `AdminClient::raw()`의 `Fschmtt\Keycloak\Keycloak`, Rust `AdminClient::raw()`의 `&KeycloakAdmin<SdkTokenSupplier>`, Ruby `AdminClient#raw`의 `Faraday::Connection`, **Kotlin `AdminClient.raw()`의 `org.keycloak.admin.client.Keycloak`**은 하위 타입을 받는다/반환한다. 정상 소비 경로(`Client.auth/admin`, `client.Auth.Validate(...)`)는 이들을 노출하지 않는다.

## 핵심 게차 (Gotchas) — 2026-07-02 검증

- ⚠️ **admin-client(26.0.11) ≠ 서버(26.6.4) — 독립 버전 트랙.** `representation` 필드가 서버와 불일치할 수 있어 의존 필드는 실서버로 검증.
- ⚠️ **Maven Central은 Central Portal 경로만(구 OSSRH 2025-06-30 종료).** `central-publishing-maven-plugin:0.11.0` 사용 — 0.9.0 예제는 낡음.
- ⚠️ **Testcontainers 2.0은 모듈명이 바뀌었다.** JUnit5 확장은 `testcontainers-junit-jupiter`(구 `junit-jupiter` 아님). `testcontainers-keycloak:4.3.1`이 KC 26.6 기본.
- ⚠️ **JWT 검증 강화 필수(CVE-2026-11800).** 알고리즘 핀닝(`none` 거부)·iss/aud 검증·클록스큐 제한 — Nimbus는 building block만 제공, 안전한 기본값 없음.
- ⚠️ **보안 기본선**: 토큰/시크릿 로깅 금지·완전 마스킹(`***`, 접두 노출 없음)·TLS 검증 기본 on·인메모리 토큰저장 + 교체 가능 `TokenStore` SPI.
- ⚠️ **시크릿 메모리 위생은 경계가 있다.** Java `KeycloakConfig`는 `char[]`(방어복사)로 보관하나 하위 라이브러리(Nimbus `Secret`·admin-client, Python `str`)가 `String`을 요구해 사용 시점에 소거불가 `String`으로 복사됨 — char[]는 심층방어일 뿐 end-to-end 소거 보장 아님. 과대광고 금지.
- ⚠️ **JWKS 재조회는 DoS-안전해야 한다(Python, 2026-07-03 감사).** 서명위조(`BadSignatureError`)는 재조회를 유발하지 않고 kid 미해결(`InvalidKeyIdError`→`TokenKeyError`)에만 재조회하며 최소간격(`_jwks_min_refetch`)으로 rate-limit — 위조 토큰마다 IdP를 때리는 DoS 증폭 차단. Java(Nimbus `JWKSourceBuilder`)는 이미 안전.
- ⚠️ **admin 타임아웃·자원정리.** Java `AdminClient`는 connect/read 타임아웃을 `KeycloakBuilder.resteasyClient(...)`로 주입해야 무한대기 방지(미주입=스레드고갈 DoS). `close()`/`aclose()`는 admin뿐 아니라 auth 세션(requests/httpx)까지 정리(미정리=FD/커넥션풀 누수).
- ⚠️ **어떤 Java OIDC 라이브러리도 자체 인증("certified") 아니다.** 완성 제품을 필요 시 OIDF에 별도 인증.
- ⚠️ **Java 17+ javadoc은 doclint 기본 엄격.** `release` 프로파일 `maven-javadoc-plugin`에 `<doclint>none</doclint>`+`<failOnError>false</failOnError>` 없으면 문서경고로 `-javadoc.jar` 생성 실패 가능.
- ⚠️ **Java 런타임 타깃은 21 LTS.** `maven.compiler.release=21`+enforcer `requireJavaVersion=[21,)`로 JDK21 미만 fail-fast. `maven-compiler-plugin`은 `3.11.0` 명시 고정. CI 전부 JDK21 단일.
- ⚠️ **jackson-databind는 2.22.1 고정(dependencyManagement, dependabot 유지)** — CVE 대응 이력(2.21.2→2.21.4→2.21.5[CVE-2026-54515]→2.22.1). **보안 불변식**: 자체 `ObjectMapper`/default·polymorphic typing 금지, 신뢰된 Keycloak 응답만 고정 POJO로 역직렬화 — default typing 활성화·커스텀 JAX-RS Jackson provider 등록·미신뢰 JSON 다형 역직렬화 도입 금지. 상세: [verification-log.md](docs/governance/verification-log.md).
- ⚠️ **(Node) admin-client `findOne`류는 404에서 `null` 반환(선언 타입은 `undefined`).** 상세: `.claude/rules/node.md`
- ⚠️ **(Go) gocloak은 네트워크 실패까지 `*gocloak.APIError`로 감싼다(`Code:0`).** 상세: `.claude/rules/go.md`
- ⚠️ **(Go) go-jose는 `exp` 부재 시 만료검사를 건너뛴다.** 상세: `.claude/rules/go.md`
- ⚠️ **(Go) 최소 런타임 Go 1.25.** 상세: `.claude/rules/go.md`
- ⚠️ **(Node) 타임아웃은 `Configuration.timeout`(초), admin-client는 `ConnectionConfig.timeout`(ms)로 주입.** 상세: `.claude/rules/node.md`
- ⚠️ **(Node) PKCE `exchangeCode`는 `nonce` 필수 전달.** 상세: `.claude/rules/node.md`
- ⚠️ **(Node) admin은 만료 시 재인증하려면 SDK provider를 `registerTokenProvider`로 배선한다 — `kc.auth()`는 호출하지 않는다(PR #63).** 상세: `.claude/rules/node.md`
- ⚠️ **(C#) `Keycloak.AuthServices.Sdk` 3.0.0은 net10 전용 → net8.0은 2.7.0 핀.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) admin 타입드 커버리지는 users/groups/realm-get뿐.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) 네임스페이스 셰도잉.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `record` 자동 `ToString()`은 토큰/시크릿을 전체 노출.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `HttpClient.Timeout` 만료는 `TaskCanceledException`이지 `HttpRequestException`이 아니다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 예외를 안 던진다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `POST /admin/realms`(신규 realm 생성)는 master realm 전용.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) Duende.IdentityModel 확장 메서드는 예외를 안 던진다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) SDK10 기본 솔루션 포맷은 `.slnx`.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `AddKeycloak(config)`는 `KeycloakConfig`도 싱글턴 등록.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(PHP) fschmtt `Users::create()`는 void 반환.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) league/stevenmaguire의 `pkceMethod` 생성자 옵션은 no-op.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) firebase/php-jwt의 `&$headers` out-파라미터는 성공 디코드 후에만 채워진다.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) `JwksStore`의 rate-limit은 per-instance 메모리 상태.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) 시크릿 메모리 위생은 언어 차원에서 불가능.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) 통합테스트는 Testcontainers 아닌 docker CLI 셸아웃.** 상세: `.claude/rules/php.md`
- ⚠️ **(Rust) `keycloak` crate와 `openidconnect`는 reqwest 메이저를 정렬해야 함.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) `openidconnect`의 `CoreClient`는 6개 엔드포인트 typestate 제네릭.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) `jsonwebtoken`의 `Validation` 기본값은 안전하지 않다.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) JWKS rate-limit은 재조회 *결정 시점*에 stamp(Go/Python 동형).** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) 공유 `reqwest::Client`는 `redirect::Policy::none()`으로 리다이렉트 전면차단(SSRF 하드닝).** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) MSRV 1.88.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) dev-dep `testcontainers 0.27.3`은 pre-1.0.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) RUSTSEC-2023-0071(rsa crate Marvin Attack)은 무영향.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) 로컬 Windows 빌드는 VS2019 BuildTools MSVC 환경 필요.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) admin 파사드는 캐싱 `ClientCredentialsTokenProvider`를 쓴다 — 무캐시 `AuthClient` 직접주입 아님(`79ecf76`).** 상세: `.claude/rules/rust.md`
- ⚠️ **(Ruby) `jwt`(ruby-jwt) 기본값은 안전하지 않다.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) `JwtValidator.new`에 nil `issuer`/`audience`를 넘기면 ruby-jwt의 verify_iss/verify_aud가 조용히 no-op.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) `JwksStore`의 rate-limit 가드는 nil 캐시(콜드스타트 IdP다운)에도 적용돼야 함.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) `rack-oauth2`의 PKCE는 passthrough.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) admin에 성숙한 gem이 없어 `faraday`로 Admin REST 직접구현.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) SimpleCov `minimum_coverage`는 프로세스 전역 게이트.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) 로컬 Windows 빌드는 MSYS2/DevKit 필요.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) 최소 3.2, CI 상단 3.4.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) `Config` 문자열 속성은 인스턴스만 freeze, deep-frozen 아님.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) 시크릿 메모리 위생은 언어 차원에서 불가능.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) `client.auth.validate`는 IdP 장애 시 `TransportError`를 raise할 수 있다(fail-closed, 의도).** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Ruby) `Faraday::SSLError`/`ParsingError`는 `Faraday::Error`의 직계형제.** 상세: `.claude/rules/ruby.md`
- ⚠️ **(Kotlin) `fun interface`+`suspend`는 컴파일된다(KT-40978 해소).** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) ktlint filename 규칙(다중선언 파일 PascalCase)은 이 모노레포와 충돌.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) `gradle --stop`을 빌드 인플라이트 중 실행 금지.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) MockK로 JAX-RS 추상클래스(`Response`·`WebApplicationException`)를 모킹하면 JDK21에서 무기한 hang한다.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) 코루틴 스택트레이스 복구는 예외 identity를 보존 안 함.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) Kover 0.9.x는 와일드카드 없는 정확 클래스명 exclude를 무시한다.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) jvm-test-suite 없이 수동 `creating` 소스셋으로 `integrationTest`를 만들면 "no tests discovered".** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) `= runBlocking {…}` 표현식-본문 `@Test`는 Jupiter가 발견 못 함.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) Kover 0.9.x는 jvm-test-suite `integrationTest`를 자동 계측대상에 포함.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) exchangeCode는 id_token을 nonce 비교 전에 완전 서명검증한다(Java보다 강함).** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) admin 파사드는 auth를 직접 알지 못한다(§4·Java 동형).** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) 로컬 포터블 Gradle과 CI 래퍼 버전을 일치시켜 둔다(현재 둘다 9.6.1).** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Kotlin) 신규 라이브러리 리스크 0.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Java·Kotlin) `resteasyClient(...)` 주입은 admin-client의 `JacksonProvider` 등록을 통째로 우회한다.** admin-client는 이 프로바이더를 자기가 만든 클라이언트에만 등록하므로, 타임아웃 주입용으로 우리 클라이언트를 넘기면 `NON_NULL`(null필드 미전송)과 `FAIL_ON_UNKNOWN_PROPERTIES=false`(미지필드 무시)를 둘 다 잃는다 — 버전스큐에서 양방향 파손(클라이언트가 앞서면 400 *Unrecognized field*, 서버가 앞서면 역직렬화 깨짐). **26.0.11의 `UserRepresentation.verifiableCredentials`에서 실제 발현(PR #84)**. `buildTimeoutClient`가 `.register(JacksonProvider.class,100)`+`.register(StreamMessageBodyReader.class)`를 직접 수행 — ⚠️ **`StreamMessageBodyReader`는 26.0.11에만 존재**(26.0.10까지는 JacksonProvider 내장, 26.0.11에서 분리 — 프로바이더의 stream 참조 26.0.10 **9건** → 26.0.11 **0건** 실측). `ClientBuilder.newBuilder()` 유지 필수 — `createClientBuilder()`로 바꾸면 커넥션풀이 50→10으로 조용히 축소. ⚠️ **동작 계약**: NON_NULL이 켜지면 부분 업데이트에서 null로 필드를 비우는 것이 불가능해진다(미설정 필드는 전송되지 않아 서버가 '변경 없음'으로 처리) — 공식 admin-client와 동일한 동작이다. 비우려면 빈 문자열/전용 API를 쓴다.
- ⚠️ **(Node) `tsconfig.json`의 `include: ["src"]`라 테스트 파일은 타입체크 안 됨.** 상세: `.claude/rules/node.md`
- ⚠️ **(Node) JWKS rate-limit 회귀는 대조군 없이는 안 잡힌다.** 상세: `.claude/rules/node.md`
- ⚠️ **(CI) Dependabot 트리거 run에는 Actions 시크릿이 노출 안 됨**(별도 스토어, 이 저장소는 비어있음) — `SONAR_TOKEN`이 빈 문자열로 보간돼 SonarCloud가 반드시 실패(코드 신호 아님). `sonarcloud.yml`은 Dependabot PR만 skip(push는 항상 통과, main 스캔 스킵 불가 — PR0 fail-closed 불변). 토큰 복제안은 기각(미검토 패키지 코드가 토큰과 같은 잡에서 실행됨 우려).
- ⚠️ **하드닝 CI 게차(로컬↔CI 차이)**: Go `gofmt`·Node `prettier`·PHP `cs-fixer`는 Windows CRLF 워킹트리를 전부 flag(변경파일 LF-정규화 후 재확인) · 전역상태 테스트(Ruby rack-oauth2)는 flaky라 config 훅 mock 검증 · pip-audit는 editable skip에도 exit1(→ `pip freeze --exclude-editable`+`-r`) · SonarCloud "0% Coverage on New Code"는 Kotlin kover만 피드해 비-Kotlin PR마다 fail(비차단·UNSTABLE).
- ⚠️ **java jacoco:check는 `verify` 페이즈 바인딩 — 로컬 `mvn test`로는 커버리지 게이트 미검증**(반드시 `mvn -pl … -am verify -DskipITs`). PR #71에서 `forRealm`에 `.rateLimited()` 1줄이 auth번들을 0.90→0.89로 떨어뜨려 CI 3잡 동시실패 — `JWKSourceBuilder` 지연특성 이용한 네트워크-프리 `forRealm` 단위테스트로 복원.
- ⚠️ **앱 빌드 이미지는 Alpine(musl) 베이스** — Debian/glibc는 Docker Desktop(Windows) 내장 DNS프록시가 레지스트리 CNAME체인을 glibc 리졸버에 실패로 돌려줘 `dotnet restore`/`pip install`/Maven·npm 다운로드가 막힘(musl은 정상, CI 네이티브 Docker 무해).
- ⚠️ **앱/레지스트리 전 컨테이너 Alpine/musl**(Windows Docker Desktop glibc-DNS 게차 회피 — install harness 전용 재확인, 위와 동일 근거).
- ⚠️ **잔여 follow-up(marginal·미착수)**: wait_healthy 크래시 조기감지(run.sh의 `sleep 3600`이 이득 제한) · go 공개프록시 폴스루(현 file-first 체인 정상동작) · rust closure Cargo.lock 커밋(저가치·유지비).

## 확정 의존성 (BOM으로 고정)

<!-- doc-guard: kind=dep source=java/pom.xml min=5 -->
| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 서버(26.6.4)와 독립 버전 트랙 — "26.6.x admin-client"는 존재하지 않는다 | 26.0.11 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | 표준 OAuth2/OIDC 흐름의 성숙한 레퍼런스 구현(단, 그 자체가 "certified"는 아님 — 완성 제품 인증은 OIDF에 별도로) | 11.38.2 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | `JWKSourceBuilder`가 캐시+RateLimited로 DoS-safe JWKS 재조회를 기본 제공(CVE-2026-11800 하드닝의 기반) — 단, 안전한 기본값 자체는 SDK가 얹어야 함 | 10.9.1 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 실제 Keycloak 26.6 컨테이너로 통합검증(단위 모킹만으론 admin-client 버전 스큐를 못 잡음) | 4.3.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0 모듈명 변경 반영 — JUnit5 확장은 `-junit-jupiter`(구 `junit-jupiter` 아님) | 2.0.5 |
| 단위 테스트 | JUnit 6.1.2 · Mockito 5.23.0 | 표준 JVM 단위테스트 스택 | — |

**Node 확정 의존성(package.json으로 고정)**: `@keycloak/keycloak-admin-client` **`~26.7.0`**(admin — 원래 `^26`→26.7.0의 `decodeToken(undefined).split()` 크래시 회귀로 `~26.6.4`로 좁혔다가[PR #62], PR #63의 provider 배선(`kc.auth()` 미호출)이 크래시 경로를 근본 차단함이 통합테스트로 실증되어 dependabot PR #48로 `~26.7.0`으로 전진) · `openid-client` **6.8.4**(auth, 함수형 API) · `jose` **`^6`**(강화 JWT — 5.10.0에서 전진, `openid-client` 6.8.4가 이미 `jose ^6.2.2`를 요구하고 있어 이 bump는 트리를 **dedupe**한다. SDK가 쓰는 7개 API/옵션이 v6에서 이름·의미 모두 동일함을 published `.d.ts`로 확인했고, `cooldownDuration` rate-limit이 실제로 살아있음을 히트 수로 실측했다) · dev: `typescript` **6**(6.0.x는 JS 기반 안정 라인 — 보류 중인 TS 7이 네이티브 포트 preview다. 산출 `dist/**`가 TS 5.9.3과 **바이트 동일**함을 확인) · `vitest`/`@vitest/coverage-v8` 3(v4는 `vi.mock` 시맨틱 변경으로 보류) · `testcontainers` 12 · `eslint` 10 + `typescript-eslint` 8 · `prettier` 3 · `@types/node` **`^22`**(engines 하한과 일치 — 최신을 따라가지 않는다. dependabot.yml에 메이저 ignore). 런타임 deps(admin-client/openid-client/jose)는 audit clean, devDeps 일부 moderate(dockerode/testcontainers 계열, `files:["dist"]`라 소비자 미배포).

**Go 확정 의존성(go.mod, major 핀)**: `github.com/Nerzal/gocloak/v13` **v13.9.0**(admin) · `golang.org/x/oauth2` **v0.36.0**(auth 흐름) · `github.com/go-jose/go-jose/v4` **v4.1.4**(강화 JWT) · `golang.org/x/sync/singleflight`(single-flight) · test: `github.com/testcontainers/testcontainers-go` **v0.43.0**(base GenericContainer — `modules/keycloak`는 독립 태그 부재로 미사용) · `github.com/stretchr/testify` **v1.11.1**. 전부 Apache-2.0/BSD-3/MIT(호환). `go-oidc`는 제외(discovery는 규약 조립, verifier는 go-jose 자체 강화).

**C#/.NET 확정 의존성(csproj, major 핀)**:

<!-- doc-guard: kind=dep source=dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj min=2 -->
| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 인증(OIDC/OAuth2) | `Duende.IdentityModel` | 확장 메서드가 예외를 던지지 않아(`resp.IsError` 검사) 결정적 파사드에 맞음 — PKCE 헬퍼는 없어 SDK가 손수 생성 | 8.1.0 |
| JWT(강화 검증) | `Microsoft.IdentityModel.JsonWebTokens` + `.Protocols.OpenIdConnect` | `ValidateTokenAsync`가 실패해도 던지지 않는 저수준 API라 SDK가 `ValidAlgorithms`/`ClockSkew`/`RequireExpirationTime` 전부 명시 강화해야 함(기본값이 안전하지 않음) | 8.20.0 |

| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `Keycloak.AuthServices.Sdk` | net8 최종 버전 — 3.0.0은 net10 전용이라 사용 불가 | **2.7.0** |
| DI 추상화 | `Microsoft.Extensions.DependencyInjection.Abstractions` | AuthServices 2.7.0의 하한(9.0.8) 충족 + net8 유지 정책으로 10.x major는 보류(PR #57 close) | 9.0.18 |
| 단위 테스트 | `xUnit` 2.9.3 · `WireMock.Net` 2.13.0 · `coverlet.msbuild` 10.0.1 | 표준 .NET 단위테스트+모킹+커버리지 스택 | — |
| 통합 테스트 | `Testcontainers.Keycloak` | 실제 Keycloak 26.6 컨테이너로 E2E 검증 | 4.13.0 |

전부 Apache-2.0/MIT(호환). `IHttpClientFactory`는 미채택(단일 장수명 `HttpClient` + `SocketsHttpHandler.PooledConnectionLifetime` — 단일서버 SDK 관용).

**PHP 확정 의존성(composer.json, 정확 핀/범위 지정)**:

<!-- doc-guard: kind=dep source=php/composer.json min=6 -->
| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `fschmtt/keycloak-rest-api-client-php` | 유일한 성숙 admin 클라이언트 — pre-1.0 계열이라 정확 핀(파괴적 변경 가능) | **0.42.0** |
| 인증(OAuth2) | `league/oauth2-client` | 성숙한 OAuth2 클라이언트(대안 `jumbojett/openid-connect-php`는 세션 슈퍼글로벌 결합으로 기각) | `^2.8` |
| 인증(OAuth2, Keycloak 프로바이더) | `stevenmaguire/oauth2-keycloak` | `league/oauth2-client`용 Keycloak 프로바이더 확장 | `^6.1` |
| JWT(강화 검증) | `firebase/php-jwt` | 표준 JWT 라이브러리 — 내장 `CachedKeySet`은 rate-limit 버그(#543)가 있어 자체 `JwksStore`로 대체 | `^7.1` |
| HTTP(PSR-18) | `guzzlehttp/guzzle` | fschmtt·league 양쪽이 공통으로 요구하는 PSR-18 전송 계층 | `^7.9` |
| HTTP(PSR-17) | `guzzlehttp/psr7` | PSR-17 메시지 팩토리(guzzle과 짝) | `^2.7` |

| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 단위 테스트 | `phpunit/phpunit` 12 · `phpstan/phpstan` 2.2(+ strict-rules·phpunit 확장) · `friendsofphp/php-cs-fixer` 3.95 | 표준 PHP 정적분석(level max)+테스트+스타일 스택 | — |
| 통합 테스트 | (docker CLI 셸아웃 — `testcontainers/testcontainers` ^1.0은 dev 의존이나 Windows native PHP 미지원으로 실사용 안 함) | Windows native PHP가 `unix://` 스트림 트랜스포트 미지원(Docker Desktop npipe도 불가) | — |

전부 MIT/BSD-3(Apache-2.0 호환). `jumbojett/openid-connect-php`는 세션 슈퍼글로벌·`header()` 리다이렉트를 자체 소유해 결정적 파사드와 상충 + JWT 검증 이력 우려로 기각.

**Rust 확정 의존성(Cargo.toml, 정확 핀 `=` 지정)**:

<!-- doc-guard: kind=dep source=rust/Cargo.toml min=5 -->
| 의존성 | 크레이트 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `keycloak`(`default-features = false`, features: `tags-all`·`resource-builder`·`reqwest12`) | `reqwest12` feature로 `openidconnect`와 reqwest 0.12를 정렬(안 맞추면 타입 불일치로 컴파일 실패) | `=26.6.2` |
| 인증(OIDC/OAuth2) | `openidconnect`(`default-features = false`, feature: `reqwest`) | `CoreClient`가 6개 엔드포인트 typestate 제네릭 — auth/introspection/token만 `EndpointSet`으로 명시해 무오류 호출 가능 | `=4.0.1` |
| JWT(강화 검증) | `jsonwebtoken`(`default-features = false`, features: `rust_crypto`·`use_pem`) | `Validation` 기본값이 안전하지 않아 `validate_nbf`/`leeway`/`required_spec_claims` 전부 재정의 필요 | `=10.4.0` |
| HTTP | `reqwest`(`default-features = false`, features: `json`·`rustls-tls`) | `keycloak` crate·`openidconnect`가 공유하는 단일 HTTP 클라이언트(SSRF 하드닝을 위해 `redirect::Policy::none()` 적용) | `0.12` |
| 비동기 런타임 | `tokio`(features: `rt-multi-thread`·`macros`·`time`·`sync`) | `openidconnect`·`keycloak` crate 양쪽이 요구하는 비동기 런타임 | `1.52` |

| 의존성 | 크레이트 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 오류/직렬화 | thiserror 2.0 · async-trait 0.1 · serde+serde_json 1 · url 2 | 표준 에러 계급·직렬화·URL 유틸 | — |
| 단위 테스트 | wiremock 0.6(HTTP 목) · rsa 0.9+rand 0.8+base64 0.22(JWKS 공격 프로브 픽스처 생성) | HTTP 목 + 공격 프로브용 테스트 키 생성(RUSTSEC-2023-0071은 서명검증 전용인 런타임에 무영향) | — |
| 통합 테스트 | testcontainers 0.27.3(pre-1.0, base `GenericImage` — 언어별 편의 모듈 없음) | pre-1.0이라 Keycloak 전용 편의 모듈이 없어 `GenericImage`로 직접 조립 | — |

전부 Apache-2.0/MIT(호환). `keycloak`/`openidconnect`/`jsonwebtoken`은 정확 핀(`=`)으로 고정(reqwest 메이저 정렬·typestate 제네릭·`Validation` 필드가 버전 간 깨지기 쉬운 표면이라 마이너 드리프트 방지). RUSTSEC-2023-0071(rsa Marvin)은 dev-dependency `rsa`(테스트 키 생성 전용)에 대한 것으로 SDK 런타임(공개키 서명검증만 수행)에는 무영향(게차 참조).

**Ruby 확정 의존성(gemspec, 범위 지정)**:

<!-- doc-guard: kind=dep source=ruby/keycloak-sdk.gemspec min=3 -->
| 의존성 | gem | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 인증(OAuth2/OIDC) | `rack-oauth2`(nov) | OIDF 인증 RP 저자(nov)의 유지 gem — PKCE는 passthrough라 S256을 SDK가 손수 생성 | `~> 2.3` |
| Admin | (성숙한 gem 부재 — faraday로 Admin REST 직접 래핑) | looorent/keycloak-admin 등은 전부 공유 TokenProvider 주입 미지원(§4 캐싱 불변식 위반)으로 기각 | — |
| HTTP | `faraday` | 직접 구현하는 admin REST + rack-oauth2 전역 타임아웃 설정의 공통 기반 | `~> 2.0` |
| JWT(강화 검증) | `jwt`(ruby-jwt) | 기본값이 안전하지 않아 `algorithms`/`verify_iss`/`verify_aud`/`leeway` 전부 재정의 필요 | `~> 3.2` |
| 단위 테스트 | rspec 3 · webmock · simplecov · rubocop(+ rubocop-rspec) | 표준 RSpec+HTTP목+커버리지+린트 스택 | — |
| 통합 테스트 | (docker CLI 셸아웃 — Windows native Ruby가 testcontainers-ruby 소켓 트랜스포트 미지원, PHP와 동일 패턴) | Windows native Ruby가 testcontainers-ruby 소켓 트랜스포트 미지원 | — |
| 의존성 감사 | bundler-audit | gem 취약점 감사 | — |

전부 MIT(Apache-2.0 호환). `rack-oauth2`는 OIDF 인증 RP 저자(nov)의 유지 gem으로 채택. `looorent/keycloak-admin`·`imagov/keycloak`·`keycloak-ruby-client`는 전부 공유 `TokenProvider` 주입 미지원(§4 캐싱 불변식 위반)으로 기각, `openid_connect`(nov)는 런타임 의존성 11개로 무거워 기각, `oauth2`(pboling)는 PKCE 완전 수작업·OIDC 비인식으로 기각.

**Kotlin 확정 의존성(build.gradle.kts, JVM 자매 Java SDK 스택 재사용 + 코루틴 경계 신규)**:

<!-- doc-guard: kind=dep source=kotlin/build.gradle.kts min=6 -->
| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin(재사용, api) | `org.keycloak:keycloak-admin-client` | JVM 자매 Java SDK가 실 Keycloak으로 이미 필드 검증 — 신규 라이브러리 리스크 0 | 26.0.11 |
| 인증(재사용) | `com.nimbusds:oauth2-oidc-sdk` | 위와 동일 이유(Java SDK 검증 스택 재사용) | 11.38.2 |
| JWT(재사용, 강화 검증) | `com.nimbusds:nimbus-jose-jwt` | 위와 동일 이유 + Java의 `JWKSourceBuilder` 캐시+RateLimited DoS-safe JWKS를 그대로 상속 | 10.9.1 |
| 코루틴(신규, 공개 suspend 노출 → api) | `org.jetbrains.kotlinx:kotlinx-coroutines-core` | 유일한 신규 경계 — `suspend`+`runInterruptible(Dispatchers.IO)`로 블로킹 JVM 라이브러리 호출을 코루틴 관용으로 감쌈 | 1.11.0 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 실제 Keycloak 26.6 컨테이너로 통합검증(Java와 동일 모듈) | 4.3.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0 모듈명 변경 반영(Java와 동형) | 2.0.5 |

| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 단위 테스트 | JUnit 6.1.2 · MockK 1.14.11 · WireMock 3.13.2 · `kotlinx-coroutines-test` 1.11.0 · `kotlin-test-junit5` 2.4.10 | JVM 표준 테스트+모킹+HTTP목+코루틴테스트 스택(MockK는 JAX-RS 추상클래스엔 미사용 — 게차 참고) | — |
| 빌드/배포 플러그인 | Kotlin 2.4.10 · vanniktech `maven.publish` 0.37.0(Central Portal) · Kover 0.9.9 · ktlint gradle 14.2.0 · Dokka 2.2.0 | Central Portal 배포(구 OSSRH 종료)+커버리지 게이트+린트+API 문서 생성 | — |

전부 Apache-2.0/EPL-2.0(호환). Admin·인증·JWT 3개 좌표는 Java SDK가 실 Keycloak으로 이미 검증한 것과 완전히 동일해 신규 라이브러리 리스크 0 — 차이는 코루틴 관용 래핑(`kotlinx-coroutines-core`)뿐이다.

## 문서 유지 규칙

작업 완료(머지/main 반영) 후 프로젝트 전체 문서(`CLAUDE.md`, `docs/`, `README.md`)를 최신화·최적화하고 커밋한다. 언어별 빌드/테스트 명령(단일 테스트 실행 포함)을 툴체인 섹션에 유지한다(Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin).

**`scripts/check-docs.mjs`(문서-소스 드리프트 가드)의 현재 앵커 스코프는 부분적이다** — `<!-- doc-guard: ... -->` 앵커는 지금 Java·.NET·Kotlin·PHP·Rust·Ruby 의존성 표 6종(pom.xml/csproj/build.gradle.kts/composer.json/Cargo.toml/gemspec 추출기)과 .NET 최소 런타임 선언 1건만 기계 검증하며, 나머지 언어(Go·Python·Node)의 의존성 표(산문 — 표 형식이 아니라 스코프 밖)와 최소 런타임 선언은 여전히 사람이 직접 맞춰야 한다(계획된 후속 확장 — 사람 판단을 완전히 대체하는 것이 아니다).

### 문서 언어 규칙 (bilingual README + 영문 사용자 문서, PR #31·#32)

- **README는 영문 기본 + 한글 미러**: [`README.md`](README.md)(영문, 기본)와 [`README.ko.md`](README.ko.md)(한글)는 **동일 구조의 미러**다 — 한쪽을 고치면 다른 쪽도 함께 갱신해 동기 유지(상단 상호 링크 `English ↔ 한국어`). 둘 다 슬림 랜딩(정적 배지·9언어 표·30초 퀵스타트·보안·상태·링크)이며, 미배포(human-gated) 상태이므로 **라이브 레지스트리 배지 금지**(정적 배지만 — 오해 방지).
- **사용자 대상 문서는 영문(in-place)**: [`docs/guides/`](docs/guides/) 3종 · [`docs/roadmap/language-support.md`](docs/roadmap/language-support.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`DEPLOY.md`](DEPLOY.md) · [`harness/README.md`](harness/README.md) · [`harness/install/README.md`](harness/install/README.md)는 영문으로 유지·갱신한다(한글 미러 없음).
- **내부 산출물은 한글 유지**: [`docs/superpowers/`](docs/superpowers/)(설계 스펙·WBS 플랜)·[`docs/governance/`](docs/governance/)(검증 로그)와 이 `CLAUDE.md`는 개발/거버넌스 내부 문서로 한글을 유지한다.
- **앵커 주의**: 영문 문서에서 헤딩을 바꾸면 `#anchor`가 바뀐다. `getting-started.md`의 `## C# / .NET`(앵커 `#c--net`)은 양쪽 README가 링크하므로 **헤딩 텍스트를 바꾸지 말 것**.
