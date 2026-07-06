# 언어 지원 로드맵 (Language Support Roadmap)

이 문서는 Keycloak 폴리글랏 SDK의 **언어 확장 전략과 우선순위**를 정의한다. 현재 지원 언어는 **Java**·**Python**·**TypeScript/Node**·**Go**·**C#/.NET**·**PHP**·**Rust** 일곱 가지이며, 일곱 언어 모두 설계·구현·단위·통합·CI가 완료되고 실배포만 사람 게이트로 남아 있다. 이 로드맵은 (1) 언어 확장의 원칙, (2) 기존 SDK를 실제로 배포하기 위한 사전 단계(step-0), (3) 다음 확장 언어의 우선순위와 후보 클라이언트, (4) 언어별 현황 매트릭스를 정리한다.

"다국어(polyglot)"는 **여러 프로그래밍 언어**를 뜻하며 자연어 현지화(i18n)와 무관하다.

## 전략

- **깊이 우선(depth-first).** 언어를 넓게 벌리기보다, 착수한 언어를 **Java/Python과 동일한 품질**까지 완성한 뒤 다음 언어로 넘어간다. 코드 생성(codegen)으로 찍어낸 저품질 티어를 만들지 않는다 — 모든 언어는 손수 설계·검증한다(단위+통합 테스트, CI, 하드닝된 JWT 검증 포함).
- **동형(isomorphic) 설계.** 언어마다 관용적이되 개념·계층·흐름은 동형이다. 언어 중립 API 계약을 **진실 원천**으로 두고 각 언어가 구현한다 — [설계 스펙 §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) 참조. camelCase ↔ snake_case 같은 관용 차이만 허용하고 개념·명명·계층은 일치시킨다.
- **최선의 기반을 감싼다 + JWT는 자체 강화.** 언어마다 가장 성숙한 인증(OIDC/OAuth2)·관리(Admin REST) 클라이언트를 파사드 뒤에 감싸되, **JWT 검증만은 어느 언어에서도 라이브러리 기본값을 신뢰하지 않고** 자체 강화 계층을 얹는다: 알고리즘 핀닝, `none`/미서명 거부, `iss` 정확일치, `aud` 포함검사, 클록 스큐 제한, DoS-안전 JWKS 재조회(CVE-2026-11800 계열 대응).
- **결합 규칙 유지.** `admin`은 `auth`를 직접 알지 못하고, 둘은 공유 `TokenProvider`(언어별 인터페이스/trait)로만 이어진다 — 하위 라이브러리 교체가 소비자에게 파급되지 않게 한다.
- **예외 경계 변환.** 하위 라이브러리의 예외/에러 타입은 항상 파사드 경계에서 SDK 예외 타입으로 변환되어 공개 API로 새지 않는다(문서화된 은닉성 예외는 설계 스펙 §4 참조).

## step-0 — 기존 SDK 실배포 (사람 게이트)

새 언어로 확장하기 전, **이미 완성된 Java·Python SDK를 실제로 배포**하는 것이 최우선 로드맵 항목이다. 두 SDK는 현재 `0.1.0-SNAPSHOT`(미배포)이며, 배포는 되돌릴 수 없으므로(같은 좌표/버전 재배포 불가) 반드시 dry-run으로 산출물을 먼저 검증한다. 전체 절차는 [DEPLOY.md](../../DEPLOY.md)를 따른다.

> **로컬 설치(미배포 상태)**: 두 SDK 모두 아직 퍼블릭 레지스트리에 없으므로 `pip install keycloak-sdk`/Maven Central 좌표 해석은 **아직 동작하지 않는다**. 로컬 검증은 다음으로 한다 — Java: `mvn -f java/pom.xml install -DskipITs=true`(Docker 불필요 · → 좌표 `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT`), Python: `pip install -e python`(또는 `cd python && python -m build`, 배포명 `keycloak-sdk`).

### Java → Maven Central (`v*` 태그 → `.github/workflows/release.yml`)

