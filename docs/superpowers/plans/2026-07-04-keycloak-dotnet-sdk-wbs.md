# Keycloak C#/.NET SDK — 구현 계획 (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development(권장) 또는 superpowers:executing-plans로 태스크 단위 구현. 스텝은 `- [ ]` 체크박스. 실행 방식: **WBS → Workflow 오케스트레이션 + AI 거버넌스(G1~G6) + 다중에이전트 어드버서리얼 리뷰 + Loops + 딥리서치**.

**Goal:** Java/Python/Node/Go와 §4 계약에 동형인 Keycloak C#/.NET SDK를 `dotnet/`에 구현한다 — 인증(OIDC)·관리(Admin) 파사드 + 자체 강화 JWT 검증, async-first(`Task<T>`+`CancellationToken`), NuGet 배포 준비.

**Architecture:** `Duende.IdentityModel`(auth 흐름)·`Microsoft.IdentityModel.JsonWebTokens`+`.Protocols.OpenIdConnect`(강화 JWT)·`Keycloak.AuthServices.Sdk`(admin)을 감싸는 파사드. 계층 `config → errors/masking → tokens → tokenprovider → oidc → jwt → auth → admin → client(+DI)`. `admin`은 `auth`를 모르고 `ITokenProvider`로만 결합(기본 소스는 `AuthClient`의 client-credentials). 하위 타입은 파사드 뒤 은닉, 하위 예외는 경계에서 `KeycloakException` 계급으로 변환.

**Tech Stack:** .NET 8(net8.0) · C# 12 · `Duende.IdentityModel` 8.1.0 · `Microsoft.IdentityModel.*` 8.19.1 · `Keycloak.AuthServices.Sdk` **2.7.0**(net8 최종 빌드; 3.0.0은 net10 전용) · `Microsoft.Extensions.DependencyInjection.Abstractions` 9.0.8(AuthServices 2.7.0 요구 하한) · 테스트 `xUnit` 2.9.3 · `WireMock.Net` 2.11.0 · `Testcontainers.Keycloak` 4.13.0 · `coverlet.msbuild` 10.0.1 · `Microsoft.NET.Test.Sdk` 18.7.0.

## Global Constraints

[설계 스펙](../specs/2026-07-04-keycloak-dotnet-sdk-design.md)에서 그대로 옮김. 모든 태스크에 암묵 적용.

- **배치**: 모노레포 `dotnet/`(java/·python/·node/·go/와 나란히). 솔루션 `Keycloak.Sdk.sln`, 루트 네임스페이스 `Xzawed.Keycloak`(csproj `<RootNamespace>`), admin은 `Xzawed.Keycloak.Admin` 서브네임스페이스. NuGet PackageId `Xzawed.Keycloak.Sdk`, 배포 태그 `dotnet-vX.Y.Z`.
- **런타임/동시성**: **net8.0** · async-first — 모든 네트워크 메서드가 `async Task<T>` + 마지막 인자 `CancellationToken ct = default`; `CreateAuthorizationRequest`만 순수 동기.
- **명명**: 값타입 `TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest`(전부 `record`). 파사드 `KeycloakClient`/`AuthClient`/`AdminClient`. 진입 `KeycloakClient.Create(config)`.
- **동형 계약**: [§4 언어중립계약](../specs/2026-07-02-keycloak-multilang-sdk-design.md). 참조 구현: `node/src/`(가장 근접 — async·representation 래핑·예외계급), `go/`, `java/`, `python/src/keycloak_sdk/`.
- **보안 불변식**: 토큰/시크릿 **완전 마스킹**(`***`, 접두/길이 노출 없음) — **⚠️ `record` 자동 `ToString()`이 전체 프로퍼티를 찍으므로 `TokenSet`·`KeycloakConfig`는 `ToString()` override 필수** · TLS 검증 기본 on(https 강제; JWKS `HttpDocumentRetriever.RequireHttps`만 http일 때 완화) · JWT 강화(alg 핀 `["RS256"]`·`none`/미서명 거부·`iss` 정확일치·`aud` **포함검사**(다중 aud)·`exp` 필수·클록스큐 기본 30s·**JWKS 재조회 DoS-safe**(`ConfigurationManager.RefreshInterval` 스로틀)) · admin 타임아웃 주입(`HttpClient.Timeout`).
- **결합 규칙**: `admin`은 `auth` 비의존 — `ITokenProvider`가 유일 접착제. `AuthClient : ITokenSource`가 기본 소스. `admin.Raw`(`IKeycloakClient`) 탈출구.
- **admin 구현 분리(딥리서치 확정)**: `Keycloak.AuthServices.Sdk` 2.7.0 타입드 클라이언트는 **users/groups/realm-get만** 커버(`IKeycloakUserClient`/`IKeycloakGroupClient`/`IKeycloakRealmClient`). **clients/roles/realm-CRUD는 같은 bearer-authed `HttpClient`로 raw Admin REST**(`admin/realms/{realm}/…`, `Models.*Representation` 재사용). 편의 `…Async`는 default interface method → 변수를 `IKeycloakClient`로 타입. `CreateUserAsync`는 void → `CreateUserWithResponseAsync` + `Location` 헤더 파싱으로 id 취득.
- **테스트**: 단위(`xUnit` + `WireMock.Net` HTTP 목, 네트워크 격리) + 통합(`Testcontainers.Keycloak`, 실제 Keycloak 26.6, `java/keycloak-sdk/src/test/resources/it-realm-realm.json` 재사용, `[Trait("Category","Integration")]`). 커버리지 게이트(`coverlet.msbuild` 라인≥90/브랜치≥85, 네트워크 경계 `[*]Xzawed.Keycloak.AuthClient`·`[*]Xzawed.Keycloak.Admin.*`·`[*]Xzawed.Keycloak.KeycloakClient` 제외).
- **툴체인(하네스)**: .NET SDK 시스템 설치 `C:\Program Files\dotnet`(10.0.102, PATH). **net8.0 런타임 8.0.23 네이티브 존재** → `dotnet <cmd>` 직접(포터블 설치 불필요). CI는 `actions/setup-dotnet`.
- **커밋**: `git add -A && git commit`. 브랜치 `feature/dotnet-sdk`(생성됨), PR로 main(사람 승인). 커밋 co-author `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **거버넌스**: 태스크마다 G1(빌드/format)·G2(단위)·G3(커버리지)·G4(스펙리뷰)·G5(다중에이전트 리뷰)·G6(보안) 통과 후 커밋. 실패 시 Loops. verification-log-dotnet 기록.
- **⚠️ 라이브러리 오류 모델(딥리서치 확정, 코드에 반영됨)**: Duende 확장 메서드는 **예외를 던지지 않음** → `resp.IsError` 검사. Keycloak은 잘못된 client 자격증명에 **401**(→`ErrorType=Http`, OAuth 코드는 `resp.Json["error"]`). `Keycloak.AuthServices` 편의 메서드는 **`KeycloakHttpClientException{int StatusCode}`**(non-2xx), 전송 실패는 `HttpRequestException`. `JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 **throw 안 함** → `result.IsValid`/`result.Exception` 검사.

## File Structure

- `dotnet/Keycloak.Sdk.sln` · `dotnet/Directory.Build.props`(net8.0·nullable·warnaserror·NuGet 메타·SourceLink) · `dotnet/.editorconfig`(선택; format 규칙).
- `dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj`(PackageId·RootNamespace·deps·InternalsVisibleTo).
- `.../Masking.cs` — `internal static string Mask(string?)`.
- `.../KeycloakException.cs` — 예외 계급 + `internal static KeycloakErrorMapping.MapHttpError`.
- `.../KeycloakConfig.cs` — `record` + `Normalized()`(검증·정규화) + `ToString()` 마스킹.
- `.../Tokens.cs` — `TokenSet`/`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest` records + `TokenSet.Create`·`IsExpired`·`ToString` 마스킹.
- `.../ITokenProvider.cs` — `ITokenProvider`/`ITokenSource` + `ClientCredentialsTokenProvider`(SemaphoreSlim single-flight).
- `.../OidcEndpoints.cs` — `record OidcEndpoints` + `For(serverUrl, realm)`(네트워크 없음).
- `.../JwtValidator.cs` — `JwtValidatorOptions` + `JwtValidator`(Microsoft.IdentityModel 강화 + `ConfigurationManager` JWKS). **보안 핵심**.
- `.../AuthClient.cs` — `AuthClient : ITokenSource`(Duende.IdentityModel 래핑 + 수동 PKCE/logout). **네트워크 경계**.
- `.../Admin/AdminClient.cs` + `Admin/{Users,Clients,Realms,Roles,Groups}Resource.cs` + `Admin/BearerHandler.cs` — `AdminClient`(타입드 + raw REST) + `Raw`. **네트워크 경계**.
- `.../KeycloakClient.cs` — `KeycloakClient : IAsyncDisposable`(Auth 즉시·Admin 지연·single-flight). **네트워크 경계**.
- `.../ServiceCollectionExtensions.cs` — `AddKeycloak` DI 확장.
- `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/…` — xUnit 단위 + `integration/` + `testdata/it-realm-realm.json`.
- `.github/workflows/dotnet-ci.yml`·`dotnet-release.yml`.

## 태스크 순서/의존

1 스캐폴딩 → 2 errors+masking → 3 config+tokens → 4 tokenprovider → 5 oidc → 6 jwt → 7 auth → 8 admin → 9 client+DI → 10 통합테스트 → 11 CI/release → 12 문서. (2~6 상호 독립성 높음; 7은 5·6·3 의존; 8은 3·4·2 의존; 9는 7·8 의존.)

---

### Task 1: 스캐폴딩 (솔루션·프로젝트·빌드)

**Files:** Create `dotnet/Directory.Build.props`, `dotnet/Keycloak.Sdk.sln`, `dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj`, `dotnet/src/Xzawed.Keycloak.Sdk/AssemblyInfo.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/Xzawed.Keycloak.Sdk.Tests.csproj`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/ScaffoldingSmokeTest.cs`

**Interfaces:** Produces: 빌드/테스트/커버리지 파이프라인, `RootNamespace=Xzawed.Keycloak`, `InternalsVisibleTo(Xzawed.Keycloak.Sdk.Tests)`. Consumes: 없음.

- [ ] **Step 1: 딥리서치 재검증(핀 버전 실존 확인)** — `dotnet` 명령으로 각 패키지가 net8.0에서 실제로 복원되는지 확인(특히 `Keycloak.AuthServices.Sdk 2.7.0`이 net8.0인지 — 3.0.0은 net10 전용). 상이하면 버전을 조정하고 스펙 §3에 반영.

- [ ] **Step 2: `Directory.Build.props` 작성**

```xml
<!-- dotnet/Directory.Build.props -->
<Project>
  <PropertyGroup>
    <TargetFramework>net8.0</TargetFramework>
    <LangVersion>12.0</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <TreatWarningsAsErrors>true</TreatWarningsAsErrors>
    <EnforceCodeStyleInBuild>true</EnforceCodeStyleInBuild>
    <!-- Pin the analyzer band to 8.0 so a newer local SDK (10.x) and CI SDK (8.x) agree under warnaserror -->
    <AnalysisLevel>8.0</AnalysisLevel>
    <Deterministic>true</Deterministic>
    <ContinuousIntegrationBuild Condition="'$(CI)' == 'true'">true</ContinuousIntegrationBuild>
  </PropertyGroup>
  <!-- Packaging/doc props apply only to packable (src) projects, NOT test projects.
       (GenerateDocumentationFile + TreatWarningsAsErrors would make CS1591 a build error on every public test member.) -->
  <PropertyGroup Condition="'$(IsTestProject)' != 'true'">
    <Authors>xzawed</Authors>
    <Product>Keycloak SDK for .NET</Product>
    <PackageLicenseExpression>Apache-2.0</PackageLicenseExpression>
    <PackageProjectUrl>https://github.com/xzawed/KeyCloakSDK</PackageProjectUrl>
    <RepositoryUrl>https://github.com/xzawed/KeyCloakSDK</RepositoryUrl>
    <RepositoryType>git</RepositoryType>
    <PublishRepositoryUrl>true</PublishRepositoryUrl>
    <GenerateDocumentationFile>true</GenerateDocumentationFile>
    <IncludeSymbols>true</IncludeSymbols>
    <SymbolPackageFormat>snupkg</SymbolPackageFormat>
    <EmbedUntrackedSources>true</EmbedUntrackedSources>
  </PropertyGroup>
</Project>
```
> **⚠️ 리뷰 반영(HIGH)**: 문서생성/패키징 props를 `IsTestProject != true`로 게이트하지 않으면 테스트 프로젝트가 `GenerateDocumentationFile=true`+`TreatWarningsAsErrors`를 상속해 **모든 public 테스트 멤버에 CS1591이 오류로 승격** → Task 1부터 빌드 실패. `AnalysisLevel=8.0`으로 로컬(SDK 10)·CI(SDK 8) 애널라이저 밴드 일치(warnaserror 재현성).

- [ ] **Step 3: 라이브러리 `.csproj` 작성**

```xml
<!-- dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -->
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <PackageId>Xzawed.Keycloak.Sdk</PackageId>
    <RootNamespace>Xzawed.Keycloak</RootNamespace>
    <AssemblyName>Xzawed.Keycloak.Sdk</AssemblyName>
    <Version>0.1.0</Version>
    <Description>Keycloak OIDC authentication + Admin REST SDK for .NET.</Description>
    <PackageTags>keycloak;oidc;oauth2;admin;jwt</PackageTags>
    <!-- 공개 멤버 XML 문서 미작성 경고를 오류로 승격하지 않음(문서는 점진적으로) -->
    <NoWarn>$(NoWarn);CS1591</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Duende.IdentityModel" Version="8.1.0" />
    <PackageReference Include="Microsoft.IdentityModel.JsonWebTokens" Version="8.19.1" />
    <PackageReference Include="Microsoft.IdentityModel.Protocols.OpenIdConnect" Version="8.19.1" />
    <PackageReference Include="Keycloak.AuthServices.Sdk" Version="2.7.0" />
    <!-- AddKeycloak DI extension needs IServiceCollection/AddSingleton (DI.Abstractions), NOT IHttpClientFactory.
         ⚠️ Pinned to 9.0.8: Keycloak.AuthServices.Sdk 2.7.0 (net8.0) requires DI.Abstractions >= 9.0.8, so a
         lower pin triggers NU1605 (downgrade → hard error under TreatWarningsAsErrors). 9.0.x supports net8.0. -->
    <PackageReference Include="Microsoft.Extensions.DependencyInjection.Abstractions" Version="9.0.8" />
    <PackageReference Include="Microsoft.SourceLink.GitHub" Version="8.0.0" PrivateAssets="All" />
  </ItemGroup>
  <ItemGroup>
    <InternalsVisibleTo Include="Xzawed.Keycloak.Sdk.Tests" />
  </ItemGroup>
