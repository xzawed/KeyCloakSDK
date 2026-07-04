# 검증 로그 — C#/.NET SDK

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 C#/.NET SDK(`Xzawed.Keycloak.Sdk`) 태스크별 정량 검증 기록. 브랜치 `feature/dotnet-sdk`.

**툴체인**: 시스템 설치 `C:\Program Files\dotnet`(SDK 10.0.102, **net8.0 런타임 8.0.23 네이티브 존재** — 포터블 설치 불필요, Go/Java와 차이). 명령은 `dotnet/`에서: `dotnet build|test --filter "Category!=Integration"|test --filter "Category=Integration"|format Keycloak.Sdk.sln --verify-no-changes`.

**게이트**: G1 빌드/format(`dotnet build` warnaserror·`dotnet format --verify-no-changes`) · G2 단위테스트(xUnit) · G3 커버리지(`coverlet.msbuild`, 로직 모듈 라인≥90/브랜치≥85; 네트워크 경계 `[*]Xzawed.Keycloak.AuthClient`/`[*]Xzawed.Keycloak.Admin.*`/`[*]Xzawed.Keycloak.KeycloakClient` omit) · G4 스펙리뷰 · G5 교차검증(다중에이전트 어드버서리얼) · G6 보안.

> **실행 방식**: 승인된 WBS → Workflow 오케스트레이션 + G1~G6 + Loops + 딥리서치. 각 태스크 TDD·계층별 커밋. Go/Node와 달리 이번 사이클은 **착수 전 WBS 계획 자체**에 5-렌즈 + 1건의 실제 컴파일 검증을 포함한 다중에이전트 어드버서리얼 리뷰를 수행해 대다수 결함을 구현 전에 흡수했고(G5, 아래), 실제 코딩 중 발견된 잔여 결함은 태스크별 소규모 리뷰 루프로 그때그때 조치했다(Loops).

---

## 딥리서치 (착수 전) — 라이브러리 API 확정

git tag·소스·MS Learn으로 현행 버전·시그니처·라이선스를 확인해 아래를 **확정**(설계 스펙 §3, 구현 중 재확인 불필요):

- **Duende.IdentityModel `8.1.0`**(Apache-2.0): 순수 OAuth2/OIDC 프로토콜 라이브러리(무료, 상용 IdentityServer와 별개). `HttpClient` 확장 — `RequestClientCredentialsTokenAsync`/`RequestAuthorizationCodeTokenAsync`/`RequestRefreshTokenAsync`/`IntrospectTokenAsync`. **모든 확장 메서드가 예외를 던지지 않음**(`resp.IsError` 검사 필요). PKCE 공개 헬퍼 없음(수동 생성), back-channel logout 헬퍼 없음(수동 POST). Keycloak은 잘못된 client 자격증명에 **401**(→`ErrorType=Http`, OAuth 에러 코드는 `resp.Json["error"]`에서 읽음).
- **Microsoft.IdentityModel.JsonWebTokens + .Protocols.OpenIdConnect `8.19.1`**(MIT): `JsonWebTokenHandler.ValidateTokenAsync` → `Task<TokenValidationResult>`(**실패해도 throw 안 함** → `result.IsValid`/`result.Exception` 검사 필수). `ValidAlgorithms` 기본 `null`=모든 알고리즘 허용(→`["RS256"]`로 반드시 핀). `ClockSkew` 기본 5분(→30s로 축소). `RequireExpirationTime=true`로 exp 필수(다른 4개 언어 동형). JWKS는 `TokenValidationParameters.ConfigurationManager`(내장 캐시 + `RefreshInterval`=DoS 스로틀). `HttpDocumentRetriever.RequireHttps` 기본 true(http 이슈어만 완화). `MapInboundClaims=false`(원시 클레임명 유지).
- **Keycloak.AuthServices.Sdk `2.7.0`**(MIT): **⚠️ 3.0.0은 net10.0 전용 → net8.0에서 복원 가능한 최종 빌드는 2.7.0**(API 동일 — 같은 네임스페이스·`KeycloakClient(HttpClient)` ctor·`KeycloakHttpClientException{int StatusCode}`). 타입드 인터페이스는 **users/groups/realm-get 3종만**(`IKeycloakUserClient`/`IKeycloakGroupClient`/`IKeycloakRealmClient`) — clients/roles/realm-CRUD는 같은 bearer-authed `HttpClient`로 raw Admin REST(`Models.*Representation` 재사용). 편의 `…Async`는 default interface method(변수를 `IKeycloakClient`로 타입해야 호출 가능). `CreateUserAsync`는 `void`(id 없음 → `CreateUserWithResponseAsync` + `Location` 헤더 파싱). 단일 유지보수자(NikiforovAll) — 키맨 리스크, 버전 핀 유지가 완화책.
- **Microsoft.Extensions.DependencyInjection.Abstractions `9.0.8`**(MIT): `AddKeycloak` DI 확장의 요구 하한 — `Keycloak.AuthServices.Sdk` 2.7.0이 이 버전 이상을 요구(낮추면 NU1605 downgrade → `TreatWarningsAsErrors` 하드오류). `IHttpClientFactory`는 미채택(단일 장수명 `HttpClient` + `SocketsHttpHandler.PooledConnectionLifetime`이 단일서버 SDK에 더 적합 — 리뷰 확정).
- **Testcontainers.Keycloak `4.13.0`**(MIT): 공식 .NET Testcontainers Keycloak 모듈. `new KeycloakBuilder("quay.io/keycloak/keycloak:26.6")`(명시 이미지 필수 — 기본 21.1은 obsolete) + `.WithResourceMapping(realm.json, "/opt/keycloak/data/import/")` + `.WithCommand("--import-realm")`. Java/Python/Node/Go의 `it-realm-realm.json` 재사용.