- [ ] **네임스페이스 검증(1회)**: [central.sonatype.com](https://central.sonatype.com)에 GitHub 계정(`xzawed`)으로 로그인 → `io.github.xzawed` 네임스페이스 검증/프로비저닝.
- [ ] **Central Portal 토큰 발급(1회)**: Account → Generate User Token → username/password 확보.
- [ ] **GPG 서명키(1회)**: `gpg --gen-key` 생성 → 키서버에 공개키 배포(`--send-keys`) → 개인키 armored 내보내기(`private.asc`).
- [ ] **GitHub Secrets 4종 등록**: `MAVEN_GPG_PRIVATE_KEY`, `MAVEN_GPG_PASSPHRASE`, `CENTRAL_TOKEN_USER`, `CENTRAL_TOKEN_PW`. (미설정 시 워크플로는 deploy 스텝에서 인증 실패로 종료.)
- [ ] **로컬 사전 검증(서명·배포 없이)**:
  ```bash
  mvn -f java/pom.xml -Prelease -DskipTests -Dgpg.skip=true package
  # → core/auth/admin/keycloak-sdk 각 target/에 *-sources.jar / *-javadoc.jar 생성 확인
  ```
- [ ] **배포 트리거**: `git tag v0.1.0 && git push origin v0.1.0` → `release.yml`이 **태그값으로 버전 set(`-SNAPSHOT` 제거)** 후 `-Prelease deploy` 실행 → Central Portal Deployments에서 Publish. (main POM은 계속 `-SNAPSHOT`; **태그가 릴리스 버전을 결정** — Central은 SNAPSHOT을 거부하므로 이 자동 치환이 필수.)

### Python → PyPI (`py-v*` 태그 → `.github/workflows/python-release.yml`)

- [ ] **Trusted Publisher 설정(1회, 시크릿 불필요)**: [pypi.org Publishing](https://pypi.org/manage/account/publishing/)에서 **Pending Publisher로 반드시 미리 등록**(`keycloak-sdk`가 아직 PyPI에 없으므로 계정 레벨 "Add a pending publisher") — Owner `xzawed` · Repo `KeyCloakSDK` · Workflow `python-release.yml` · Environment 비움. OIDC 인증이라 저장 토큰이 없다.
- [ ] **로컬 사전 검증(업로드 없이)**:
  ```bash
  cd python && python -m build
  # → dist/keycloak_sdk-0.1.0-py3-none-any.whl + .tar.gz 생성 확인
  ```
- [ ] **배포 트리거**: `git tag py-v0.1.0 && git push origin py-v0.1.0` → `python-release.yml`이 verify(ruff·mypy·pytest) 통과 후 build + publish 실행.

> ⚠️ 버전을 올릴 때는 Java `java/pom.xml`(및 모듈) `<version>`, Python `python/pyproject.toml` `[project].version`을 함께 올리고 태그(`v*`/`py-v*`)를 그에 맞춘다. SemVer는 SDK 자체 API 기준이며 Keycloak/의존 라이브러리 버전과 분리한다.

## 확장 우선순위

**선정 기준**: 생태계 수요 × 성숙한 클라이언트 가용성(활발히 유지되고 라이선스가 Apache-2.0 호환). 아래 각 언어의 auth·admin 클라이언트는 **확정이 아니라 후보이며, 착수 시 딥리서치로 유지보수·인증(OIDF 등)·라이선스를 재검증해 확정한다**([설계 스펙 §6.3·§10](../superpowers/specs/2026-07-03-keycloak-docs-and-language-expansion-design.md)). 모든 경우 JWT 검증은 자체 강화 계층으로 얹는다(라이브러리 기본값 미신뢰).

> ⚠️ **후보 · 시점 스냅샷 주의.** 아래 표의 버전 핀(예: `openid-client` v6, `gocloak` v14, `fschmtt` 0.42.x), MSRV 수치, 툴체인/서버 대상 버전, 아카이브 날짜, OIDF 인증 여부, 유지보수 상태, CVE 언급은 **모두 이 문서 작성 시점의 예시(illustrative-as-of-drafting)**이며 저장소에서 검증되지 않는다. 각 언어 사이클 착수 시점에 딥리서치로 **반드시 재검증**한 뒤 확정한다 — 그 사이 최신 버전/유지보수/인증 상태가 바뀔 수 있다. 이 표는 방향성(어떤 계열의 클라이언트를 후보로 두는지)만 고정하고, 하드 넘버는 확정 사실로 인용하지 않는다.

| 순위 | 언어 | auth 클라이언트 후보 (감쌈) | admin 클라이언트 후보 (감쌈) | 유지보수 / 라이선스 · 주의점 (착수 시 재검증) |
|---|---|---|---|---|
| ✅ 완료 | **TypeScript / Node.js** | `openid-client`(panva) **6.8.4** 함수형 API + `jose` **5.10.0** 강화 검증 | `@keycloak/keycloak-admin-client`(공식) **26.6.4** | **구현 완료(총 76 테스트, 현황 매트릭스 참조).** 확정 사실(딥리서치·구현 검증): `openid-client` v6는 함수형 API·ESM·Node 20+·`Configuration.timeout`(초) 내장·`allowInsecureRequests`(http 로컬용); `jose` `createRemoteJWKSet`가 쿨다운으로 DoS-safe JWKS 재조회 제공. admin-client는 서버 버전 npm 트랙 추종(26.6.4), `findOne`이 404에서 `null` 반환(선언 타입 `undefined`)이라 경계에서 NotFound로 변환. `keycloak-connect`(구 어댑터)·`keycloak-js`/`oidc-client-ts`(브라우저)는 서버 파사드에 부적합 → 미사용. |
| ✅ 완료 | **Go** | `golang.org/x/oauth2` **v0.36** + `go-jose/v4` **v4.1.4** 자체 강화 | `Nerzal/gocloak/v13` **v13.9** | **구현 완료(총 41 테스트, 현황 매트릭스 참조).** 확정 사실(딥리서치·구현 검증): `go-oidc`는 **제외**(discovery는 규약 URL 조립, verifier는 go-jose로 자체 강화 → 불필요). `x/oauth2`가 client-credentials/authorization-code+PKCE(`GenerateVerifier`/`S256ChallengeOption`)/refresh 제공, introspect/logout은 수동 POST. `go-jose/v4`의 `jwt.ParseSigned(allowedAlgs)`로 alg 핀·`none` 거부, `Expected.AnyAudience`로 다중 aud 포함검사; DoS-safe JWKS 캐시(single-flight + 강제 재조회 rate-limit)는 자체 구현. `gocloak.APIError`는 네트워크 실패도 `Code:0`으로 감싸므로 경계에서 `Code==0`→`TransportError`, `>0`→`AdminError`로 변환. representation(`gocloak.User` 등) 노출은 문서화된 은닉성 예외. **최소 Go는 1.25**(x/oauth2 v0.36 요구). |
| ✅ 완료 | **C# / .NET** | `Duende.IdentityModel` **8.1.0** + `Microsoft.IdentityModel.JsonWebTokens`+`.Protocols.OpenIdConnect` **8.19.1** 자체 강화 검증 | `Keycloak.AuthServices.Sdk` **2.7.0**(net8 최종 — 3.0.0은 net10 전용) | **구현 완료(총 59 테스트, 현황 매트릭스 참조).** 확정 사실(딥리서치·구현 검증): `Keycloak.AuthServices.Sdk` 2.7.0 타입드 클라이언트는 users/groups/realm-get만 커버(`IKeycloakUserClient`/`IKeycloakGroupClient`/`IKeycloakRealmClient`) — clients/roles/realm-CRUD는 같은 bearer-authed `HttpClient`로 raw Admin REST(representation 재사용). `JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 예외를 던지지 않아 `IsValid` 검사가 필수, `ValidAlgorithms`(기본 null=모든 알고리즘 허용)를 `["RS256"]`로 핀·`RequireExpirationTime=true`로 exp 필수·JWKS는 `TokenValidationParameters.ConfigurationManager`의 `RefreshInterval`로 DoS 스로틀. Duende 확장 메서드는 예외를 던지지 않아 `resp.IsError` 검사(Keycloak은 잘못된 client 자격증명에 401을 반환, OAuth 코드는 응답 바디의 `error` 필드에서 읽음). `record` 자동 `ToString()`이 전체 프로퍼티를 출력하므로 `TokenSet`/`KeycloakConfig`는 `ToString()` override + `JsonConverter<T>` 둘 다로 마스킹. 구 `IdentityModel*`(비-Duende) 리포는 아카이브 방향이라 미사용. |
| ✅ 완료 | **PHP** | `league/oauth2-client` **^2.8** + `stevenmaguire/oauth2-keycloak` **^6.1** 래핑(PKCE S256 오버라이드) + `firebase/php-jwt` **^7.1** 자체 강화 검증 | `fschmtt/keycloak-rest-api-client-php` **0.42.0**(정확 핀) | **구현 완료(총 67 테스트, 현황 매트릭스 참조).** 확정 사실(딥리서치·구현 검증): 후보였던 `jumbojett/openid-connect-php`는 세션 슈퍼글로벌·`header()` 리다이렉트를 자체 소유해 결정적 파사드와 상충 + JWT 검증 이력 우려로 **채택하지 않고 league+stevenmaguire로 확정**. `stevenmaguire`의 `pkceMethod` 생성자 옵션은 no-op(내부에서 재계산돼 무시) → `PkceKeycloakProvider::getPkceMethod()` 오버라이드로 S256 강제. `firebase/php-jwt`는 `&$headers` out-파라미터가 성공 디코드 후에만 채워지므로 alg 핀은 첫 세그먼트 자체 디코드로 사전 게이트, 내장 `CachedKeySet`은 rate-limit 버그(#543)로 미사용(자체 `JwksStore`). `fschmtt`는 `Users::create()`가 void 반환(id는 `search()` 후속 조회), `Clients`/`Realms`는 `create`가 아니라 `import`(대상에 id/realm 사전 세팅 필요), Guzzle 예외를 변환하지 않아 경계에서 전부 흡수(base `RequestException`까지). JWKS rate-limit은 per-instance 메모리 상태 — 장수명 워커(Swoole/RoadRunner)에서만 요청간 유효, 클래식 per-request PHP-FPM은 요청 내로 한정(배포모델 의존 한계, 정직히 문서화). 6번째 언어로 선행 5개 SDK의 게차가 선반영되어 통합테스트 신규 버그 0건. |
| ✅ 완료 | **Rust** | `openidconnect`(ramosbugs) **=4.0.1** 수동 EndpointSet typestate + `jsonwebtoken` **=10.4.0** 자체 강화 | `keycloak` crate(kilork) **=26.6.2**(`reqwest12` feature) | **구현 완료(총 33 테스트, 현황 매트릭스 참조).** 확정 사실(딥리서치·구현 검증): `openidconnect` 4.0.1은 6개 엔드포인트 typestate 파라미터를 갖는 `CoreClient` 제네릭이라 auth/introspection/token만 `EndpointSet`으로 명시해 `?` 없이 exchange 빌더를 호출 가능한 구체 타입으로 좁힌다(id_token은 openidconnect 자체 검증기 대신 자체 `JwtValidator`가 access_token을 강화 검증하므로 JWKS는 비워 둔다). `keycloak` crate는 `reqwest12` feature로 reqwest 0.12 라인에 정렬해야 `openidconnect`(reqwest 0.12 고정)와 의존성이 맞는다 — 전역 reqwest 0.12 통일이 스캐폴딩 단계의 확정 사항. `jsonwebtoken`은 기본값이 안전하지 않아(`validate_nbf` 기본 false, `leeway` 기본 60초) 자체로 `validate_nbf=true`·`leeway=30`·`required_spec_claims=["exp","iss","aud"]`로 강화. DoS-safe JWKS(`JwksStore`)는 자체 구현(kid 캐시·미해결만 재조회·rate-limit을 재조회 *결정 시점*에 stamp — Go/Python 동형). `admin`↔`auth`는 `TokenProvider` trait(async, `#[async_trait]`)로만 접착, `keycloak::KeycloakError`는 경계(`map_admin`)에서 SDK `KeycloakError`로 변환. representation struct(`keycloak::types::*`) 노출은 Java/Go/C#/PHP와 동일한 문서화된 은닉성 예외. RUSTSEC-2023-0071(rsa Marvin, dev-dependency `rsa`는 테스트 키 생성 전용)은 개인키 복호화 사이드채널이라 우리 공개키 서명검증 전용 사용에는 무영향. |
| 6 | **Ruby** | `openid_connect` gem(nov, 인증 RP 코어) + 자체 강화 JWT 계층 | `keycloak-admin`(looorent) | 작성 시점 활발 · 모두 MIT(Apache-2.0 호환). `openid_connect`는 OIDF 인증 RP 레퍼런스의 기반. ⚠️ OmniAuth 전략(`omniauth_openid_connect`)보다 **raw `openid_connect` gem을 코어로 감싼다** — 후자는 Rack 미들웨어(Rails 지향)·저속 릴리스, 전자는 discovery/JWKS/token 프리미티브 제공. Rails 소비자용으로 `omniauth_openid_connect` 어댑터는 선택 제공. `keycloak-admin`은 gem 버전만 배포(representation 필드는 서버 변화 추종, 최근 KC의 writable 프로필 속성 전달 요구 등) — 핀 + 실서버 검증. |

> **Kotlin(선택)**: 신규 클라이언트 없이 **JVM(Java) SDK 재사용**으로 관용적 Kotlin 표면을 얹을 수 있어, 별도 순위가 아닌 저비용 옵션으로 둔다.

## 현황 매트릭스

| 언어 | 설계 | 구현 | 단위 | 통합 | CI | 배포 |
|---|---|---|---|---|---|---|
| **Java** | ✅ | ✅ | ✅ (117) | ✅ (6, Testcontainers) | ✅ | 🔒 사람 게이트 (총 123) |
| **Python** | ✅ | ✅ (+ `aio` async 미러) | ✅ (224) | ✅ (11, Testcontainers) | ✅ | 🔒 사람 게이트 (총 235) |
| **TypeScript / Node.js** | ✅ | ✅ (ESM · async-only) | ✅ (71) | ✅ (5, Testcontainers) | ✅ | 🔒 사람 게이트 (총 76) |
| **Go** | ✅ | ✅ (sync + `context.Context`) | ✅ (40) | ✅ (1 E2E, Testcontainers) | ✅ | 🔒 사람 게이트 (총 41) |
| **C# / .NET** | ✅ | ✅ (async-first `Task<T>`+`CancellationToken`) | ✅ (58) | ✅ (1 E2E, Testcontainers) | ✅ | 🔒 사람 게이트 (총 59) |
| **PHP** | ✅ | ✅ (`readonly class` · 예외 기반) | ✅ (64) | ✅ (3, docker CLI 셸아웃 — 실제 Keycloak 26.6) | ✅ | 🔒 사람 게이트 (총 67) |
| **Rust** | ✅ | ✅ (edition 2024 · async-only) | ✅ (32) | ✅ (1 E2E, Testcontainers) | ✅ | 🔒 사람 게이트 (총 33) |
| **Ruby** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |

**범례**: ✅ 완료 · 🔒 준비됨·사람 게이트(태그 push 대기) · 계획 미착수. Java 총 123개(단위 117 + 통합 6), Python 총 235개(단위 224 + 통합 11), Node 총 76개(단위 71 + 통합 5), Go 총 41개(단위 40 + 통합 1 E2E), C#/.NET 총 59개(단위 58 + 통합 1 E2E `Full_flow`), PHP 총 67개(단위 64 + 통합 3 `FullFlowIT`), Rust 총 33개(단위 32 + 통합 1 E2E `full_flow`)는 실측 기준이다. Java/Python/Node/Go/C#/Rust는 실제 Keycloak 26.6(.4)에 대한 Testcontainers 통합테스트를 포함하고, **PHP만 docker CLI 셸아웃 폴백**(Windows native PHP가 testcontainers-php의 `unix://` 소켓 트랜스포트를 지원하지 않아 `docker run`을 직접 구동 — CI의 ubuntu 러너에서는 동일하게 동작)으로 동일한 실제 Keycloak 26.6을 검증한다. 신규 언어는 착수 시 동일한 6개 열을 모두 채운 뒤에만 "완료"로 간주한다(depth-first). Node 배포는 `node-v*` 태그 → `.github/workflows/node-release.yml`(npm Trusted Publishing / OIDC + provenance, human-gated)로 트리거된다. **Go 배포는 레지스트리 없이 `go/v*` 태그 자체가 릴리스**(`proxy.golang.org` 자동 캐시) → `.github/workflows/go-release.yml`(검증 + GitHub Release + 프록시 워밍, human-gated). C#/.NET 배포는 `dotnet-v*` 태그 → `.github/workflows/dotnet-release.yml`(NuGet, `NUGET_API_KEY` 시크릿 필요, human-gated). **PHP 배포는 레지스트리 업로드가 아니라 Packagist가 GitHub 웹훅으로 태그를 감지해 자동 게시**(`php-v*` 태그 → `.github/workflows/php-release.yml`, 저장 시크릿 없음, Packagist에 `xzawed/keycloak-sdk` 저장소 등록은 1회 수동 선행, human-gated). Rust 배포는 `rust-v*` 태그 → `.github/workflows/rust-release.yml`(`cargo publish`, `CARGO_REGISTRY_TOKEN` 시크릿 필요, human-gated).

이 매트릭스와 별개로, 5개 언어 SDK가 동일 HTTP 계약으로 실제 Keycloak에 대해 동형 동작하는지 k6 가상사용자 부하로 실측 비교·검증하는 하네스([`harness/`](../../harness/README.md), CI: [`.github/workflows/harness.yml`](../../.github/workflows/harness.yml))가 별도로 있다 — **5개 언어(Go/C#/Node/Python/Java) 샘플 앱이 모두 완료**됐다(`./run.sh go dotnet node python java`로 기능 정확성(checks==1.00)을 강제하고 언어간 성능 실측 비교표를 산출; 각 앱은 net/http·ASP.NET Core·Express 5·FastAPI·Spring Boot 관용 프레임워크로 SDK를 소비한다). CI(harness.yml)는 안 A — PR/푸시엔 빠른 Go 스모크 게이트, 야간(schedule)·수동(workflow_dispatch)엔 5개 언어 전체 비교를 실행한다.