</Project>
```
`dotnet/src/Xzawed.Keycloak.Sdk/AssemblyInfo.cs`:
```csharp
// intentionally minimal; InternalsVisibleTo is generated from the csproj item.
```

- [ ] **Step 4: 테스트 `.csproj` 작성**

```xml
<!-- dotnet/tests/Xzawed.Keycloak.Sdk.Tests/Xzawed.Keycloak.Sdk.Tests.csproj -->
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <RootNamespace>Xzawed.Keycloak.Sdk.Tests</RootNamespace>
    <AssemblyName>Xzawed.Keycloak.Sdk.Tests</AssemblyName>
    <IsPackable>false</IsPackable>
    <IsTestProject>true</IsTestProject>
    <!-- belt-and-suspenders: no XML docs required for test members (CS1591 would be an error under warnaserror) -->
    <GenerateDocumentationFile>false</GenerateDocumentationFile>
    <NoWarn>$(NoWarn);CS1591</NoWarn>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="18.7.0" />
    <PackageReference Include="xunit" Version="2.9.3" />
    <PackageReference Include="xunit.runner.visualstudio" Version="3.1.5" />
    <PackageReference Include="coverlet.collector" Version="10.0.1" />
    <PackageReference Include="coverlet.msbuild" Version="10.0.1" />
    <PackageReference Include="WireMock.Net" Version="2.11.0" />
    <PackageReference Include="Testcontainers.Keycloak" Version="4.13.0" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="../../src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 5: 솔루션 생성 + 프로젝트 추가 + smoke 테스트 + .gitignore**

```bash
cd dotnet && dotnet new sln -n Keycloak.Sdk --format sln   # ⚠️ SDK 10은 기본 .slnx → --format sln으로 Keycloak.Sdk.sln 생성
dotnet sln add src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj
dotnet sln add tests/Xzawed.Keycloak.Sdk.Tests/Xzawed.Keycloak.Sdk.Tests.csproj
```
`dotnet/.gitignore`(빌드 산출물 커밋 방지):
```gitignore
bin/
obj/
[Bb]in/
[Oo]bj/
*.user
TestResults/
```
`dotnet/tests/Xzawed.Keycloak.Sdk.Tests/ScaffoldingSmokeTest.cs`:
```csharp
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

public class ScaffoldingSmokeTest
{
    [Fact]
    public void Solution_builds_and_tests_run() => Assert.True(true);
}
```

- [ ] **Step 6: 검증** — `cd dotnet && dotnet build && dotnet test --filter "Category!=Integration"`
  Expected: 복원·빌드 성공, smoke 테스트 1개 PASS.
- [ ] **Step 7: Commit** — `git add -A && git commit -m "feat(dotnet): 스캐폴딩 — 솔루션·src/tests 프로젝트·Directory.Build.props·의존성 핀 (WBS 1)"`

---

### Task 2: 예외 계급 + 마스킹 (Masking.cs, KeycloakException.cs)

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/Masking.cs`, `dotnet/src/Xzawed.Keycloak.Sdk/KeycloakException.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/MaskingTests.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/ErrorsTests.cs`

**Interfaces:** Produces: `internal static string Masking.Mask(string?)`; 예외 `KeycloakException`(base) → `KeycloakConfigException`·`KeycloakAuthException`(`string? OAuthError`)·`KeycloakTokenValidationException`·`KeycloakAdminException`(`int StatusCode`) → `KeycloakNotFoundException`·`KeycloakConflictException`·`KeycloakForbiddenException`·`KeycloakTransportException`; `internal static KeycloakException KeycloakErrorMapping.MapHttpError(int status, string message, Exception? cause = null)`. 참조: Node `errors.ts`.

- [ ] **Step 1: 실패 테스트 작성**

`MaskingTests.cs`:
```csharp
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests;

public class MaskingTests
{
    [Theory]
    [InlineData("supersecret")]
    [InlineData("")]
    [InlineData(null)]
    public void Mask_is_always_opaque(string? input)
    {
        var masked = Xzawed.Keycloak.Masking.Mask(input);
        Assert.Equal("***", masked);
        Assert.DoesNotContain("secret", masked);
    }
}
```
`ErrorsTests.cs`:
```csharp
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class ErrorsTests
{
    [Fact]
    public void MapHttpError_404_is_NotFound_and_AdminException_and_base()
    {
        var ex = KeycloakErrorMapping.MapHttpError(404, "gone");
        Assert.IsType<KeycloakNotFoundException>(ex);
        Assert.IsAssignableFrom<KeycloakAdminException>(ex);
        Assert.IsAssignableFrom<KeycloakException>(ex);
        Assert.Equal(404, ((KeycloakAdminException)ex).StatusCode);
    }

    [Fact]
    public void MapHttpError_409_and_403()
    {
        Assert.IsType<KeycloakConflictException>(KeycloakErrorMapping.MapHttpError(409, "x"));
        Assert.IsType<KeycloakForbiddenException>(KeycloakErrorMapping.MapHttpError(403, "x"));
    }

    [Fact]
    public void MapHttpError_other_is_AdminException_with_status_in_message()
    {
        var ex = KeycloakErrorMapping.MapHttpError(500, "boom");
        Assert.IsType<KeycloakAdminException>(ex);
        Assert.Contains("500", ex.Message);
    }

    [Fact]
    public void Exceptions_preserve_inner()
    {
        var inner = new System.Exception("root");
        var ex = new KeycloakAuthException("auth failed", inner) { OAuthError = "invalid_grant" };
        Assert.Same(inner, ex.InnerException);
        Assert.Equal("invalid_grant", ex.OAuthError);
    }
}
```

- [ ] **Step 2: 실패 확인** — `cd dotnet && dotnet test --filter "Category!=Integration"` → FAIL(타입 미정의로 컴파일 실패).
- [ ] **Step 3: 구현**

`Masking.cs`:
```csharp
namespace Xzawed.Keycloak;

/// <summary>Opaque masking for secrets and tokens — never exposes length or prefix.
/// Internal: an implementation detail (consumed by config/tokens/errors), not public API (Node barrel hides it).</summary>
internal static class Masking
{
    public static string Mask(string? value) => "***";
}
```
(테스트는 별도 어셈블리지만 `InternalsVisibleTo`(Task 1)로 접근 가능.)
`KeycloakException.cs`:
```csharp
namespace Xzawed.Keycloak;

