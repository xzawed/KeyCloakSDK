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

### Java 툴체인 (빌드 명령)

하네스 셸은 프로파일을 소싱하지 않으므로 mvn 명령마다 환경을 인라인 지정한다:
```bash
JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml <goal>
```
- 전체 빌드+검증: `mvn -f java/pom.xml verify` (커버리지 게이트 90/85 포함)
- 단위테스트만: `mvn -f java/pom.xml test -DskipITs=true`
- 단일 테스트: `mvn -f java/pom.xml test -pl <module> -Dtest=<ClassName>#<method>`
- 통합테스트(Docker 필요): `mvn -f java/pom.xml verify`
- examples 모듈만 컴파일: `mvn -f java/pom.xml -pl keycloak-sdk-examples -am compile`
- 배포(release) 산출물 로컬 검증(서명·배포 없이): `mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package` — core/auth/admin/keycloak-sdk 각각 `*-sources.jar`/`*-javadoc.jar` 생성 확인
- 실제 `deploy`(Maven Central 배포)는 로컬에서 실행하지 않는다 — `v*` 태그 push 시 `.github/workflows/release.yml`에서만 시크릿과 함께 실행(사람 승인 게이트)
- JDK 21.0.8 (Eclipse Temurin) · Maven 3.9.9 (머신 전용 경로 — 리포지토리에 커밋 안 함, CI는 setup-java 사용)

### Python 툴체인 (빌드 명령)

가상환경은 `python/.venv`에 있다(리포지토리에 커밋 안 함). 명령은 `python/`에서 실행하거나 절대경로의 venv 인터프리터를 직접 호출한다:
```bash
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m pytest -m "not integration" --cov=keycloak_sdk   # 단위테스트 224개 + 커버리지 게이트 100%
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m pytest -m integration            # 통합테스트 11개(Docker 필요, testcontainers)
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m ruff check src tests examples     # 린트(보안 S/bandit 포함 확장 룰셋)
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m ruff format --check src tests examples  # 포맷 검사
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m mypy src                          # 정적 타입 검사(strict)
```
- 로컬 배포 빌드 검증(업로드 없이): `cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m build` → `dist/keycloak_sdk-0.1.0-py3-none-any.whl` + `.tar.gz` 생성 확인
- 실제 PyPI 배포는 로컬에서 실행하지 않는다 — `py-v*` 태그 push 시 `.github/workflows/python-release.yml`에서 PyPI Trusted Publisher(OIDC, 저장 시크릿 없음)로 실행(사람 승인 게이트)
- 패키지 `keycloak_sdk`(배포명 `keycloak-sdk`)는 PEP 561 `py.typed` 마커를 포함 — 소비자 측 mypy도 타입 검사 가능

### Node 툴체인 (빌드 명령)

Node는 시스템 설치(현재 v22, 요구 20+)를 사용한다. 명령은 `node/`에서 실행한다:
```bash
cd node && npm ci                    # 의존성 설치(package-lock.json 기준)
cd node && npm test                  # 단위테스트 71개 + 커버리지 게이트(라인 90/브랜치 85). Docker 불필요
cd node && npm run test:unit         # 동일(단위만 명시)
cd node && npm run test:it           # 통합테스트 5개(Docker 필요 — vitest.integration.config.ts, 실제 Keycloak 26.6)
cd node && npm run typecheck         # tsc --noEmit (strict)
cd node && npm run lint              # eslint (typescript-eslint recommended)
cd node && npm run build             # tsc → dist/ (배포 산출물)
```
- 단일 테스트 파일: `cd node && npx vitest run test/unit/<name>.test.ts`
- 로컬 배포 빌드 검증(업로드 없이): `cd node && npm run build && npm pack --dry-run` → `dist/**` + package.json만 포함(약 24kB, `files:["dist"]`) 확인
- 실제 npm 배포는 로컬에서 실행하지 않는다 — `node-v*` 태그 push 시 `.github/workflows/node-release.yml`에서 npm Trusted Publishing(OIDC + provenance, 저장 토큰 없음)로 실행(사람 승인 게이트)
- 패키지 `@xzawed/keycloak-sdk`는 ESM 전용(`"type":"module"`)이며 `.d.ts` 타입 선언을 포함 — 소비자 측 TypeScript 타입 검사 가능
- ⚠️ 커버리지 게이트에서 `src/auth.ts`·`src/admin/**`·`src/index.ts` omit(네트워크 경계) — 통합테스트로 검증. 나머지 로직 모듈은 라인 100%/브랜치 94% 실측

### Go 툴체인 (빌드 명령)

Go는 포터블 설치 `C:\Users\dirtc\tools\go`(1.26.4, 리포지토리 미커밋)를 사용한다. 프리픽스를 인라인 지정하고 `go -C go`로 실행한다(cwd를 go/로 바꾸지 않아 git과 충돌 방지):
```bash
export PATH="/c/Users/dirtc/tools/go/bin:$PATH" GOTOOLCHAIN=local
go -C /d/Source/KeyCloakSDK/go build ./...      # 빌드
go -C /d/Source/KeyCloakSDK/go test ./...        # 단위테스트 40개(integration 태그 없이 — E2E 제외)
go -C /d/Source/KeyCloakSDK/go test -tags=integration -run TestE2E -count=1 ./...  # 통합 E2E(Docker 필요)
go -C /d/Source/KeyCloakSDK/go vet ./...         # 정적 분석
gofmt -l /d/Source/KeyCloakSDK/go                # 포맷 검사(출력 없으면 OK; -w로 수정)
```
- 단일 테스트: `go -C go test -run TestValidateValidToken ./...`
- 커버리지 게이트(로직 statement ≥90, 네트워크 경계 omit): `go test ./... -coverprofile=cover.out` → `grep -vE '/(auth|admin|admin_users|admin_clients|admin_realms|admin_roles|admin_groups|client)\.go:' cover.out`로 경계 제외 → `go tool cover -func`로 total 확인(실측 95.2%)
- ⚠️ **최소 Go는 1.25**(`golang.org/x/oauth2` v0.36이 요구 → `go.mod`의 `go 1.25`). CI matrix는 1.25·1.26. `golangci-lint`는 로컬 미설치(CI에서 `golangci/golangci-lint-action@v6`) — 로컬은 `go vet`·`gofmt`로 대체
- **배포는 레지스트리 없음** — Go 모듈은 `go/v*` 태그가 곧 릴리스(`proxy.golang.org` 자동 캐시). `.github/workflows/go-release.yml`이 태그 push 시 verify + GitHub Release + 프록시 워밍(사람 승인 게이트). 소비자: `go get github.com/xzawed/KeyCloakSDK/go@vX.Y.Z`

### .NET 툴체인 (빌드 명령)

.NET은 시스템 설치 `C:\Program Files\dotnet`(SDK 10.0.102, net8.0 런타임 8.0.23 네이티브 존재 — 포터블 설치 불필요)을 사용한다. 명령은 `dotnet/`에서 실행한다:
```bash
cd dotnet && dotnet build                                          # 빌드(warnaserror·Nullable·AnalysisLevel 8.0)
cd dotnet && dotnet test --filter "Category!=Integration"          # 단위테스트 58개. Docker 불필요
cd dotnet && dotnet test --filter "Category=Integration"           # 통합테스트 1개(E2E `Full_flow`, Docker 필요 — 실제 Keycloak 26.6)
cd dotnet && dotnet format Keycloak.Sdk.sln --verify-no-changes    # 포맷 검사
```
- 단일 테스트: `dotnet test --filter "FullyQualifiedName~<TestName>"`
- 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%, 네트워크 경계 omit): `dotnet test --filter "Category!=Integration" /p:CollectCoverage=true /p:Threshold="90,85" /p:ThresholdType="line,branch" /p:Exclude="[*]Xzawed.Keycloak.AuthClient,[*]Xzawed.Keycloak.Admin.*,[*]Xzawed.Keycloak.KeycloakClient"`(실측 라인 97.34%/브랜치 93.47%)
- 로컬 배포 빌드 검증(업로드 없이): `dotnet pack src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release` → `Xzawed.Keycloak.Sdk.<version>.nupkg`(+ `.snupkg`) 생성 확인
- 실제 NuGet 배포는 로컬에서 실행하지 않는다 — `dotnet-v*` 태그 push 시 `.github/workflows/dotnet-release.yml`에서 `NUGET_API_KEY` 시크릿으로 실행(사람 승인 게이트; 시크릿 미설정 시 push 스텝은 스킵)
- 패키지 `Xzawed.Keycloak.Sdk`는 net8.0 타깃·async-first(`Task<T>`+`CancellationToken`)이며 XML 문서(`GenerateDocumentationFile`)를 포함 — 소비자 측 IntelliSense 지원
- ⚠️ SDK 10 기본 솔루션 포맷은 `.slnx` — 이 리포는 `dotnet new sln --format sln`으로 생성한 `Keycloak.Sdk.sln`(구 포맷) 사용. `AnalysisLevel=8.0`으로 로컬(SDK 10)/CI(SDK 8) 애널라이저 밴드 일치. `GenerateDocumentationFile`/패키징 props는 `Directory.Build.props`에서 `IsTestProject != true`로 게이트(테스트 프로젝트의 CS1591 격상 방지)

### PHP 툴체인 (빌드 명령)

