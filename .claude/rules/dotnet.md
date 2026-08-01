---
paths:
  - "dotnet/**"
  - "harness/apps/dotnet/**"
  - "harness/install/consume/dotnet*"
  - "harness/install/consume/dotnet/**"
  - ".github/workflows/dotnet-*.yml"
---

# C#/.NET 규칙

## 툴체인 (빌드 명령)

.NET은 시스템 설치 `C:\Program Files\dotnet`(SDK 10.0.102, net8.0 런타임 8.0.23 네이티브 존재 — 포터블 설치 불필요)을 사용한다. 명령은 `dotnet/`에서 실행한다:
```bash
cd dotnet && dotnet build                                          # 빌드(warnaserror·Nullable·AnalysisLevel 8.0)
cd dotnet && dotnet test --filter "Category!=Integration"          # 단위테스트 67개. Docker 불필요
cd dotnet && dotnet test --filter "Category=Integration"           # 통합테스트 1개(E2E `Full_flow`, Docker 필요 — 실제 Keycloak 26.6)
cd dotnet && dotnet format Keycloak.Sdk.sln --verify-no-changes    # 포맷 검사
```
- 단일 테스트: `dotnet test --filter "FullyQualifiedName~<TestName>"`
- 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%, 네트워크 경계 omit): `dotnet test --filter "Category!=Integration" /p:CollectCoverage=true /p:Threshold="90,85" /p:ThresholdType="line,branch" /p:Exclude="[*]Xzawed.Keycloak.AuthClient,[*]Xzawed.Keycloak.Admin.*,[*]Xzawed.Keycloak.KeycloakClient"`(실측 라인 97.34%/브랜치 93.47%)
- 로컬 배포 빌드 검증(업로드 없이): `dotnet pack src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release` → `Xzawed.Keycloak.Sdk.<version>.nupkg`(+ `.snupkg`) 생성 확인
- 실제 NuGet 배포는 로컬에서 실행하지 않는다 — `dotnet-v*` 태그 push 시 `.github/workflows/dotnet-release.yml`에서 `NUGET_API_KEY` 시크릿으로 실행(사람 승인 게이트). **시크릿 미설정은 스킵이 아니라 실패다**(아래 게차). 발행 전 게이트로 실 Keycloak 통합 E2E `integration` 잡이 `needs:`에 들어간다
- 패키지 `Xzawed.Keycloak.Sdk`는 net8.0 타깃·async-first(`Task<T>`+`CancellationToken`)이며 XML 문서(`GenerateDocumentationFile`)를 포함 — 소비자 측 IntelliSense 지원. `Directory.Build.props`가 `PackageReadmeFile=README.md`를 설정하고 `dotnet/README.md`·`dotnet/LICENSE`를 `IsTestProject != true` 조건으로 패키지 루트에 pack한다(nuget.org 랜딩 페이지용 — nupkg 안에서는 저장소 상대 링크가 깨지므로 README 링크는 전부 절대 URL)
- ⚠️ SDK 10 기본 솔루션 포맷은 `.slnx` — 이 리포는 `dotnet new sln --format sln`으로 생성한 `Keycloak.Sdk.sln`(구 포맷) 사용. `AnalysisLevel=8.0`으로 로컬(SDK 10)/CI(SDK 8) 애널라이저 밴드 일치. `GenerateDocumentationFile`/패키징 props는 `Directory.Build.props`에서 `IsTestProject != true`로 게이트(테스트 프로젝트의 CS1591 격상 방지)

## 게차

