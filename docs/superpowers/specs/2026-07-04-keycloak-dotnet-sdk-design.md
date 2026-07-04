# Keycloak C#/.NET SDK — 설계 문서 (Design Spec)

- **작성일**: 2026-07-04
- **상태**: 승인 대기 (User Review)
- **대상**: 5번째 언어 — C#/.NET (`dotnet/`)
- **진실 원천**: [언어 중립 계약 §4](2026-07-02-keycloak-multilang-sdk-design.md) · 절차: [add-a-language 플레이북](../../guides/add-a-language-playbook.md)
- **참조 구현**: Java(`java/`) · Python(`python/`) · Node(`node/`) · Go(`go/`)
- **라이선스**: Apache-2.0

---

## 1. 개요 (Overview)

Keycloak을 위한 **C#/.NET용 SDK**를 만든다. Java(`keycloak-admin-client`+Nimbus)·Python(`python-keycloak`+joserfc)·Node(`openid-client`+jose+admin-client)·Go(`gocloak`+x/oauth2+go-jose)에 이어 **5번째 언어**로, **§4 언어 중립 계약에 동형(isomorphic)**이다 — 같은 계층(`config → auth → jwt → admin → client`)·같은 예외 분류·같은 보안 불변식·같은 테스트 시나리오. 관용은 C#/.NET을 따른다(예외 기반 오류, `async`/`Task<T>` + `CancellationToken`, `record` 값 타입, DI 확장).

두 API 표면을 각 언어 최고의 성숙 클라이언트로 감싼다 — **인증(OIDC/OAuth2)은 `Duende.IdentityModel`, JWT 검증은 `Microsoft.IdentityModel.JsonWebTokens`(+`.Protocols.OpenIdConnect`), 관리(Admin REST)는 `Keycloak.AuthServices.Sdk`** — 그 위에 일관된 파사드를 얹는다. **JWT 검증은 라이브러리 기본값을 신뢰하지 않고 명시적으로 강화한 `TokenValidationParameters`로 자체 구성**한다.

### 핵심 결정 (브레인스토밍 승인)
- **배치**: 모노레포 — 이 저장소 최상위 `dotnet/`(java/·python/·node/·go/와 나란히). 솔루션 `Keycloak.Sdk.sln`, 네임스페이스 루트 `Xzawed.Keycloak`, NuGet 배포명 `Xzawed.Keycloak.Sdk`, 배포 태그 `dotnet-vX.Y.Z`. §4 계약·거버넌스·docs·CHANGELOG 공유.
- **TFM**: **`net8.0` 단일 타깃**(LTS — .NET 8/9/10 런타임에서 실행). 미래 멀티타깃은 열어두되 MVP는 net8.0 하나.
- **오류**: **예외 기반**(Java와 유사) — `KeycloakException` 계급, 경계에서 하위 라이브러리 예외를 SDK 예외로 변환.
- **동시성**: **async-first** — 모든 네트워크 메서드가 `async Task<T>` + `CancellationToken`(취소·데드라인). `CreateAuthorizationRequest`만 순수 동기. 별도 sync 표면 없음.
- **DI**: 코어는 DI에 비의존(POCO 생성 `KeycloakClient.Create(config)`)이되, `Microsoft.Extensions.DependencyInjection`용 `services.AddKeycloak(...)` 확장을 **같은 패키지에 포함**(`IHttpClientFactory` 통합).

---

## 2. 범위 (Scope) & 비목표

### 범위
- **인증 흐름**: Authorization Code + PKCE(S256), Client Credentials, Refresh, Logout, Introspection, JWT 검증.
- **관리 파사드**: `Users`/`Clients`/`Realms`/`Roles`/`Groups` + 원시 접근 `Raw`.
- **횡단**: 통합 예외 계급, 시크릿·토큰 마스킹, TLS 검증 기본 on, 수명주기(`IAsyncDisposable`), 타임아웃(+`CancellationToken`).
- **품질/배포**: 단위 + Testcontainers 통합테스트, NuGet 배포(태그 드리븐, human-gated), CI. DI 확장(`AddKeycloak`).

### 비목표
- 브라우저/Blazor WASM 클라이언트측 인증(서버측 파사드에 집중).
- 별도 sync API(.NET은 async-first가 관용).
- ASP.NET Core 인증 미들웨어/핸들러(`Keycloak.AuthServices.Authentication`이 이미 담당 — 우리는 SDK 파사드에 집중, 비목표).
- 자동 discovery 강제(엔드포인트를 규약으로 조립 — JWKS만 `ConfigurationManager`로 네트워크 조회).