/// <summary>Base for every error raised by this SDK. Lower-library exceptions are converted at the boundary.</summary>
public class KeycloakException : Exception
{
    public KeycloakException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>Configuration validation failure (missing/blank required value, missing clientSecret for admin).</summary>
public sealed class KeycloakConfigException : KeycloakException
{
    public KeycloakConfigException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>OIDC/OAuth2 flow failure (token endpoint, introspection, logout).</summary>
public sealed class KeycloakAuthException : KeycloakException
{
    /// <summary>OAuth2 error code from the token endpoint body, when available.</summary>
    public string? OAuthError { get; init; }
    public KeycloakAuthException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>JWT hardened-validation failure (signature/algorithm/issuer/audience/expiry).</summary>
public sealed class KeycloakTokenValidationException : KeycloakException
{
    public KeycloakTokenValidationException(string message, Exception? innerException = null) : base(message, innerException) { }
}

/// <summary>Admin REST failure carrying the HTTP status.</summary>
public class KeycloakAdminException : KeycloakException
{
    public int StatusCode { get; }
    public KeycloakAdminException(int statusCode, string message, Exception? innerException = null)
        : base(message, innerException) => StatusCode = statusCode;
}

public sealed class KeycloakNotFoundException : KeycloakAdminException
{
    public KeycloakNotFoundException(string message, Exception? innerException = null) : base(404, message, innerException) { }
}

public sealed class KeycloakConflictException : KeycloakAdminException
{
    public KeycloakConflictException(string message, Exception? innerException = null) : base(409, message, innerException) { }
}

public sealed class KeycloakForbiddenException : KeycloakAdminException
{
    public KeycloakForbiddenException(string message, Exception? innerException = null) : base(403, message, innerException) { }
}

/// <summary>Network/transport failure (connect/DNS/TLS/timeout) — no HTTP response received.</summary>
public sealed class KeycloakTransportException : KeycloakException
{
    public KeycloakTransportException(string message, Exception? innerException = null) : base(message, innerException) { }
}

internal static class KeycloakErrorMapping
{
    public static KeycloakException MapHttpError(int status, string message, Exception? cause = null) => status switch
    {
        404 => new KeycloakNotFoundException(message, cause),
        409 => new KeycloakConflictException(message, cause),
        403 => new KeycloakForbiddenException(message, cause),
        _   => new KeycloakAdminException(status, $"HTTP {status}: {message}", cause),
    };
}
```

- [ ] **Step 4: 통과 확인** — 동일 명령 → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): 마스킹 + 예외 계급(경계 변환·MapHttpError) (WBS 2)"`

---

### Task 3: KeycloakConfig + 값 타입 (KeycloakConfig.cs, Tokens.cs)

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/KeycloakConfig.cs`, `dotnet/src/Xzawed.Keycloak.Sdk/Tokens.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/ConfigTests.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/TokensTests.cs`

**Interfaces:** Produces: `record KeycloakConfig`(init props + `Normalized()` + `ToString()` 마스킹); `record TokenSet`(`Create` 팩토리·`IsExpired`·`ToString` 마스킹), `record ValidatedToken`, `record IntrospectionResult`, `record AuthorizationRequest`. Consumes: `Masking`·`KeycloakConfigException`·`KeycloakAuthException`(T2). 참조: Node `config.ts`/`tokens.ts`.

- [ ] **Step 1: 실패 테스트 작성**

`ConfigTests.cs`:
```csharp
using System.Linq;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class ConfigTests
{
    static KeycloakConfig Base() => new() { ServerUrl = "https://kc.example.com", Realm = "r", ClientId = "c" };

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    public void Normalized_rejects_blank_required(string blank)
    {
        Assert.Throws<KeycloakConfigException>(() => (Base() with { ServerUrl = blank }).Normalized());
        Assert.Throws<KeycloakConfigException>(() => (Base() with { Realm = blank }).Normalized());
        Assert.Throws<KeycloakConfigException>(() => (Base() with { ClientId = blank }).Normalized());
    }

    [Fact]
    public void Normalized_strips_trailing_slash_and_applies_defaults()
    {
        var c = (Base() with { ServerUrl = "https://kc.example.com/" }).Normalized();
        Assert.Equal("https://kc.example.com", c.ServerUrl);
        Assert.Equal(30, c.ClockSkewSeconds);
        Assert.Equal(10_000, c.ConnectTimeoutMs);
        Assert.Equal(30_000, c.ReadTimeoutMs);
        Assert.Empty(c.Scopes);
    }

    [Fact]
    public void ToString_masks_client_secret()
    {
        var c = Base() with { ClientSecret = "supersecret" };
        var s = c.ToString();
        Assert.Contains("***", s);
        Assert.DoesNotContain("supersecret", s);
        Assert.Equal("supersecret", c.ClientSecret); // property access returns real value
    }

    [Fact]
    public void ToString_without_secret_has_no_mask()
    {
        Assert.DoesNotContain("***", Base().ToString());
    }

    [Fact]
    public void JsonSerialize_masks_client_secret()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(Base() with { ClientSecret = "supersecret" });
        Assert.Contains("***", json);
        Assert.DoesNotContain("supersecret", json);
    }
}
```
`TokensTests.cs`:
```csharp
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class TokensTests
{
    [Fact]
    public void Create_maps_and_computes_absolute_expiry()
    {
        var ts = TokenSet.Create("AT", "Bearer", 300, "RT", "IDT", "openid", issuedAtSeconds: 1_000_000);
        Assert.Equal("AT", ts.AccessToken);
        Assert.Equal("Bearer", ts.TokenType);
        Assert.Equal(300, ts.ExpiresIn);
        Assert.Equal(1_000_300, ts.ExpiresAt);
        Assert.Equal("IDT", ts.IdToken);
        Assert.Equal("openid", ts.Scope);
    }

    [Fact]
    public void Create_defaults_and_unknown_expiry()
    {
        var ts = TokenSet.Create("AT", tokenType: null, expiresIn: 0, refreshToken: null, idToken: null, scope: null, issuedAtSeconds: 1);
        Assert.Equal("Bearer", ts.TokenType);
        Assert.Null(ts.ExpiresAt);
        Assert.Null(ts.RefreshToken);
    }

    [Fact]
    public void Create_rejects_missing_access_token()
        => Assert.Throws<KeycloakAuthException>(() => TokenSet.Create("", "Bearer", 60, null, null, null, 0));

    [Fact]
    public void IsExpired_respects_skew_and_unknown()
    {
        var ts = TokenSet.Create("AT", "Bearer", 300, null, null, null, 1_000_000); // expiresAt=1_000_300
        Assert.False(ts.IsExpired(1_000_000, 30));
        Assert.True(ts.IsExpired(1_000_280, 30)); // 1_000_280+30 >= 1_000_300
        Assert.True(TokenSet.Create("AT", "Bearer", 0, null, null, null, 0).IsExpired(0, 0)); // unknown => expired
    }

    [Fact]
    public void ToString_masks_access_and_refresh()
    {
        var s = TokenSet.Create("SECRETat", "Bearer", 60, "SECRETrt", null, null, 0).ToString();
        Assert.Contains("***", s);
        Assert.DoesNotContain("SECRETat", s);
        Assert.DoesNotContain("SECRETrt", s);
    }

    [Fact]
    public void JsonSerialize_masks_tokens()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(
            TokenSet.Create("SECRETat", "Bearer", 60, "SECRETrt", null, null, 0));
        Assert.Contains("***", json);
        Assert.DoesNotContain("SECRETat", json);
        Assert.DoesNotContain("SECRETrt", json);
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현**

`KeycloakConfig.cs`:
```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Xzawed.Keycloak;

/// <summary>Immutable SDK configuration. Build with an object initializer, then pass to
/// <see cref="KeycloakClient.Create"/> which validates and normalizes it.</summary>
[JsonConverter(typeof(KeycloakConfigJsonConverter))]   // mask clientSecret in JSON/structured logging too
public sealed record KeycloakConfig
{
    public required string ServerUrl { get; init; }
    public required string Realm { get; init; }
    public required string ClientId { get; init; }
    public string? ClientSecret { get; init; }
    public IReadOnlyList<string> Scopes { get; init; } = Array.Empty<string>();
    public int ConnectTimeoutMs { get; init; } = 10_000;
    public int ReadTimeoutMs { get; init; } = 30_000;
    public int ClockSkewSeconds { get; init; } = 30;

    /// <summary>Validates required fields and returns a normalized copy (trailing '/' stripped from ServerUrl).</summary>
    public KeycloakConfig Normalized()
    {
        Require(ServerUrl, nameof(ServerUrl));
        Require(Realm, nameof(Realm));
        Require(ClientId, nameof(ClientId));
        return this with { ServerUrl = ServerUrl.TrimEnd('/') };
    }

    private static void Require(string value, string name)
    {
        if (string.IsNullOrWhiteSpace(value))
            throw new KeycloakConfigException($"Missing required config: {name}");
    }

    public override string ToString() =>
        $"KeycloakConfig {{ ServerUrl = {ServerUrl}, Realm = {Realm}, ClientId = {ClientId}, " +
        $"ClientSecret = {(ClientSecret is null ? "(none)" : Masking.Mask(ClientSecret))}, " +
        $"Scopes = [{string.Join(", ", Scopes)}] }}";
}

/// <summary>Masks clientSecret when a KeycloakConfig is JSON-serialized (e.g. Serilog destructuring).</summary>
internal sealed class KeycloakConfigJsonConverter : JsonConverter<KeycloakConfig>
{
    public override KeycloakConfig Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("KeycloakConfig is not deserializable from JSON.");

    public override void Write(Utf8JsonWriter writer, KeycloakConfig value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("serverUrl", value.ServerUrl);
        writer.WriteString("realm", value.Realm);
        writer.WriteString("clientId", value.ClientId);
        if (value.ClientSecret is null) writer.WriteNull("clientSecret");
        else writer.WriteString("clientSecret", Masking.Mask(value.ClientSecret));
        writer.WriteStartArray("scopes");
        foreach (var s in value.Scopes) writer.WriteStringValue(s);
        writer.WriteEndArray();
        writer.WriteEndObject();
    }
}
```
`Tokens.cs`:
```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Xzawed.Keycloak;

/// <summary>Token-endpoint response. AccessToken/RefreshToken are masked by ToString.
/// Isomorphic with the Java/Python/Node/Go TokenSet (absolute ExpiresAt in epoch seconds, IsExpired).</summary>
[JsonConverter(typeof(TokenSetJsonConverter))]   // mask access/refresh tokens in JSON/structured logging too
public sealed record TokenSet
{
    public required string AccessToken { get; init; }
    public required string TokenType { get; init; }
    public long ExpiresIn { get; init; }        // relative seconds
    public long? ExpiresAt { get; init; }        // absolute epoch seconds; null if unknown
    public string? RefreshToken { get; init; }
    public string? IdToken { get; init; }
    public string? Scope { get; init; }

    /// <summary>Maps raw token-response values to a TokenSet, computing absolute expiry.</summary>
    public static TokenSet Create(string accessToken, string? tokenType, long expiresIn,
                                  string? refreshToken, string? idToken, string? scope, long issuedAtSeconds)
    {
        if (string.IsNullOrEmpty(accessToken))
            throw new KeycloakAuthException("token response missing access_token");
        return new TokenSet
        {
            AccessToken = accessToken,
            TokenType = string.IsNullOrEmpty(tokenType) ? "Bearer" : tokenType,
            ExpiresIn = expiresIn,
            ExpiresAt = expiresIn > 0 ? issuedAtSeconds + expiresIn : null,
            RefreshToken = refreshToken,
            IdToken = idToken,
            Scope = scope,
        };
    }

    /// <summary>Conservative: an unknown ExpiresAt is treated as expired.</summary>
    public bool IsExpired(long nowSeconds, long skewSeconds) =>
        ExpiresAt is null || nowSeconds + skewSeconds >= ExpiresAt.Value;

    public override string ToString() =>
        $"TokenSet {{ TokenType = {TokenType}, ExpiresIn = {ExpiresIn}, " +
        $"AccessToken = {Masking.Mask(AccessToken)}, RefreshToken = {Masking.Mask(RefreshToken)} }}";
}

/// <summary>Trusted claim set of an access token that passed hardened validation.</summary>
public sealed record ValidatedToken(
    string Subject,
    IReadOnlyList<string> Audience,
    string Issuer,
    long? ExpiresAt,
    long? IssuedAt,
    IReadOnlyDictionary<string, object?> Claims);

/// <summary>RFC 7662 introspection response.</summary>
public sealed record IntrospectionResult(
    bool Active,
    string? Username,
    string? ClientId,
    IReadOnlyDictionary<string, object?> Claims);

/// <summary>Returned by CreateAuthorizationRequest to start a PKCE authorization-code flow.
/// The caller stores CodeVerifier/State/Nonce until the callback (the SDK is stateless).</summary>
public sealed record AuthorizationRequest(string Url, string CodeVerifier, string State, string Nonce);

/// <summary>Masks access/refresh tokens when a TokenSet is JSON-serialized (e.g. Serilog destructuring).</summary>
internal sealed class TokenSetJsonConverter : JsonConverter<TokenSet>
{
    public override TokenSet Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
        => throw new NotSupportedException("TokenSet is not deserializable from JSON.");

    public override void Write(Utf8JsonWriter writer, TokenSet value, JsonSerializerOptions options)
    {
        writer.WriteStartObject();
        writer.WriteString("tokenType", value.TokenType);
        writer.WriteNumber("expiresIn", value.ExpiresIn);
        if (value.ExpiresAt is { } ea) writer.WriteNumber("expiresAt", ea); else writer.WriteNull("expiresAt");
        writer.WriteString("accessToken", Masking.Mask(value.AccessToken));
        writer.WriteString("refreshToken", Masking.Mask(value.RefreshToken));
        writer.WriteEndObject();
    }
}
```

- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): KeycloakConfig(검증·정규화·ToString 마스킹) + 값 타입(TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest) (WBS 3)"`

---

### Task 4: 토큰 프로바이더 (ITokenProvider.cs)

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/ITokenProvider.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/TokenProviderTests.cs`

**Interfaces:** Produces: `interface ITokenProvider { Task<string> GetAccessTokenAsync(CancellationToken) }`, `interface ITokenSource { Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken) }`, `sealed class ClientCredentialsTokenProvider : ITokenProvider`(ctor `(ITokenSource, int skewSeconds=30, TimeProvider? clock=null)`, SemaphoreSlim single-flight, 만료 전 캐시, 실패 비캐시). Consumes: `TokenSet`(T3). 참조: Node `token-provider.ts`.

- [ ] **Step 1: 실패 테스트 작성**

`TokenProviderTests.cs`:
```csharp
using System.Threading;
using System.Threading.Tasks;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class TokenProviderTests
{
    sealed class CountingSource : ITokenSource
    {
        public int Calls;
        public long ExpiresIn = 300;
        private int _n;
        public Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
        {
            Interlocked.Increment(ref Calls);
            var tok = $"tok-{Interlocked.Increment(ref _n)}";
            return Task.FromResult(TokenSet.Create(tok, "Bearer", ExpiresIn, null, null, null, 0));
        }
    }

    [Fact]
    public async Task Caches_before_expiry_source_called_once()
    {
        var src = new CountingSource();
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        var a = await p.GetAccessTokenAsync();
        var b = await p.GetAccessTokenAsync();
        Assert.Equal(a, b);
        Assert.Equal(1, src.Calls);
    }

    [Fact]
    public async Task Concurrent_calls_single_flight()
    {
        var src = new CountingSource();
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        var results = await Task.WhenAll(Enumerable.Range(0, 20).Select(_ => p.GetAccessTokenAsync()));
        Assert.All(results, r => Assert.Equal(results[0], r));
        Assert.Equal(1, src.Calls);
    }

    [Fact]
    public async Task Expired_token_refetched()
    {
        var src = new CountingSource { ExpiresIn = 0 };
        var p = new ClientCredentialsTokenProvider(src, skewSeconds: 0);
        var a = await p.GetAccessTokenAsync();
        var b = await p.GetAccessTokenAsync();
        Assert.NotEqual(a, b);
        Assert.Equal(2, src.Calls);
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현** — SemaphoreSlim 이중검사(async lock 불가 → `lock` 사용 금지). 실패는 캐시 미갱신(예외가 대입 전 전파).

`ITokenProvider.cs`:
```csharp
namespace Xzawed.Keycloak;

/// <summary>Supplies access tokens to the admin facade — the only glue between auth and admin.
/// Consumers may inject a custom implementation.</summary>
public interface ITokenProvider
{
    Task<string> GetAccessTokenAsync(CancellationToken ct = default);
}

/// <summary>Obtains a fresh token set (e.g. via client-credentials). AuthClient implements this.</summary>
public interface ITokenSource
{
    Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default);
}

/// <summary>Caches a token and refreshes it before expiry, collapsing concurrent callers into one fetch.</summary>
public sealed class ClientCredentialsTokenProvider : ITokenProvider
{
    private readonly ITokenSource _source;
    private readonly int _skewSeconds;
    private readonly TimeProvider _clock;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _token;
    private DateTimeOffset _expiresAt = DateTimeOffset.MinValue;

    public ClientCredentialsTokenProvider(ITokenSource source, int skewSeconds = 30, TimeProvider? clock = null)
    {
        _source = source;
        _skewSeconds = skewSeconds;
        _clock = clock ?? TimeProvider.System;
    }

    public async Task<string> GetAccessTokenAsync(CancellationToken ct = default)
    {
        if (!IsExpired() && _token is { } cached) return cached;      // fast path, no gate

        await _gate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (!IsExpired() && _token is { } fresh) return fresh;    // double-check under gate

            var ts = await _source.ClientCredentialsTokenAsync(ct).ConfigureAwait(false); // failure => not cached
            _token = ts.AccessToken;
            _expiresAt = _clock.GetUtcNow().AddSeconds(Math.Max(0, ts.ExpiresIn - _skewSeconds));
            return ts.AccessToken;
        }
        finally { _gate.Release(); }
    }

    private bool IsExpired() => _clock.GetUtcNow() >= _expiresAt;
}
```

- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): ITokenProvider/ITokenSource + ClientCredentialsTokenProvider(SemaphoreSlim single-flight) (WBS 4)"`

---

### Task 5: OIDC 엔드포인트 (OidcEndpoints.cs)

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/OidcEndpoints.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/OidcEndpointsTests.cs`

**Interfaces:** Produces: `record OidcEndpoints(string Issuer, string Token, string Authorization, string Introspection, string EndSession, string Jwks)` + `static OidcEndpoints For(string serverUrl, string realm)`(네트워크 없음). 참조: Node `oidc-metadata.ts`.

- [ ] **Step 1: 실패 테스트 작성**

`OidcEndpointsTests.cs`:
```csharp
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class OidcEndpointsTests
{
    [Fact]
    public void Assembles_all_endpoints()
    {
        var e = OidcEndpoints.For("https://kc.example.com/", "myrealm");
        Assert.Equal("https://kc.example.com/realms/myrealm", e.Issuer);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/token", e.Token);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/auth", e.Authorization);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/token/introspect", e.Introspection);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/logout", e.EndSession);
        Assert.Equal("https://kc.example.com/realms/myrealm/protocol/openid-connect/certs", e.Jwks);
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현**

`OidcEndpoints.cs`:
```csharp
namespace Xzawed.Keycloak;

/// <summary>Keycloak OIDC endpoints assembled from convention — no network round-trip.</summary>
public sealed record OidcEndpoints(
    string Issuer, string Token, string Authorization, string Introspection, string EndSession, string Jwks)
{
    public static OidcEndpoints For(string serverUrl, string realm)
    {
        var issuer = $"{serverUrl.TrimEnd('/')}/realms/{realm}";
        var b = $"{issuer}/protocol/openid-connect";
        return new OidcEndpoints(issuer, $"{b}/token", $"{b}/auth", $"{b}/token/introspect", $"{b}/logout", $"{b}/certs");
    }
}
```

- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): OIDC 엔드포인트 조립(네트워크 없음) (WBS 5)"`

---

### Task 6: JwtValidator (Microsoft.IdentityModel 강화 — 🔴 보안 핵심)

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/JwtValidator.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/JwtValidatorTests.cs`

**Interfaces:** Produces: `sealed class JwtValidatorOptions { string Issuer; IReadOnlyList<string> Audiences; IReadOnlyList<string> AllowedAlgorithms=["RS256"]; int ClockSkewSeconds=30; int RefreshIntervalSeconds=30 }`; `sealed class JwtValidator` — public ctor `(string issuer, JwtValidatorOptions opts, HttpClient http)`(운영: `ConfigurationManager` JWKS), `internal ctor (TokenValidationParameters tvp)`(테스트 시임), `internal static TokenValidationParameters BuildParameters(string issuer, JwtValidatorOptions opts)`, `Task<ValidatedToken> ValidateAsync(string token, CancellationToken)`. Consumes: `Microsoft.IdentityModel.JsonWebTokens`·`.Tokens`·`.Protocols(.OpenIdConnect)`, `ValidatedToken`(T3), `KeycloakTokenValidationException`(T2). 참조: Node `jwt.ts`, `research_0.md`.

> **⚠️ 딥리서치 확정(반드시 준수)**: (1) `ValidateTokenAsync`는 **실패해도 예외를 던지지 않음** → `result.IsValid` 검사 후 `result.Exception`을 감싼다. (2) `ValidAlgorithms` 기본 `null`=**모든 alg 허용** → `["RS256"]`로 반드시 핀. (3) `ClockSkew` 기본 **5분** → 명시적으로 줄인다. (4) `RequireExpirationTime=true`로 **exp 없는 토큰 거부**(라이브러리 기본에 의존 금지 — 다른 4개 언어 동형). (5) JWKS는 `TVP.ConfigurationManager`(type `BaseConfigurationManager`)에 `ConfigurationManager<OpenIdConnectConfiguration>` 대입, `RefreshInterval`이 **DoS 스로틀**(kid 미스 시 재조회를 간격당 1회로 제한). (6) `HttpDocumentRetriever.RequireHttps` 기본 true → http 이슈어는 false. (7) `JsonWebTokenHandler.MapInboundClaims=false`(원시 클레임명 유지). (8) 클레임은 `(JsonWebToken)result.SecurityToken`에서 typed 접근.

- [ ] **Step 1: 실패 테스트 작성** — RSA 키로 테스트 토큰을 서명·검증(네트워크 없이 `IssuerSigningKey` 정적 주입). 강화 케이스 전부.

`JwtValidatorTests.cs`:
```csharp
using System.Security.Cryptography;
using System.Threading.Tasks;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class JwtValidatorTests
{
    private const string Issuer = "https://kc.example.com/realms/it-realm";
    private static readonly RsaSecurityKey Key = new(RSA.Create(2048)) { KeyId = "test-kid" };

    private static string Sign(string payloadJson, SecurityKey? key = null)
    {
        // ⚠️ SetDefaultTimesOnTokenCreation defaults TRUE and would auto-inject exp/iat/nbf,
        // invalidating the Missing_exp test. Disable it so the payload is emitted verbatim.
        var handler = new JsonWebTokenHandler { SetDefaultTimesOnTokenCreation = false };
        if (key is null) return handler.CreateToken(payloadJson); // unsigned => alg none
        var creds = new SigningCredentials(key, SecurityAlgorithms.RsaSha256);
        return handler.CreateToken(payloadJson, creds);
    }

    private static JwtValidator ValidatorWith(JwtValidatorOptions opts)
    {
        var tvp = JwtValidator.BuildParameters(Issuer, opts);
        tvp.IssuerSigningKey = Key;           // static key instead of ConfigurationManager (no network)
        tvp.ConfigurationManager = null;
        return new JwtValidator(tvp);          // internal test ctor
    }

    private static string PayloadJson(string aud, long expOffset = 300, string iss = Issuer)
        => $$"""{"iss":"{{iss}}","sub":"user-1","aud":{{aud}},"exp":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds() + expOffset}},"iat":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}}}""";

    [Fact]
    public async Task Valid_RS256_returns_claims()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateAsync(Sign(PayloadJson("\"it-client\""), Key));
        Assert.Equal("user-1", vt.Subject);
        Assert.Contains("it-client", vt.Audience);
        Assert.Equal(Issuer, vt.Issuer);
        Assert.True(vt.ExpiresAt > vt.IssuedAt);
    }

