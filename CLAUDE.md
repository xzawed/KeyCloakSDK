# CLAUDE.md
<!-- doc-budget: max-bytes=48500 -->
<!-- ⚠️ 래칫이다(목표치 아님). 줄일 때마다 이 숫자를 함께 내린다. 올리는 PR은 그 자체가 리뷰 대상 —
     이관 직후 44 KB였던 이 파일이 13일 만에 66 KB가 됐다(+50%). 산문 규칙으로는 막히지 않았다.

     승인된 목표는 33 KB였다(2026-07-23-docs-restructure-design.md). **실측 바닥은 그보다 높다.**
     47.5 KB의 구성: 게차 스텁 79건 12.4 KB + doc-guard 앵커가 걸린 의존성 표 10.9 KB(=기계 검증
     46 facts) + 나머지 24 KB. 앞의 둘은 줄일 수 없다 — 스텁을 지우면 `.claude/rules/<lang>.md`는
     경로 스코프 자동로드라 컨텍스트 압축 후 재주입되지 않아 게차의 존재 자체가 안 보이고(설계 §4.3),
     앵커 표를 지우면 `--min-facts/--min-anchors`가 실패한다. 33 KB로 가려면 둘 중 하나를 버려야
     하므로 목표를 낮추는 대신 **바닥을 인정하고 그 위에서 래칫한다.** 여지는 나머지 24 KB에 있다. -->

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
- **9번째 언어**: Kotlin — 빌드는 KGP 2.4.10이되 **소비자 하한은 2.2+**(`languageVersion`/`apiVersion`=KOTLIN_2_2로 게시 아티팩트 메타데이터를 낮춤, 게차 참고) · JDK 21 · 단일 Gradle 모듈 · coroutines(`suspend`+`runInterruptible(Dispatchers.IO)`) · JVM 자매 Java SDK 라이브러리 스택(`keycloak-admin-client` 26.0.11 + `oauth2-oidc-sdk` 11.38.2) 재사용 래핑 + `nimbus-jose-jwt` 자체 JWT 검증 (`main` 병합, PR #23)
- **라이선스**: Apache-2.0 · **groupId**: `io.github.xzawed` · Python 배포명: `keycloak-sdk` · npm 배포명: `@xzawed/keycloak-sdk` · Go 모듈: `github.com/xzawed/KeyCloakSDK/go` · NuGet 배포명: `Xzawed.Keycloak.Sdk` · Packagist 배포명: `xzawed/keycloak-sdk` · crates.io 배포명: `keycloak-sdk` · RubyGems 배포명: `keycloak-sdk` · Maven Central 좌표(Kotlin): `io.github.xzawed:keycloak-sdk-kotlin`

**핵심 전략**: 언어마다 가장 좋은 기반을 사용한다 — 공식/성숙 클라이언트가 있으면 감싼다(Java는 `keycloak-admin-client`, Python은 `python-keycloak`, Node는 공식 `@keycloak/keycloak-admin-client` + `openid-client`, Go는 `gocloak` + `x/oauth2`, C#은 `Keycloak.AuthServices.Sdk` + `Duende.IdentityModel`, PHP는 `fschmtt/keycloak-rest-api-client-php` + `league/oauth2-client`, Rust는 `keycloak` crate + `openidconnect`, Ruby는 성숙한 admin gem이 없어 `faraday`로 직접 래핑 + `rack-oauth2`, Kotlin은 JVM 자매 Java SDK의 검증된 스택(`keycloak-admin-client` + `oauth2-oidc-sdk` + `nimbus-jose-jwt`)을 코루틴 관용으로 재래핑) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다. JWT 검증은 아홉 언어 모두 자체 강화 구현(algorithm pinning·iss 정확일치·aud 포함검사·`exp` 필수·클록 스큐·DoS-안전 JWKS 재조회)이다.

## 현재 상태

9개 언어 SDK 모두 `main` 병합 완료. PHP·Python·.NET·**Rust** 4개는 첫 RC가 공개 레지스트리에 게시됐다 — Packagist `xzawed/keycloak-sdk` 0.1.0-rc.1 · PyPI `keycloak-sdk` 0.1.0rc1 · NuGet `Xzawed.Keycloak.Sdk` 0.1.0-rc.1 · crates.io `keycloak-sdk` 0.1.0-rc.1. 나머지 5개(Java·Node·Go·Ruby·Kotlin)는 미게시이며, 배포는 여전히 전부 사람 승인 게이트다(사람이 태그를 민다).

| 언어 | 배포명 | 태그 접두 | 배포 |
|---|---|---|---|
| Java | `io.github.xzawed:keycloak-sdk` | `v*` | 미실행 |
| Python | `keycloak-sdk` | `py-v*` | 게시됨(`0.1.0rc1` RC) |
| Node | `@xzawed/keycloak-sdk` | `node-v*` | 미실행 |
| Go | `github.com/xzawed/KeyCloakSDK/go` | `go/v*` | 미실행 |
| C#/.NET | `Xzawed.Keycloak.Sdk` | `dotnet-v*` | 게시됨(`0.1.0-rc.1` RC) |
| PHP | `xzawed/keycloak-sdk` | `php-v*` | 게시됨(`0.1.0-rc.1` RC) |
| Rust | `keycloak-sdk` | `rust-v*` | 게시됨(`0.1.0-rc.1` RC) |
| Ruby | `keycloak-sdk` | `ruby-v*` | 미실행 |
| Kotlin | `io.github.xzawed:keycloak-sdk-kotlin` | `kotlin-v*` | 미실행 |

**릴리스-레디니스 감사(브랜치 `fix/release-readiness-blockers`)**: 게시 직전 차단요소를 훑어 릴리스 워크플로(태그↔매니페스트 버전 가드·시크릿 미설정 시 fail-closed·발행 전 통합 E2E 게이트·서드파티 액션 SHA 핀·`permissions` 최소화)와 패키징 표면(패키지에 담기는 LICENSE·영문 README·레지스트리 메타데이터 보강, Rust 캐럿 요구 전환 + `Cargo.lock` 커밋 + `keycloak::types` 재노출)을 고쳤다. **PHP 선행작업은 전부 끝났다** — 미러 저장소 `xzawed/keycloak-sdk-php` 생성과 `PHP_SPLIT_TOKEN` 등록(`./scripts/release-readiness.sh php` → `secrets=set`)에 이어, 첫 `php-v*` 릴리스가 미러를 채운 뒤 **Packagist 등록까지 완료**됐다(`xzawed/keycloak-sdk` 라이브 — 아래 (PHP) Packagist 게차).

구현 경위·PR 이력: [docs/governance/history.md](docs/governance/history.md) · 배포 절차: [DEPLOY.md](DEPLOY.md) · **`docs/` 전체 지도(62개 문서 · 각 문서에만 있는 것): [docs/README.md](docs/README.md)**

## 툴체인 (빌드 명령)

언어별 전체 빌드/테스트/린트/배포 명령(단일 테스트 실행 포함)은 `.claude/rules/<lang>.md`에 있다(해당 언어 경로 작업 시 자동 로드). 아래는 언어별 핵심 진입 명령 하나씩만 남긴 표다.

**새 머신에서 시작한다면**: `node scripts/doctor.mjs [<lang>…]`이 각 언어의 빌드 파일에서 최소 런타임 선언을 읽어 이 PC에 무엇이 없는지 알려준다. 설치·환경변수 규약(`KCSDK_TOOLS`·`KCSDK_JDK21`·`KCSDK_PY`)은 [docs/guides/development-setup.md](docs/guides/development-setup.md). 툴체인 경로는 `.claude/rules/*.md`에 머신 기본값을 둔 채 이 변수들로 덮어쓸 수 있다(리포지토리에 특정 PC 경로를 못박지 않는다).

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

**아홉 언어 공통**: `admin`은 `auth`에 의존하지 않는다 — `TokenProvider` 계열 인터페이스(Rust는 async trait, Ruby는 덕 타이핑, Kotlin은 `fun interface`)가 유일한 접착제이고, 하위 라이브러리 오류는 **경계에서** SDK 타입으로 변환된다. 그래서 auth 없이도 admin을 자체 토큰 소스로 쓸 수 있고, 내부 라이브러리 교체가 소비자에게 파급되지 않는다.

**공통에서 벗어나는 곳만 아래에 적는다**(각 언어의 상세는 `.claude/rules/<lang>.md`, `raw`/`Raw` 탈출구 타입은 §4(b)):

| 언어 | 벗어나는 지점 |
|---|---|
| Go | **전체가 단일 `package keycloak`** — admin을 서브패키지로 두면 `Client.Admin`이 `*AdminClient`를 반환할 때 import 순환이 생긴다. 그래서 `admin_*.go`로 같은 패키지다. |
| Rust | **admin도 `KeycloakClient::new`에서 즉시 조립된다** — 나머지 여덟 언어의 "최초 접근 시 지연 생성"과 다르다(공유 `http`·전용 캐싱 provider 재사용). |
| Kotlin | **admin이 토큰을 자체 소유한다** — `KeycloakBuilder` 내장 client-credentials 그랜트의 `TokenManager`가 획득·갱신하고, 파사드는 admin에 provider를 배선하지 않는다. `ClientCredentialsTokenProvider`는 §4 접착 유틸이자 시임일 뿐이다(Java가 커스텀 RESTEasy 필터 충돌로 내린 결정을 상속). |
| Node | **파사드가 주입한 캐싱 provider를 `registerTokenProvider`로 배선하고 `kc.auth()`는 호출하지 않는다**(PR #63) — admin-client 내장 TokenManager는 만료 시 refresh만 시도해 client_credentials에서 영구 실패한다(Rust `79ecf76`와 동형 결정). |

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
- ⚠️ **(Java) 퍼블릭/PKCE 클라이언트에서 `char[]` 시크릿을 무조건 문자열화하면 맨 NPE다.** 상세: `.claude/rules/java.md`
- ⚠️ **(Node) admin-client `findOne`류는 404에서 `null` 반환(선언 타입은 `undefined`).** 상세: `.claude/rules/node.md`
- ⚠️ **(Go) gocloak은 네트워크 실패까지 `*gocloak.APIError`로 감싼다(`Code:0`).** 상세: `.claude/rules/go.md`
- ⚠️ **(Go) go-jose는 `exp` 부재 시 만료검사를 건너뛴다.** 상세: `.claude/rules/go.md`
- ⚠️ **(Go) 최소 런타임 Go 1.25.** 상세: `.claude/rules/go.md`
- ⚠️ **(Node) 타임아웃은 `Configuration.timeout`(초), admin-client는 `ConnectionConfig.timeout`(ms)로 주입.** 상세: `.claude/rules/node.md`
- ⚠️ **(Node) PKCE `exchangeCode`는 `nonce` 필수 전달.** 상세: `.claude/rules/node.md`
- ⚠️ **(Node) admin은 만료 시 재인증하려면 SDK provider를 `registerTokenProvider`로 배선한다 — `kc.auth()`는 호출하지 않는다(PR #63).** 상세: `.claude/rules/node.md`
- ⚠️ **(C#) `Keycloak.AuthServices.Sdk` 3.0.0은 net10 전용 → net8.0은 2.7.0 핀.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `Raw`는 users/groups/realm-read만 커버 — 그 밖은 파사드가 raw Admin REST로 직접 구현한다(한때 3건이 도달 불가능했다).** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(Rust) `search_users`의 `max`에 `Option`을 두지 말 것 — Keycloak은 미전송 시 조용히 100을 적용한다(무제한 아님).** 상세: `.claude/rules/rust.md`
- ⚠️ **(C#) admin 타입드 커버리지는 users/groups/realm-get뿐.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) 네임스페이스 셰도잉.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `record` 자동 `ToString()`은 토큰/시크릿을 전체 노출.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `HttpClient.Timeout` 만료는 `TaskCanceledException`이지 `HttpRequestException`이 아니다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) 위조 서명은 JWKS 재조회를 유발한다 — 나머지 8개 언어와 달리 재조회 0회 불변식을 갖지 못하고 rate-limit 상한만 걸린다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 예외를 안 던진다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `POST /admin/realms`(신규 realm 생성)는 master realm 전용.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) Duende.IdentityModel 확장 메서드는 예외를 안 던진다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) SDK10 기본 솔루션 포맷은 `.slnx`.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) `AddKeycloak(config)`는 `KeycloakConfig`도 싱글턴 등록.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) coverlet msbuild 통합은 히트 flush 유실 시 `0%`를 "커버리지 90 미만"으로 둔갑시킨다 — 컬렉터+자체 가드로 전환했다.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(C#) 브랜치 게이트 실제 여유는 2개다(분모 50, 1개당 2%p) — 백분율로 읽지 말 것.** 상세: `.claude/rules/dotnet.md`
- ⚠️ **(PHP) fschmtt `Users::create()`는 void 반환.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) league/stevenmaguire의 `pkceMethod` 생성자 옵션은 no-op.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) firebase/php-jwt의 `&$headers` out-파라미터는 성공 디코드 후에만 채워진다.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) `JwksStore`의 rate-limit은 per-instance 메모리 상태.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) 시크릿 메모리 위생은 언어 차원에서 불가능.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) 통합테스트는 Testcontainers 아닌 docker CLI 셸아웃.** 상세: `.claude/rules/php.md`
- ⚠️ **(PHP) 모노레포는 Packagist에 직접 게시할 수 없다 — subtree-split 미러가 필수다**(웹훅 전제는 성립한 적이 없다). 미러·토큰·Packagist 등록은 전부 완료됐고 순서는 뒤집을 수 없었다. 상세: `.claude/rules/php.md` · 절차: [DEPLOY.md §2-D](DEPLOY.md)
- ⚠️ **(Rust) `keycloak` crate와 `openidconnect`는 reqwest 메이저를 정렬해야 함.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) `openidconnect`의 `CoreClient`는 6개 엔드포인트 typestate 제네릭.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) `jsonwebtoken`의 `Validation` 기본값은 안전하지 않다.** 상세: `.claude/rules/rust.md`
- ⚠️ **(Rust) jsonwebtoken 11.0.0부터 기형 JWKS 거부가 파싱이 아니라 키 생성 단계에서 일어난다(`Transport`→`TokenValidation`) — fail-closed는 유지, 미지 kty 혼재 세트는 이제 죽지 않는다.** 상세: `.claude/rules/rust.md`
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
- ⚠️ **(Kotlin) 게시 아티팩트의 바이너리 메타데이터 버전은 KGP 버전이 아니라 `languageVersion`/`apiVersion`이 정한다 — 설정 없이 KGP 2.4.10으로 빌드하면 Kotlin 2.4 미만 소비자는 라이브러리를 아예 쓸 수 없다.** 상세: `.claude/rules/kotlin.md`
- ⚠️ **(Java·Kotlin) `jwksMinRefetch`는 Nimbus 캐시 TTL(기본 5분) 미만이어야 한다** — 크면 `JWKSourceBuilder.build()`가 던지고, 그 foreign 예외가 공개 API로 새면 §4 위반이다(지금은 경계에서 `KeycloakConfigException`으로 변환). ⚠️ **JWKS rate-limit 테스트에는 반드시 대조군을 둘 것** — 캐시만으로도 통과해 하드닝 한 줄을 지워도 초록이 된다. 상세: `.claude/rules/java.md`·`.claude/rules/kotlin.md`
- ⚠️ **JWKS 재조회 최소 간격 기본값은 아홉 언어 전부 30초다(2026-07-31 정렬).** 그 전에는 10초(Ruby)·30초(Java·Node·.NET·Kotlin)·60초(Python·Go·PHP·Rust) 세 갈래였는데, 이는 설계 결정이 아니라 PR #71에서 config화할 때 "기존 동작 무변경"을 위해 각 언어의 하드코딩 값을 그대로 기본값으로 삼은 **산물**이었다(같은 위조 kid 폭주에 Ruby가 Python보다 IdP를 6배 자주 때렸다). 30초는 Nimbus `DEFAULT_RATE_LIMIT_MIN_INTERVAL`과 같은 값이라 외부 근거가 있는 유일한 후보다. 새 언어를 추가하거나 이 값을 바꿀 때는 아홉 언어를 함께 움직일 것.
- ⚠️ **(Java·Kotlin) `resteasyClient(...)` 주입은 admin-client의 `JacksonProvider` 등록을 통째로 우회한다** — `NON_NULL`과 `FAIL_ON_UNKNOWN_PROPERTIES=false`를 함께 잃어 버전 스큐에서 양방향으로 깨진다(26.0.11 `UserRepresentation.verifiableCredentials`에서 실제 발현). `buildTimeoutClient`가 프로바이더를 직접 등록한다. 상세: `.claude/rules/java.md`·`.claude/rules/kotlin.md`
- ⚠️ **(Python) python-keycloak sync는 `allow_redirects`를 전달하지 않고, admin 세션이 둘(하나는 지연 생성)이라 바깥만 막으면 client_secret이 샌다.** 상세: `.claude/rules/python.md`
- ⚠️ **(Node) `tsconfig.json`의 `include: ["src"]`라 테스트 파일은 타입체크 안 됨.** 상세: `.claude/rules/node.md`
- ⚠️ **(Node) JWKS rate-limit 회귀는 대조군 없이는 안 잡힌다.** 상세: `.claude/rules/node.md`
- ⚠️ **(CI) `main`은 룰셋 `PRIMARY`가 지킨다 — required 체크에 언어 CI를 넣으면 저장소가 잠긴다**(`paths:` 필터는 체크를 *생성조차* 안 해 Pending 영구 차단, `bypass_actors: []`라 소유자도 못 푼다 — 잡 레벨 `if:` skip과 정반대다). 상세: `.claude/rules/ci.md` · [CONTRIBUTING.md §4](CONTRIBUTING.md)
- ⚠️ **(CI) 태그 룰셋 3종은 active이되 admin bypass가 있다 — 사람이 손으로 미는 경로는 살아 있다.** GitHub App을 `tags-create.json` bypass에 넣는 것이 남아서 `dispatch-release.yml`은 아직 fail-closed다. 상세: `.claude/rules/ci.md`
- ⚠️ **(CI) 배포 시크릿 미설정은 "스킵"이 아니라 실패여야 한다** — 아무것도 게시하지 않고 green으로 끝난 실행은 성공한 실행과 구분되지 않는다(태그·Release는 있는데 레지스트리는 빈 상태). 상세: `.claude/rules/ci.md`
- ⚠️ **(CI) dependabot이 자동으로 올려서는 안 되는 핀 두 종류**(ref 이름이 곧 의미인 액션 · 소비자 하한을 나타내는 버전) — `.github/dependabot.yml`의 `ignore`가 근거와 함께 막는다. 상세: `.claude/rules/ci.md`
- ⚠️ **(CI) Dependabot 트리거 run에는 Actions 시크릿이 노출되지 않는다** — `SONAR_TOKEN`이 빈 문자열이 되어 SonarCloud가 반드시 실패한다(코드 신호 아님). 상세: `.claude/rules/ci.md`
- ⚠️ **(CI) 로컬↔CI 발산**(CRLF 포매터 오탐 · pip-audit editable · jacoco는 `verify` 바인딩이라 `mvn test`로 미검증 등). 상세: `.claude/rules/ci.md`
- ⚠️ **(하네스) 앱/레지스트리 전 컨테이너 Alpine(musl)** — Windows Docker Desktop의 glibc-DNS 게차 회피. 잔여 follow-up도 함께. 상세: `.claude/rules/ci.md`