---

## 3. 의존성 (래핑 대상 · 딥리서치 2026-07-04 확정)

| 계층 | 라이브러리 | 버전 | 라이선스 | 근거 · 주의 |
|---|---|---|---|---|
| **auth 흐름** | `Duende.IdentityModel` | 8.1.0 | Apache-2.0 | OAuth2/OIDC 프로토콜 메시지(token/introspection/PKCE 헬퍼). 순수 프로토콜 라이브러리(무료·상용 IdentityServer와 별개). `HttpClient` 확장(`RequestClientCredentialsTokenAsync` 등). |
| **jwt** | `Microsoft.IdentityModel.JsonWebTokens` + `Microsoft.IdentityModel.Protocols.OpenIdConnect` | 8.19.1 | MIT | `JsonWebTokenHandler.ValidateTokenAsync` + `TokenValidationParameters`(우리가 강화). JWKS는 `ConfigurationManager<OpenIdConnectConfiguration>`(내장 캐시 + `AutomaticRefreshInterval`/`RefreshInterval` rate-limit → DoS-safe). MS 유지·ASP.NET Core와 동일 스택. |
| **admin** | `Keycloak.AuthServices.Sdk` | 3.0.0 | MIT | Keycloak Admin REST 타입드 클라이언트(`IKeycloakUserClient`/`Client`/`Realm`/`Role`/`Group`). representation 타입 노출(문서화된 은닉성 예외). **단일 유지보수자(NikiforovAll) — 키맨 리스크, 버전 핀**. 예외를 경계에서 변환. |
| **DI/HTTP** | `Microsoft.Extensions.Http` + `Microsoft.Extensions.DependencyInjection.Abstractions` | 8.0.x | MIT | `AddKeycloak` 확장·`IHttpClientFactory`(소켓 고갈 회피·타임아웃). net8.0 정렬(8.0.x). |
| **통합테스트** | `Testcontainers.Keycloak` | 4.13.0 | MIT | **공식 .NET Testcontainers Keycloak 모듈** — realm import 지원. Java/Python/Node/Go `it-realm-realm.json` 재사용. |
| **단위테스트** | `xUnit` (+ `xunit.runner.visualstudio`) · `WireMock.Net` · `coverlet.collector` | 최신 | Apache-2.0/MIT | xUnit(.NET 관용 러너). 토큰/JWKS 엔드포인트 스텁은 `WireMock.Net`(HTTP 목). 커버리지 `coverlet`. |

> **`Keycloak.AuthServices.Authentication`/`.Authorization` 제외 근거**: ASP.NET Core 인증 파이프라인 통합용(미들웨어·정책). 우리 SDK는 **파사드 + 자체 강화 JWT 검증**에 집중하므로 불필요. admin은 `Keycloak.AuthServices.Sdk`(HTTP 클라이언트)만 사용.
>
> **JWT를 `JsonWebTokenHandler`로 자체 강화하는 근거**: `Keycloak.AuthServices`나 ASP.NET Core JwtBearer 미들웨어에 위임하지 않고, §4 불변식(alg 핀·none 거부·iss 정확일치·aud 포함검사·exp 필수·클록 스큐·DoS-safe JWKS)을 **명시적 `TokenValidationParameters`로 직접 구성**한다. 라이브러리 기본값은 안전하지 않을 수 있어 신뢰하지 않는다(다른 4개 언어와 동일 원칙).
>
> **⚠️ 착수 시 재확인**(플레이북 1단계): 유지보수 상태·라이선스(전부 Apache-2.0/MIT 호환 확인됨)·`Keycloak.AuthServices.Sdk` representation 필드는 실제 Keycloak 26.6으로 검증. `Duende.IdentityModel`·`Microsoft.IdentityModel` API 시그니처 실검증. net8.0에서 8.0.x 전이 의존성 정합 확인.

---

## 4. 디렉터리 구조 (`dotnet/`)