    [Fact]
    public async Task Multi_aud_membership_passes()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var vt = await v.ValidateAsync(Sign(PayloadJson("[\"it-client\",\"realm-management\"]"), Key));
        Assert.Contains("it-client", vt.Audience);
    }

    [Fact]
    public async Task Aud_not_member_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"other-client\""), Key)));
    }

    [Fact]
    public async Task Wrong_issuer_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", iss: "https://evil.example.com/realms/x"), Key)));
    }

    [Fact]
    public async Task Expired_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" }, ClockSkewSeconds = 0 });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\"", expOffset: -300), Key)));
    }

    [Fact]
    public async Task Missing_exp_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        var noExp = $$"""{"iss":"{{Issuer}}","sub":"u","aud":"it-client","iat":{{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}}}""";
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(() => v.ValidateAsync(Sign(noExp, Key)));
    }

    [Fact]
    public async Task Unsigned_none_rejected()
    {
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\""), key: null))); // alg none
    }

    [Fact]
    public async Task Algorithm_pin_violation_rejected()
    {
        // token signed RS256, but validator pins ES256 only
        var v = ValidatorWith(new JwtValidatorOptions { Issuer = Issuer, Audiences = new[] { "it-client" }, AllowedAlgorithms = new[] { "ES256" } });
        await Assert.ThrowsAsync<KeycloakTokenValidationException>(
            () => v.ValidateAsync(Sign(PayloadJson("\"it-client\""), Key)));
    }

    // Covers the PRODUCTION ctor (ConfigurationManager/HttpDocumentRetriever wiring) + §6 TLS/JWKS regression guard.
    // ConfigurationManager is lazy, so construction performs NO network call (parity with Node's "forJwksUri constructs lazily").
    [Theory]
    [InlineData("https://kc.example.com/realms/it-realm")]
    [InlineData("http://localhost:8080/realms/it-realm")]
    public void Production_ctor_builds_without_network(string issuer)
    {
        using var http = new HttpClient();
        var opts = new JwtValidatorOptions { Issuer = issuer, Audiences = new[] { "it-client" }, RefreshIntervalSeconds = 15 };
        var validator = new JwtValidator(issuer, opts, http); // no exception, no network (lazy ConfigurationManager)
        Assert.NotNull(validator);
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL(컴파일 실패).
- [ ] **Step 3: 구현**

`JwtValidator.cs`:
```csharp
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;

namespace Xzawed.Keycloak;

/// <summary>Options for hardened JWT validation. Defaults pin RS256 and a tight clock skew.</summary>
public sealed class JwtValidatorOptions
{
    public required string Issuer { get; init; }
    public required IReadOnlyList<string> Audiences { get; init; }
    public IReadOnlyList<string> AllowedAlgorithms { get; init; } = new[] { "RS256" };
    public int ClockSkewSeconds { get; init; } = 30;
    public int RefreshIntervalSeconds { get; init; } = 30;
}

/// <summary>Hardened Keycloak access-token validator: algorithm pinning, none/unsigned rejection,
/// exact issuer, audience membership, required expiry, bounded clock skew, DoS-safe rate-limited JWKS.</summary>
public sealed class JwtValidator
{
    private static readonly JsonWebTokenHandler Handler = new() { MapInboundClaims = false };
    private readonly TokenValidationParameters _tvp;

    /// <summary>Production: JWKS via ConfigurationManager (OIDC discovery), rate-limited refresh.</summary>
    public JwtValidator(string issuer, JwtValidatorOptions opts, HttpClient http)
    {
        _tvp = BuildParameters(issuer, opts);
        var docRetriever = new HttpDocumentRetriever(http)
        {
            RequireHttps = issuer.StartsWith("https", StringComparison.OrdinalIgnoreCase),
        };
        _tvp.ConfigurationManager = new ConfigurationManager<OpenIdConnectConfiguration>(
            $"{issuer}/.well-known/openid-configuration",
            new OpenIdConnectConfigurationRetriever(),
            docRetriever)
        {
            AutomaticRefreshInterval = TimeSpan.FromHours(12),
            RefreshInterval = TimeSpan.FromSeconds(opts.RefreshIntervalSeconds),
        };
    }

    internal JwtValidator(TokenValidationParameters tvp) => _tvp = tvp;

    /// <summary>Base parameters (everything except the key source). Callers add ConfigurationManager or IssuerSigningKey.</summary>
    internal static TokenValidationParameters BuildParameters(string issuer, JwtValidatorOptions opts) => new()
    {
        ValidAlgorithms = opts.AllowedAlgorithms.ToArray(),   // algorithm pin (reject header-chosen alg)
        RequireSignedTokens = true,                            // reject 'none'/unsigned
        RequireExpirationTime = true,                          // exp required
        ValidateLifetime = true,
        ClockSkew = TimeSpan.FromSeconds(opts.ClockSkewSeconds),
        ValidateIssuer = true,
        ValidIssuer = issuer,                                  // exact match
        ValidateAudience = true,
        ValidAudiences = opts.Audiences.ToArray(),             // membership (multi-aud safe)
        ValidateIssuerSigningKey = true,
    };

    public async Task<ValidatedToken> ValidateAsync(string token, CancellationToken ct = default)
    {
        TokenValidationResult result;
        try
        {
            result = await Handler.ValidateTokenAsync(token, _tvp).ConfigureAwait(false);
        }
        catch (Exception ex) // malformed token (SecurityTokenMalformedException) still throws from parse
        {
            throw new KeycloakTokenValidationException(ex.Message, ex);
        }
        if (!result.IsValid)
            throw new KeycloakTokenValidationException(result.Exception?.Message ?? "invalid token", result.Exception);

        var jwt = (JsonWebToken)result.SecurityToken;
        var claims = result.Claims.ToDictionary(kv => kv.Key, kv => (object?)kv.Value); // matches IntrospectAsync projection; no CS8620
        return new ValidatedToken(
            Subject: jwt.Subject,
            Audience: jwt.Audiences.ToArray(),
            Issuer: jwt.Issuer,
            ExpiresAt: jwt.TryGetPayloadValue<long>("exp", out var exp) ? exp : null,
            IssuedAt: jwt.TryGetPayloadValue<long>("iat", out var iat) ? iat : null,
            Claims: claims);
    }
}
```
> `ValidateTokenAsync`에 `CancellationToken` 오버로드가 없어 취소는 JWKS fetch에 간접 전달된다(운영 경로는 `http`의 `Timeout`으로 상한). 테스트 경로는 네트워크가 없다.

- [ ] **Step 4: 통과 확인** → PASS(강화 케이스 전부).
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): JwtValidator — Microsoft.IdentityModel 자체 강화(alg핀·none거부·iss·aud포함·exp필수·클록스큐·DoS-safe JWKS) (WBS 6)"`

---