- ⚠️ **(C#) `Raw`는 타입드 클라이언트라 users/groups/realm-read만 커버한다 — 파사드가 그 밖의 것을 raw Admin REST로 직접 구현하는 이유다.** 한때 `realms.list`·`realms.update`·`roles.update`가 파사드에도 `Raw`에도 없어 **아홉 SDK 중 유일하게 도달 불가능**했다(내부 raw-REST 헬퍼는 `internal`, bearer `HttpClient`는 `private`이라 별도 클라이언트를 손수 만드는 수밖에 없었고 그러면 오류 변환·타임아웃·리다이렉트 하드닝을 전부 잃는다). 지금은 셋 다 기존 raw REST 패턴으로 파사드에 구현했고 `groups.update`까지 더해 25/25다. ⚠️ **.NET에서 `Raw`가 모든 것을 덮는다고 가정하지 말 것** — 새 admin 연산을 추가할 때 타입드 클라이언트에 없으면 `SendRawAsync`/`GetJsonAsync`로 구현하는 것이 이 SDK의 관용이다.
- ⚠️ **(C#) `Keycloak.AuthServices.Sdk` 3.0.0은 net10 전용 → net8.0은 2.7.0 핀.** 2.7.0이 요구하는 `DI.Abstractions >= 9.0.8`보다 낮은 핀은 NU1605(downgrade)로 `TreatWarningsAsErrors` 하드오류.
- ⚠️ **(C#) admin 타입드 커버리지는 users/groups/realm-get뿐**(`IKeycloakUserClient`/`IKeycloakGroupClient`/`IKeycloakRealmClient`) — clients/roles/realm-CRUD는 같은 bearer `HttpClient`로 raw REST. `…Async` 편의메서드 호출하려면 변수를 `IKeycloakClient`로 타입. `CreateUserAsync`는 void 반환이라 `CreateUserWithResponseAsync`+`Location` 헤더로 id 취득.
- ⚠️ **(C#) 네임스페이스 셰도잉**: `Xzawed.Keycloak.Admin` 안에서 `new KeycloakClient(http)`는 파사드(private ctor)에 바인딩돼 CS1729 — `using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;` 별칭 필요.
- ⚠️ **(C#) `record` 자동 `ToString()`은 토큰/시크릿을 전체 노출** — `TokenSet`/`KeycloakConfig`는 `ToString()` override+`JsonConverter<T>`로 마스킹. **단 Serilog `{@}` 구조분해는 raw 프로퍼티를 직접 읽어 이 마스킹을 우회** — 두 타입을 `{@}`로 구조분해하지 말 것.
- ⚠️ **(C#) `HttpClient.Timeout` 만료는 `TaskCanceledException`이지 `HttpRequestException`이 아니다** — admin 경계는 `catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)`로 `KeycloakTransportException` 변환 필요.
- ⚠️ **(C#) 위조 서명은 JWKS 재조회를 **유발한다** — 나머지 8개 언어와 다르다(rate-limit으로 상한만 걸린다).** `Microsoft.IdentityModel`은 서명 검증 실패를 키 회전 신호로 보고 `ConfigurationManager.RequestRefresh()` 후 재시도한다. 이는 `ConfigurationManager`를 버리지 않는 한 끌 수 없다. Python·Go·Rust·Ruby·Java는 "위조 서명은 재조회 0회"라는 더 강한 불변식을 갖지만 .NET은 갖지 못하며, 실제 피해를 막는 것은 `RefreshIntervalSeconds`(기본 30초)다 — 실측: 위조 토큰 6건 → 추가 조회 1회. **테스트를 "0회"로 바꾸지 말 것**(이 SDK가 하지 않는 것을 주장하게 된다). 근거: `Forged_signature_with_known_kid_refetch_is_rate_limited`.
- ⚠️ **(C#) `JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 예외를 안 던진다** — `result.IsValid` 검사 필수. `ValidAlgorithms` 기본 `null`(전체허용)이라 `["RS256"]` 핀, `ClockSkew` 기본 5분→30초, `RequireExpirationTime=true`(다른 4개 언어와 동형). JWKS는 `TokenValidationParameters.ConfigurationManager`(`RefreshInterval`이 DoS 스로틀)로 재조회한다. **테스트 함정**: `CreateToken`이 `exp` 자동주입하므로 no-exp 테스트는 `SetDefaultTimesOnTokenCreation=false` 명시 필요.
- ⚠️ **(C#) `POST /admin/realms`(신규 realm 생성)는 master realm 전용** — 어떤 realm의 service account도(최광범위 롤 포함) 403. E2E는 master bootstrap admin으로 검증.
- ⚠️ **(C#) Duende.IdentityModel 확장 메서드는 예외를 안 던진다**(`resp.IsError` 검사 필요) — 잘못된 client 자격증명엔 401(`ErrorType=Http`)이라 에러코드는 `resp.Json["error"]`에서 읽는다. PKCE는 라이브러리 미지원(수동 생성), introspection은 `IntrospectTokenAsync`, logout은 수동 POST.
- ⚠️ **(C#) SDK10 기본 솔루션 포맷은 `.slnx`** — `dotnet new sln --format sln`으로 구포맷 명시 생성 필요. `AnalysisLevel=8.0`으로 로컬/CI 애널라이저 밴드 일치. `GenerateDocumentationFile`은 `IsTestProject != true`로 게이트(안 하면 테스트 프로젝트 CS1591로 빌드 실패).
- ⚠️ **(C#) `AddKeycloak(config)`는 `KeycloakConfig`도 싱글턴 등록** — 소비자가 별도로 `AddSingleton<KeycloakConfig>`하면 등록 중복으로 해석 모호. `AddKeycloak` 후 별도 등록 금지.
- ⚠️ **(C#) `NUGET_API_KEY` 미설정은 스킵이 아니라 실패다 — 그리고 `dotnet nuget push --skip-duplicate`는 쓰지 않는다.** 이전에는 시크릿이 없으면 push 스텝이 `exit 0`으로 조용히 넘어가면서 **GitHub Release는 그대로 생성**돼, 게시되지 않은 버전이 게시된 것처럼 보였다(green 실행 = 아무것도 안 한 실행). 지금은 `::error::`+`exit 1`. `--skip-duplicate`도 같은 이유로 제거 — 이미 존재하는(= 태워버린) 버전에 대한 push를 성공으로 위장하므로, 중복이면 실패해서 사람이 알아채야 한다. ⚠️ job-level `if:`는 secrets 컨텍스트를 읽지 못하므로 가드는 스텝 안에서 env-매핑된 값으로 한다.