```
dotnet/
├─ Keycloak.Sdk.sln
├─ Directory.Build.props            # net8.0·nullable enable·LangVersion·공통 NuGet 메타·SourceLink
├─ src/Xzawed.Keycloak.Sdk/
│  ├─ Xzawed.Keycloak.Sdk.csproj    # 패키지 정의(PackageId=Xzawed.Keycloak.Sdk·license·symbols)
│  ├─ KeycloakConfig.cs             # record + 검증 + ToString 마스킹
│  ├─ KeycloakException.cs          # 예외 계급(경계 변환)
│  ├─ Tokens.cs                     # TokenSet/ValidatedToken/IntrospectionResult(record, ToString 마스킹)
│  ├─ ITokenProvider.cs             # 인터페이스 + ClientCredentialsTokenProvider(SemaphoreSlim single-flight)
│  ├─ OidcEndpoints.cs              # 엔드포인트 조립(네트워크 없음)
│  ├─ JwtValidator.cs               # JsonWebTokenHandler 강화 + ConfigurationManager JWKS(DoS-safe)
│  ├─ AuthClient.cs                 # Duende.IdentityModel 래핑 + 수동 logout
│  ├─ Admin/
│  │  ├─ AdminClient.cs             # 파사드 + Raw + 경계 예외 변환
│  │  └─ Users.cs Clients.cs Realms.cs Roles.cs Groups.cs
│  ├─ KeycloakClient.cs             # 통합 진입점(Auth 즉시·Admin 지연·IAsyncDisposable)
│  └─ ServiceCollectionExtensions.cs # AddKeycloak DI 확장(IHttpClientFactory)
└─ tests/Xzawed.Keycloak.Sdk.Tests/
   ├─ Xzawed.Keycloak.Sdk.Tests.csproj
   ├─ unit/*.cs                     # xUnit 단위(WireMock 스텁)
   ├─ integration/*.cs             # [Trait("Category","Integration")] Testcontainers
   └─ testdata/it-realm-realm.json  # Java/Python/Node/Go 재사용
```