### Task 7: AuthClient (Duende.IdentityModel 래핑) — 네트워크 경계

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/AuthClient.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/AuthClientTests.cs`

**Interfaces:** Produces: `sealed class AuthClient : ITokenSource` — ctor `(KeycloakConfig cfg, OidcEndpoints ep, JwtValidator validator, HttpClient http)`; 메서드 `AuthorizationRequest CreateAuthorizationRequest(string redirectUri)`(동기·수동 PKCE) · `Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken)` · `Task<TokenSet> ExchangeCodeAsync(string code, string redirectUri, string codeVerifier, string? nonce=null, CancellationToken)` · `Task<TokenSet> RefreshAsync(string refreshToken, CancellationToken)` · `Task<IntrospectionResult> IntrospectAsync(string token, CancellationToken)` · `Task LogoutAsync(string refreshToken, CancellationToken)` · `Task<ValidatedToken> ValidateAsync(string accessToken, CancellationToken)`. Consumes: `Duende.IdentityModel(.Client)`, `OidcEndpoints`(T5), `JwtValidator`(T6), `TokenSet`/`IntrospectionResult`/`AuthorizationRequest`(T3), `KeycloakAuthException`(T2). 참조: Node `auth.ts`, `research_2.md`.

> **⚠️ 딥리서치 확정**: (1) 모든 Duende 확장은 **예외 미던짐** → `resp.IsError` 검사, OAuth 코드는 `resp.Json?["error"]`(Keycloak은 잘못된 자격증명에 401→`ErrorType=Http`이라 `resp.Error`는 reason phrase). (2) **공개 PKCE 헬퍼 없음** → `CryptoRandom.CreateUniqueId(32, Base64Url)` verifier + 수동 base64url(SHA256) challenge. (3) authorize URL은 `new RequestUrl(ep.Authorization).CreateAuthorizeUrl(...)`. (4) introspection은 **`IntrospectTokenAsync`**(`RequestIntrospectionAsync` 아님). (5) back-channel logout 헬퍼 없음 → 수동 `FormUrlEncodedContent` POST(204 기대). (6) `TokenResponse.IdentityToken`(IdToken 아님), 절대만료 미노출(`ExpiresIn`만). (7) **NONCE**: Duende는 openid-client와 달리 id_token nonce를 자동검증하지 않으므로, `ExchangeCodeAsync`는 nonce가 주어지면 반환된 id_token의 `nonce` 클레임을 직접 대조(불일치→`KeycloakAuthException`). TLS는 `HttpClient`가 https 기본 검증·http 투명 처리(Node의 allowInsecure 로직 불필요).

- [ ] **Step 1: 실패 테스트 작성** — `WireMockServer`로 token/introspect/logout 엔드포인트 스텁(네트워크 격리). auth는 커버리지 제외 경계지만 매핑·PKCE·오류변환은 단위 검증.

`AuthClientTests.cs`:
```csharp
using System.Threading.Tasks;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class AuthClientTests : IDisposable
{
    private readonly WireMockServer _mock = WireMockServer.Start();
    private readonly HttpClient _http = new();

    private AuthClient Build(out KeycloakConfig cfg)
    {
        cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s",
                                   Scopes = new[] { "openid", "profile" } }.Normalized();
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(JwtValidator.BuildParameters(ep.Issuer,
            new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { "c" } }));
        return new AuthClient(cfg, ep, validator, _http);
    }

    public void Dispose() { _mock.Stop(); _http.Dispose(); }

    [Fact]
    public void CreateAuthorizationRequest_builds_s256_url_with_all_params()
    {
        var auth = Build(out _);
        var req = auth.CreateAuthorizationRequest("https://app/callback");
        Assert.Contains("response_type=code", req.Url);
        Assert.Contains("code_challenge_method=S256", req.Url);
        Assert.Contains("code_challenge=", req.Url);
        Assert.Contains("scope=openid%20profile", req.Url);
        Assert.Contains($"state={req.State}", req.Url);
        Assert.Contains($"nonce={req.Nonce}", req.Url);
        Assert.NotEmpty(req.CodeVerifier);
    }

    [Fact]
    public void CreateAuthorizationRequest_values_differ_per_call()
    {
        var auth = Build(out _);
        var a = auth.CreateAuthorizationRequest("https://app/cb");
        var b = auth.CreateAuthorizationRequest("https://app/cb");
        Assert.NotEqual(a.CodeVerifier, b.CodeVerifier);
        Assert.NotEqual(a.State, b.State);
        Assert.NotEqual(a.Nonce, b.Nonce);
    }

    [Fact]
    public async Task ClientCredentialsToken_maps_response()
    {
        var auth = Build(out var cfg);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { access_token = "AT", token_type = "Bearer", expires_in = 300, scope = "openid" }));
        var ts = await auth.ClientCredentialsTokenAsync();
        Assert.Equal("AT", ts.AccessToken);
        Assert.Equal(300, ts.ExpiresIn);
        Assert.NotNull(ts.ExpiresAt);
    }

    [Fact]
    public async Task ClientCredentialsToken_error_wrapped()
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(401).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { error = "invalid_client", error_description = "bad creds" }));
        var ex = await Assert.ThrowsAsync<KeycloakAuthException>(() => auth.ClientCredentialsTokenAsync());
        Assert.Equal("invalid_client", ex.OAuthError);
    }

    [Fact]
    public async Task Introspect_maps_active_and_fields()
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/token/introspect").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { active = true, username = "alice", client_id = "c" }));
        var ir = await auth.IntrospectAsync("some-token");
        Assert.True(ir.Active);
        Assert.Equal("alice", ir.Username);
        Assert.Equal("c", ir.ClientId);
    }

    [Fact]
    public async Task Logout_posts_and_errors_on_non_2xx()
    {
        var auth = Build(out _);
        _mock.Given(Request.Create().WithPath("/realms/r/protocol/openid-connect/logout").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(400));
        await Assert.ThrowsAsync<KeycloakAuthException>(() => auth.LogoutAsync("rt"));
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현**

`AuthClient.cs`:
```csharp
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Duende.IdentityModel;
using Duende.IdentityModel.Client;

namespace Xzawed.Keycloak;

/// <summary>OIDC/OAuth2 facade wrapping Duende.IdentityModel. Also serves as the default
/// client-credentials <see cref="ITokenSource"/> for the admin facade.</summary>
public sealed class AuthClient : ITokenSource
{
    private readonly KeycloakConfig _cfg;
    private readonly OidcEndpoints _ep;
    private readonly JwtValidator _validator;
    private readonly HttpClient _http;

    public AuthClient(KeycloakConfig cfg, OidcEndpoints ep, JwtValidator validator, HttpClient http)
    {
        _cfg = cfg; _ep = ep; _validator = validator; _http = http;
    }

    /// <summary>Starts a PKCE (S256) authorization-code flow. Synchronous — no network.</summary>
    public AuthorizationRequest CreateAuthorizationRequest(string redirectUri)
    {
        var codeVerifier = CryptoRandom.CreateUniqueId(32, CryptoRandom.OutputFormat.Base64Url);
        var codeChallenge = Base64Url(SHA256.HashData(Encoding.ASCII.GetBytes(codeVerifier)));
        var state = CryptoRandom.CreateUniqueId(16, CryptoRandom.OutputFormat.Base64Url);
        var nonce = CryptoRandom.CreateUniqueId(16, CryptoRandom.OutputFormat.Base64Url);
        var scope = _cfg.Scopes.Count > 0 ? string.Join(' ', _cfg.Scopes) : "openid";

        var url = new RequestUrl(_ep.Authorization).CreateAuthorizeUrl(
            clientId: _cfg.ClientId,
            responseType: OidcConstants.ResponseTypes.Code,
            scope: scope,
            redirectUri: redirectUri,
            state: state,
            nonce: nonce,
            codeChallenge: codeChallenge,
            codeChallengeMethod: OidcConstants.CodeChallengeMethods.Sha256);

        return new AuthorizationRequest(url, codeVerifier, state, nonce);
    }

    public async Task<TokenSet> ClientCredentialsTokenAsync(CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var resp = await _http.RequestClientCredentialsTokenAsync(new ClientCredentialsTokenRequest
        {
            Address = _ep.Token,
            ClientId = _cfg.ClientId,
            ClientSecret = _cfg.ClientSecret,
            Scope = _cfg.Scopes.Count > 0 ? string.Join(' ', _cfg.Scopes) : null,
        }, ct).ConfigureAwait(false);
        return ToTokenSet(resp, "Client credentials grant failed", issuedAt);
    }

    public async Task<TokenSet> ExchangeCodeAsync(string code, string redirectUri, string codeVerifier,
                                                  string? nonce = null, CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var resp = await _http.RequestAuthorizationCodeTokenAsync(new AuthorizationCodeTokenRequest
        {
            Address = _ep.Token,
            ClientId = _cfg.ClientId,
            ClientSecret = _cfg.ClientSecret,
            Code = code,
            RedirectUri = redirectUri,
            CodeVerifier = codeVerifier,
        }, ct).ConfigureAwait(false);
        var tokens = ToTokenSet(resp, "Authorization code exchange failed", issuedAt);

        // NONCE: Duende does not auto-validate the id_token (unlike openid-client). Fully validate it
        // (signature/iss/aud/exp via the hardened validator — Keycloak id_token aud == clientId, which
        // the validator is already configured for) and then check the nonce claim. Fails CLOSED when a
        // nonce was supplied (CreateAuthorizationRequest always issues one), matching the Node posture.
        if (nonce is not null && tokens.IdToken is { } idToken)
        {
            ValidatedToken idt;
            try { idt = await _validator.ValidateAsync(idToken, ct).ConfigureAwait(false); }
            catch (KeycloakTokenValidationException ex) { throw new KeycloakAuthException("id_token validation failed", ex); }
            if (!idt.Claims.TryGetValue("nonce", out var n) || n as string != nonce)
                throw new KeycloakAuthException("id_token nonce mismatch");
        }
        return tokens;
    }

    public async Task<TokenSet> RefreshAsync(string refreshToken, CancellationToken ct = default)
    {
        var issuedAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var resp = await _http.RequestRefreshTokenAsync(new RefreshTokenRequest
        {
            Address = _ep.Token,
            ClientId = _cfg.ClientId,
            ClientSecret = _cfg.ClientSecret,
            RefreshToken = refreshToken,
        }, ct).ConfigureAwait(false);
        return ToTokenSet(resp, "Token refresh failed", issuedAt);
    }

    public async Task<IntrospectionResult> IntrospectAsync(string token, CancellationToken ct = default)
    {
        var resp = await _http.IntrospectTokenAsync(new TokenIntrospectionRequest
        {
            Address = _ep.Introspection,
            ClientId = _cfg.ClientId,
            ClientSecret = _cfg.ClientSecret,
            Token = token,
        }, ct).ConfigureAwait(false);
        if (resp.IsError)
            throw new KeycloakAuthException($"Token introspection failed: {resp.Error}", resp.Exception);

        var claims = resp.Claims.GroupBy(c => c.Type)
            .ToDictionary(g => g.Key, g => (object?)(g.Count() == 1 ? g.First().Value : g.Select(c => c.Value).ToArray()));
        return new IntrospectionResult(resp.IsActive, resp.UserName, resp.ClientId, claims);
    }

    public async Task LogoutAsync(string refreshToken, CancellationToken ct = default)
    {
        var form = new Dictionary<string, string>
        {
            ["client_id"] = _cfg.ClientId,
            ["refresh_token"] = refreshToken,
        };
        if (_cfg.ClientSecret is { } secret) form["client_secret"] = secret;

        HttpResponseMessage resp;
        try
        {
            using var content = new FormUrlEncodedContent(form);
            resp = await _http.PostAsync(_ep.EndSession, content, ct).ConfigureAwait(false);
        }
        catch (HttpRequestException ex)
        {
            throw new KeycloakAuthException($"Logout request error: {ex.Message}", ex);
        }
        if (!resp.IsSuccessStatusCode)
            throw new KeycloakAuthException($"Logout failed (HTTP {(int)resp.StatusCode})");
    }

    public Task<ValidatedToken> ValidateAsync(string accessToken, CancellationToken ct = default)
        => _validator.ValidateAsync(accessToken, ct);

    private static TokenSet ToTokenSet(TokenResponse resp, string failureMessage, long issuedAtSeconds)
    {
        if (resp.IsError)
            throw new KeycloakAuthException($"{failureMessage}: {resp.Error}", resp.Exception) { OAuthError = OAuthErrorOf(resp) };
        return TokenSet.Create(resp.AccessToken!, resp.TokenType, resp.ExpiresIn,
                               resp.RefreshToken, resp.IdentityToken, resp.Scope, issuedAtSeconds);
    }

    // Keycloak returns 401 for bad client creds => ErrorType=Http (resp.Error = reason phrase),
    // so read the OAuth code from the JSON body.
    private static string? OAuthErrorOf(TokenResponse resp)
    {
        if (resp.Json is JsonElement j && j.ValueKind == JsonValueKind.Object
            && j.TryGetProperty("error", out var e) && e.ValueKind == JsonValueKind.String)
            return e.GetString();
        return resp.Error;
    }

    private static string Base64Url(byte[] bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}
```
> ⚠️ auth.cs는 네트워크 경계 → 커버리지 omit(스펙 §7). 로직(PKCE·매핑·오류변환)은 WireMock 단위테스트로, 실호출은 통합테스트(Task 10)로 검증.

- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): AuthClient — Duende.IdentityModel 래핑(PKCE·client-credentials·exchangeCode+nonce·refresh·introspect·logout·validate) (WBS 7)"`

---

### Task 8: AdminClient + 5 리소스 (Keycloak.AuthServices.Sdk 2.7.0 타입드 + raw REST) — 네트워크 경계

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/Admin/BearerHandler.cs`, `Admin/AdminClient.cs`, `Admin/UsersResource.cs`, `Admin/GroupsResource.cs`, `Admin/RealmsResource.cs`, `Admin/ClientsResource.cs`, `Admin/RolesResource.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/AdminClientTests.cs`

**Interfaces:** Produces (namespace `Xzawed.Keycloak.Admin`): `sealed class AdminClient : IAsyncDisposable` — `static Task<AdminClient> CreateAsync(KeycloakConfig cfg, ITokenProvider tokenProvider, CancellationToken)`, props `Users`/`Clients`/`Realms`/`Roles`/`Groups`, `IKeycloakClient Raw`, `string Realm`, 경계 헬퍼(internal) `CallTypedAsync`/`SendRawAsync`/`GetJsonAsync`/`CreateReturningIdAsync`; 5개 리소스 클래스 각 `CreateAsync/GetAsync/…`. Consumes: `Keycloak.AuthServices.Sdk(.Admin(.Models/.Requests.*))`, `ITokenProvider`(T4), `KeycloakConfig`(T3), 예외·`KeycloakErrorMapping`(T2). 참조: Node `admin/`, `research_4.md`.

> **⚠️ 딥리서치 확정**: (1) 타입드 인터페이스는 **users/groups/realm-get만**(`IKeycloakUserClient`/`IKeycloakGroupClient`/`IKeycloakRealmClient`). clients/roles/realm-CRUD는 raw REST. (2) 편의 `…Async`는 **default interface method** → `IKeycloakClient`로 타입한 참조에서만 호출 가능(`new KeycloakClient(http)`를 `IKeycloakClient`로 캐스팅). (3) `CreateUserAsync`/`CreateGroupAsync`는 **void** → `…WithResponseAsync` + `resp.Headers.Location.Segments[^1]`로 id 취득. (4) 오류는 편의 메서드에서 `KeycloakHttpClientException{int StatusCode}`, 전송 실패는 `HttpRequestException`. (5) `HttpClient.BaseAddress`는 **반드시 `/`로 끝나야** 함(상대 경로 `admin/realms/{realm}/…`). (6) representation은 `Keycloak.AuthServices.Sdk.Admin.Models` — 전부 nullable + `[JsonIgnore(WhenWritingDefault)]`.

- [ ] **Step 1: 실패 테스트 작성** — WireMock으로 admin REST 스텁(raw 경로) + secret 가드. 타입드 경로는 E2E(Task 10)로 검증.

`AdminClientTests.cs`:
```csharp
using System.Threading.Tasks;
using WireMock.RequestBuilders;
using WireMock.ResponseBuilders;
using WireMock.Server;
using Xunit;
using Xzawed.Keycloak;
using Xzawed.Keycloak.Admin;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Sdk.Tests;

public class AdminClientTests : IDisposable
{
    private readonly WireMockServer _mock = WireMockServer.Start();

    private sealed class FixedToken : ITokenProvider
    {
        public Task<string> GetAccessTokenAsync(System.Threading.CancellationToken ct = default) => Task.FromResult("test-token");
    }

