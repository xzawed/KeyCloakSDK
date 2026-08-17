---
paths:
  - "dotnet/**"
  - "harness/apps/dotnet/**"
  - "harness/install/consume/dotnet*"
  - "harness/install/consume/dotnet/**"
  - ".github/workflows/dotnet-*.yml"
---

# C#/.NET 규칙

## 툴체인

시스템 설치 `C:\Program Files\dotnet`(SDK 10, net8.0 런타임 네이티브). 명령은 `dotnet/`에서.

```bash
cd dotnet && dotnet build                                       # warnaserror · Nullable · AnalysisLevel 8.0
cd dotnet && dotnet test --filter "Category!=Integration"       # 단위. Docker 불필요
cd dotnet && dotnet test --filter "Category=Integration"        # 통합 E2E. Docker 필요(KC 26.6)
cd dotnet && dotnet format Keycloak.Sdk.sln --verify-no-changes
cd dotnet && dotnet pack src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release   # 배포 빌드 검증
```

- 단일 테스트: `dotnet test --filter "FullyQualifiedName~<TestName>"`
- **커버리지는 2단계다.** 수집은 coverlet **컬렉터**, 판정은 `scripts/check-coverage.mjs`(제외 필터 SSOT는 `dotnet/coverlet.runsettings`):
  ```bash
  cd dotnet && dotnet test --filter "Category!=Integration" \
    --collect:"XPlat Code Coverage" --settings coverlet.runsettings --results-directory /tmp/cov
  node ../scripts/check-coverage.mjs /tmp/cov --min-line 90 --min-branch 85
  ```
  실측 라인 96.91%(188/194) · 브랜치 90.00%(45/50).
- 배포는 `dotnet-v*` 태그 → `dotnet-release.yml`(사람 승인 게이트). 발행 전 `integration` 잡이 `needs:`에 있다.
- 솔루션은 구 포맷 `Keycloak.Sdk.sln`(SDK 10 기본은 `.slnx`). `AnalysisLevel=8.0`으로 로컬(SDK 10)/CI(SDK 8) 애널라이저 밴드를 맞춘다. `GenerateDocumentationFile`·패키징 props는 `IsTestProject != true`로 게이트(안 하면 테스트 프로젝트 CS1591로 빌드 실패).

## 커버리지 함정 둘

- ⚠️ **coverlet **msbuild** 통합은 쓰지 않는다.** 히트를 `ProcessExit`에서 flush하는데 VSTest가 종료를 짧게만 기다려서, 느린 실행에서는 분모는 살아있고 **분자만 0**인 리포트가 나온다. 내장 임계값 게이트는 그걸 진짜 하락과 **완전히 같은 문구**로 보고한다(같은 커밋 재실행은 통과했다). 컬렉터는 `SessionEnd`에 flush하므로 이 경로가 없고, `check-coverage.mjs`가 **분모와 분자를 따로 본다**(`lines-valid>0`인데 `lines-covered==0`이면 하락이 아니라 측정 실패).
- ⚠️ **브랜치 게이트의 여유는 백분율이 아니라 개수로 읽는다.** 분모가 50이라 1개당 2.0%p다 — 45/50에서 임계 85%는 43개를 요구하므로 **실제 여유는 2개**다. else 없는 `if` 하나면 깨진다. `check-coverage.mjs`가 매 실행 `브랜치 여유: N개`를 찍는 이유다. **0%를 보고 임계값을 내리는 것이 정확히 하지 말아야 할 대응이다.**

## admin 표면