각 파일은 단일 책임. 파사드(`KeycloakClient.cs`·`Admin/AdminClient.cs`) 뒤에 하위 타입 은닉. admin은 **서브네임스페이스 `Xzawed.Keycloak.Admin`**(C#은 순환 참조가 어셈블리 단위라 Go 같은 import-cycle 문제 없음 — 논리적 분리만). 단위테스트는 별도 테스트 프로젝트(`tests/`), 내부 접근이 필요하면 `[InternalsVisibleTo]`.

---

## 5. 계층 설계 (동형 + C# 관용)

### 5.1 공개 API

```csharp
var config = new KeycloakConfig
{
    ServerUrl    = "https://kc.example.com",
    Realm        = "myrealm",
    ClientId     = "my-app",
    ClientSecret = "…",                 // confidential client일 때
    Scopes       = ["openid"],          // 생략 시 auth URL에선 "openid"
};
await using var kc = KeycloakClient.Create(config);   // 검증 실패 → KeycloakConfigException

// --- auth (즉시 조립, kc.Auth 프로퍼티) ---
TokenSet ts            = await kc.Auth.ClientCredentialsTokenAsync(ct);        // → TokenSet
ValidatedToken vt      = await kc.Auth.ValidateAsync(ts.AccessToken, ct);      // 강화 검증
IntrospectionResult ir = await kc.Auth.IntrospectAsync(ts.AccessToken, ct);    // → IntrospectionResult
// var ar = kc.Auth.CreateAuthorizationRequest(redirectUri);  // (동기): AuthorizationRequest{Url,CodeVerifier,State,Nonce}
// TokenSet ts = await kc.Auth.ExchangeCodeAsync(code, redirectUri, ar.CodeVerifier, ar.Nonce, ct);
// TokenSet ts = await kc.Auth.RefreshAsync(refreshToken, ct);
// await kc.Auth.LogoutAsync(refreshToken, ct);

// --- admin (지연, clientSecret 필요) ---
AdminClient admin = await kc.AdminAsync(ct);                                   // 최초 호출 시 인증·캐시(single-flight)
string id         = await admin.Users.CreateAsync(new UserRepresentation { Username = "alice" }, ct);
var u             = await admin.Users.GetAsync(id, ct);                        // 없으면 KeycloakNotFoundException
var users         = await admin.Users.SearchAsync("alice", first: 0, max: 20, ct);
await admin.Users.UpdateAsync(id, rep, ct);
await admin.Users.DeleteAsync(id, ct);
var raw           = admin.Raw;                                                 // Keycloak.AuthServices 클라이언트(탈출구)

// --- DI ---
// builder.Services.AddKeycloak(config);   // → KeycloakClient 등록(IHttpClientFactory 사용)
```

- **`kc.Auth`**: 프로퍼티(`AuthClient`), `Create`에서 즉시 조립(네트워크 없음).
- **`kc.AdminAsync(ct)`**: 메서드 `Task<AdminClient>` — 최초 호출 시 admin 클라이언트 생성 + client-credentials 인증, 캐시·`SemaphoreSlim` single-flight. `ClientSecret` 없으면 네트워크 전 `KeycloakConfigException`.
- **리소스 메서드**: `CreateAsync/GetAsync/SearchAsync/UpdateAsync/DeleteAsync` 등 — Java `UsersResource`와 동형. `Keycloak.AuthServices` representation 타입(`UserRepresentation`/`ClientRepresentation`/`RoleRepresentation`/`GroupRepresentation`/`RealmRepresentation`)을 데이터 모델로 노출(문서화된 은닉성 예외).
- **모든 네트워크 메서드**는 `CancellationToken ct` 마지막 인자(취소·데드라인, C# 관용). `CreateAuthorizationRequest`만 순수 동기.

### 5.2 값 타입 (`Tokens.cs`)

```csharp
public sealed record TokenSet
{
    public required string AccessToken { get; init; }
    public required string TokenType   { get; init; }
    public long ExpiresIn  { get; init; }   // 상대(초)
    public long ExpiresAt  { get; init; }   // 절대(epoch 초) — 0이면 미상
    public string? RefreshToken { get; init; }
    public string? IdToken      { get; init; }   // OIDC id_token(auth-code/refresh)
    public string? Scope        { get; init; }
    public bool IsExpired(long nowSec, long skewSec);
    public override string ToString();       // ⚠️ access/refresh 마스킹 — record 기본 ToString override 필수
}

public sealed record ValidatedToken(
    string Subject, IReadOnlyList<string> Audience, string Issuer,
    long ExpiresAt /*exp*/, long IssuedAt /*iat*/, IReadOnlyDictionary<string, object> Claims);

public sealed record IntrospectionResult(
    bool Active, string? Username, string? ClientId, IReadOnlyDictionary<string, object> Claims);

public sealed record AuthorizationRequest(   // CreateAuthorizationRequest 반환
    string Url, string CodeVerifier, string State, string Nonce);
```

값 타입은 Java/Python/Node/Go와 동형(`ExpiresAt`/`IdToken`/`IsExpired`·`Username`/`ClientId`·`exp`/`iat` 포함).

> **⚠️ record 마스킹 함정(핵심 보안 불변식)**: C# `record`는 컴파일러가 **모든 프로퍼티를 그대로 찍는 `ToString()`을 자동 생성**한다 — `TokenSet`을 로그에 넣으면 access/refresh 토큰 전체가 평문 노출된다. `TokenSet`과 `KeycloakConfig`는 반드시 `ToString()`을 override해 토큰/시크릿을 `***`로 마스킹한다(Go `Stringer` 필수와 동일 이유). 단위 테스트로 회귀 가드.

### 5.3 결합 규칙

`admin`은 `auth`를 직접 모른다 — `ITokenProvider` 인터페이스로만 연결.

```csharp
public interface ITokenProvider
{
    Task<string> GetTokenAsync(CancellationToken ct = default);
}
```

기본 `ClientCredentialsTokenProvider`는 client-credentials로 토큰 자동 획득·캐시(만료 전 재사용)·갱신하며, 동시 요청은 `SemaphoreSlim`으로 단일 발급(single-flight). 소비자는 자체 `ITokenProvider`를 주입 가능(admin의 토큰 출처 교체).

### 5.4 예외 계급 (`KeycloakException.cs`)

```csharp
public class KeycloakException : Exception { … }                              // 루트
public sealed class KeycloakConfigException          : KeycloakException { }   // 설정 검증
public sealed class KeycloakAuthException            : KeycloakException {      // 인증/토큰 교환
    public string? OAuthError { get; }                                        //   OAuth error 코드 보존
}
public sealed class KeycloakTokenValidationException : KeycloakException { }   // 서명·만료·iss·aud
public class        KeycloakAdminException           : KeycloakException {      // 관리 API
    public int StatusCode { get; }                                            //   HTTP status 보존
}
public sealed class KeycloakNotFoundException  : KeycloakAdminException { }     // 404
public sealed class KeycloakConflictException  : KeycloakAdminException { }     // 409
public sealed class KeycloakForbiddenException : KeycloakAdminException { }     // 403
public sealed class KeycloakTransportException : KeycloakException { }          // 네트워크/타임아웃/취소
```

- **경계에서 하위 라이브러리 예외 변환** — `Duende.IdentityModel`의 `TokenResponse.IsError`·`Microsoft.IdentityModel`의 `SecurityTokenException` 계열·`Keycloak.AuthServices`의 `HttpRequestException`/`ApiException`(status)·`TaskCanceledException`이 공개 API로 새지 않는다. HTTP status → `NotFound(404)`/`Conflict(409)`/`Forbidden(403)`/기타 `KeycloakAdminException`.
- 예외 계급은 Java와 동형(`ConfigException`/`AuthException`/`TokenValidationException`/`AdminException`(→Found/Conflict/Forbidden)/`TransportException`).
- 시크릿/토큰은 예외 메시지에 마스킹(§6).

---

## 6. 보안 불변식 (§4 · 게차 준수)

- **마스킹**: 토큰/시크릿은 `ToString()`/로그·예외 메시지에 **완전 불투명 `***`**(접두 노출 없음). **`record` 자동 `ToString()`이 전체 노출하므로 `TokenSet`·`KeycloakConfig`는 override 필수**(§5.2 함정). `ClientSecret`은 `string`(SecureString은 .NET에서 비권장 — 하위 라이브러리가 `string` 요구, Java char[]와 같은 심층방어 경계 한계 문서화).
- **TLS 검증 기본 on**: `HttpClient`/`HttpClientHandler` 기본값이 https 인증서 검증. `ServerUrl`이 `http://`일 때만 완화(로컬/테스트). 커스텀 핸들러로 검증 비활성화하지 않는다.
- **JWT 강화(`JwtValidator.cs`)**: `JsonWebTokenHandler.ValidateTokenAsync` + 명시적 `TokenValidationParameters` —
  - `ValidAlgorithms = ["RS256"]`(알고리즘 핀, 헤더 `alg` 불신) · `RequireSignedTokens = true`(none/미서명 거부)
  - `ValidateIssuer = true` + `ValidIssuer`(정확일치) · `ValidateAudience = true` + `ValidAudiences`(clientId 포함검사, 다중 aud 수용)
  - `RequireExpirationTime = true`(exp 필수) · `ValidateLifetime = true` · `ClockSkew`(기본 30s)
  - **JWKS DoS-안전**: `ConfigurationManager<OpenIdConnectConfiguration>`의 내장 캐시 + `AutomaticRefreshInterval`/최소 `RefreshInterval`로 rate-limit(서명 위조 토큰마다 IdP를 때리지 않음). issuer(realm)당 `ConfigurationManager` 캐시.
- **admin 타임아웃 주입**: `KeycloakConfig`의 connect/read 타임아웃을 `HttpClient.Timeout`에 주입 + 모든 호출에 `CancellationToken` 전달(무한대기 방지). `IHttpClientFactory`로 소켓 고갈 회피.
- **single-flight**: 만료 시점 토큰 갱신을 `SemaphoreSlim`으로 중복 제거.
- **CI 회귀 가드**: 마스킹(record ToString)·TLS·JWT 강화·JWKS rate-limit 단위 테스트를 머지 차단 잡으로.

---

## 7. 테스트 (Java/Python/Node/Go 패리티)

| 층위 | 도구 | 대상 |
|---|---|---|
| **단위** | `xUnit` + `WireMock.Net`(토큰/JWKS 엔드포인트 스텁) | PKCE 생성, 설정 검증·기본값, 토큰 응답 파싱, JWT 강화(alg 핀·none·iss·aud·exp+클록스큐), 예외 경계 매핑(HTTP status→예외 계급), 마스킹(record ToString), single-flight |
| **통합** | `Testcontainers.Keycloak` + 실제 **Keycloak 26.6** | client-credentials→`ValidateAsync`(다중 aud)→`IntrospectAsync`→user CRUD→`Raw`→delete 후 `KeycloakNotFoundException`. **Java/Python/Node/Go `it-realm-realm.json` 재사용** |
| **커버리지** | `coverlet`(`dotnet test --collect`) + 임계값 검사 | 로직 파일 라인≥90/브랜치≥85 상당, 네트워크 경계(`AuthClient`/`Admin/**`) 제외. 실측 임계값은 착수 시 확정 |

시나리오 집합은 Java/Python/Node/Go와 **동형**(개수는 언어차 허용). 통합은 Docker 필요. 커버리지 게이트는 `coverlet` XPlat + `[ExcludeFromCodeCoverage]` 또는 필터로 네트워크 경계 제외, CI에서 임계값 강제(예: `dotnet test /p:Threshold` 또는 리포트 파싱 스크립트).

---

## 8. 빌드 · CI · 배포

- **빌드/품질**: `dotnet build -warnaserror`·`dotnet format --verify-no-changes`(포맷/스타일)·`dotnet test`(단위+커버리지). nullable enable·analyzer 경고를 오류로.
- **패키지**: `PackageId=Xzawed.Keycloak.Sdk`, TFM `net8.0`, `Directory.Build.props`에 공통 메타(Authors·License=Apache-2.0·RepositoryUrl·SourceLink·`GenerateDocumentationFile`). 소비자: `dotnet add package Xzawed.Keycloak.Sdk` → `using Xzawed.Keycloak;`.
- **CI (`.github/workflows/dotnet-ci.yml`)**: `actions/setup-dotnet`(net8.0 SDK) → restore+build(-warnaserror)+format 검사+단위테스트+커버리지 잡, integration 잡(Docker) 별도. paths `dotnet/**`. NuGet 캐시.
- **배포 (`.github/workflows/dotnet-release.yml`)**: `dotnet-v*` 태그 → `dotnet pack -c Release` + `dotnet nuget push`(NuGet.org). **NuGet API 키 필요 = human-gated**(저장 시크릿). 대안으로 GitHub Packages 검토(레포 토큰). 워크플로는 verify(build+test) 후 pack+push, GitHub Release 생성. 사람이 `dotnet-v*` 태그 push.
- **로컬 사전검증**: `dotnet build`·`dotnet test --filter Category!=Integration`·`dotnet pack -c Release`(업로드 없이 `.nupkg` 생성 확인).

---

## 9. 문서 · 거버넌스

- getting-started에 **C#/.NET 섹션(4블록: 요구 런타임 .NET 8+·로컬 프로젝트참조/`dotnet add`·배포후 `dotnet add package`·최소 예제)** 추가 · README·CLAUDE 구조 트리·로드맵 현황 매트릭스 C# ✅ 갱신 · CHANGELOG `(dotnet)` 태그.
- **verification-log-dotnet.md**(게이트 통과·Loops·딥리서치 이력) 기록.
- **G1~G6 게이트 + 이중검증(다중에이전트 어드버서리얼 리뷰) + Loops** 준수. 실행은 **WBS → Workflow 오케스트레이션**(플레이북 6단계 매핑). 착수 전 딥리서치 재검증.
- **툴체인**: 이 머신은 .NET SDK `C:\Program Files\dotnet`(10.0.102, PATH 등록)에 설치, **net8.0 런타임(`Microsoft.NETCore.App` 8.0.23) 네이티브 존재** — net8.0 빌드/테스트가 roll-forward 없이 실행됨(2026-07-04 확인). 명령은 `dotnet <cmd>` 직접(포터블 설치 불필요 — Go/Java와 달리 시스템 설치됨). CI는 `actions/setup-dotnet`.

---

## 10. 결정 · 열린 항목

- **결정됨**: 모노레포 `dotnet/`(솔루션 `Keycloak.Sdk.sln`, NuGet `Xzawed.Keycloak.Sdk`, `dotnet-vX.Y.Z` 태그) · net8.0 단일 TFM · 예외 기반 오류(Java 동형) · async-first(`Task<T>`+`CancellationToken`) · 코어 DI-agnostic + `AddKeycloak` 확장 포함 · 전체 §4 계약 동형 · 래핑(Duende.IdentityModel + Microsoft.IdentityModel.JsonWebTokens/Protocols.OpenIdConnect + Keycloak.AuthServices.Sdk) · JWT 자체 강화(JsonWebTokenHandler + 명시 TokenValidationParameters + ConfigurationManager JWKS) · Testcontainers.Keycloak 공식 모듈 · record 값 타입(ToString 마스킹 필수) · 네임스페이스 `Xzawed.Keycloak`.
- **착수 시 확정**: Duende.IdentityModel/Microsoft.IdentityModel/Keycloak.AuthServices.Sdk 유지보수·API 시그니처 실검증 · net8.0 전이 의존성(8.0.x) 정합 · 커버리지 임계값 수치 · analyzer 룰셋(warnaserror 범위) · ConfigurationManager rate-limit 세부(RefreshInterval) · admin representation 필드 실서버 검증 · NuGet 대 GitHub Packages 배포 대상.
- **비목표 재확인**: 브라우저/Blazor WASM·별도 sync API·ASP.NET Core 인증 미들웨어는 범위 밖.