    private Task<AdminClient> BuildAsync()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c", ClientSecret = "s" }.Normalized();
        return AdminClient.CreateAsync(cfg, new FixedToken());
    }

    public void Dispose() => _mock.Stop();

    [Fact]
    public async Task Create_without_secret_throws_before_network()
    {
        var cfg = new KeycloakConfig { ServerUrl = _mock.Urls[0], Realm = "r", ClientId = "c" }.Normalized();
        await Assert.ThrowsAsync<KeycloakConfigException>(() => AdminClient.CreateAsync(cfg, new FixedToken()));
    }

    [Fact]
    public async Task Clients_create_parses_location_id()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/clients").UsingPost())
             .RespondWith(Response.Create().WithStatusCode(201)
                 .WithHeader("Location", $"{_mock.Urls[0]}/admin/realms/r/clients/abc-123"));
        var id = await admin.Clients.CreateAsync(new ClientRepresentation { ClientId = "svc" });
        Assert.Equal("abc-123", id);
    }

    [Fact]
    public async Task Clients_get_404_maps_to_NotFound()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/clients/missing").UsingGet())
             .RespondWith(Response.Create().WithStatusCode(404));
        await Assert.ThrowsAsync<KeycloakNotFoundException>(() => admin.Clients.GetAsync("missing"));
    }

    [Fact]
    public async Task Bearer_token_attached_on_raw_calls()
    {
        await using var admin = await BuildAsync();
        _mock.Given(Request.Create().WithPath("/admin/realms/r/roles/app-admin").UsingGet()
                 .WithHeader("Authorization", "Bearer test-token"))
             .RespondWith(Response.Create().WithStatusCode(200).WithHeader("Content-Type", "application/json")
                 .WithBodyAsJson(new { name = "app-admin" }));
        var role = await admin.Roles.GetAsync("app-admin");
        Assert.Equal("app-admin", role.Name);
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현**

`Admin/BearerHandler.cs`:
```csharp
using System.Net.Http.Headers;

namespace Xzawed.Keycloak.Admin;

/// <summary>Attaches a fresh bearer token from the token provider on every admin request.</summary>
internal sealed class BearerHandler : DelegatingHandler
{
    private readonly ITokenProvider _tokenProvider;
    public BearerHandler(ITokenProvider tokenProvider) => _tokenProvider = tokenProvider;

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", await _tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false));
        return await base.SendAsync(request, ct).ConfigureAwait(false);
    }
}
```
`Admin/AdminClient.cs`:
```csharp
using System.Net.Http.Json;
using Keycloak.AuthServices.Sdk;              // KeycloakHttpClientException
using Keycloak.AuthServices.Sdk.Admin;         // IKeycloakClient
// ⚠️ Alias REQUIRED: inside namespace Xzawed.Keycloak.Admin, the bare name `KeycloakClient` binds to the
// enclosing-namespace facade Xzawed.Keycloak.KeycloakClient (private ctor) — an enclosing-namespace type
// wins over an inner `using`. `new KeycloakClient(http)` would be CS1729. Alias to the library type.
using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;

namespace Xzawed.Keycloak.Admin;

/// <summary>Admin REST facade. users/groups/realm-get go through the typed Keycloak.AuthServices client;
/// clients/roles/realm-CRUD use raw REST on the same bearer-authed HttpClient. Lower-library errors are
/// converted to the KeycloakException hierarchy at the boundary.</summary>
public sealed class AdminClient : IAsyncDisposable, IDisposable
{
    private readonly HttpClient _http;          // bearer-authed via BearerHandler; owned
    private readonly IKeycloakClient _typed;     // typed as interface => default interface methods callable
    public string Realm { get; }

    public UsersResource Users { get; }
    public ClientsResource Clients { get; }
    public RealmsResource Realms { get; }
    public RolesResource Roles { get; }
    public GroupsResource Groups { get; }

    private AdminClient(HttpClient http, string realm)
    {
        _http = http;
        _typed = new KcAdminClient(http);        // Keycloak.AuthServices concrete, held as IKeycloakClient
        Realm = realm;
        Users = new UsersResource(this);
        Clients = new ClientsResource(this);
        Realms = new RealmsResource(this);
        Roles = new RolesResource(this);
        Groups = new GroupsResource(this);
    }

    /// <summary>Builds a bearer-authed admin client and authenticates eagerly (client-credentials).
    /// Faults before any network if clientSecret is absent.</summary>
    public static async Task<AdminClient> CreateAsync(KeycloakConfig cfg, ITokenProvider tokenProvider, CancellationToken ct = default)
    {
        if (cfg.ClientSecret is null)
            throw new KeycloakConfigException("clientSecret is required for the admin client (client-credentials).");
        var http = new HttpClient(new BearerHandler(tokenProvider) { InnerHandler = new HttpClientHandler() })
        {
            BaseAddress = new Uri(cfg.ServerUrl.TrimEnd('/') + "/"),   // must end with '/'
            Timeout = TimeSpan.FromMilliseconds(cfg.ReadTimeoutMs),
        };
        try { await tokenProvider.GetAccessTokenAsync(ct).ConfigureAwait(false); } // authenticate on first admin build (§5.1)
        catch { http.Dispose(); throw; }                                            // don't leak the client on failed warm-up
        return new AdminClient(http, cfg.Realm);
    }

    /// <summary>Escape hatch: the underlying typed admin client (documented hiding-exception).</summary>
    public IKeycloakClient Raw => _typed;

    // ---- boundary helpers ----
    internal async Task<T> CallTypedAsync<T>(Func<IKeycloakClient, Task<T>> fn)
    {
        try { return await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
    }

    internal async Task CallTypedAsync(Func<IKeycloakClient, Task> fn)
    {
        try { await fn(_typed).ConfigureAwait(false); }
        catch (KeycloakHttpClientException ex) { throw KeycloakErrorMapping.MapHttpError(ex.StatusCode, ex.Response?.ErrorDescription ?? ex.HttpResponse ?? ex.Message, ex); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
    }

    internal async Task<string> CreateReturningIdAsync(Func<IKeycloakClient, Task<HttpResponseMessage>> fn, CancellationToken ct)
    {
        HttpResponseMessage resp;
        try { resp = await fn(_typed).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        return await IdFromLocationAsync(resp, ct).ConfigureAwait(false);
    }

    internal async Task<HttpResponseMessage> SendRawAsync(HttpRequestMessage req, CancellationToken ct)
    {
        HttpResponseMessage resp;
        try { resp = await _http.SendAsync(req, ct).ConfigureAwait(false); }
        catch (HttpRequestException ex) { throw new KeycloakTransportException("admin request failed", ex); }
        if (!resp.IsSuccessStatusCode)
            throw KeycloakErrorMapping.MapHttpError((int)resp.StatusCode, await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        return resp;
    }

    internal async Task<T> GetJsonAsync<T>(string relativeUrl, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, relativeUrl);
        var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        var value = await resp.Content.ReadFromJsonAsync<T>(cancellationToken: ct).ConfigureAwait(false);
        return value ?? throw new KeycloakNotFoundException($"empty response body for {relativeUrl}");
    }

    internal async Task<string> CreateRawReturningIdAsync(string relativeUrl, object body, CancellationToken ct)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, relativeUrl) { Content = JsonContent.Create(body) };
        var resp = await SendRawAsync(req, ct).ConfigureAwait(false);
        return await IdFromLocationAsync(resp, ct).ConfigureAwait(false);
    }

    private async Task<string> IdFromLocationAsync(HttpResponseMessage resp, CancellationToken ct)
    {
        if (!resp.IsSuccessStatusCode)
            throw KeycloakErrorMapping.MapHttpError((int)resp.StatusCode, await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
        var id = resp.Headers.Location?.Segments[^1]?.TrimEnd('/');
        return string.IsNullOrEmpty(id)
            ? throw new KeycloakAdminException(500, "resource created but no id returned in Location header")
            : id;
    }

    public void Dispose() => _http.Dispose();

    public ValueTask DisposeAsync()
    {
        Dispose();
        return ValueTask.CompletedTask;
    }
}
```
`Admin/UsersResource.cs`:
```csharp
using Keycloak.AuthServices.Sdk.Admin.Models;
using Keycloak.AuthServices.Sdk.Admin.Requests.Users;

namespace Xzawed.Keycloak.Admin;

public sealed class UsersResource
{
    private readonly AdminClient _a;
    internal UsersResource(AdminClient a) => _a = a;

    public Task<string> CreateAsync(UserRepresentation user, CancellationToken ct = default)
        => _a.CreateReturningIdAsync(c => c.CreateUserWithResponseAsync(_a.Realm, user, ct), ct);

    public Task<UserRepresentation> GetAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.GetUserAsync(_a.Realm, id, cancellationToken: ct));   // 404 => NotFound

    public Task<IReadOnlyList<UserRepresentation>> SearchAsync(string? username, int first = 0, int max = 100, CancellationToken ct = default)
        => _a.CallTypedAsync(async c =>
            (IReadOnlyList<UserRepresentation>)(await c.GetUsersAsync(_a.Realm,
                new GetUsersRequestParameters { Username = username, First = first, Max = max }, ct)).ToList());

    public Task UpdateAsync(string id, UserRepresentation user, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.UpdateUserAsync(_a.Realm, id, user, ct));

    public Task DeleteAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.DeleteUserAsync(_a.Realm, id, ct));
}
```
`Admin/GroupsResource.cs`:
```csharp
using Keycloak.AuthServices.Sdk.Admin.Models;
using Keycloak.AuthServices.Sdk.Admin.Requests.Groups;

namespace Xzawed.Keycloak.Admin;

public sealed class GroupsResource
{
    private readonly AdminClient _a;
    internal GroupsResource(AdminClient a) => _a = a;

    public Task<string> CreateAsync(GroupRepresentation group, CancellationToken ct = default)
        => _a.CreateReturningIdAsync(c => c.CreateGroupWithResponseAsync(_a.Realm, group, ct), ct);

    public Task<GroupRepresentation> GetAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.GetGroupAsync(_a.Realm, id, ct));

    public Task<IReadOnlyList<GroupRepresentation>> ListAsync(int first = 0, int max = 100, CancellationToken ct = default)
        => _a.CallTypedAsync(async c =>
            (IReadOnlyList<GroupRepresentation>)(await c.GetGroupsAsync(_a.Realm,
                new GetGroupsRequestParameters { First = first, Max = max }, ct)).ToList());

    public Task DeleteAsync(string id, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.DeleteGroupAsync(_a.Realm, id, ct));
}
```
`Admin/RealmsResource.cs`:
```csharp
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Admin;

/// <summary>Realm resource — NOT realm-scoped; the realm name is the argument. get is typed; create/delete are raw.</summary>
public sealed class RealmsResource
{
    private readonly AdminClient _a;
    internal RealmsResource(AdminClient a) => _a = a;

    public async Task CreateAsync(RealmRepresentation realm, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, "admin/realms")
        { Content = System.Net.Http.Json.JsonContent.Create(realm) };
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }

    public Task<RealmRepresentation> GetAsync(string realmName, CancellationToken ct = default)
        => _a.CallTypedAsync(c => c.GetRealmAsync(realmName, ct));

    public async Task DeleteAsync(string realmName, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, $"admin/realms/{Uri.EscapeDataString(realmName)}");
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }
}
```
`Admin/ClientsResource.cs`:
```csharp
using System.Net.Http.Json;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Admin;

/// <summary>Clients resource — raw REST (no typed client in Keycloak.AuthServices). id = internal UUID.</summary>
public sealed class ClientsResource
{
    private readonly AdminClient _a;
    internal ClientsResource(AdminClient a) => _a = a;

    public Task<string> CreateAsync(ClientRepresentation client, CancellationToken ct = default)
        => _a.CreateRawReturningIdAsync($"admin/realms/{_a.Realm}/clients", client, ct);

    public Task<ClientRepresentation> GetAsync(string id, CancellationToken ct = default)
        => _a.GetJsonAsync<ClientRepresentation>($"admin/realms/{_a.Realm}/clients/{id}", ct);

    public async Task<IReadOnlyList<ClientRepresentation>> FindByClientIdAsync(string clientId, CancellationToken ct = default)
        => await _a.GetJsonAsync<List<ClientRepresentation>>(
            $"admin/realms/{_a.Realm}/clients?clientId={Uri.EscapeDataString(clientId)}", ct).ConfigureAwait(false);

    public async Task UpdateAsync(string id, ClientRepresentation client, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Put, $"admin/realms/{_a.Realm}/clients/{id}")
        { Content = JsonContent.Create(client) };
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }

    public async Task DeleteAsync(string id, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, $"admin/realms/{_a.Realm}/clients/{id}");
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }
}
```
`Admin/RolesResource.cs`:
```csharp
using System.Net.Http.Json;
using Keycloak.AuthServices.Sdk.Admin.Models;

namespace Xzawed.Keycloak.Admin;

/// <summary>Realm roles — raw REST, addressed by NAME (API deviation vs id-addressed users/clients/groups).</summary>
public sealed class RolesResource
{
    private readonly AdminClient _a;
    internal RolesResource(AdminClient a) => _a = a;

    public async Task CreateAsync(RoleRepresentation role, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Post, $"admin/realms/{_a.Realm}/roles")
        { Content = JsonContent.Create(role) };
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }

    public Task<RoleRepresentation> GetAsync(string name, CancellationToken ct = default)
        => _a.GetJsonAsync<RoleRepresentation>($"admin/realms/{_a.Realm}/roles/{Uri.EscapeDataString(name)}", ct);

    public async Task<IReadOnlyList<RoleRepresentation>> ListAsync(CancellationToken ct = default)
        => await _a.GetJsonAsync<List<RoleRepresentation>>($"admin/realms/{_a.Realm}/roles", ct).ConfigureAwait(false);

    public async Task DeleteAsync(string name, CancellationToken ct = default)
    {
        using var req = new HttpRequestMessage(HttpMethod.Delete, $"admin/realms/{_a.Realm}/roles/{Uri.EscapeDataString(name)}");
        await _a.SendRawAsync(req, ct).ConfigureAwait(false);
    }
}
```

- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): AdminClient + 5 리소스(users/groups 타입드·clients/roles/realm raw REST) + BearerHandler + 경계 변환 + Raw (WBS 8)"`

---

### Task 9: KeycloakClient 통합 진입점 + AddKeycloak DI 확장

**Files:** Create `dotnet/src/Xzawed.Keycloak.Sdk/KeycloakClient.cs`, `dotnet/src/Xzawed.Keycloak.Sdk/ServiceCollectionExtensions.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/KeycloakClientTests.cs`

**Interfaces:** Produces: `sealed class KeycloakClient : IAsyncDisposable` — `static KeycloakClient Create(KeycloakConfig config)`, `AuthClient Auth { get; }`(즉시), `Task<AdminClient> AdminAsync(CancellationToken)`(지연·캐시·SemaphoreSlim single-flight·실패 비캐시), `ValueTask DisposeAsync()`; `static class ServiceCollectionExtensions` — `IServiceCollection AddKeycloak(this IServiceCollection, KeycloakConfig)`. Consumes: T3·T4·T6·T7·T8. 참조: Node `client.ts`, Java `KeycloakClient`, `research_1.md`(IAsyncDisposable·AddKeycloak).

- [ ] **Step 1: 실패 테스트 작성** — Auth 즉시 조립·Admin 지연·secret 없으면 AdminAsync에서 `KeycloakConfigException`·`await using` 처분. (실제 admin 생성은 네트워크라 clientSecret 없는 경로만 단위; 실생성은 통합테스트.)