## 확정 의존성 (BOM으로 고정)

<!-- doc-guard: kind=dep source=java/pom.xml min=5 -->
| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 서버(26.6.4)와 독립 버전 트랙 — "26.6.x admin-client"는 존재하지 않는다 | 26.0.11 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | 표준 OAuth2/OIDC 흐름의 성숙한 레퍼런스 구현(단, 그 자체가 "certified"는 아님 — 완성 제품 인증은 OIDF에 별도로) | 11.38.2 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | `JWKSourceBuilder`가 DoS-safe JWKS 재조회 제공 — 안전한 기본값은 SDK가 얹는다 | 10.9.1 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 실제 Keycloak 26.6 컨테이너로 통합검증(단위 모킹만으론 admin-client 버전 스큐를 못 잡음) | 4.3.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0 모듈명 변경 반영 — JUnit5 확장은 `-junit-jupiter`(구 `junit-jupiter` 아님) | 2.0.5 |
| 단위 테스트 | JUnit 6.1.2 · Mockito 5.23.0 | 표준 JVM 단위테스트 스택 | — |

**Python 확정 의존성(pyproject.toml, major 상한 고정)**:

<!-- doc-guard: kind=dep source=python/pyproject.toml min=2 -->
| 의존성 | 배포명 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin + 인증 | `python-keycloak` | 성숙한 Keycloak 클라이언트. ⚠️ admin 세션이 **둘**이라 SSRF·정리 양쪽에서 함정 — rules | `>=7.1,<8` |
| JWT(강화 검증) | `joserfc` | 보안 핵심이라 major 상한 고정. ⚠️ 기형 JWKS에서 stdlib 예외가 새는 경계 문제는 rules | `>=1.7,<2` |