PHP는 포터블 설치 `C:\Users\dirtc\tools\php`(8.3.32 NTS x64 — ext: openssl/curl/mbstring/fileinfo/sodium/zip/json, 리포지토리 미커밋)를 사용한다. Composer(`composer.phar` + bash shim)와 Xdebug 3.5.3(zend_extension, 기본 mode off)도 같은 경로에 있다. 프리픽스를 인라인 지정하고 명령은 `php/`에서 실행한다:
```bash
export PATH="/c/Users/dirtc/tools/php:$PATH" OPENSSL_CONF="C:\Users\dirtc\tools\php\extras\ssl\openssl.cnf"
cd php && composer install                                    # 의존성 설치
cd php && vendor/bin/phpunit --testsuite unit                  # 단위테스트 64개. Docker 불필요
cd php && vendor/bin/phpunit --testsuite integration           # 통합테스트 3개(Docker 필요 — docker CLI 셸아웃, 실제 Keycloak 26.6)
cd php && vendor/bin/phpstan analyse                           # 정적분석(level max + strict-rules + phpunit 확장)
cd php && vendor/bin/php-cs-fixer fix --dry-run --allow-risky=yes   # 스타일 검사(--allow-risky는 declare_strict_types risky rule에 필요)
```
- 단일 테스트: `vendor/bin/phpunit --filter <TestName> tests/Unit/<Path>Test.php`
- 커버리지 게이트(로직 라인 ≥90%, 네트워크 경계 omit): `XDEBUG_MODE=coverage vendor/bin/phpunit --testsuite unit --coverage-clover clover.xml` → `phpunit.xml`의 `<source><exclude>`가 `AuthClient`/`Admin/**`/`KeycloakClient`를 이미 제외하므로 clover의 `project.metrics`를 그대로 집계(실측 100.00%)
- ⚠️ `OPENSSL_CONF`는 로컬 RSA 키 생성(`JwtValidatorTest`)에 필요 — 없으면 openssl 확장이 시스템 기본 cnf를 못 찾아 키 생성이 실패한다.
- PHP 8.3.32 NTS · Composer 2.10 · Xdebug 3.5.3은 머신 전용 경로(리포지토리에 커밋 안 함, CI는 `shivammathur/setup-php` 사용).
- 배포명 `xzawed/keycloak-sdk`. Packagist는 레지스트리 업로드가 아니라 GitHub 웹훅으로 태그를 자동감지해 게시하므로 실제 배포는 로컬에서 실행하지 않는다 — `php-v*` 태그 push 시 `.github/workflows/php-release.yml`이 verify(`composer audit`+`phpstan`+단위테스트) 후 GitHub Release를 생성한다(사람 승인 게이트; Packagist에 `xzawed/keycloak-sdk` 저장소 등록은 1회 수동 선행).

### Rust 툴체인 (빌드 명령)

Rust는 시스템 설치(MSRV 1.88, edition 2024)를 사용한다. **Windows 로컬 빌드는 VS2019 BuildTools MSVC 환경(`vcvars64.bat`)이 필요**하다(`ring`/`rsa` 등 네이티브 의존성 컴파일 — CI의 ubuntu-latest는 무관). 명령은 `rust/`에서 실행한다:
```bash
cd rust && cargo build --all-targets              # 빌드(examples/tests 포함)
cd rust && cargo fmt --all --check                # 포맷 검사
cd rust && cargo clippy --all-targets -- -D warnings  # 린트(0 경고 게이트)
cd rust && cargo test                              # 단위테스트 34개. Docker 불필요
cd rust && cargo test --test integration_test -- --ignored  # 통합 E2E 1개(Docker 필요 — testcontainers, 실제 Keycloak 26.6)
cd rust && cargo run --example quickstart           # QuickStart 예제 실행(Keycloak 필요)
```
- 단일 테스트: `cargo test <test_name>` (예: `cargo test rejects_none_alg`)
- 커버리지 게이트(로직 모듈 라인 ≥90%, 네트워크 경계 omit): `rustup component add llvm-tools-preview` → `cargo install cargo-llvm-cov --locked` → `cargo llvm-cov --ignore-filename-regex '(auth|admin|client)\.rs' --fail-under-lines 90` — **실측 94.85%**(855줄 중 44줄 미실행; 파일별 `error.rs`/`oidc.rs` 100%·`jwks.rs` 96.05%·`token_provider.rs` 95.86%·`jwt.rs` 94.26%·`config.rs` 94.29%·`tokens.rs` 87.93%. 상세는 [verification-log-rust.md](docs/governance/verification-log-rust.md) 참고)
- ⚠️ **로컬 셸에서 정규식 인자(`(auth|admin|client)\.rs`)에 포함된 `|`가 셸/배치 파서에 파이프로 오인될 수 있다** — PowerShell에서 배치 래퍼를 거칠 때는 `--ignore-filename-regex="(auth|admin|client)\.rs"`처럼 값 전체를 하나의 인자로 묶거나, 정규식을 하드코딩한 전용 스크립트를 쓴다(CI의 YAML `run:` 블록은 셸이 다르므로 이 문제가 없다).
- ⚠️ **`cargo-llvm-cov`는 `llvm-tools-preview` rustup 컴포넌트 미설치 시 인터랙티브 확인("Proceed? [Y/n]")으로 자동 설치를 시도한다** — 비대화형 셸(CI 잡, 자동화 스크립트)에서는 이 프롬프트가 응답을 받지 못해 **무기한 행(hang)** 된다(자식 프로세스 CPU 시간이 0에 가까운 것으로 진단 가능). `rustup component add llvm-tools-preview`를 먼저 명시 실행해 사전 설치하면 이후 호출이 프롬프트 없이 진행된다. CI의 `taiki-e/install-action@cargo-llvm-cov`는 이 설치를 자체 처리하므로 CI에서는 발생하지 않는다.
- 실제 crates.io 배포(`cargo publish`)는 로컬에서 실행하지 않는다 — `rust-v*` 태그 push 시 `.github/workflows/rust-release.yml`에서 `CARGO_REGISTRY_TOKEN` 시크릿으로 실행(사람 승인 게이트)
- 크레이트명 `keycloak-sdk`(루트 모듈 `keycloak_sdk`), MSRV 1.88(edition 2024 + let-chain 문법 요구 — `jwks.rs`의 `if let ... && let ...`). CI 매트릭스는 1.88(MSRV 회귀 방지)·stable.

### Ruby 툴체인 (빌드 명령)

Ruby는 포터블 설치 `C:\Users\dirtc\tools\ruby`(3.4.10, non-devkit RubyInstaller — 리포지토리 미커밋)를 사용한다. 프리픽스를 인라인 지정하고 명령은 `ruby/`에서 실행한다:
```bash
export PATH="/c/Users/dirtc/tools/ruby/bin:$PATH"
cd ruby && bundle install                                     # 의존성 설치
cd ruby && bundle exec rspec                                   # 단위테스트 73개 + 커버리지 게이트(라인≥90%/브랜치≥85%). Docker 불필요
cd ruby && RUN_INTEGRATION=1 bundle exec rspec spec/integration --tag integration  # 통합 1개(Docker 필요 — docker CLI 셸아웃, 실제 Keycloak 26.6)
cd ruby && bundle exec rubocop                                 # 린트
cd ruby && bundle exec bundler-audit check --update            # 의존성 취약점 감사
```
- 단일 테스트: `bundle exec rspec spec/unit/<path>_spec.rb -e "<example name>"`
- 로컬 배포 빌드 검증(업로드 없이): `gem build keycloak-sdk.gemspec` → `keycloak-sdk-0.1.0.gem` 생성 확인(`gemspec`의 `spec.files`가 `lib/**/*.rb`+`LICENSE`+`README.md`를 포함 — 둘 다 `ruby/`에 로컬 사본 필요)
- 실제 RubyGems 배포는 로컬에서 실행하지 않는다 — `ruby-v*` 태그 push 시 `.github/workflows/ruby-release.yml`에서 RubyGems Trusted Publishing(OIDC, 저장 시크릿 없음)로 실행(사람 승인 게이트; 최초 1회는 API 키 수동 게시 또는 rubygems.org UI에서 Trusted Publisher 사전등록 필요 — gem이 존재하기 전에는 Trusted Publisher를 붙일 수 없다)
- ⚠️ **로컬 Windows 빌드는 MSYS2/DevKit이 필요하다.** 네이티브 gem(racc·prism·bigdecimal 등 — Windows precompiled 없음) 컴파일 때문(Rust의 VS2019 BuildTools와 동류, CI ubuntu-latest는 무관). MSYS2 pacman의 c-ares 리졸버가 이 네트워크에서 DNS를 못 풀어(mingw curl/MSYS2 wget은 정상) `msys64/etc/pacman.conf`의 `XferCommand = /usr/bin/wget --timeout=30 -O %o %u`(wget=getaddrinfo=hosts 사용)+origin-pinned mirrorlist+`/etc/hosts` 핀으로 우회 후 `ridk install 3`(mingw dev toolchain, 1회) 필요.
- ⚠️ `rubocop -a`(자동수정)가 Windows에서 CRLF를 쓸 수 있다 — Write 도구로 직접 덮어써 LF를 유지한다(`.gitattributes`의 `eol=lf`가 커밋 시점 정규화는 하지만 로컬 워킹트리 파일 자체는 CRLF로 남을 수 있음).
- 배포명 `keycloak-sdk`(gem), require명 `keycloak_sdk`(모듈 `KeycloakSdk` — 기존 `keycloak` gem의 `Keycloak` 모듈과 충돌 회피). Ruby 개발 3.4.10 / `required_ruby_version >= 3.2`(CI 매트릭스 3.2/3.3/3.4).

### Kotlin 툴체인 (빌드 명령)