`KeycloakClientTests.cs`:
```csharp
using System.Threading.Tasks;
using Microsoft.Extensions.DependencyInjection;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests;

public class KeycloakClientTests
{
    [Fact]
    public void Create_validates_and_builds_auth_eagerly()
    {
        var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = "https://kc.example.com/", Realm = "r", ClientId = "c" });
        Assert.NotNull(kc.Auth);
    }

    [Fact]
    public void Create_rejects_missing_required()
        => Assert.Throws<KeycloakConfigException>(
            () => KeycloakClient.Create(new KeycloakConfig { ServerUrl = "", Realm = "r", ClientId = "c" }));

    [Fact]
    public async Task AdminAsync_without_secret_throws_config()
    {
        await using var kc = KeycloakClient.Create(new KeycloakConfig { ServerUrl = "https://kc.example.com", Realm = "r", ClientId = "c" });
        await Assert.ThrowsAsync<KeycloakConfigException>(() => kc.AdminAsync());
    }

    [Fact]
    public void AddKeycloak_registers_singleton_client()
    {
        var services = new ServiceCollection();
        services.AddKeycloak(new KeycloakConfig { ServerUrl = "https://kc.example.com", Realm = "r", ClientId = "c" });
        using var sp = services.BuildServiceProvider();
        var kc = sp.GetRequiredService<KeycloakClient>();
        Assert.NotNull(kc.Auth);
        Assert.Same(kc, sp.GetRequiredService<KeycloakClient>()); // singleton
    }
}
```

- [ ] **Step 2: 실패 확인** → FAIL.
- [ ] **Step 3: 구현**

`KeycloakClient.cs`:
```csharp
using Xzawed.Keycloak.Admin;

namespace Xzawed.Keycloak;

/// <summary>Unified entry point. Auth is built eagerly; the admin facade is built lazily on first
/// AdminAsync, cached, and single-flighted. Dispose (await using / using) releases owned resources.</summary>
public sealed class KeycloakClient : IAsyncDisposable, IDisposable
{
    private readonly KeycloakConfig _config;
    private readonly HttpClient _httpClient;      // owned; used by Auth + JwtValidator
    private readonly SemaphoreSlim _adminGate = new(1, 1);
    private AdminClient? _admin;
    private ITokenProvider? _adminTokenProvider;

    public AuthClient Auth { get; }

    private KeycloakClient(KeycloakConfig config, HttpClient httpClient, AuthClient auth)
    {
        _config = config; _httpClient = httpClient; Auth = auth;
    }

    public static KeycloakClient Create(KeycloakConfig config)
    {
        var cfg = config.Normalized();                 // validates + strips trailing slash
        // Single long-lived HttpClient (idiomatic for a one-server SDK client); PooledConnectionLifetime
        // recycles connections so a captured client still picks up DNS changes (the IHttpClientFactory concern).
        var http = new HttpClient(new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.FromMinutes(5) })
        {
            Timeout = TimeSpan.FromMilliseconds(cfg.ReadTimeoutMs),
        };
        var ep = OidcEndpoints.For(cfg.ServerUrl, cfg.Realm);
        var validator = new JwtValidator(ep.Issuer,
            new JwtValidatorOptions { Issuer = ep.Issuer, Audiences = new[] { cfg.ClientId }, ClockSkewSeconds = cfg.ClockSkewSeconds },
            http);
        var auth = new AuthClient(cfg, ep, validator, http);
        return new KeycloakClient(cfg, http, auth);
    }

    /// <summary>Lazily builds the admin facade (client-credentials). Throws before any network if clientSecret is absent.</summary>
    public async Task<AdminClient> AdminAsync(CancellationToken ct = default)
    {
        if (_config.ClientSecret is null)
            throw new KeycloakConfigException("clientSecret is required to use the admin client.");
        if (_admin is { } cached) return cached;

        await _adminGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (_admin is { } fresh) return fresh;      // double-check under gate
            _adminTokenProvider ??= new ClientCredentialsTokenProvider(Auth, _config.ClockSkewSeconds);
            var admin = await AdminClient.CreateAsync(_config, _adminTokenProvider, ct).ConfigureAwait(false); // failure not cached
            _admin = admin;
            return admin;
        }
        finally { _adminGate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        if (_admin is { } admin) await admin.DisposeAsync().ConfigureAwait(false);
        _httpClient.Dispose();
        _adminGate.Dispose();
        GC.SuppressFinalize(this);
    }

    // Sync dispose so a DI container (ServiceProvider.Dispose) — which cannot sync-dispose an
    // async-only-disposable tracked singleton — can release this client without throwing.
    public void Dispose()
    {
        _admin?.Dispose();
        _httpClient.Dispose();
        _adminGate.Dispose();
        GC.SuppressFinalize(this);
    }
}
```
`ServiceCollectionExtensions.cs`:
```csharp
using Microsoft.Extensions.DependencyInjection;

namespace Xzawed.Keycloak;

/// <summary>DI integration. Registers a singleton KeycloakClient built from the config.</summary>
public static class ServiceCollectionExtensions
{
    public static IServiceCollection AddKeycloak(this IServiceCollection services, KeycloakConfig config)
    {
        var normalized = config.Normalized();
        services.AddSingleton(normalized);
        services.AddSingleton(_ => KeycloakClient.Create(normalized));
        return services;
    }
}
```
> KeycloakClient는 장수명(long-lived) 클라이언트로 싱글턴이 권장 사용(내장 `HttpClient`는 하나의 Keycloak 서버를 가리키므로 재사용이 관용). 팩토리 관리 `HttpClient`가 필요한 소비자는 `KeycloakClient.Create`를 직접 호출.

- [ ] **Step 4: 통과 확인** → PASS.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "feat(dotnet): KeycloakClient 통합 진입점(Auth 즉시·Admin 지연 single-flight·IAsyncDisposable) + AddKeycloak DI 확장 (WBS 9)"`

---

### Task 10: 통합 E2E (Testcontainers.Keycloak + 실제 Keycloak 26.6)

**Files:** Create `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/integration/KeycloakFixture.cs`, `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/integration/E2ETests.cs`; Copy `java/keycloak-sdk/src/test/resources/it-realm-realm.json` → `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/testdata/it-realm-realm.json`; Modify `dotnet/tests/Xzawed.Keycloak.Sdk.Tests/Xzawed.Keycloak.Sdk.Tests.csproj`(realm json 복사)

**Interfaces:** Consumes: 전 계층(`KeycloakClient`·`AuthClient`·`AdminClient`+5리소스). 참조: Java `AuthFlowIT`/`AdminOpsIT`, Node `e2e.it.test.ts`, Go `integration_test.go`, `research_3.md`(Testcontainers.Keycloak).

> **⚠️ 딥리서치 확정**: `new KeycloakBuilder("quay.io/keycloak/keycloak:26.6")`(명시 이미지 필수)·`.WithResourceMapping(new FileInfo(realm.json), "/opt/keycloak/data/import/")`·`.WithCommand("--import-realm")`(start-dev에 append)·`GetBaseAddress()`(끝에 `/` 포함). realm 이름은 JSON의 `realm` 필드(=`it-realm`). realm은 `it-client`/`it-secret`(serviceAccounts + realm-management perms + it-client audience mapper) — Java/Python/Node/Go와 동일 JSON 재사용.

- [ ] **Step 1: realm json 복사 + csproj 복사 설정**

`dotnet/tests/Xzawed.Keycloak.Sdk.Tests/Xzawed.Keycloak.Sdk.Tests.csproj`에 추가:
```xml
  <ItemGroup>
    <None Update="testdata/it-realm-realm.json"><CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory></None>
  </ItemGroup>
```
```bash
mkdir -p dotnet/tests/Xzawed.Keycloak.Sdk.Tests/testdata
cp java/keycloak-sdk/src/test/resources/it-realm-realm.json dotnet/tests/Xzawed.Keycloak.Sdk.Tests/testdata/it-realm-realm.json
```

- [ ] **Step 2: 컨테이너 픽스처**

`integration/KeycloakFixture.cs`:
```csharp
using Testcontainers.Keycloak;
using Xunit;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

public sealed class KeycloakFixture : IAsyncLifetime
{
    public const string Realm = "it-realm";
    public const string ClientId = "it-client";
    public const string ClientSecret = "it-secret";

    private readonly KeycloakContainer _container = new KeycloakBuilder("quay.io/keycloak/keycloak:26.6")
        .WithResourceMapping(new FileInfo("testdata/it-realm-realm.json"), "/opt/keycloak/data/import/")
        .WithCommand("--import-realm")
        .Build();

    public string BaseUrl { get; private set; } = string.Empty;

    public async Task InitializeAsync()
    {
        await _container.StartAsync();
        BaseUrl = _container.GetBaseAddress().TrimEnd('/'); // strip trailing slash for KeycloakConfig
    }

    public async Task DisposeAsync() => await _container.DisposeAsync();
}

[CollectionDefinition("keycloak")]
public sealed class KeycloakCollection : ICollectionFixture<KeycloakFixture> { }
```

- [ ] **Step 3: E2E 시나리오(Java/Node/Go 동형·순서)** — client-credentials → validate(다중 aud) → introspect → user CRUD → delete 후 NotFound → 5 리소스 CRUD → Raw.

`integration/E2ETests.cs`:
```csharp
using System.Threading.Tasks;
using Keycloak.AuthServices.Sdk.Admin.Models;
using Xunit;
using Xzawed.Keycloak;

namespace Xzawed.Keycloak.Sdk.Tests.Integration;

[Collection("keycloak")]
[Trait("Category", "Integration")]
public class E2ETests
{
    private readonly KeycloakFixture _kc;
    public E2ETests(KeycloakFixture kc) => _kc = kc;

    private KeycloakClient NewClient() => KeycloakClient.Create(new KeycloakConfig
    {
        ServerUrl = _kc.BaseUrl,
        Realm = KeycloakFixture.Realm,
        ClientId = KeycloakFixture.ClientId,
        ClientSecret = KeycloakFixture.ClientSecret,
    });

    [Fact]
    public async Task Full_flow()
    {
        await using var client = NewClient();

        // 1) client-credentials + masking
        var token = await client.Auth.ClientCredentialsTokenAsync();
        Assert.False(string.IsNullOrEmpty(token.AccessToken));
        Assert.True(token.ExpiresIn > 0);
        var rendered = token.ToString();
        Assert.Contains("***", rendered);
        Assert.DoesNotContain(token.AccessToken, rendered);

        // 2) validate (multi-aud membership)
        var validated = await client.Auth.ValidateAsync(token.AccessToken);
        Assert.EndsWith($"/realms/{KeycloakFixture.Realm}", validated.Issuer);
        Assert.Contains(KeycloakFixture.ClientId, validated.Audience);
        Assert.False(string.IsNullOrEmpty(validated.Subject));

        // 3) introspect
        var introspection = await client.Auth.IntrospectAsync(token.AccessToken);
        Assert.True(introspection.Active);

        // 4) user CRUD (+ delete-then-NotFound)
        var admin = await client.AdminAsync();
        var userId = await admin.Users.CreateAsync(new UserRepresentation { Username = "bob", Email = "bob@example.com", Enabled = true });
        Assert.False(string.IsNullOrEmpty(userId));
        Assert.Equal("bob", (await admin.Users.GetAsync(userId)).Username);
        Assert.NotEmpty(await admin.Users.SearchAsync("bob"));
        await admin.Users.UpdateAsync(userId, new UserRepresentation { FirstName = "Bob", Enabled = true });
        Assert.Equal("Bob", (await admin.Users.GetAsync(userId)).FirstName);
        await admin.Users.DeleteAsync(userId);
        await Assert.ThrowsAsync<KeycloakNotFoundException>(() => admin.Users.GetAsync(userId));

        // 5) clients (raw)
        var clientUuid = await admin.Clients.CreateAsync(new ClientRepresentation { ClientId = "svc-e2e", Enabled = true });
        Assert.Equal("svc-e2e", (await admin.Clients.GetAsync(clientUuid)).ClientId);
        Assert.NotEmpty(await admin.Clients.FindByClientIdAsync("svc-e2e"));
        await admin.Clients.DeleteAsync(clientUuid);

        // 6) roles (raw, by name)
        await admin.Roles.CreateAsync(new RoleRepresentation { Name = "role-e2e" });
        Assert.Equal("role-e2e", (await admin.Roles.GetAsync("role-e2e")).Name);
        Assert.Contains(await admin.Roles.ListAsync(), r => r.Name == "role-e2e");
        await admin.Roles.DeleteAsync("role-e2e");

        // 7) groups (typed)
        var groupId = await admin.Groups.CreateAsync(new GroupRepresentation { Name = "group-e2e" });
        Assert.Equal("group-e2e", (await admin.Groups.GetAsync(groupId)).Name);
        Assert.Contains(await admin.Groups.ListAsync(), g => g.Name == "group-e2e");
        await admin.Groups.DeleteAsync(groupId);

        // 8) realms: get current (typed) + create/delete throwaway (raw)
        Assert.Equal(KeycloakFixture.Realm, (await admin.Realms.GetAsync(KeycloakFixture.Realm)).Realm);
        await admin.Realms.CreateAsync(new RealmRepresentation { Realm = "throwaway-e2e", Enabled = true });
        Assert.Equal("throwaway-e2e", (await admin.Realms.GetAsync("throwaway-e2e")).Realm);
        await admin.Realms.DeleteAsync("throwaway-e2e");

        // 9) Raw escape hatch
        var raw = admin.Raw;
        Assert.Equal(KeycloakFixture.Realm, (await raw.GetRealmAsync(KeycloakFixture.Realm)).Realm);
    }
}
```

- [ ] **Step 4: 실행(Docker 필요)** — `cd dotnet && dotnet test --filter "Category=Integration"` → GREEN.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "test(dotnet): Testcontainers E2E(client-credentials·validate·introspect·5리소스 CRUD·Raw) + it-realm-realm.json 재사용 (WBS 10)"`

---

### Task 11: CI + release 워크플로