dev(비앵커): `pytest`·`pytest-asyncio`·`pytest-cov`·`mypy`(strict)·`ruff`(보안 S/bandit 포함)·`testcontainers[keycloak]`. ⚠️ 버전 상수를 매니페스트와 중복하지 말 것 — `__version__`은 `importlib.metadata` 파생이다(경위: `.claude/rules/python.md`).

**Node 확정 의존성(package.json으로 고정)**:

<!-- doc-guard: kind=dep source=node/package.json min=3 -->
| 의존성 | 패키지 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `@keycloak/keycloak-admin-client` | 공식 클라이언트. 원래 `^26`이었는데 26.7.0의 `decodeToken(undefined).split()` 크래시 회귀로 `~26.6.4`까지 좁혔다가(PR #62), PR #63의 provider 배선(`kc.auth()` 미호출)이 그 크래시 경로를 **근본 차단**함이 통합테스트로 실증되어 dependabot PR #48로 전진 | `~26.7.0` |
| 인증(OIDC/OAuth2) | `openid-client` | v6 함수형 API. 선언은 범위이고 해석값은 lockfile이 정한다 | `^6` |
| JWT(강화 검증) | `jose` | 5.10.0에서 전진 — `openid-client`가 이미 `jose ^6.2.2`를 요구하고 있어 이 bump는 트리를 **dedupe**한다. SDK가 쓰는 7개 API/옵션이 v6에서 이름·의미 모두 동일함을 published `.d.ts`로 확인했고, `cooldownDuration` rate-limit이 실제로 살아있음을 히트 수로 실측했다(현재 해석값 6.2.4) | `^6` |

dev(비앵커 — 버전이 셀 안 산문이라 기계 대조 밖): `typescript` 6 · `vitest`/`@vitest/coverage-v8` 3(v4는 `vi.mock` 시맨틱 변경으로 보류) · `testcontainers` 12 · `eslint` 10 + `typescript-eslint` 8 · `prettier` 3 · `@types/node` `^22`(engines 하한과 일치 — dependabot.yml에 메이저 ignore). 런타임 deps는 audit clean, devDeps 일부 moderate(`files:["dist"]`라 소비자 미배포).

**Go 확정 의존성(go.mod, major 핀)**:

<!-- doc-guard: kind=dep source=go/go.mod min=5 -->
| 의존성 | 모듈 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `github.com/Nerzal/gocloak/v13` | Go에서 가장 성숙한 Keycloak admin 클라이언트. ⚠️ 네트워크 실패까지 `*APIError{Code:0}`로 감싸므로 경계에서 `Code==0`↔`>0`으로 나눠야 한다 | `v13.9.0` |
| 인증(OAuth2 흐름) | `golang.org/x/oauth2` | 표준 OAuth2 흐름 — **최소 Go 1.25를 요구하는 쪽이 이것이다**(`go.mod`를 낮춰도 `go mod tidy`가 재상향) | `v0.36.0` |
| JWT(강화 검증) | `github.com/go-jose/go-jose/v4` | ⚠️ `exp` 부재 시 만료검사를 조용히 건너뛰므로 SDK가 `claims.Expiry == nil` 명시 거부를 얹는다 | `v4.1.4` |
| single-flight | `golang.org/x/sync` | `singleflight`로 JWKS 동시 미스를 한 번의 조회로 수렴(`client.go`·`jwt.go`·`tokenprovider.go`) | `v0.22.0` |
| 통합 테스트 | `github.com/testcontainers/testcontainers-go` | base `GenericContainer`로 직접 조립 — 언어별 편의 모듈 `modules/keycloak`는 독립 태그 부재로 미사용 | `v0.43.0` |

전부 Apache-2.0/BSD-3/MIT(호환).

⚠️ **Go에는 dev-dependency 개념이 없다** — `// indirect`는 우리가 고른 것이 아니다(근거·실측: `.claude/rules/go.md`).

**C#/.NET 확정 의존성(csproj, major 핀)**:

<!-- doc-guard: kind=dep source=dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj min=2 -->
| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 인증(OIDC/OAuth2) | `Duende.IdentityModel` | 확장 메서드가 예외를 던지지 않아(`resp.IsError` 검사) 결정적 파사드에 맞음 — PKCE 헬퍼는 없어 SDK가 손수 생성 | 8.1.0 |
| JWT(강화 검증) | `Microsoft.IdentityModel.JsonWebTokens` + `.Protocols.OpenIdConnect` | 기본값이 안전하지 않아 전부 명시 강화. 실패해도 안 던지는 API — rules | 8.22.0 |

| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `Keycloak.AuthServices.Sdk` | net8 최종 버전 — 3.0.0은 net10 전용이라 사용 불가 | **2.7.0** |
| DI 추상화 | `Microsoft.Extensions.DependencyInjection.Abstractions` | AuthServices 2.7.0의 하한(9.0.8) 충족 + net8 유지 정책으로 10.x major는 보류(PR #57 close) | 9.0.18 |
| 단위 테스트 | `xUnit` 2.9.3 · `WireMock.Net` 2.13.0 · `coverlet.collector` 10.0.1 | 표준 .NET 단위테스트+모킹+커버리지 스택(컬렉터만 — msbuild 통합은 히트 flush 유실로 제거, 게차 참고) | — |
| 통합 테스트 | `Testcontainers.Keycloak` | 실제 Keycloak 26.6 컨테이너로 E2E 검증 | 4.13.0 |

전부 Apache-2.0/MIT(호환).

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

전부 MIT/BSD-3(Apache-2.0 호환).

**Rust 확정 의존성(Cargo.toml, 정확 핀 없음 — 크레이트별로 캐럿/틸드 + 커밋된 `Cargo.lock`)**:

<!-- doc-guard: kind=dep source=rust/Cargo.toml min=5 -->
| 의존성 | 크레이트 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `keycloak`(`default-features = false`, features: `tags-all`·`resource-builder`·`reqwest12`) | `reqwest12` feature로 reqwest 0.12 정렬 필수. 틸드 요구인 이유는 rules | `~26.6.2` |
| 인증(OIDC/OAuth2) | `openidconnect`(`default-features = false`, feature: `reqwest`) | `CoreClient`가 6개 엔드포인트 typestate 제네릭 — auth/introspection/token만 `EndpointSet`으로 명시해 무오류 호출 가능 | `4.0.1` |
| JWT(강화 검증) | `jsonwebtoken`(`default-features = false`, features: `rust_crypto`·`use_pem`) | `Validation` 기본값이 안전하지 않아 `validate_nbf`/`leeway`/`required_spec_claims` 전부 재정의 필요 | `11.0.0` |
| HTTP | `reqwest`(`default-features = false`, features: `json`·`rustls-tls`) | `keycloak` crate·`openidconnect`가 공유하는 단일 HTTP 클라이언트(SSRF 하드닝을 위해 `redirect::Policy::none()` 적용) | `0.12` |
| 비동기 런타임 | `tokio`(features: `rt-multi-thread`·`macros`·`time`·`sync`) | `openidconnect`·`keycloak` crate 양쪽이 요구하는 비동기 런타임 | `1.52` |

| 의존성 | 크레이트 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 오류/직렬화 | thiserror 2.0 · async-trait 0.1 · serde+serde_json 1 · url 2 | 표준 에러 계급·직렬화·URL 유틸 | — |
| 단위 테스트 | wiremock 0.6(HTTP 목) · rsa 0.9+rand 0.8+base64 0.23(JWKS 공격 프로브 픽스처 생성) | HTTP 목 + 공격 프로브용 테스트 키 생성(RUSTSEC-2023-0071은 서명검증 전용인 런타임에 무영향) | — |
| 통합 테스트 | testcontainers 0.27.3(pre-1.0, base `GenericImage` — 언어별 편의 모듈 없음) | pre-1.0이라 Keycloak 전용 편의 모듈이 없어 `GenericImage`로 직접 조립 | — |

전부 Apache-2.0/MIT(호환). ⚠️ **셋 다 정확 핀(`=`)이 아니다** — `openidconnect`/`jsonwebtoken`은 캐럿, `keycloak`은 틸드 `~26.6.2`(버전이 semver가 아니라 Keycloak 서버 라인을 추종). 라이브러리에서 정확 핀이 왜 소비자 빌드를 하드 실패시키는지, 커밋된 `Cargo.lock`이 소비자에게 왜 닿지 않는지는 `.claude/rules/rust.md`.

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

전부 MIT(Apache-2.0 호환). ⚠️ admin gem 후보 3종(`looorent/keycloak-admin` 등)은 **공유 `TokenProvider` 주입 미지원**(§4 캐시 불변식 위반)으로 기각했다 — 그래서 `faraday` 직접 래핑이다(상세: `.claude/rules/ruby.md`).

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

전부 Apache-2.0/EPL-2.0(호환). Admin·인증·JWT 3좌표는 Java SDK가 실 Keycloak으로 이미 검증한 것과 동일해 **신규 라이브러리 리스크 0** — 차이는 코루틴 래핑뿐이다.

⚠️ 위 표의 `Kotlin 2.4.10`은 **빌드 툴체인(KGP) 버전**이지 소비자 하한이 아니다 — 게시 jar의 메타데이터는 `languageVersion`/`apiVersion`(=`KOTLIN_2_2`)이 정하므로 **소비자 하한은 2.2+**다(전이 `kotlin-stdlib`까지 함께 내려야 하는 이유는 `.claude/rules/kotlin.md`).

## 문서 유지 규칙

작업 완료(머지/main 반영) 후 프로젝트 전체 문서(`CLAUDE.md`, `docs/`, `README.md`)를 최신화·최적화하고 커밋한다. 언어별 빌드/테스트 명령(단일 테스트 실행 포함)을 툴체인 섹션에 유지한다(Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin).

**`scripts/check-docs.mjs`(문서-소스 드리프트 가드)의 의존성 앵커 스코프는 이제 9개 언어 전부다** — `<!-- doc-guard: ... -->` 앵커가 Java·Python·Node·Go·.NET·PHP·Rust·Ruby·Kotlin 의존성 표 9종(pom.xml/**pyproject.toml**/package.json/**go.mod**/csproj/composer.json/Cargo.toml/gemspec/build.gradle.kts)과 .NET 최소 런타임 선언 1건, 합쳐 **38 facts / 10 anchors**를 기계 검증한다. **최소 런타임 선언도 9개 언어 전부 앵커가 걸렸다** — [docs/guides/getting-started.md](docs/guides/getting-started.md)의 언어별 "Required runtime" 문장에 `kind=runtime` 앵커가 있다. 합쳐 **46 facts / 18 anchors**다.

⚠️ **런타임 앵커는 "앵커 뒤 3줄 안의 *첫* 백틱 스팬 중 숫자를 포함한 것"을 문서의 주장으로 읽는다** — 그래서 버전보다 먼저 오는 백틱 토큰에 숫자가 있으면 그걸 주장으로 오인한다. 실제로 걸렸던 둘: Java의 `` `--release 21` ``과 Go의 `` `golang.org/x/oauth2` ``(둘 다 숫자를 품는다). 두 절은 버전을 문장 앞으로 옮겨 해결했다. ⚠️ **Kotlin 앵커는 `jvmToolchain(21)`, 즉 JDK 툴체인을 검증한다 — Kotlin 언어 버전(2.2)이 아니다.** 그래서 그 절은 JDK 절을 먼저 두고 그 사실을 본문에 명시했다. 이걸 모르고 "Kotlin 버전을 가리키도록 고치면" 앵커가 21 vs 2.2로 깨진다.

표의 dev/도구 의존성 절은 버전이 셀 안 산문에 있어 구조적으로 스코프 밖이다.

⚠️ **앵커를 추가하면 `.github/workflows/repo-hygiene.yml`의 `--min-facts`/`--min-anchors`도 함께 올려야 한다.** 그 하한은 "앵커 주석만 지우고 표를 남기는" 자기기만을 막는 장치인데, 한때 `14/4`에 머물러 있고 실측은 이미 `28/7`이라 **앵커 절반이 사라져도 CI가 통과하는** 상태였다.

✅ **버전 *제약 연산자* 사각지대는 닫혔다(2026-08-04).** 예전에는 `normalizeVersion()`이 비교 전에 선행 `=`/`^`/`~`/`>=`/`~>`를 떼어내 `=26.6.2`와 `26.6.2`를 같은 값으로 판정했고, Rust 3개 크레이트를 정확 핀에서 캐럿/틸드로 바꾼 변경에서 문서가 여전히 `=`를 주장하는데도 `doc-facts`가 통과한 실제 사례가 있었다 — **핀 방식 변경은 구조적으로 보이지 않는 드리프트**였다. 지금은 의존성 표(`kind=dep`)만 `normalizeRequirement()`로 **연산자까지 포함해** 대조한다. 최소 런타임(`kind=runtime`)은 그대로 연산자를 벗긴다 — 거기서는 `>=22`와 문서 관용 `22+`가 같은 말이라 연산자가 포맷이지만, 의존성에서는 `=`·`~`·`^`가 소비자에게 서로 다른 계약이라 값 자체이기 때문이다. ⚠️ **따라서 표 셀은 빌드 파일이 쓴 대로 적는다.** cargo에서 맨 `"4.0.1"`과 `"^4.0.1"`은 의미가 같지만 가드는 문자로 대조하므로, 매니페스트에 `^`를 명시하면 표도 함께 고쳐야 한다(npm은 맨 `22`와 `^22`가 실제로 다른 의미라 이 엄격함이 오히려 옳다). 전환 시 실측: 오탐 0건, 진짜 드리프트 1건(`keycloak` 셀이 `26.6.2`인데 `Cargo.toml`은 `~26.6.2`)만 잡혀 그 자리에서 고쳤다.

### 문서 언어 규칙 (bilingual README + 영문 사용자 문서, PR #31·#32)

- **README는 영문 기본 + 한글 미러**: [`README.md`](README.md)(영문, 기본)와 [`README.ko.md`](README.ko.md)(한글)는 **동일 구조의 미러**다 — 한쪽을 고치면 다른 쪽도 함께 갱신해 동기 유지(상단 상호 링크 `English ↔ 한국어`). 둘 다 슬림 랜딩(정적 배지·9언어 표·30초 퀵스타트·보안·상태·링크)이며, 게시가 언어별로 진행 중인 전환기(human-gated, 9개 중 4개만 첫 RC 게시)이므로 **라이브 레지스트리 배지 금지**(정적 배지만 — 오해 방지).
- **사용자 대상 문서는 영문(in-place)**: [`docs/guides/`](docs/guides/) 3종 · [`docs/roadmap/language-support.md`](docs/roadmap/language-support.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`DEPLOY.md`](DEPLOY.md) · [`harness/README.md`](harness/README.md) · [`harness/install/README.md`](harness/install/README.md)는 영문으로 유지·갱신한다(한글 미러 없음).
- **내부 산출물은 한글 유지**: [`docs/superpowers/`](docs/superpowers/)(설계 스펙·WBS 플랜)·[`docs/governance/`](docs/governance/)(검증 로그)와 이 `CLAUDE.md`는 개발/거버넌스 내부 문서로 한글을 유지한다.
- **앵커 주의**: 영문 문서에서 헤딩을 바꾸면 `#anchor`가 바뀐다. `getting-started.md`의 `## C# / .NET`(앵커 `#c--net`)은 양쪽 README가 링크하므로 **헤딩 텍스트를 바꾸지 말 것**.