Kotlin은 JDK 21(Eclipse Temurin `jdk-21.0.8.9-hotspot`) + 포터블 Gradle `9.6.1`(로컬 실행용)을 사용한다(래퍼도 동일하게 `9.6.1` — `kotlin/gradle/wrapper/gradle-wrapper.properties`). 프리픽스를 인라인 지정하고 명령은 `gradle -p kotlin <task>`(또는 `kotlin/`에서 `./gradlew`)로 실행한다:
```bash
export JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/gradle-9.6.1/bin:$PATH" GRADLE_USER_HOME="/c/Users/dirtc/.gradle"
gradle -p kotlin build              # 빌드
gradle -p kotlin test               # 단위테스트 100개. Docker 불필요
gradle -p kotlin integrationTest    # 통합 E2E 1개(Docker 필요 — Testcontainers/dasniko, 실제 Keycloak 26.6)
gradle -p kotlin koverVerify        # 커버리지 게이트(로직 모듈 라인≥90%/브랜치≥85%, 네트워크 경계 omit)
gradle -p kotlin ktlintCheck        # 린트(무경고; 수정은 ktlintFormat)
```
- 단일 테스트: `gradle -p kotlin test --tests "*<ClassName>"`
- 커버리지 게이트(Kover, 네트워크 경계 omit): `gradle -p kotlin koverVerify` — **실측 라인 99.24%/브랜치 85.71%**(omit 대상 `AuthClient*`/`admin.*`/`KeycloakClient*` — 통합 E2E로 검증). 상세는 [verification-log-kotlin.md](docs/governance/verification-log-kotlin.md) 참고
- 로컬 배포 빌드 검증(업로드 없이): `gradle -p kotlin publishToMavenLocal` → 로컬 `~/.m2`에 `keycloak-sdk-kotlin-0.1.0.jar`(+`-sources.jar`/`-javadoc.jar`, Dokka) 생성 확인
- 실제 Maven Central 배포는 로컬에서 실행하지 않는다 — `kotlin-v*` 태그 push 시 `.github/workflows/kotlin-release.yml`에서 vanniktech maven.publish로 `publishToMavenCentral`(Central Portal 스테이징) 실행(`ORG_GRADLE_PROJECT_` 접두 in-memory GPG 시크릿) 후, 사람이 Portal 콘솔에서 수동 release하는 2단계 승인 게이트(human-gated, 미실행)
- 좌표 `io.github.xzawed:keycloak-sdk-kotlin`. Kotlin 2.4.10 · JDK 21 타깃(`jvmToolchain(21)`) · `explicitApi()`로 public API 가시성 엄격 강제 — 소비자 측 코틀린 API 문서화 요구가 컴파일 타임에 강제됨
- ⚠️ **`gradle --stop`을 빌드 인플라이트 중 실행 금지** — `--no-daemon`도 jvmargs 때문에 단일-사용 데몬을 fork하므로 진행 중 빌드를 죽인다(동일 프로젝트에 gradle 2개 동시 실행도 락 경합으로 금지). kill 후 stale 빌드 상태는 `gradle -p kotlin clean`으로 복구
- ⚠️ ktlint의 소문자 다중선언 파일명(`errors.kt`/`masking.kt`/`tokens.kt`/`client.kt` 등, 모노레포 공통 관용) 규칙은 `kotlin/.editorconfig`의 `ktlint_standard_filename = disabled`로 비활성 — 커밋 전 `ktlintFormat`으로 나머지 포매팅 자동정렬

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