**Files:** Create `.github/workflows/dotnet-ci.yml`, `.github/workflows/dotnet-release.yml`

**Interfaces:** Consumes: `dotnet/` 솔루션. 참조: `.github/workflows/go-ci.yml`/`node-ci.yml`.

> **⚠️ 커버리지 게이트**: `coverlet.collector`는 임계값을 강제하지 못함 → `coverlet.msbuild`의 `/p:Threshold`를 쓴다. 네트워크 경계(`AuthClient`·`Admin.*`·`KeycloakClient`)는 `/p:Exclude`로 제외(다른 언어의 auth/admin/client omit 정책과 동형).

- [ ] **Step 1: `dotnet-ci.yml`**

```yaml
name: dotnet-ci
on:
  push:
    paths: ['dotnet/**', '.github/workflows/dotnet-ci.yml']
  pull_request:
    paths: ['dotnet/**', '.github/workflows/dotnet-ci.yml']
jobs:
  build-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Restore
        run: dotnet restore dotnet/Keycloak.Sdk.sln
      - name: Build (warnaserror)
        run: dotnet build dotnet/Keycloak.Sdk.sln --no-restore -c Release
      - name: Format check
        run: dotnet format dotnet/Keycloak.Sdk.sln --verify-no-changes
      - name: Unit tests + coverage gate
        run: >
          dotnet test dotnet/Keycloak.Sdk.sln --no-build -c Release
          --filter "Category!=Integration"
          /p:CollectCoverage=true /p:CoverletOutputFormat=cobertura
          /p:Threshold=\"90,85\" /p:ThresholdType=\"line,branch\" /p:ThresholdStat=minimum
          /p:Exclude=\"[*]Xzawed.Keycloak.AuthClient,[*]Xzawed.Keycloak.Admin.*,[*]Xzawed.Keycloak.KeycloakClient\"
  integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Integration tests (Docker)
        run: dotnet test dotnet/Keycloak.Sdk.sln -c Release --filter "Category=Integration"
```

- [ ] **Step 2: `dotnet-release.yml`** — `dotnet-v*` 태그 → `dotnet pack` + `dotnet nuget push`(NuGet.org, API 키 시크릿 필요 = human-gated).

```yaml
name: dotnet-release
on:
  push:
    tags: ['dotnet-v*']
jobs:
  release:
    runs-on: ubuntu-latest
    # job-level env so the push step's own `if:` can see it (a step-level env is NOT in scope for that step's if)
    env:
      NUGET_API_KEY: ${{ secrets.NUGET_API_KEY }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '8.0.x'
      - name: Verify (build + unit tests)
        run: |
          dotnet build dotnet/Keycloak.Sdk.sln -c Release
          dotnet test dotnet/Keycloak.Sdk.sln -c Release --filter "Category!=Integration"
      - name: Pack
        run: dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release -o artifacts /p:ContinuousIntegrationBuild=true
      - name: Push to NuGet (human-gated; requires NUGET_API_KEY secret)
        if: ${{ env.NUGET_API_KEY != '' }}
        run: dotnet nuget push "artifacts/*.nupkg" --api-key "$NUGET_API_KEY" --source https://api.nuget.org/v3/index.json --skip-duplicate
      - name: GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: artifacts/*.nupkg
```

- [ ] **Step 3: 검증** — YAML 파싱 확인 + 로컬 `cd dotnet && dotnet build -c Release && dotnet pack src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release -o /tmp/artifacts`로 `.nupkg`(+`.snupkg`) 생성 확인(업로드 없이).
- [ ] **Step 4: Commit** — `git add -A && git commit -m "ci(dotnet): dotnet-ci(build+format+unit/coverage+integration) + dotnet-release(태그=NuGet, human-gated) (WBS 11)"`

---

### Task 12: 문서 · 거버넌스 로그

**Files:** Modify `docs/guides/getting-started.md`(C# 섹션 4블록), `README.md`, `CLAUDE.md`(구조·명령·gotchas·테스트 수), `docs/roadmap/language-support.md`(매트릭스 C# ✅), `CHANGELOG.md`(`(dotnet)` Added), `docs/guides/add-a-language-playbook.md`(선택); Create `docs/governance/verification-log-dotnet.md`

**Interfaces:** Consumes: 전 태스크 결과. CLAUDE.md 전역 규칙(작업 완료 후 전체 문서 최신화).

- [ ] **Step 1**: getting-started에 C#/.NET 4블록 — 요구 런타임 .NET 8+ · 로컬 프로젝트참조(`dotnet add reference`) · 배포후 `dotnet add package Xzawed.Keycloak.Sdk` · 최소 예제(실제 API: `KeycloakClient.Create` → `ClientCredentialsTokenAsync` → `ValidateAsync` → `AdminAsync().Users.CreateAsync`).
- [ ] **Step 2**: README 언어 표에 C# 행 추가(✅ 완료·기반 Duende.IdentityModel + Microsoft.IdentityModel + Keycloak.AuthServices.Sdk 2.7.0·NuGet `Xzawed.Keycloak.Sdk` human-gated) · 호환성 표(대상 26.6·라이브러리 버전) · 전략 섹션 C# 추가. 로드맵 매트릭스 C# 행 ✅(설계·구현·단위·통합·CI) + 🔒 배포. CHANGELOG `(dotnet) 5번째 언어 추가`.
- [ ] **Step 3**: CLAUDE.md — "현재 상태"에 .NET SDK 완료 문단 추가(테스트 수 실측 기입) · 아키텍처에 `dotnet/` 트리 + 결합 규칙(admin↔auth 분리·타입드/raw 분리) · Node 툴체인 섹션 뒤에 **.NET 툴체인 섹션**(빌드/단위/통합/단일테스트/pack 명령) · Gotchas에 dotnet 항목(record ToString 마스킹·Keycloak.AuthServices 2.7.0 net8 핀·타입드 커버리지 users/groups/realm-get만·Duende 예외 미던짐/401·`ValidateTokenAsync` throw 안 함·`TVP.ConfigurationManager` JWKS) · 확정 의존성 표 dotnet 추가.
- [ ] **Step 4**: `docs/governance/verification-log-dotnet.md` 신설(딥리서치 6-에이전트·태스크별 G1~G6·Loops·다중에이전트 리뷰 이력). 문서 간 링크·테스트 수 일관성 스윕.
- [ ] **Step 5: Commit** — `git add -A && git commit -m "docs(dotnet): getting-started C# 섹션 + README·CLAUDE·로드맵·CHANGELOG·verification-log-dotnet (WBS 12)"`

---

## Self-Review (계획 ↔ 스펙 대조)

- **스펙 커버리지**: §1 개요/핵심결정→전 태스크 · §2 범위→T7(auth 흐름)·T8(admin)·T6(jwt)·비목표(브라우저·sync·미들웨어) 제외 확인 · §3 의존성→T1(핀)·T6·T7·T8 · §4 구조(`dotnet/`)→T1~T9 · §5 계층/값타입/결합/예외→T2~T9 · §6 보안불변식→T2(마스킹)·T3(ToString override)·T6(JWT 강화·DoS-safe JWKS)·T7(TLS·nonce)·T8(타임아웃) · §7 테스트→T2~T9 단위 + T10 통합 + 커버리지 게이트(T11) · §8 빌드/CI/배포→T1·T11 · §9 문서→T12. 누락 없음.
- **플레이스홀더 스캔**: 라이브러리 API는 딥리서치(6-에이전트, git tag/소스/MS Learn 실검증)로 확정된 실코드. "착수 시 확정"은 커버리지 임계값 수치·representation 필드 실서버 검증 등 의도적 잔여(다른 언어 플랜과 동형). `TODO`/`fill in`/추상 지시 없음 — 모든 코드 스텝에 실제 코드·명령·기대값.
- **타입/명칭 일관**(전 태스크 대조): `KeycloakConfig`(`Normalized()`·`ToString` 마스킹)·`TokenSet`(`Create`·`IsExpired`·`ExpiresAt` long?)·`ValidatedToken`/`IntrospectionResult`/`AuthorizationRequest`·예외 계급(`KeycloakException`→`Config`/`Auth`(`OAuthError`)/`TokenValidation`/`Admin`(`StatusCode`)→`NotFound`/`Conflict`/`Forbidden`/`Transport`)·`KeycloakErrorMapping.MapHttpError`·`Masking.Mask`·`ITokenProvider.GetAccessTokenAsync`/`ITokenSource.ClientCredentialsTokenAsync`·`ClientCredentialsTokenProvider`·`OidcEndpoints.For`·`JwtValidatorOptions`/`JwtValidator`(`BuildParameters`·`ValidateAsync`)·`AuthClient : ITokenSource`(7 메서드)·`AdminClient`(`CreateAsync`·`Raw`·`Realm`·경계 헬퍼)·5 리소스(`Users`/`Clients`/`Realms`/`Roles`/`Groups`)·`KeycloakClient`(`Create`·`Auth`·`AdminAsync`·`DisposeAsync`)·`AddKeycloak`가 전 태스크·스펙·Global Constraints와 일치.
- **동형성 확인**(§4): 계층(config→errors→tokens→tokenprovider→oidc→jwt→auth→admin→client)·값타입·결합(`ITokenProvider` 유일 접착제, `AuthClient`가 기본 소스)·예외 경계 변환·테스트 시나리오가 Java/Python/Node/Go와 동형. C# 관용 적용(예외·async `Task<T>`+`CancellationToken`·record ToString override·DI 확장).
- **딥리서치 반영 확인**: (1) Keycloak.AuthServices.Sdk **2.7.0**(net8) · (2) admin 타입드 users/groups/realm-get + clients/roles/realm-CRUD raw · (3) `CreateUserAsync` void → Location 파싱 · (4) `IKeycloakClient` 타입 캐스팅(default interface method) · (5) `ValidateTokenAsync` throw 안 함 → `IsValid` · (6) `TVP.ConfigurationManager` JWKS · (7) `RequireExpirationTime`/`ValidAlgorithms` 명시 · (8) Duende 예외 미던짐/401 body에서 error · (9) 수동 PKCE/logout · (10) record ToString 마스킹 함정 — 전부 태스크 코드에 반영.

## 다중에이전트 어드버서리얼 검증 반영 (2026-07-04, 6-에이전트 — 1 실제 컴파일 검증 포함)

WBS 작성 후 5개 렌즈(Duende/JWT API·AuthServices admin API·테스트/빌드 툴링·타입일관+컴파일가능성·스펙커버리지+동형성+보안)로 어드버서리얼 검증. **확정 결함 전부 계획에 보정 완료**:

- **HIGH — Task 8 네임스페이스 셰도잉**(실제 컴파일로 포착): `namespace Xzawed.Keycloak.Admin` 안에서 `new KeycloakClient(http)`가 enclosing 파사드 `Xzawed.Keycloak.KeycloakClient`(private ctor)에 바인딩 → CS1729. `using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;` 별칭으로 해결.
- **HIGH — Task 1 테스트 프로젝트 CS1591**: `GenerateDocumentationFile`+`TreatWarningsAsErrors` 상속으로 모든 public 테스트 멤버가 빌드 오류. Directory.Build.props에서 `IsTestProject != true` 게이트 + 테스트 csproj `GenerateDocumentationFile=false`. `AnalysisLevel=8.0`으로 SDK 밴드 일치.
- **HIGH — Task 6 exp-필수 테스트 무효**: `JsonWebTokenHandler.CreateToken`이 exp를 자동 주입해 no-exp 테스트가 실제로 exp 있는 토큰을 만들어 통과 실패 + 불변식 미검증. `SetDefaultTimesOnTokenCreation=false`로 수정.
- **MEDIUM — Task 3 JSON 마스킹 누락**: ToString만으로는 `JsonSerializer.Serialize`/Serilog destructuring이 시크릿/토큰 평문 노출. `JsonConverter<TokenSet>`·`JsonConverter<KeycloakConfig>` 추가 + 회귀 테스트.
- **MEDIUM — Task 7 nonce 파스온리·fail-open**: `ExchangeCodeAsync`가 id_token을 파싱만 하고 nonce 없으면 무검증 통과. `_validator.ValidateAsync`로 완전 검증(서명/iss/aud/exp) 후 nonce 대조(fail-closed)로 강화.
- **MEDIUM — Task 6 프로덕션 ctor 미커버**: JWKS/TLS 배선 ctor가 단위 미커버 → 커버리지 게이트 위협 + §6 TLS 회귀가드 부재. http/https ctor 스모크 테스트 추가(lazy ConfigurationManager, 네트워크 없음).
- **MEDIUM — Task 9 DI 동기 dispose 예외**: async-only-disposable 싱글턴을 `ServiceProvider.Dispose()`가 동기 처분하면 예외. `KeycloakClient`/`AdminClient`에 `IDisposable` 추가. `PooledConnectionLifetime`로 단일 HttpClient DNS 갱신(IHttpClientFactory 관심사 대응).
- **MEDIUM — Task 11 release `if` env 스코프**: step-level env는 같은 step의 `if:`에 안 보임 → NuGet push 항상 스킵. job-level env로 승격.
- **LOW/폴리시**: Task 8 `CreateAsync` async화 + 토큰 워밍(§5.1 "최초 호출 시 인증" 정합) · Task 6 claims dict `.ToDictionary((object?))` 투영(IntrospectAsync와 일관) · Task 1 의존성 `Microsoft.Extensions.Http`→`DependencyInjection.Abstractions`(IHttpClientFactory 미사용) · xUnit 2.9.3 deprecated(v2 의도적 유지).
- **컴파일로 반증된 오탐(수정 안 함)**: `new Dictionary<string,object?>(result.Claims!)`는 CS8620 아님(Claims 비널) — 그래도 일관성 위해 투영형으로 통일. `(JsonWebToken)result.SecurityToken` deref·`ReadFromJsonAsync<T>` null-throw·record `required`+ToString override — 전부 실제 컴파일 통과 확인.
- **CLEAN 판정**: 타입 일관성(전 크로스태스크 참조 일치), 플레이스홀더(없음), Keycloak.AuthServices.Sdk 2.7.0 admin API(전부 소스 검증), Testcontainers/WireMock/coverlet 툴링 — 결함 없음.