- ⚠️ **`Raw`는 타입드 클라이언트라 users/groups/realm-read만 덮는다.** 그 밖의 연산은 파사드가 raw Admin REST(`SendRawAsync`/`GetJsonAsync`)로 직접 구현하는 것이 이 SDK의 관용이다 — 새 admin 연산이 타입드에 없다고 멈추지 말 것. 현재 25/25.
- ⚠️ **네임스페이스 셰도잉**: `Xzawed.Keycloak.Admin` 안에서 `new KeycloakClient(http)`는 파사드(private ctor)에 바인딩돼 CS1729 — `using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;` 별칭이 필요하다.
- `CreateUserAsync`는 void 반환이라 id는 `CreateUserWithResponseAsync` + `Location` 헤더에서 얻는다.
- ⚠️ **`POST /admin/realms`(신규 realm 생성)는 master realm 전용이다** — 어떤 realm의 service account도 403. E2E는 master bootstrap admin으로 검증한다.

## 라이브러리 게차

- ⚠️ **`JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 예외를 던지지 않는다** — `result.IsValid` 검사가 필수다. 기본값도 안전하지 않다: `ValidAlgorithms`가 `null`(전체 허용)이라 `["RS256"]` 핀, `ClockSkew` 5분 → 30초, `RequireExpirationTime=true`. **테스트 함정**: `CreateToken`이 `exp`를 자동 주입하므로 no-exp 테스트는 `SetDefaultTimesOnTokenCreation=false`가 필요하다.
- ⚠️ **위조 서명이 JWKS 재조회를 유발한다 — 9개 언어 중 .NET만 그렇다.** `Microsoft.IdentityModel`이 서명 실패를 키 회전 신호로 보고 `RequestRefresh()` 후 재시도하는데, `ConfigurationManager`를 버리지 않는 한 끌 수 없다. 실제 피해를 막는 것은 `RefreshIntervalSeconds`(30초)뿐이다(실측: 위조 6건 → 추가 조회 1회). **테스트를 "0회"로 바꾸지 말 것** — 이 SDK가 하지 않는 것을 주장하게 된다.
- ⚠️ **`HttpClient.Timeout` 만료는 `TaskCanceledException`이지 `HttpRequestException`이 아니다** — 경계에서 `catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)`로 잡아 변환한다.
- ⚠️ **Duende.IdentityModel 확장 메서드는 예외를 던지지 않는다**(`resp.IsError` 검사). 잘못된 자격증명도 401(`ErrorType=Http`)이라 에러코드는 `resp.Json["error"]`에서 읽는다. PKCE는 미지원(수동 생성), logout은 수동 POST.
- ⚠️ **`record`의 자동 `ToString()`은 토큰·시크릿을 전부 노출한다** — `TokenSet`/`KeycloakConfig`는 `ToString()` override + `JsonConverter<T>`로 마스킹한다. **단 Serilog `{@}` 구조분해는 raw 프로퍼티를 직접 읽어 마스킹을 우회하므로 두 타입을 `{@}`로 쓰지 않는다.**
- ⚠️ **`AddKeycloak(config)`는 `KeycloakConfig`도 싱글턴 등록한다** — 소비자가 별도로 `AddSingleton<KeycloakConfig>`하면 해석이 모호해진다.

## 의존성·구조 결정

- ⚠️ **`Keycloak.AuthServices.Sdk` 3.0.0은 net10 전용이라 net8.0은 2.7.0 핀이다.** 2.7.0이 요구하는 `DI.Abstractions >= 9.0.8`보다 낮으면 NU1605로 하드 에러.
- ⚠️ **`DI.Abstractions`의 10.x major는 net8 유지 정책으로 보류다** — 9.x 패치는 받고 10.x는 닫는다. 현재 핀은 루트 `CLAUDE.md` 의존성 표에만 적는다.
- **`IHttpClientFactory`는 의도적으로 쓰지 않는다** — 단일 장수명 `HttpClient` + `PooledConnectionLifetime`(5분)으로 stale DNS를 피한다. DI 없이 쓰이는 라이브러리라 팩토리 수명주기를 소비자에게 강요하지 않는다.
- `admin`↔`auth` 접착제는 `ITokenProvider` 하나다(`AuthClient : ITokenSource`가 기본 소스) — §4 동형.