- ⚠️ **admin-client 버전 ≠ 서버 버전.** Keycloak 서버는 26.6.4지만 `keycloak-admin-client`는 독립 트랙 **26.0.11**이다("26.6.x admin-client"는 존재하지 않음). 하나의 클라이언트가 여러 서버 버전을 지원한다. `representation` 필드가 서버와 완전히 일치하지 않을 수 있으니 의존 필드는 실제 서버로 검증한다.
- ⚠️ **Maven Central은 Central Portal 경로만.** 구 OSSRH는 2025-06-30 종료. `central-publishing-maven-plugin:0.11.0` 사용(공식 문서 예제의 0.9.0은 낡음).
- ⚠️ **Testcontainers 2.0 모듈명 변경.** JUnit5 확장 모듈은 `org.testcontainers:testcontainers-junit-jupiter`(구 `junit-jupiter` 아님). `testcontainers-keycloak:4.3.1`은 KC 26.6 기본.
- ⚠️ **JWT 검증 강화 필수(CVE-2026-11800).** 알고리즘 핀닝(`none` 거부·헤더 신뢰 금지), iss/aud 검증, 클록 스큐 제한. Nimbus는 building block만 제공하고 안전한 기본값은 주지 않는다.
- ⚠️ **보안**: 토큰/시크릿 로깅 금지·마스킹(완전 불투명 `***`, 접두 노출 없음), TLS 검증 기본 on, 기본 인메모리 토큰 저장 + 교체 가능한 `TokenStore` SPI.
- ⚠️ **시크릿 메모리 위생은 경계가 있다.** Java `KeycloakConfig`는 시크릿을 `char[]`(방어적 clone)로 보관하나, 하위 라이브러리(Nimbus `Secret`·keycloak-admin-client, Python은 `str`)가 `String`을 요구해 사용 시점에 소거 불가 `String`으로 복사된다 — char[]는 심층방어일 뿐 end-to-end 소거 보장이 아니다(HTTP Basic 직렬화·라이브러리 내부 보존 때문). 과대광고 금지.
- ⚠️ **JWKS 재조회는 DoS-안전해야 한다(Python, 2026-07-03 감사).** 서명 위조(`BadSignatureError`)는 certs 재조회를 유발하지 않고, 키(kid) 미해결(`InvalidKeyIdError`→`TokenKeyError`)에만 재조회하며, 재조회 자체도 최소 간격(`_jwks_min_refetch`)으로 rate-limit한다 — 위조 Bearer 토큰마다 IdP를 때리는 미인증 DoS 증폭 차단. Java(Nimbus `JWKSourceBuilder`)는 캐시+RateLimited로 이미 안전.
- ⚠️ **admin 타임아웃·자원 정리.** Java `AdminClient`는 `config`의 connect/read 타임아웃을 `KeycloakBuilder.resteasyClient(...)`로 반드시 주입해야 admin 호출이 무한 대기하지 않는다(미주입=스레드 고갈 DoS). 파사드 `close()`/`aclose()`는 admin뿐 아니라 **auth 세션(requests/httpx)까지** 정리한다(미정리=FD/커넥션 풀 누수).
- ⚠️ **어떤 Java OIDC 라이브러리도 자체 "certified" 아님.** 완성 제품을 필요 시 OIDF에 인증한다.
- ⚠️ **Java 17+ javadoc은 doclint 기본 엄격.** `release` 프로파일의 `maven-javadoc-plugin`에 `<doclint>none</doclint>` + `<failOnError>false</failOnError>`를 주지 않으면 문서 경고로 `-javadoc.jar` 생성이 실패할 수 있다.
- ⚠️ **Java 런타임 타깃은 21 LTS(2026-07-03 업그레이드).** `maven.compiler.release=21` + enforcer `requireJavaVersion=[21,)`로 JDK 21 미만 빌드를 fail-fast. `maven-compiler-plugin`은 pluginManagement에서 `3.11.0`으로 명시 고정(기본값 드리프트 방지). CI(`ci.yml` build matrix·integration, `release.yml`)는 모두 JDK 21 단일 사용.
- ⚠️ **jackson-databind는 2.22.1 고정(dependencyManagement, dependabot 유지).** 초기 CVE 대응(2026-07-03)으로 계열 6종을 2.21.2→2.21.4→2.21.5(CVE-2026-54515)까지 상향했고, 이후 **dependabot PR #53(java-minor-patch, merge)로 jackson 계열 6종을 2.22.1**(annotations는 별도 트랙 2.22)로 상향 — enforcer `DependencyConvergence` + 전 모듈 `mvn verify -DskipITs` GREEN 확인. **보안 불변식(위반 시 노출 재개)**: SDK는 자체 `ObjectMapper`/default·polymorphic typing을 쓰지 않고 신뢰된 Keycloak 응답만 고정 representation POJO로 역직렬화한다 — default typing 활성화·커스텀 JAX-RS Jackson provider 등록·미신뢰 JSON의 다형성 역직렬화를 도입하지 말 것. 상세: [verification-log.md](docs/governance/verification-log.md).
- ⚠️ **(Node) admin-client `findOne`/`findOneByName`은 404에서 `null` 반환(선언 타입은 `undefined`).** `get()`류는 `null`/`undefined`를 모두 부재로 보고 `KeycloakNotFoundError`로 변환한다(`admin/call.ts`의 `requireFound`). `=== undefined`만 검사하면 삭제 후 조회가 NotFound 대신 `null`을 반환하는 버그 — 통합테스트가 포착했다.
- ⚠️ **(Go) gocloak은 네트워크 실패까지 `*gocloak.APIError`로 감싼다(`Code:0`).** `toSDKError`는 `Code==0`이면 `*TransportError`, `>0`이면 `*AdminError`로 나눈다 — 그러지 않으면 연결 거부/DNS 실패가 `AdminError{HTTP 0}`로 오분류되고 `errors.As(err, &TransportError)` 경로가 死코드가 된다(리뷰 포착).
- ⚠️ **(Go) go-jose는 `exp` 부재 시 만료검사를 건너뛴다.** `jwt.Validate`는 `claims.Expiry == nil`을 명시 거부해야 무만료 토큰 통과를 막는다(Java/Python 동형). `ValidateWithLeeway`만 믿으면 안 됨. JWKS 재조회는 초기(non-forced) 로드에 `forcedAt`를 소모하지 않아야 첫 키회전 재조회가 허용되고(Python `-inf` 동형), 동시 미스는 `singleflight`로 수렴한다(IdP 폭주 상한).
- ⚠️ **(Go) 최소 런타임 Go 1.25**(`x/oauth2` v0.36 요구). `go.mod`의 `go` 지시자를 1.24로 낮추면 `go mod tidy`가 다시 1.25로 올린다(의존성 요구). Validator의 JWKS `http.Client`는 `Config.ReadTimeout`을 주입해야 한다(미주입 시 `http.DefaultClient` 무한대기 — hung IdP에 영원히 블록). TLS는 Go `http.Client`가 https를 기본 검증하고 http는 투명 처리하므로 `allowInsecure` 로직 불필요(Node와 차이).
- ⚠️ **(Node) openid-client v6 함수형 API·타임아웃·TLS.** 타임아웃은 `Configuration.timeout`(초, 내장 프로퍼티)로 주입한다. admin-client 타임아웃은 `ConnectionConfig.timeout`(**ms**)로 주입(`requestOptions`는 `Omit<RequestInit,"signal">`이라 signal 주입 불가). TLS는 기본 강제 — `serverUrl`이 `http://`일 때만 `allowInsecureRequests`를 적용한다(로컬/테스트 완화, https는 강제 유지).
- ⚠️ **(Node) PKCE `exchangeCode`는 `nonce`를 반드시 전달해야 한다.** `createAuthorizationRequest`가 nonce를 실으면 Keycloak이 id_token에 담아 돌려주고, openid-client v6는 이를 자동 검증하므로 기대 nonce를 주지 않으면 "unexpected nonce"로 **전면 거부**한다(리뷰 HIGH 결함). 마스킹: `TokenSet`은 access/refresh 토큰을, `KeycloakConfig`는 `clientSecret`을 `toString`/`toJSON`/`util.inspect`에서 마스킹한다(속성 접근·스프레드는 유지). JWKS는 jose `createRemoteJWKSet`의 `cooldownDuration`으로 DoS-안전(kid 미해결 시에만 재조회).
- ⚠️ **(Node) admin은 만료 시 재인증하도록 SDK provider를 `registerTokenProvider`로 배선한다 — `kc.auth()` 미호출(PR #63, 배포 전 하드닝).** `@keycloak/keycloak-admin-client`의 내장 TokenManager는 액세스 토큰 만료 시 `#refreshAccessToken`에서 refresh_token 그랜트만 시도하고 client_credentials 재인증 폴백이 없다 — 그대로 위임하면 **최초 토큰 만료(≈accessTokenLifespan−MIN_VALIDITY, 기본 ~4.5분) 후 모든 admin 호출이 "Cannot refresh token: missing refresh token or credentials"로 500 영구 실패**(장수명 서버 치명). 파사드가 `new ClientCredentialsTokenProvider(this.auth)`를 `AdminClient.create(config, provider)`로 주입하고 admin이 `kc.registerTokenProvider(...)`로 등록해 만료 시 client_credentials로 재인증한다. 부가로 `kc.auth()`를 안 부르므로 admin-client 26.7.x가 부재한 refresh_token을 `decodeToken(undefined).split()`로 파싱하다 크래시하는 경로도 회피(그래서 이 배선이 원래의 `~26.6.4` 핀[PR #62]보다 근본적 — 26.7.0에서도 크래시·만료 둘 다 무영향). **이 무영향이 통합테스트로 실증되어(admin 5-리소스 E2E GREEN·크래시 0) dependabot PR #48로 핀을 `~26.7.0`으로 전진**했다 — 핀은 이제 provider 배선의 심층방어 보조일 뿐이다. **⚠️ 9언어 중 node만 취약**: JVM admin-client(Java/Kotlin)는 `TokenManager.refreshToken()`이 refresh 부재 시 `grantToken()` 재인증 폴백 보유(바이트코드 확정), go/dotnet/rust/ruby는 자체 캐싱 provider, python/php는 하위 라이브러리가 만료 시 재인증 — 전부 SAFE. 재현: realm `accessTokenLifespan`을 낮춰(마스터 admin `PUT /admin/realms/it-realm {accessTokenLifespan:60}`) admin op → 45s 대기 → op(만료 후) 관찰.
- ⚠️ **(C#) `Keycloak.AuthServices.Sdk` 3.0.0은 net10.0 전용 → net8.0은 2.7.0 핀.** 2.7.0이 `Microsoft.Extensions.DependencyInjection.Abstractions >= 9.0.8`을 요구하므로 낮은 핀은 NU1605(downgrade)로 `TreatWarningsAsErrors` 하드오류가 된다.
- ⚠️ **(C#) admin 타입드 커버리지는 users/groups/realm-get뿐이다**(`IKeycloakUserClient`/`IKeycloakGroupClient`/`IKeycloakRealmClient`). clients/roles/realm-CRUD는 같은 bearer-authed `HttpClient`로 **raw Admin REST**다. 편의 `…Async`는 default interface method라 변수를 `IKeycloakClient`로 타입해야 호출 가능하고, `CreateUserAsync`는 `void` 반환이라 `CreateUserWithResponseAsync` + `Location` 헤더 파싱으로 id를 얻는다.
- ⚠️ **(C#) 네임스페이스 셰도잉**: `namespace Xzawed.Keycloak.Admin` 안에서 `new KeycloakClient(http)`를 쓰면 파사드 `Xzawed.Keycloak.KeycloakClient`(private ctor)에 바인딩되어 CS1729가 난다(실제 컴파일로 포착) — `using KcAdminClient = Keycloak.AuthServices.Sdk.Admin.KeycloakClient;` 별칭이 필요하다.
- ⚠️ **(C#) `record` 자동 `ToString()`은 토큰/시크릿을 전체 노출한다.** `TokenSet`·`KeycloakConfig`는 `ToString()` override와 `JsonConverter<T>`(`JsonSerializer.Serialize` 경로) 둘 다 마스킹한다. **단, 리플렉션 기반 구조분해 로거(Serilog `{@}`)는 raw 프로퍼티를 직접 읽어 이 마스킹을 완전히 우회한다** — `JsonConverter`는 Serilog destructuring 경로를 커버하지 않으므로 `TokenSet`/`KeycloakConfig`를 `{@}`로 구조분해하지 말 것.
- ⚠️ **(C#) `HttpClient.Timeout` 만료는 `TaskCanceledException`(=`OperationCanceledException`)이지 `HttpRequestException`이 아니다.** admin 경계 헬퍼는 `catch (OperationCanceledException ex) when (ex.InnerException is TimeoutException)`로 `KeycloakTransportException`으로 변환해야 hung IdP가 하드닝된다.
- ⚠️ **(C#) JWT: `JsonWebTokenHandler.ValidateTokenAsync`는 실패해도 예외를 던지지 않는다** — `result.IsValid`로 검사해야 한다. `ValidAlgorithms` 기본값은 `null`(=모든 알고리즘 허용)이라 `["RS256"]`로 반드시 핀해야 하고, `ClockSkew` 기본값은 5분이라 30초로 줄인다. `RequireExpirationTime=true`로 `exp` 없는 토큰을 거부한다(다른 4개 언어와 동형). JWKS는 `TokenValidationParameters.ConfigurationManager`(`RefreshInterval`이 DoS 스로틀)로 재조회한다. **테스트 함정**: `JsonWebTokenHandler.CreateToken`은 `exp`를 자동 주입하므로 no-exp 테스트는 `SetDefaultTimesOnTokenCreation=false`를 명시해야 실제로 exp 없는 토큰이 만들어진다.
- ⚠️ **(C#) `POST /admin/realms`(신규 realm 생성)는 master realm 전용이다.** 어떤 realm의 service account(가장 넓은 realm-management 롤 포함)로도 403 — 기존 realm에 대한 연산이 아니라 전역 부트스트랩 권한이기 때문이다(E2E는 master realm bootstrap admin으로 검증).
- ⚠️ **(C#) Duende.IdentityModel 확장 메서드는 예외를 던지지 않는다**(`resp.IsError` 검사 필요). Keycloak은 잘못된 client 자격증명에 **401**을 반환하므로(`ErrorType=Http`) OAuth 에러 코드는 `resp.Json["error"]`에서 읽어야 한다. PKCE 헬퍼는 라이브러리에 없어 수동 생성, introspection은 `IntrospectTokenAsync`, logout은 수동 POST다.
- ⚠️ **(C#) SDK 10 기본 솔루션 포맷은 `.slnx`다** — `dotnet new sln --format sln`으로 구 포맷 `.sln`을 명시 생성해야 한다. `AnalysisLevel=8.0`으로 로컬(SDK 10)·CI(SDK 8) 애널라이저 밴드를 일치시킨다. `GenerateDocumentationFile`은 `IsTestProject != true`로 게이트해야 테스트 프로젝트의 public 멤버가 CS1591로 빌드 실패하지 않는다.
- ⚠️ **(C#) `AddKeycloak(config)`는 `KeycloakClient`뿐 아니라 `KeycloakConfig`도 싱글턴으로 등록한다.** 소비자가 `IServiceCollection`에 자기 `KeycloakConfig`를 별도로 `AddSingleton`하면 등록이 중복돼 해석이 모호해질 수 있다 — `AddKeycloak` 호출 후에는 별도로 `KeycloakConfig`를 등록하지 말 것.
- ⚠️ **(PHP) fschmtt `Users::create()`는 void 반환.** 생성된 id는 `findIdByUsername()`(내부적으로 `search()`)로 후속 조회해야 한다. `Clients`/`Realms`는 `create`가 아니라 **`import`**이고, 대상 representation에 `id`/`realm`을 미리 세팅해야 내부 재조회(re-GET)가 성립한다. fschmtt는 Guzzle 예외를 SDK 타입으로 변환하지 않으므로 경계(`ErrorTranslation`)에서 404/409/403뿐 아니라 **base `RequestException`**(TLS 검증 실패·malformed URI 등 non-HTTP 전송 실패)까지 흡수해야 한다.
- ⚠️ **(PHP) league/stevenmaguire의 `pkceMethod` 생성자 옵션은 no-op이다** — 내부에서 재계산돼 무시된다. `PkceKeycloakProvider::getPkceMethod()`를 오버라이드해야 S256이 실제로 강제된다. `exchangeCode()`는 무상태라 OAuth `state` 파라미터를 검증하지 않는다(호출자가 콜백에서 대조할 책임 — Node/Go/C# SDK와 동형).
- ⚠️ **(PHP) firebase/php-jwt는 `&$headers` out-파라미터를 성공 디코드 후에만 채운다.** alg를 사전 신뢰해 검증에 쓰면 위조 방지가 안 되므로, 원본 토큰의 **첫 세그먼트를 직접 base64url 디코드**해 alg를 사전 게이트해야 한다. 내장 `CachedKeySet`은 rate-limit 버그(GitHub #543)로 미사용(자체 `JwksStore`). 악성 JWKS 모듈러스(`n`이 배열)에 firebase/php-jwt가 던지는 `\TypeError`(`\Error`의 서브클래스 — `\Exception` 아님)까지 `catch(\Throwable)`로 경계 전면화해야 한다(놓치면 미변환 예외가 공개 API로 누출).
- ⚠️ **(PHP) `JwksStore`의 rate-limit은 per-instance 메모리 상태다.** 장수명 워커(Swoole/RoadRunner)에서는 요청 간 유효하지만, 클래식 per-request PHP-FPM은 요청마다 fresh store가 생성되어 DoS 보호가 **요청 내에서만** 유효하다 — 배포모델 의존적 한계를 과대광고하지 말 것.
- ⚠️ **(PHP) 시크릿 메모리 위생은 언어 차원에서 불가능하다** — PHP에는 char[] 같은 소거 가능한 문자열 타입이 없어 `clientSecret`은 항상 일반 `string`이다. 마스킹(`__toString()`의 `***`)은 심층방어일 뿐 end-to-end 소거 보장이 아니다(다른 5개 언어와 동일한 근본 한계).
- ⚠️ **(PHP) 통합테스트는 Testcontainers가 아니라 docker CLI 셸아웃이다.** Windows native PHP 빌드는 testcontainers-php가 요구하는 `unix://` 스트림 트랜스포트가 컴파일되어 있지 않고, Docker Desktop(Windows)의 기본 컨텍스트도 named pipe(`npipe://`)라 TCP 폴백도 불가 — `KeycloakContainerTrait`가 `docker run`/`docker port`/`docker rm`을 `exec()`로 직접 구동한다(ubuntu CI 러너에서는 동일하게 동작). `phpunit.xml`의 integration testsuite는 `suffix="IT.php"`를 명시해야 한다(누락 시 기본 패턴 `*Test.php`로 IT가 무음 스킵된다 — Task 1 스캐폴딩에서 실제로 발생했던 결함).
- ⚠️ **(Rust) `keycloak` crate와 `openidconnect`는 reqwest 메이저 버전이 반드시 정렬돼야 한다.** `openidconnect` 4.0.1은 reqwest **0.12**를 고정하는데 `keycloak` crate의 기본 HTTP 백엔드는 다른 라인이라 `reqwest12` feature(`default-features = false`)를 명시해야 두 크레이트가 같은 `reqwest::Client` 타입을 공유한다 — 안 맞추면 타입 불일치로 컴파일이 실패한다(스캐폴딩 단계의 확정 사항, `Cargo.toml` 주석에 명문화).
- ⚠️ **(Rust) `openidconnect`의 `CoreClient`는 6개 엔드포인트 typestate 파라미터를 갖는 제네릭이다.** auth/introspection/token만 `EndpointSet`으로 명시해 구체 타입 별칭(`KcOidcClient`)을 만들어야 `exchange_code`/`exchange_client_credentials`/`introspect` 빌더가 `?` 없이 호출 가능(infallible)해진다(device/revocation/userinfo는 `EndpointNotSet`으로 미사용). id_token은 openidconnect의 자체 검증기 대신 SDK의 강화 `JwtValidator`가 access_token을 검증하므로 `CoreClient::new`에 빈 `JsonWebKeySet`을 넘긴다 — openidconnect가 자체적으로 id_token 서명을 검증하지 않는다는 뜻이며, 이는 의도된 설계다.
- ⚠️ **(Rust) `jsonwebtoken`의 `Validation` 기본값은 안전하지 않다.** `validate_nbf` 기본 `false`(미래 `nbf` 통과 허용) → SDK가 `true`로 강화. `leeway` 기본 60초 → SDK가 `config.clock_skew`(기본 30초)로 강화(테스트가 leeway=60이면 통과했을 45초-만료 토큰을 leeway=30에서 거부함을 실증). `set_required_spec_claims(&["exp","iss","aud"])`로 세 클레임 부재를 명시 거부한다. 헤더 `alg`는 신뢰하지 않고 `v.algorithms = vec![Algorithm::RS256]`로 고정 핀(`Algorithm` enum에 `none` 변형 자체가 없어 `alg:"none"` 헤더는 `decode_header` 단계에서 구조적으로 거부됨).
- ⚠️ **(Rust) JWKS 재조회 rate-limit은 재조회 *결정 시점*에 stamp한다(Go/Python 동형).** `JwksStore::get_key`의 `refetch_gate`는 fetch *성공 후*가 아니라 재조회를 하기로 결정한 순간 즉시 갱신된다 — IdP 장애로 fetch가 실패해도 gate는 이미 소모되므로, 장애창에서 위조 kid를 연속 주입해도 재시도가 상한된다(회귀테스트 `fetch_failure_still_stamps_gate_rate_limiting_next_lookup`가 certs 엔드포인트 히트 수를 정확히 카운트해 증명).
- ⚠️ **(Rust) `KeycloakClient`의 공유 `reqwest::Client`는 `redirect::Policy::none()`으로 리다이렉트를 전면 차단한다(SSRF 하드닝).** Keycloak 응답이 예상 밖의 3xx로 내부망 주소를 가리키더라도 SDK가 자동으로 따라가지 않는다 — auth·admin·JWKS 조회 모두 이 공유 클라이언트(connect/read 타임아웃 주입됨)를 재사용한다.
- ⚠️ **(Rust) MSRV는 1.88이다** — `edition = "2024"` + `let`-chain(`if let ... && ...` — `jwks.rs`의 `get_key`·`token_provider.rs`가 사용) 문법이 요구하는 최소 버전(let-chain은 1.88 stable). CI 매트릭스는 1.88(MSRV 회귀 방지)·stable 둘 다 검증한다.
- ⚠️ **(Rust) dev-dependency `testcontainers` `0.27.3`은 pre-1.0(API가 안정화 전).** `modules::keycloak` 같은 언어별 편의 모듈이 없어 `GenericImage` 베이스로 이미지·포트·헬스체크를 직접 조립한다(Go의 `testcontainers-go` v0.43과 동일한 이유로 base 모듈만 사용).
- ⚠️ **(Rust) RUSTSEC-2023-0071(rsa crate, "Marvin Attack")은 우리 사용에 무영향이다.** `rsa`는 dev-dependency로 테스트에서 RSA 키를 생성(`jwt.rs`의 JWKS 공격 프로브 픽스처)하는 데만 쓰인다 — 해당 advisory는 **개인키 복호화**의 타이밍 사이드채널이고 SDK의 런타임 경로는 `jsonwebtoken`으로 공개키 **서명검증만** 수행하므로 영향 경로가 없다. `cargo audit`는 CI에 아직 별도 잡으로 배선되지 않았다(Task 12 스코프 밖 — 향후 추가 시 이 advisory를 문서화된 예외로 처리).
- ⚠️ **(Rust) 로컬 Windows 빌드는 VS2019 BuildTools MSVC 환경이 필요하다.** `ring`(rustls의 암호 백엔드)·`rsa` 등 네이티브/C 컴파일 의존성 때문에 `vcvars64.bat`를 소싱한 셸에서 `cargo`를 실행해야 한다(CI의 ubuntu-latest는 무관 — gcc/clang 툴체인이 기본 존재).
- ⚠️ **(Rust) admin 파사드는 캐싱 `ClientCredentialsTokenProvider`를 쓴다 — 무캐시 `AuthClient`가 아니다(최종리뷰 Important, `79ecf76`).** `KeycloakClient::new`가 admin에 `auth`(`AuthClient`)를 그대로 주입하면 admin 호출마다 토큰을 재발급해 §4 캐시/single-flight 불변식(Go/Java/Python/Node/C#/PHP 6개 자매 SDK가 모두 지키는)을 위반한다 — 공유 `http` 클라이언트는 재사용하되 admin 전용 `ClientCredentialsTokenProvider` 인스턴스를 별도 생성해 주입해야 한다. 같은 커밋에서 `config.scopes`가 token-provider의 client-credentials 요청과 `AuthClient`의 authorization URL 양쪽에 threading됐다(이전엔 `"openid"` 하드코딩 — 커스텀 스코프가 무시됨).
- ⚠️ **(Ruby) `jwt`(ruby-jwt)의 기본값은 안전하지 않다.** `algorithms:` 미지정 시 `none` 포함 광범위 허용 → `["RS256"]`로 고정 핀. `verify_iss`/`verify_aud`/`verify_expiration`/`verify_not_before`가 기본 꺼짐 → 전부 `true`로 강화, `required_claims: %w[exp iss aud]` 명시, `leeway: config.clock_skew`로 클록 스큐 주입. **alg 핀은 키 조회/서명 검증 이전에 발동**(ruby-jwt 소스 확인)하므로 PHP(firebase/php-jwt `&$headers`가 성공 디코드 후에만 채워짐)와 달리 원본 헤더를 직접 base64url 디코드해 사전 게이트할 필요가 없다 — 구조적으로 안전.
- ⚠️ **(Ruby) `JwtValidator.new`에 nil `issuer`/`audience`를 넘기면 ruby-jwt의 `verify_iss`/`verify_aud`가 조용히 no-op이 된다.** `verify_iss:true`/`verify_aud:true`를 켜도 값이 nil이면 검사 자체를 건너뛰므로, 생성자에서 `issuer`/`audience`가 nil·공백이면 `ConfigError`로 fail-closed 방어한다(방어심층 — `from_config` 경로는 실제로는 항상 값이 있어 미발현이나, 공개 `new` 생성자 직접 호출 시 대비).
- ⚠️ **(Ruby) `JwksStore`의 rate-limit 가드는 nil 캐시(콜드-스타트 IdP 다운)에도 적용돼야 한다.** `return @cache if @cache && force && !refetch_allowed?`처럼 `@cache &&`를 앞에 걸면 캐시가 비어있는 최초 상태에서 rate-limit이 완전히 우회돼 위조 kid 폭주가 무제한 재조회를 유발한다 — `return @cache if force && !refetch_allowed?`(캐시 존재 여부와 무관하게 게이트 우선 확인)로 정정해야 한다(Task 6 리뷰 Important, Go/Python/Rust와 동일 클래스의 결함).
- ⚠️ **(Ruby) `rack-oauth2`의 PKCE는 1급 기능이 아니라 passthrough다.** S256 `code_verifier`/`code_challenge`는 SDK가 `SecureRandom`+`Digest::SHA256`+`Base64.urlsafe_encode64`로 손수 생성해 `access_token!(code_verifier:)`로 전달해야 한다(누락 시 Keycloak `invalid_grant`). `Rack::OAuth2::Client::Error`에는 `#error` 접근자가 없어 OAuth 에러 코드는 `e.response[:error]`에서 읽어야 하고(WBS 원안 버그, Task 8에서 자가수정), `client_credentials_token`의 scope는 위치인자가 아니라 `access_token!(scope: ...)` 키워드로 전달해야 실제로 전송된다(위치인자는 auth_method로 소비돼 무음 누락). `Bearer` 응답 객체에는 id_token 접근자가 없어 `raw_attributes[:id_token]`으로 직접 추출해야 한다. `Rack::OAuth2.http_config`의 블록 인자는 `Faraday::Connection` 자체가 아니라 그 `#options`(`Faraday::RequestOptions`)에 타임아웃을 설정해야 한다(`conn.open_timeout=`이 아니라 `conn.options.open_timeout=`).
- ⚠️ **(Ruby) admin에 성숙한 gem이 없어 `faraday`로 Admin REST를 직접 구현한다.** 딥리서치 후보였던 `looorent/keycloak-admin`은 외부 `TokenProvider` 주입 시임이 없어(자체 무캐시 토큰 라이프사이클) §4 결합 규칙에 비호환 — 대신 5리소스(`users`/`clients`/`realms`/`roles`/`groups`)를 Faraday로 직접 래핑했다. **base_url 조립은 `"{server_url}/"` + 리소스별 풀경로**(`admin/realms/{realm}/users` 등)여야 한다 — `"{server_url}/admin/realms/"` + 상대경로로 조립하면 Faraday URI-join이 트레일링 슬래시 있는 `POST /admin/realms/`를 만들어 실 KC/WebMock의 `/admin/realms`와 불일치한다(Task 9에서 발견·정정). `Users#create`/`Roles#create` 등은 201+`Location` 헤더에서 id(또는 role name)를 추출한다.
- ⚠️ **(Ruby) SimpleCov `minimum_coverage`는 프로세스 전역 게이트다.** 통합 스펙(`spec/integration`)만 단독 실행하면 로직 브랜치 대부분을 타지 않아 브랜치 커버리지가 게이트(85%) 미달로 떨어져 CI의 통합 잡이 실패한다 — `spec_helper.rb`에서 `minimum_coverage(...) unless ENV["RUN_INTEGRATION"]`로 가드해 통합 전용 실행에서는 게이트를 적용하지 않는다(단위 전용 실행의 게이트는 그대로 90/85 강제 — 실측: 통합 단독 실행 시 라인 90.48%/브랜치 39.13%로 게이트 미달치지만 가드 덕에 exit 0).
- ⚠️ **(Ruby) 로컬 Windows 빌드는 MSYS2/DevKit 네이티브 gem 컴파일 환경이 필요하다.** non-devkit RubyInstaller로는 `racc`/`prism`/`bigdecimal` 등(Windows precompiled 없음) 컴파일이 안 된다(Rust의 VS2019 BuildTools와 동류의 로컬 개발 마찰 — CI ubuntu-latest는 무관). 게다가 **MSYS2 pacman의 c-ares 리졸버가 이 네트워크에서 DNS 해석에 실패**(mingw curl·MSYS2 wget은 정상, `/etc/hosts` 핀도 c-ares는 무시) — `pacman.conf`의 `XferCommand = /usr/bin/wget --timeout=30 -O %o %u`(wget은 getaddrinfo 사용)+origin-pinned mirrorlist+`/etc/hosts` 핀 조합으로 우회 후 `ridk install 3`(1회)가 필요하다.
- ⚠️ **(Ruby) 최소 Ruby는 3.2, 개발/CI 상단은 3.4다.** Ruby 4.0이 이미 존재하지만 gem CI 매트릭스는 3.2/3.3/3.4까지만 검증한다(`required_ruby_version >= 3.2`). gem명은 `keycloak-sdk`(하이픈)이나 require/모듈명은 `keycloak_sdk`/`KeycloakSdk`(언더스코어) — 기존 `keycloak` gem이 이미 `Keycloak` 모듈을 점유하고 있어 충돌을 피하려는 의도적 명명이다.
- ⚠️ **(Ruby) `Config` 문자열 속성은 인스턴스 자체만 freeze되고 deep-frozen은 아니다.** `Config#server_url`/`#realm`/`#client_id` 등이 반환하는 `String` 객체 자체는 별도로 freeze되지 않는다(다른 언어 SDK의 동류 근본 한계와 동형 — 문자열 소거/불변성은 언어 차원에서 완전 보장되지 않음).
- ⚠️ **(Ruby) 시크릿 메모리 위생은 언어 차원에서 불가능하다** — Ruby `String`은 소거 가능한 타입이 아니므로 `client_secret`은 항상 일반 `String`이다. 마스킹(`inspect`의 `"***"`)은 심층방어일 뿐 end-to-end 소거 보장이 아니다(다른 7개 언어와 동일한 근본 한계).
- ⚠️ **(Ruby) `client.auth.validate`는 IdP 장애 시에도 `TransportError`를 raise할 수 있다(fail-closed, 의도).** JWKS 재조회가 전송 실패로 끝나면 검증이 통과 대신 명시적으로 실패해야 하므로, 호출자는 `TokenValidationError`뿐 아니라 `TransportError`도 함께 처리해야 한다.
- ⚠️ **(Ruby) `Faraday::SSLError`/`Faraday::ParsingError`는 `Faraday::Error`의 직계 형제**(`ConnectionFailed`/`TimeoutError`의 서브클래스가 아님)다. 모든 네트워크 경계(`token_provider`/`jwks_store`/`auth_client`/`admin/call`)는 `rescue Faraday::Error`로 넓게 잡아 TLS 검증 실패(만료/자가서명 인증서·MITM 프록시)·파싱 실패를 `TransportError`로 변환해야 한다(좁은 두 타입만 잡으면 raw `Faraday::SSLError`가 공개 API로 누출 — §4 위반, 최종리뷰 Important). `RaiseError` 미들웨어를 설치하지 않으므로(리소스가 `resp.success?`를 손수 검사) status 기반 `Faraday::ClientError`는 이 경계에 도달하지 않아 광범위 rescue가 안전하다.
- ⚠️ **(Kotlin) `fun interface` + `suspend`는 컴파일된다(KT-40978 해소).** 2.2.20에서 실증했고 현재 2.4.10에서도 유효하다. `TokenProvider`를 SAM 변환 가능한 함수형 인터페이스로 선언(`public fun interface TokenProvider { public suspend fun accessToken(): String }`) — 과거 버전에서 거부됐던 조합이 실증적으로 통과한다.
- ⚠️ **(Kotlin) ktlint filename 규칙은 이 모노레포와 충돌한다.** 언어 공통으로 소문자 다중선언 파일(`errors.kt`·`masking.kt`·`tokens.kt`·`client.kt` 등)을 쓰는데 ktlint의 "단일/다중 선언 파일은 PascalCase" 요구는 자동수정 불가라 `kotlin/.editorconfig`의 `ktlint_standard_filename = disabled`로 비활성한다. 나머지 포매팅은 `ktlintFormat`이 자동정렬(커밋 전 실행) + `ktlintCheck`로 게이트.
- ⚠️ **(Kotlin) `gradle --stop`을 빌드 인플라이트 중에 실행하면 진행 중 빌드를 죽인다.** `--no-daemon`도 jvmargs(`-Xmx2g`) 때문에 단일-사용 데몬을 fork하므로 `--stop`이 그 데몬을 죽여 "stop command received"로 실패한다(테스트 실패로 오인). **빌드 중 `--stop` 금지·동일 프로젝트에 gradle 2개 동시실행 금지**(락 경합). kill 후 stale build 상태는 `NoClassDefFoundError`(람다 `$1` 클래스)를 유발 → `gradle -p kotlin clean`으로 복구.
- ⚠️ **(Kotlin) MockK로 JAX-RS 추상 클래스(`jakarta.ws.rs.core.Response`·`WebApplicationException`)를 모킹하면 JDK 21에서 무기한 hang한다.** byte-buddy가 RESTEasy 구현 클래스 그래프를 계측하다 멈춘다(단일 테스트도 2.5분 타임아웃 실측 — "non-final이라 서브클래싱 안전"은 오판). `AdminBoundaryTest`는 실객체로 재작성한다: `WebApplicationException(message, status)`·`Response.status(500).entity("body").build()`·`object : WebApplicationException(){ override fun getResponse()=null }`(익명 서브클래스로 null-response 재현). `UsersResource` 등 **인터페이스**는 MockK 프록시가 가벼워 안전(계측 hang 무관).
- ⚠️ **(Kotlin) 코루틴 스택트레이스 복구가 예외 identity를 보존하지 않는다.** `kotlinx.coroutines`는 suspend 경계를 넘는 예외를 (동일 정보의) 새 인스턴스로 복사하므로, 원인 검증에 `assertSame`이 아니라 `assertIs<T>` + message 비교를 쓴다.
- ⚠️ **(Kotlin) Kover 0.9.x는 와일드카드 없는 정확 클래스명 exclude를 적용하지 않는다.** `"AuthClient"` 정확명은 무시돼 브랜치 집계에 섞인다 → 네트워크 경계 클래스는 전부 `*` 접미(`AuthClient*`/`KeycloakClient*`/`admin.*`)로 지정해야 클래스 본체 + 파일-레벨 top-level 함수 클래스(`…Kt`)까지 함께 제외된다.
- ⚠️ **(Kotlin) jvm-test-suite 없이 수동 `creating` 소스셋으로 `integrationTest`를 만들면 "no tests discovered"로 실패한다.** 수동 소스셋의 `compileClasspath +=`/`runtimeClasspath +=` 오버라이드가 Kotlin 컴파일 출력을 소스셋 `output.classesDirs`에 등록하지 못한다 — Gradle 표준 `jvm-test-suite`(`testing { suites { register<JvmTestSuite> } }`)로 전환해야 소스셋·Kotlin 컴파일·Test 태스크·JUnit Platform·resources가 정합 배선된다. 스위트 `dependencies` 블록엔 `kotlin("test")` 헬퍼가 없어 `kotlin.test.Test` typealias를 제공하는 **`kotlin-test-junit5`** 좌표를 명시해야 한다(plain `kotlin-test`는 assertions만).
- ⚠️ **(Kotlin) `= runBlocking { … }` 표현식-본문 `@Test` 메서드는 JUnit Jupiter가 발견하지 못한다.** `runBlocking`은 블록의 결과 타입 T를 반환하므로, 블록 마지막 식이 non-Unit이면 메서드가 non-void가 되어 Jupiter가 `@Test`로 인식하지 않는다 — `: Unit` 반환 타입을 명시해 void 바이트코드로 컴파일해야 한다.
- ⚠️ **(Kotlin) Kover 0.9.x는 jvm-test-suite로 등록된 `integrationTest`를 자동 계측 대상에 포함한다.** 그 결과 (1) `FullFlowIT`가 커버리지 subject로 집계돼 태스크 미실행 시 0% covered로 총계가 붕괴(실측 라인 51%/브랜치 69%), (2) `koverVerify`가 `integrationTest`를 태스크 그래프로 끌어들여 Docker 없는 단위 CI 게이트가 파손된다. **두 조치 모두 필요**: `instrumentation.disabledForTestTasks.add("integrationTest")` + `sources.excludedSourceSets.add("integrationTest")`.
- ⚠️ **(Kotlin) exchangeCode는 id_token을 nonce 비교 전에 완전 서명 검증한다(Java보다 강함).** `AuthClient.exchangeCode`는 SDK의 강화 `JwtValidator`로 id_token 서명을 먼저 검증한 뒤 nonce를 대조한다(Java는 nonce 파스온리였음).
- ⚠️ **(Kotlin) admin 파사드는 auth를 직접 알지 못한다(§4·Java 동형).** `KeycloakClient`는 admin에 provider를 배선하지 않고, `AdminClient`가 `KeycloakBuilder` 내장 client-credentials 그랜트로 토큰을 자체 소유한다(내부 `TokenManager`가 자동 획득·갱신) — Java SDK가 커스텀 RESTEasy 필터 충돌로 내린 동일 결정을 상속.
- ⚠️ **(Kotlin) 로컬 포터블 Gradle과 CI 래퍼 버전을 일치시켜 둔다(현재 둘 다 9.6.1).** 한때 래퍼만 9.5.0으로 핀했으나 지금은 `kotlin/gradle/wrapper/gradle-wrapper.properties`도 9.6.1이다. CI의 `gradle/actions/setup-gradle@v4`가 이 래퍼를 캐시·실행하므로, 로컬만 올리고 래퍼를 두면 로컬에서 재현되지 않는 CI 실패가 생긴다. KGP를 올릴 때 Gradle 지원 밴드를 확인할 것(현재 KGP 2.4.10).
- ⚠️ **(Kotlin) 신규 라이브러리 리스크 0.** JVM 자매 Java SDK가 실 Keycloak으로 이미 필드 검증한 3개 라이브러리(`org.keycloak:keycloak-admin-client` 26.0.11·`com.nimbusds:oauth2-oidc-sdk` 11.38.2·`com.nimbusds:nimbus-jose-jwt` 10.9.1)를 그대로 재사용하므로, Java의 게차(admin-client 버전≠서버 버전·admin 타임아웃 주입·jackson-databind CVE 등)를 코루틴 경계만 다르게 그대로 상속한다.
- ⚠️ **(Java·Kotlin) `resteasyClient(...)` 주입은 admin-client의 `JacksonProvider` 등록을 통째로 우회한다.** admin-client는 이 프로바이더를 **자기가 만든** JAX-RS 클라이언트에만 등록한다(`ResteasyClientClassicProvider.newRestEasyClient` → `register(JacksonProvider.class, 100)`, 바이트코드 확인). 타임아웃 주입(위의 필수 하드닝)을 위해 우리가 만든 클라이언트를 넘기면 `Keycloak` 생성자가 그 경로를 건너뛰어 `setSerializationInclusion(NON_NULL)`(null 필드 미전송)과 `configure(FAIL_ON_UNKNOWN_PROPERTIES, false)`(서버의 미지 필드 무시)를 **둘 다** 잃는다 — 즉 타임아웃 하드닝이 조용히 JSON 하드닝을 깨뜨린다. 유실 시 클라이언트/서버 버전 스큐에서 양방향으로 터진다: 클라이언트가 앞서면 우리가 신규 필드를 `null`로 실어 보내 구버전 서버가 400(*Unrecognized field*)을 내고, 서버가 앞서면 응답 역직렬화가 깨진다. **26.0.11의 `UserRepresentation.verifiableCredentials`(초기화 없는 `List` → null)에서 실제로 발현했다** — Dependabot bump가 비호환처럼 보였으나 실제로는 우리 잠재 결함의 폭로였다(PR #84). `buildTimeoutClient`가 `.register(JacksonProvider.class, 100)` + `.register(StreamMessageBodyReader.class)`를 직접 수행한다. ⚠️ **`StreamMessageBodyReader`는 `org.keycloak.admin.client.spi` 소속이며 26.0.11에만 존재한다**(resteasy jar에는 없다). 26.0.10까지는 `JacksonProvider`가 Stream 모듈을 내부에 품었고 26.0.11에서 분리됐다(프로바이더의 stream 참조 26.0.10 **9건** → 26.0.11 **0건** 실측). 기반 빌더는 `ClientBuilder.newBuilder()`를 유지할 것 — `createClientBuilder()`로 바꾸면 커넥션 풀이 기본 50에서 **10**으로 조용히 줄어든다. ⚠️ **동작 계약**: NON_NULL이 켜지면 부분 업데이트에서 `null`로 필드를 비우는 것이 불가능해진다(미설정 필드는 전송되지 않아 서버가 '변경 없음'으로 처리) — 이는 공식 admin-client와 **동일한** 동작이다. 비우려면 빈 문자열/전용 API를 쓴다.
- ⚠️ **(Node) `tsconfig.json`의 `include`가 `["src"]`라 테스트 파일은 타입체크되지 않는다.** `npm run typecheck` GREEN이 테스트의 타입 오류를 보장하지 않는다 — jose v6가 제거한 `KeyLike`를 `test/unit/jwt.test.ts`가 계속 import해도 typecheck·eslint·vitest(esbuild가 타입을 벗겨낸다) **어느 것도 잡지 못했다**. 의존성 메이저 bump를 검증할 때 이 사각을 염두에 둘 것. (`include`에 `test`를 넣으면 `token-provider.test.ts`의 선행 `TS2554` 5건이 드러나므로 별도 작업이 필요하다.)
- ⚠️ **(Node) JWKS rate-limit 회귀는 대조군 없이는 잡히지 않는다.** `cooldownDuration`이 개명·제거되면 JS가 알 수 없는 프로퍼티를 조용히 무시해 하드닝만 사라진다. 그런데 **jose는 그 경우 자체 기본값 30초로 폴백**하므로, 우리 설정값도 30초인 정상 케이스는 그대로 통과한다(변이 검증 실측). `cooldown=0`을 요구하는 대조군만이 히트 7 → 1로 떨어지며 실패한다 — `test/unit/jwt-jwks.test.ts`의 두 번째 케이스를 지우지 말 것.
- ⚠️ **(CI) Dependabot이 트리거한 run에는 Actions 시크릿이 노출되지 않는다.** 별도 Dependabot 시크릿 스토어만 보이며 이 저장소의 그 스토어는 비어 있다(`gh api repos/…/dependabot/secrets` → `total_count: 0`). 그래서 `SONAR_TOKEN`이 빈 문자열로 보간되어 SonarCloud가 *Not authorized* + exit 3으로 **반드시** 실패한다 — 코드 신호가 아니다. `sonarcloud.yml`이 `if: github.event_name != 'pull_request' || github.actor != 'dependabot[bot]'`로 Dependabot PR만 건너뛴다(push는 첫 논리항에서 항상 통과 → main 스캔은 구조적으로 스킵 불가, PR0 fail-closed 불변). 토큰을 Dependabot 스토어에 복제하는 대안은 기각했다 — 이 잡은 PR head에서 `npm ci`/`composer install`/`mvn verify`를 실행하므로 방금 bump된 미검토 패키지의 임의 코드가 토큰과 같은 잡에서 돌게 된다.
- ⚠️ **하드닝 CI 게차**(로컬↔CI 차이): Go `gofmt`·Node `prettier`·PHP `cs-fixer`는 Windows CRLF 워킹트리를 전부 flag해 실이슈를 가릴 수 있어 **변경 파일 LF-정규화 후 재확인** 필요 · 전역 상태 테스트(Ruby rack-oauth2)는 순서/버전 의존 flaky라 config 훅을 mock해 검증 · pip-audit는 editable 로컬 패키지 skip에도 exit1이라 `pip freeze --exclude-editable` + `-r`로 감사 · SonarCloud "0% Coverage on New Code"는 sonar-project.properties가 Kotlin kover만 피드해 비-Kotlin PR마다 fail(비차단·UNSTABLE, 다언어 커버리지 배선은 후속).
- ⚠️ **java jacoco:check는 `verify` 페이즈 바인딩이라 로컬 `mvn test`로는 커버리지 게이트가 검증되지 않는다**(반드시 `mvn -pl … -am verify -DskipITs`) — PR #71에서 `forRealm`(원격 JWKS·유닛 미커버, IT 전용)에 `.rateLimited()` 1줄 추가가 auth 번들을 0.90→0.89로 떨어뜨려 CI 3잡 동시 실패, `JWKSourceBuilder` 지연 특성을 이용한 네트워크-프리 `forRealm` 단위테스트로 복원.
- **⚠️ 앱 빌드 이미지는 Alpine(musl) 베이스**: Debian/glibc 빌드 이미지는 Docker Desktop(Windows) 내장 DNS 프록시가 패키지 레지스트리의 CNAME 체인을 glibc 리졸버에 실패로 돌려줘 `dotnet restore`/`pip install`/Maven·npm 다운로드가 막힌다(musl은 정상, CI 네이티브 Docker도 무해) — 공유 compose 파일엔 하드코딩 IP/`extra_hosts`가 없다.
- ⚠️ **앱/레지스트리 전 컨테이너 Alpine/musl**(Windows Docker Desktop glibc-DNS 게차 회피).
- ⚠️ 잔여 follow-up(평가상 marginal·미착수): wait_healthy 크래시 조기감지(각 run.sh가 실패 시 `sleep 3600`으로 컨테이너를 살려둬 이득 제한)·go 공개프록시 폴스루(현 file-first 체인이 정상 동작)·rust closure Cargo.lock 커밋(하네스 전이 dep 재현성 — 저가치·유지비).

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

| 의존성 | 좌표 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `fschmtt/keycloak-rest-api-client-php` | 유일한 성숙 admin 클라이언트 — pre-1.0 계열이라 정확 핀(파괴적 변경 가능) | **0.42.0** |
| 인증(OAuth2) | `league/oauth2-client` + `stevenmaguire/oauth2-keycloak` | 성숙한 OAuth2 클라이언트 + Keycloak 프로바이더 확장(대안 `jumbojett/openid-connect-php`는 세션 슈퍼글로벌 결합으로 기각) | `^2.8` / `^6.1` |
| JWT(강화 검증) | `firebase/php-jwt` | 표준 JWT 라이브러리 — 내장 `CachedKeySet`은 rate-limit 버그(#543)가 있어 자체 `JwksStore`로 대체 | `^7.1` |
| HTTP(PSR-18/17) | `guzzlehttp/guzzle` + `guzzlehttp/psr7` | fschmtt·league 양쪽이 공통으로 요구하는 PSR-18/17 전송 계층 | `^7.9` / `^2.7` |
| 단위 테스트 | `phpunit/phpunit` 12 · `phpstan/phpstan` 2.2(+ strict-rules·phpunit 확장) · `friendsofphp/php-cs-fixer` 3.95 | 표준 PHP 정적분석(level max)+테스트+스타일 스택 | — |
| 통합 테스트 | (docker CLI 셸아웃 — `testcontainers/testcontainers` ^1.0은 dev 의존이나 Windows native PHP 미지원으로 실사용 안 함) | Windows native PHP가 `unix://` 스트림 트랜스포트 미지원(Docker Desktop npipe도 불가) | — |

전부 MIT/BSD-3(Apache-2.0 호환). `jumbojett/openid-connect-php`는 세션 슈퍼글로벌·`header()` 리다이렉트를 자체 소유해 결정적 파사드와 상충 + JWT 검증 이력 우려로 기각.

**Rust 확정 의존성(Cargo.toml, 정확 핀 `=` 지정)**:

| 의존성 | 크레이트 | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| Admin | `keycloak`(`default-features = false`, features: `tags-all`·`resource-builder`·`reqwest12`) | `reqwest12` feature로 `openidconnect`와 reqwest 0.12를 정렬(안 맞추면 타입 불일치로 컴파일 실패) | `=26.6.2` |
| 인증(OIDC/OAuth2) | `openidconnect`(`default-features = false`, feature: `reqwest`) | `CoreClient`가 6개 엔드포인트 typestate 제네릭 — auth/introspection/token만 `EndpointSet`으로 명시해 무오류 호출 가능 | `=4.0.1` |
| JWT(강화 검증) | `jsonwebtoken`(`default-features = false`, features: `rust_crypto`·`use_pem`) | `Validation` 기본값이 안전하지 않아 `validate_nbf`/`leeway`/`required_spec_claims` 전부 재정의 필요 | `=10.4.0` |
| HTTP | `reqwest`(`default-features = false`, features: `json`·`rustls-tls`) | `keycloak` crate·`openidconnect`가 공유하는 단일 HTTP 클라이언트(SSRF 하드닝을 위해 `redirect::Policy::none()` 적용) | `0.12` |
| 비동기 런타임 | `tokio`(features: `rt-multi-thread`·`macros`·`time`·`sync`) | `openidconnect`·`keycloak` crate 양쪽이 요구하는 비동기 런타임 | `1.52` |
| 오류/직렬화 | `thiserror` `2.0` · `async-trait` `0.1` · `serde`+`serde_json` `1` · `url` `2` | 표준 에러 계급·직렬화·URL 유틸 | — |
| 단위 테스트 | `wiremock` `0.6`(HTTP 목) · `rsa` `0.9`+`rand` `0.8`+`base64` `0.22`(JWKS 공격 프로브 픽스처 생성) | HTTP 목 + 공격 프로브용 테스트 키 생성(RUSTSEC-2023-0071은 서명검증 전용인 런타임에 무영향) | — |
| 통합 테스트 | `testcontainers` `0.27.3`(pre-1.0, base `GenericImage` — 언어별 편의 모듈 없음) | pre-1.0이라 Keycloak 전용 편의 모듈이 없어 `GenericImage`로 직접 조립 | — |

전부 Apache-2.0/MIT(호환). `keycloak`/`openidconnect`/`jsonwebtoken`은 정확 핀(`=`)으로 고정(reqwest 메이저 정렬·typestate 제네릭·`Validation` 필드가 버전 간 깨지기 쉬운 표면이라 마이너 드리프트 방지). RUSTSEC-2023-0071(rsa Marvin)은 dev-dependency `rsa`(테스트 키 생성 전용)에 대한 것으로 SDK 런타임(공개키 서명검증만 수행)에는 무영향(게차 참조).

**Ruby 확정 의존성(gemspec, 범위 지정)**:

| 의존성 | gem | 왜 이 선택인가 | 버전 |
|---|---|---|---|
| 인증(OAuth2/OIDC) | `rack-oauth2`(nov) | OIDF 인증 RP 저자(nov)의 유지 gem — PKCE는 passthrough라 S256을 SDK가 손수 생성 | `~> 2.3` |
| Admin | (성숙한 gem 부재 — `faraday`로 Admin REST 직접 래핑) | `looorent/keycloak-admin` 등은 전부 공유 `TokenProvider` 주입 미지원(§4 캐싱 불변식 위반)으로 기각 | — |
| HTTP | `faraday` | 직접 구현하는 admin REST + rack-oauth2 전역 타임아웃 설정의 공통 기반 | `~> 2.0` |
| JWT(강화 검증) | `jwt`(ruby-jwt) | 기본값이 안전하지 않아 `algorithms`/`verify_iss`/`verify_aud`/`leeway` 전부 재정의 필요 | `~> 3.2` |
| 단위 테스트 | `rspec` 3 · `webmock` · `simplecov` · `rubocop`(+ `rubocop-rspec`) | 표준 RSpec+HTTP목+커버리지+린트 스택 | — |
| 통합 테스트 | (docker CLI 셸아웃 — Windows native Ruby가 testcontainers-ruby 소켓 트랜스포트 미지원, PHP와 동일 패턴) | Windows native Ruby가 testcontainers-ruby 소켓 트랜스포트 미지원 | — |
| 의존성 감사 | `bundler-audit` | gem 취약점 감사 | — |

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

### 문서 언어 규칙 (bilingual README + 영문 사용자 문서, PR #31·#32)

- **README는 영문 기본 + 한글 미러**: [`README.md`](README.md)(영문, 기본)와 [`README.ko.md`](README.ko.md)(한글)는 **동일 구조의 미러**다 — 한쪽을 고치면 다른 쪽도 함께 갱신해 동기 유지(상단 상호 링크 `English ↔ 한국어`). 둘 다 슬림 랜딩(정적 배지·9언어 표·30초 퀵스타트·보안·상태·링크)이며, 미배포(human-gated) 상태이므로 **라이브 레지스트리 배지 금지**(정적 배지만 — 오해 방지).
- **사용자 대상 문서는 영문(in-place)**: [`docs/guides/`](docs/guides/) 3종 · [`docs/roadmap/language-support.md`](docs/roadmap/language-support.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) · [`DEPLOY.md`](DEPLOY.md) · [`harness/README.md`](harness/README.md) · [`harness/install/README.md`](harness/install/README.md)는 영문으로 유지·갱신한다(한글 미러 없음).
- **내부 산출물은 한글 유지**: [`docs/superpowers/`](docs/superpowers/)(설계 스펙·WBS 플랜)·[`docs/governance/`](docs/governance/)(검증 로그)와 이 `CLAUDE.md`는 개발/거버넌스 내부 문서로 한글을 유지한다.
- **앵커 주의**: 영문 문서에서 헤딩을 바꾸면 `#anchor`가 바뀐다. `getting-started.md`의 `## C# / .NET`(앵커 `#c--net`)은 양쪽 README가 링크하므로 **헤딩 텍스트를 바꾸지 말 것**.