## 계층별 구현 (Task 1~11)

각 태스크 TDD(실패 테스트 → 구현 → 통과) 후 계층별 커밋. G1(build/format)·G2(test)·G3(커버) 각 태스크 통과.

| Task | 커밋 | 내용 | G1 | G2 | G3 |
|---|---|---|---|---|---|
| 1 | `2d52e69` | 스캐폴딩(솔루션·src/tests 프로젝트·Directory.Build.props·의존성 핀) | ✅ | ✅ | — |
| 2 | `cb0e300` | Masking + 예외 계급(경계 변환·`MapHttpError`) | ✅ | ✅ | ✅ |
| 3 | `04dfc7e` | `KeycloakConfig`(검증·정규화·`ToString` 마스킹) + 값 타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest`) | ✅ | ✅ | ✅ |
| 4 | `8136bff` | `ITokenProvider`/`ITokenSource` + `ClientCredentialsTokenProvider`(SemaphoreSlim single-flight) | ✅ | ✅ | ✅ |
| 5 | `9b94869` | OIDC 엔드포인트 조립(네트워크 없음) | ✅ | ✅ | ✅ |
| 6 | `aa9b50d` | `JwtValidator`(Microsoft.IdentityModel 강화 + DoS-safe JWKS) | ✅ | ✅ | ✅ |
| 7 | `b704719` | `AuthClient`(Duende.IdentityModel 래핑 + PKCE·nonce fail-closed) | ✅ | ✅(omit) | — |
| 8 | `1e7a4f5` | `AdminClient` + 5 리소스(users/groups 타입드·clients/roles/realm raw REST) + `Raw` | ✅ | ✅(omit) | — |
| 9 | `403aa4b` | `KeycloakClient` 통합 진입점 + `AddKeycloak` DI 확장 | ✅ | ✅(omit) | — |
| 10 | `cedcf4d` | Testcontainers E2E(실제 Keycloak 26.6) | ✅ | ✅ E2E | — |
| 11 | `4450648`→`372914a`→`6e944bf` | dotnet-ci(build+format+unit/coverage+integration) + dotnet-release(태그=NuGet, human-gated) + 시크릿/permissions 보안 강화 | ✅ | — | ✅ 97.64%/93.18% |

### 태스크별 리뷰 루프 (Loops)

WBS 자체의 착수 전 어드버서리얼 리뷰(아래 G5)가 대다수 잠재 결함을 계획 단계에서 흡수했지만, 실제 코딩 중 아래 잔여 결함이 발견되어 각 태스크 직후 소규모 루프로 조치했다:

- **Task 1**(`e4402db`): 딥리서치 재검증(Step 1: 핀 버전 실존 확인) 결과 `Microsoft.Extensions.DependencyInjection.Abstractions` 요구 하한을 `dotnet restore` 실측으로 **9.0.8**로 확정·반영.
- **Task 2**(`b38692a`): `Masking.Mask`를 `public`→`internal`로 — 마스킹 헬퍼는 구현 세부(공개 API 아님), Node의 `masking.ts`가 배럴에서 숨기는 것과 동형.
- **Task 3**(`33e89c5`): `KeycloakConfig`의 XML 문서 `<see cref="KeycloakClient.Create"/>`가 (`KeycloakClient`는 Task 9에서야 등장하므로) 미해결 참조 CS1574(→warnaserror 오류) — `<c>...</c>`로 변경해 forward-reference 회피.
- **Task 4**(`b93d7e4`): `Concurrent_calls_single_flight` 테스트가 즉시-반환 소스라 실제 경합 없이도 통과할 수 있어 `DelayMs`로 실접전 유도 + 캐시를 `volatile Cached` 스냅샷(토큰+만료를 하나의 불변 레코드)으로 변경해 ARM64 등 약한 메모리 모델에서의 tearing 방지.
- **Task 7**(`2620331`): nonce fail-open 문제는 WBS 사전검증에서 이미 fail-closed로 계획에 반영됐으나(`ExchangeCodeAsync`가 `_validator.ValidateAsync`로 id_token을 완전 검증 후 nonce 대조), 오프라인 서명 id_token으로 단위 테스트를 보강.
- **Task 8**(`a650635`): admin 경계에서 `HttpClient.Timeout` 만료가 `TaskCanceledException`(=`OperationCanceledException`)으로 온다는 점을 처음엔 놓쳐 `HttpRequestException`만 잡고 있었음 → `catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)` 추가로 `KeycloakTransportException` 변환. `Location` 헤더가 상대 URI일 수 있어 `IsAbsoluteUri` 가드도 추가.
- **Task 9**(`7d2805b`): `_admin` 캐시 필드에 `volatile` 누락(Task 4와 동일한 tearing 위험) 발견 + `AdminAsync()` 동시 최초 호출이 인증을 한 번만 수행하는지(single-flight) 검증하는 테스트 추가.
- **Task 11**(`372914a`): `dotnet format` 잔여 diff 정리 + 브랜치 커버리지가 게이트(85%) 미달이라 도달 가능한 미커버 분기(reachable branch)에 테스트 추가해 임계값 도달. (`6e944bf`): release/CI 워크플로에서 시크릿을 스텝 스코프로 좁히고 `permissions`를 least-privilege로, 서드파티 액션 대신 `gh` CLI를 사용하도록 보안 리뷰 반영.

## G5 — 다중에이전트 어드버서리얼 리뷰 (착수 전, WBS 계획 대상)

Go/Node는 **구현 완료 후**(Task 12 직전) 코드를 리뷰했지만, 이번 사이클은 **WBS 작성 직후 계획 자체**를 5개 렌즈(Duende/JWT API·AuthServices admin API·테스트/빌드 툴링·타입일관성+컴파일가능성·스펙커버리지+동형성+보안) + **1건의 실제 컴파일 검증**(6-에이전트 워크플로우)으로 어드버서리얼 검증했다(`f573a48`). **확정 결함 전부 계획에 보정 완료된 뒤 구현에 착수**:

| # | 심각도 | 결함 | 조치 |
|---|---|---|---|
| 1 | 🔴 HIGH | (실컴파일로 포착) `namespace Xzawed.Keycloak.Admin` 안에서 `new KeycloakClient(http)`가 enclosing 파사드 `Xzawed.Keycloak.KeycloakClient`(private ctor)에 바인딩되어 CS1729 | `using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;` 별칭 |
| 2 | 🔴 HIGH | `GenerateDocumentationFile`+`TreatWarningsAsErrors` 상속으로 모든 public 테스트 멤버가 CS1591 빌드 오류(Task 1부터 빌드 실패) | `Directory.Build.props`에서 `IsTestProject != true` 게이트 + 테스트 csproj `GenerateDocumentationFile=false`, `AnalysisLevel=8.0`으로 로컬(SDK 10)/CI(SDK 8) 밴드 일치 |
| 3 | 🔴 HIGH | `JsonWebTokenHandler.CreateToken`이 `exp`를 자동 주입해 no-exp 테스트가 실제로는 exp 있는 토큰을 만들어 불변식 미검증(테스트가 통과해도 의미 없음) | `SetDefaultTimesOnTokenCreation=false` |
| 4 | 🟡 MED | `record` 자동 `ToString()`만으로는 `JsonSerializer.Serialize`/Serilog destructuring 경로에서 시크릿·토큰 평문 노출 | `JsonConverter<TokenSet>`·`JsonConverter<KeycloakConfig>` 추가 + 회귀 테스트 |
| 5 | 🟡 MED | `ExchangeCodeAsync`가 id_token을 파싱만 하고 nonce가 없으면 무검증 통과(fail-open) | `_validator.ValidateAsync`로 id_token을 완전 검증(서명/iss/aud/exp) 후 nonce 대조(fail-closed) |
| 6 | 🟡 MED | 운영용 JWKS/TLS 배선 ctor가 단위 미커버 → 커버리지 게이트 위협 + §6 TLS 회귀가드 부재 | http/https ctor 스모크 테스트 추가(lazy `ConfigurationManager`, 네트워크 없음) |
| 7 | 🟡 MED | async-only-disposable 싱글턴을 `ServiceProvider.Dispose()`가 동기 처분하려 하면 예외 | `KeycloakClient`/`AdminClient`에 `IDisposable` 추가, `PooledConnectionLifetime`로 단일 HttpClient DNS 갱신 대응 |
| 8 | 🟡 MED | release workflow의 step-level `env`가 같은 step의 `if:`에 보이지 않아 NuGet push가 항상 스킵 | job-level `env`로 승격 |
| 9 | 🟢 LOW/정책 | `AdminClient.CreateAsync` 비동기 워밍 누락(§5.1 "최초 호출 시 인증" 정합)·claims dict 투영 비일관·의존성 오표기(`Microsoft.Extensions.Http`)·xUnit v2 deprecated | async화 + 토큰 워밍 / `.ToDictionary((object?))` 투영 통일 / `DependencyInjection.Abstractions`로 정정 / v2 의도적 유지 |

**컴파일로 반증된 오탐(수정 안 함)**: `new Dictionary<string,object?>(result.Claims!)`는 CS8620 아님(`Claims` 비널) — 그래도 일관성을 위해 투영형으로 통일. `(JsonWebToken)result.SecurityToken` deref·`ReadFromJsonAsync<T>` null-throw·record `required`+`ToString` override — 전부 실제 컴파일 통과 확인.

**CLEAN 판정**: 타입 일관성(전 크로스태스크 참조 일치), 플레이스홀더(없음), `Keycloak.AuthServices.Sdk` 2.7.0 admin API(전부 소스 검증), Testcontainers/WireMock/coverlet 툴링 — 결함 없음.

## 최종 상태 (G1~G6 종합)

- **G1**: ✅ `dotnet build`(`TreatWarningsAsErrors`·`Nullable`·`AnalysisLevel 8.0`) · `dotnet format --verify-no-changes` 통과.
- **G2**: ✅ 단위 **58** GREEN(config 8 · tokens 7 · errors 4 · masking 3 · tokenprovider 4 · oidc 1 · jwt 11 · auth 9 · admin 5 · client 5 · scaffolding 1 — `[Fact]`+`[InlineData]` 실측).
- **G3**: ✅ 로직 모듈 라인 **97.64%**/브랜치 **93.18%**(게이트 90/85), 네트워크 경계(`AuthClient`/`Admin.*`/`KeycloakClient`) omit(`coverlet.msbuild`).
- **통합**: ✅ Testcontainers E2E **1**(`Full_flow`, 다단계) GREEN(실제 Keycloak 26.6 — client-credentials→validate 다중aud→introspect→user CRUD→삭제 후 `KeycloakNotFoundException`→clients/roles/groups CRUD→realm get(자기 realm) + create/delete(master realm bootstrap admin)→`Raw`).
- **G4**: ✅ §4 언어중립 계약·Java/Python/Node/Go 참조와 동형(계층·예외계급·값타입·보안불변식). C# 관용 편차(예외 기반·`Task<T>`+`CancellationToken`·record `ToString` override·DI 확장)는 §4 허용.
- **G5**: ✅ 착수 전 WBS 계획 자체에 대한 5-렌즈+1-실컴파일 다중에이전트 어드버서리얼 리뷰(9건 확정 조치, 위 표) + 태스크별 소규모 리뷰 루프(위 Loops).
- **G6**: ✅ JWT 강화(alg 핀 `RS256`·`none` 거부·iss 정확일치·aud 포함검사·**`exp` 필수**·클록 스큐 30s·DoS-안전 JWKS `ConfigurationManager.RefreshInterval`) · 완전 마스킹(토큰·시크릿·Config — `ToString()` override + `JsonConverter<T>` 이중) · TLS 기본(`HttpDocumentRetriever.RequireHttps`, http 이슈어만 완화) · admin/JWKS 타임아웃 주입(무한대기 차단) · admin 타임아웃(`TaskCanceledException`)→`KeycloakTransportException` 변환 · release 시크릿 step-스코프 + least-privilege `permissions`.
- **배포**: 🔒 NuGet(`NUGET_API_KEY` 시크릿 기반, Trusted Publishing 아님), `dotnet-v*` 태그 push 대기(human-gated, 미실행).
