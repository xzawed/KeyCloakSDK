# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Keycloak을 위한 **다국어(polyglot) SDK** — "다국어"는 **여러 프로그래밍 언어**(Java·Python·Node·Go·C#·PHP·향후 확장)를 뜻하며 자연어 현지화(i18n)와 무관하다. Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다룬다. 언어마다 관용적이되 개념·계층·흐름은 **동형(isomorphic)** 이도록 설계한다.

- **기준 언어**: Java 21 · Maven (첫 구현; 초기 Java 17 → 21 LTS 런타임 업그레이드 반영)
- **2번째 언어**: Python 3.10+ · `python-keycloak` 래핑 + `joserfc` 자체 JWT 검증 (`feature/python-sdk`)
- **3번째 언어**: Node.js 20+ · TypeScript(ESM·async-only) · `@keycloak/keycloak-admin-client` + `openid-client` v6 래핑 + `jose` 자체 JWT 검증 (`feature/node-sdk`)
- **4번째 언어**: Go 1.25+ · sync + `context.Context` · `Nerzal/gocloak/v13` + `golang.org/x/oauth2` 래핑 + `go-jose/v4` 자체 JWT 검증 (`feature/go-sdk`)
- **5번째 언어**: C# / .NET 8+ · async-first(`Task<T>`+`CancellationToken`) · `Keycloak.AuthServices.Sdk` 2.7.0 + `Duende.IdentityModel` 래핑 + `Microsoft.IdentityModel.JsonWebTokens` 자체 JWT 검증 (`main` 병합, PR #14)
- **6번째 언어**: PHP 8.3+ · `final readonly class` 값타입 · `fschmtt/keycloak-rest-api-client-php` 래핑(admin) + `league/oauth2-client`+`stevenmaguire/oauth2-keycloak` 래핑(auth, PKCE S256 오버라이드) + `firebase/php-jwt` 자체 JWT 검증 (`feature/php-sdk`)
- **라이선스**: Apache-2.0 · **groupId**: `io.github.xzawed` · Python 배포명: `keycloak-sdk` · npm 배포명: `@xzawed/keycloak-sdk` · Go 모듈: `github.com/xzawed/KeyCloakSDK/go` · NuGet 배포명: `Xzawed.Keycloak.Sdk` · Packagist 배포명: `xzawed/keycloak-sdk`

**핵심 전략**: 언어마다 가장 좋은 기반을 사용한다 — 공식/성숙 클라이언트가 있으면 감싼다(Java는 `keycloak-admin-client`, Python은 `python-keycloak`, Node는 공식 `@keycloak/keycloak-admin-client` + `openid-client`, Go는 `gocloak` + `x/oauth2`, C#은 `Keycloak.AuthServices.Sdk` + `Duende.IdentityModel`, PHP는 `fschmtt/keycloak-rest-api-client-php` + `league/oauth2-client`) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다. JWT 검증은 여섯 언어 모두 자체 강화 구현(algorithm pinning·iss 정확일치·aud 포함검사·`exp` 필수·클록 스큐·DoS-안전 JWKS 재조회)이다.

## 현재 상태

**Java MVP 완료 — `main` 병합됨 (PR #1).** WBS Phase 1~7(기반 → core → auth → admin → facade → 통합테스트 → 배포&문서) 전체 구현. 전 모듈 단위테스트 + Testcontainers 기반 통합테스트(실제 Keycloak 26.6.4)까지 GREEN(`mvn -f java/pom.xml clean verify`). Maven Central 배포 프로파일(`-Prelease`)과 태그 드리븐 릴리스 CI는 준비되었으나, 실제 배포는 사람이 `v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**Python SDK 완료 — `main` 병합됨 (PR #2 sync, PR #4 async).** WBS Phase 1~7 전체 구현 + `keycloak_sdk.aio` 비동기 미러(python-keycloak `a_*` 래핑, sync `JwtValidator` 재사용). 단위테스트 224개(sync 135 + async 89) + Testcontainers 통합테스트(실제 Keycloak 26.6.4) 11개(sync 6 + async 5) GREEN(로직 커버리지 100% 강제, `mypy --strict`, `ruff`). 하드닝(품질·CI 통합잡·ruff·DEPLOY.md)은 PR #3으로 병합됨. PyPI Trusted Publisher(OIDC) 릴리스 CI 준비됨, 실제 배포는 사람이 `py-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**Node.js/TypeScript SDK 완료 — `main` 병합됨 (PR #12).** WBS Task 1~12 전체 구현(스캐폴딩 → config → 핵심타입 → token-provider → oidc-metadata → JwtValidator → auth → admin → client+배럴 → 통합테스트 → CI → 문서). ESM 전용·async-only·strict TypeScript. 단위테스트 71개 + Testcontainers 통합테스트(실제 Keycloak 26.6) 5개 = 총 76개 GREEN(로직 모듈 라인 100%/브랜치 94% — 네트워크 경계 `auth.ts`/`admin/**`/`index.ts` omit), `tsc`(strict)·`eslint` 통과. 착수 전 딥리서치로 라이브러리 API 확정, 12태스크 계층별 커밋, 완료 후 4-차원 다중에이전트 어드버서리얼 리뷰(정확성·보안·동형성·테스트)로 7건 확정 결함 수정(HIGH: exchangeCode nonce). npm Trusted Publishing(OIDC + provenance) 릴리스 CI 준비됨, 실제 배포는 사람이 `node-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**Go SDK 완료 — `main` 병합됨 (PR #13).** WBS Task 1~12 전체 구현. 단일 `package keycloak`(admin을 서브패키지로 두면 `Client.Admin`이 `*AdminClient` 반환 시 import 순환 → `admin_*.go`로 같은 패키지), sync + `context.Context`(모든 네트워크 메서드 첫 인자). 단위테스트 40개 + Testcontainers 통합테스트(실제 Keycloak 26.6) 1개(E2E — 전 흐름·5 admin 리소스) = 총 41개 GREEN(로직 커버리지 95.2% — 네트워크 경계 `auth.go`/`admin*.go`/`client.go` omit), `go vet`·`gofmt`·CI 린터(`go run staticcheck@v0.7.0`·`gosec@v2.27.1` — golangci-lint은 빌드-Go 결합 문제로 미사용) 통과. 착수 전 딥리서치로 라이브러리 API 확정, 완료 후 4-차원 다중에이전트 어드버서리얼 리뷰로 9건 확정 결함 수정(admin 네트워크오류→TransportError·Validator JWKS 타임아웃·`exp` 필수·JWKS rate-limit/single-flight). Go 모듈은 레지스트리 없이 `go/v*` 태그가 곧 릴리스(`proxy.golang.org` 자동 캐시), 실제 배포는 사람이 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**.NET SDK 완료 — `main` 병합됨 (PR #14).** WBS Task 1~12 전체 구현(스캐폴딩 → errors/masking → config/tokens → tokenprovider → oidc → jwt → auth → admin → client+DI → 통합테스트 → CI/release → 문서). net8.0 · C# 12 · async-first(모든 네트워크 메서드가 `Task<T>` + 끝자리 `CancellationToken`). 단위테스트 58개 + Testcontainers 통합테스트(실제 Keycloak 26.6) 1개(E2E `Full_flow` — 전 흐름·5 admin 리소스) = 총 59개 GREEN(로직 커버리지 라인 97.34%/브랜치 93.47% — 게이트 90/85, 네트워크 경계 `AuthClient`/`Admin.*`/`KeycloakClient` omit), CI의 build-test·integration 잡 모두 GREEN(GitHub Actions에서 실제 Keycloak E2E 통과), `dotnet build`(`TreatWarningsAsErrors`)·`dotnet format` 통과. 착수 전 딥리서치로 `Keycloak.AuthServices.Sdk` 2.7.0(net8 최종 — 3.0.0은 net10 전용)의 admin 타입드 커버리지가 users/groups/realm-get뿐임을 확정(clients/roles/realm-CRUD는 raw REST), 태스크별 리뷰 루프 + 완료 후 실제 컴파일 검증을 포함한 다중에이전트 어드버서리얼 최종리뷰로 확정 결함 보정(HIGH: `Xzawed.Keycloak.Admin` 네임스페이스 안 `KeycloakClient` 셰도잉 → 별칭 `using`, 테스트 프로젝트 CS1591 게이트; MEDIUM: JSON 마스킹 누락·nonce 파스온리 fail-open·release workflow env 스코프·admin/auth 타임아웃(`TaskCanceledException`)→`TransportException` 변환·동시성 테스트 실접전 지연·`_admin`/토큰캐시 volatile). 실서버 발견: `POST /admin/realms`(새 realm 생성)는 master-realm 전용(realm 서비스계정 403). NuGet 릴리스 CI(`NUGET_API_KEY` 시크릿) 준비됨, 실제 배포는 사람이 `dotnet-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**PHP SDK 완료 — `feature/php-sdk`(PR 대기, main 기준).** WBS Task 1~12 전체 구현(스캐폴딩 → masking/exc → config → tokens/oidc → tokenprovider → jwks → jwt → auth → admin → client → 통합테스트 → CI/문서). PHP 8.3+ · `final readonly class` 값타입 · 예외 기반 관용. 단위테스트 64개 + 통합테스트(docker CLI 셸아웃, 실제 Keycloak 26.6) 3개(`FullFlowIT`: `testFullFlow`·`testAdminClientCrud`·`testRawEscapeHatch`) = 총 67개 GREEN(집계 로직 라인 커버리지 100.00% — 게이트 ≥90%, `phpunit.xml` source exclude로 네트워크 경계 `AuthClient`/`Admin/**`/`KeycloakClient` omit), `phpstan analyse`(level max)·`php-cs-fixer --dry-run --allow-risky=yes`·`composer audit` 통과. 착수 전 딥리서치로 `fschmtt/keycloak-rest-api-client-php` 0.42.0(admin, `Users::create()`는 void 반환·`Clients`/`Realms`는 `create`가 아니라 `import`) + `league/oauth2-client`+`stevenmaguire/oauth2-keycloak`(auth, `pkceMethod` 옵션 no-op) + `firebase/php-jwt`(jwt, `&$headers`는 성공 디코드 후에만 채워짐) 확정, 태스크별 리뷰 루프(Task 1/3/4/5/8/9/10/11) + Task 7(JwtValidator) OPUS 어드버서리얼 보안리뷰(20+ 공격 프로브)로 Critical 1건(악성 JWKS `\TypeError` 경계 누출) 확정 수정. 6번째 언어로 선행 5개 SDK의 게차가 선반영되어 통합테스트 신규 SDK 버그 0건(첫 사례). Packagist는 레지스트리 업로드가 아니라 GitHub 웹훅으로 태그를 자동감지해 게시하므로 릴리스 CI에 저장 시크릿이 없으며, 실제 배포는 사람이 `php-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**남은 로드맵(사람 게이트)**: Maven Central 실배포(`io.github.xzawed` 네임스페이스 검증 + GPG/Portal 토큰) · PyPI 실배포(`keycloak-sdk` Trusted Publisher 설정) · npm 실배포(`@xzawed/keycloak-sdk` Trusted Publisher 설정) · Go 실배포(`go/v*` 태그 push) · .NET 실배포(`Xzawed.Keycloak.Sdk` NuGet API 키 등록 + `dotnet-v*` 태그 push) · PHP `main` 병합(PR) + Packagist 실배포(`xzawed/keycloak-sdk` 저장소 등록 + `php-v*` 태그 push). 배포 절차는 [DEPLOY.md](DEPLOY.md) 참고.

- 설계 스펙: [docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) — **구현 전 반드시 정독**
- 구현 계획(WBS): [docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md](docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md)(Java) · [docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md](docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md)(Python) · [docs/superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md](docs/superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md)(Node) · [docs/superpowers/plans/2026-07-04-keycloak-go-sdk-wbs.md](docs/superpowers/plans/2026-07-04-keycloak-go-sdk-wbs.md)(Go) · [docs/superpowers/plans/2026-07-04-keycloak-dotnet-sdk-wbs.md](docs/superpowers/plans/2026-07-04-keycloak-dotnet-sdk-wbs.md)(C#/.NET) · [docs/superpowers/plans/2026-07-06-keycloak-php-sdk-wbs.md](docs/superpowers/plans/2026-07-06-keycloak-php-sdk-wbs.md)(PHP)
- 실행 거버넌스: [docs/governance/ai-governance-framework.md](docs/governance/ai-governance-framework.md) (Codex 이중검증·G1~G6 게이트·루프 엔지니어링)
- 검증 로그: [docs/governance/verification-log.md](docs/governance/verification-log.md)(Java) · [docs/governance/verification-log-python.md](docs/governance/verification-log-python.md)(Python) · [docs/governance/verification-log-node.md](docs/governance/verification-log-node.md)(Node) · [docs/governance/verification-log-go.md](docs/governance/verification-log-go.md)(Go) · [docs/governance/verification-log-dotnet.md](docs/governance/verification-log-dotnet.md)(C#/.NET) · [docs/governance/verification-log-php.md](docs/governance/verification-log-php.md)(PHP) — 태스크별 게이트 통과 이력
- 설치·시작: [docs/guides/getting-started.md](docs/guides/getting-started.md) · Keycloak 서버 배포(단일 VM+Compose): [docs/guides/deploying-keycloak-server.md](docs/guides/deploying-keycloak-server.md) · 언어 확장 로드맵: [docs/roadmap/language-support.md](docs/roadmap/language-support.md) · 새 언어 추가 플레이북: [docs/guides/add-a-language-playbook.md](docs/guides/add-a-language-playbook.md)
- **테스트 수(Java)**: 단위테스트 117개(core 34 · auth 34 · admin 43 · keycloak-sdk 6) + 통합테스트(Testcontainers) 6개(SmokeIT 1 · AuthFlowIT 3 · AdminOpsIT 2) = **총 123개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%) 통과. (surefire/failsafe 실측 기준 — Phase 7의 94는 최종리뷰 Wave A/B 이전 수치)
- **테스트 수(Python, main)**: 단위테스트 224개(sync 135 + `aio` async 89) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 11개(sync 6 + async 5) = **총 235개**, 로직 모듈 커버리지 **100% 강제**(`--cov-fail-under=100`, 경계모듈 omit), `mypy --strict`·`ruff`(보안 S/bandit 포함 확장 룰셋)·`ruff format` 통과.
- **테스트 수(Node, main)**: 단위테스트 71개(config 5 · masking 2 · errors 3 · tokens 6 · oidc-metadata 1 · token-provider 4 · jwt 7 · auth 15 · admin 17 · client 11) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 5개(E2E) = **총 76개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85% — 실측 라인 100%/브랜치 94%, 네트워크 경계 `auth.ts`/`admin/**`/`index.ts` omit) 통과, `tsc`(strict)·`eslint` 통과.
- **테스트 수(Go, main)**: 단위테스트 40개(config·errors·masking·tokens·tokenprovider·oidc·jwt·auth·admin·client) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 1개(E2E — client-credentials→validate→introspect→user CRUD→5 리소스 CRUD→Raw) = **총 41개**, 커버리지 게이트(로직 파일 statement ≥90% — 실측 95.2%, 네트워크 경계 `auth.go`/`admin*.go`/`client.go` omit) 통과, `go vet`·`gofmt`·staticcheck·gosec 통과.
- **테스트 수(C#/.NET, main)**: 단위테스트 58개(config 8 · tokens 7 · errors 4 · masking 3 · tokenprovider 4 · oidc 1 · jwt 11 · auth 10 · admin 5 · client 5 — Fact+InlineData 실측; 최종리뷰에서 vacuous scaffolding 테스트 제거) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 1개(E2E `Full_flow` — client-credentials→validate→introspect→user CRUD→5 리소스 CRUD→Raw) = **총 59개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85% — 실측 라인 97.34%/브랜치 93.47%, 네트워크 경계 `AuthClient`/`Admin.*`/`KeycloakClient` omit) 통과, `dotnet build`(warnaserror·Nullable)·`dotnet format` 통과. GitHub Actions CI(build-test·integration) GREEN.
- **테스트 수(PHP, feature/php-sdk)**: 단위테스트 64개(242 assertions) + 통합테스트(docker CLI 셸아웃, 실제 Keycloak 26.6) 3개(`FullFlowIT`: `testFullFlow`·`testAdminClientCrud`·`testRawEscapeHatch`) = **총 67개**, 집계 로직 라인 커버리지 **100.00%**(게이트 ≥90%, `phpunit.xml` source exclude로 네트워크 경계 `AuthClient`/`Admin/**`/`KeycloakClient` omit) 통과, `phpstan analyse`(level max)·`php-cs-fixer --dry-run --allow-risky=yes`·`composer audit` 통과.

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

## 아키텍처

폴리글랏 모노레포. Java 구현이 `java/`에서, Python 구현이 `python/`에서, Node 구현이 `node/`에서, Go 구현이 `go/`에서, C#/.NET 구현이 `dotnet/`에서, PHP 구현이 `php/`에서 완료됐다(각각 독립 빌드).

**Java** — 6개 Maven 모듈(reactor 빌드):

```
java/                          # Maven 멀티모듈 reactor
├─ keycloak-sdk-bom/           # 의존성 버전 고정 BOM (배포)
├─ keycloak-sdk-core/          # KeycloakConfig, TokenProvider, 예외 계층, 보안 정책 (외부만 의존)
├─ keycloak-sdk-auth/          # 인증 래퍼 — Nimbus OAuth2/OIDC SDK 감쌈 (core 의존)
├─ keycloak-sdk-admin/         # 관리 파사드 — 공식 keycloak-admin-client 감쌈 (core 의존)
├─ keycloak-sdk/               # 통합 진입점 KeycloakClient (core+auth+admin)
└─ keycloak-sdk-examples/      # 실행 예제 (배포 제외)
```

**결합 규칙(Java)**: `admin`은 `auth`를 직접 알지 못한다. 둘을 잇는 유일한 접착제는 `core`의 `TokenProvider` 인터페이스다 — auth 없이도 admin을 자체 토큰 소스로 쓸 수 있고, 내부 라이브러리 교체가 소비자에게 파급되지 않는다.

**Python** — 단일 패키지 `keycloak_sdk` + 서브모듈(`python/`, `src/` 레이아웃):

```
python/
├─ pyproject.toml              # hatchling · 배포명 keycloak-sdk · Apache-2.0
├─ src/keycloak_sdk/
│  ├─ config.py                # KeycloakConfig (불변 dataclass)
│  ├─ auth.py                  # AuthClient — KeycloakOpenID 래핑
│  ├─ jwt.py                   # JwtValidator — joserfc 자체 강화 검증
│  ├─ admin/                   # AdminClient + users/clients/realms/roles/groups
│  ├─ client.py                # KeycloakClient 통합 진입점 (auth 즉시·admin 지연)
│  ├─ aio/                     # async 미러(AsyncKeycloakClient/AsyncAuthClient/AsyncAdminClient) — `feature/python-async`, python-keycloak `a_*` 래핑
│  └─ py.typed                 # PEP 561 마커
├─ examples/quickstart.py, async_quickstart.py
└─ tests/{unit,integration}/  # tests/unit/aio/, tests/integration/*_async_it.py 포함
```

**결합 규칙(Python)**: `admin`은 `auth`에 의존하지 않는다(각자 독립적으로 client-credentials 인증). `python-keycloak`(`KeycloakOpenID`/`KeycloakAdmin`)을 래핑하고, 예외는 경계에서 `keycloak_sdk.exceptions.*`로 변환되어 `keycloak.exceptions.*` 타입이 공개 API에 노출되지 않는다. JWT 검증만 `python-keycloak`에 의존하지 않고 `joserfc`로 자체 강화 구현(algorithm pinning·`none`/미서명 거부·iss 정확일치·aud 포함검사·클록 스큐).

**Node** — 단일 패키지 `@xzawed/keycloak-sdk`(`node/`, `src/` 레이아웃, ESM):

```
node/
├─ package.json                # ESM("type":"module") · 배포명 @xzawed/keycloak-sdk · files:["dist"]
├─ tsconfig.json               # strict · NodeNext · noUncheckedIndexedAccess · verbatimModuleSyntax
├─ src/
│  ├─ config.ts                # KeycloakConfig + defineConfig(검증·clientSecret 마스킹)
│  ├─ errors.ts                # KeycloakError 계급 + mapHttpError
│  ├─ masking.ts · tokens.ts   # mask() · TokenSet/ValidatedToken/IntrospectionResult
│  ├─ token-provider.ts        # TokenProvider + ClientCredentialsTokenProvider(single-flight)
│  ├─ oidc-metadata.ts         # 엔드포인트 조립(네트워크 없음)
│  ├─ jwt.ts                   # JwtValidator — jose 자체 강화 검증(보안 핵심)
│  ├─ auth.ts                  # AuthClient — openid-client v6 함수형 API 래핑
│  ├─ admin/                   # AdminClient + users/clients/realms/roles/groups + call(경계변환)
│  ├─ client.ts                # KeycloakClient 통합 진입점(auth 즉시·admin 지연·asyncDispose)
│  └─ index.ts                 # 공개 배럴
├─ examples/quickstart.ts
└─ test/{unit,integration}/    # vitest(unit) + vitest.integration.config.ts(testcontainers)
```

**결합 규칙(Node)**: `admin`은 `auth`에 의존하지 않는다(각자 독립 client-credentials 인증) — `core`의 `TokenProvider` 인터페이스가 유일 접착제. `openid-client`(auth)·`@keycloak/keycloak-admin-client`(admin)를 래핑하고, 예외는 경계에서 `KeycloakError` 계급으로 변환되어 하위 라이브러리 에러(`NetworkError` 등)가 공개 API로 새지 않는다. `admin.raw()`가 탈출구. JWT 검증만 `jose`로 자체 강화 구현.

**Go** — 단일 패키지 `keycloak`(`go/`, 모듈 `github.com/xzawed/KeyCloakSDK/go`):

```
go/
├─ go.mod / go.sum          # go 1.25 · 배포 태그 go/vX.Y.Z(레지스트리 없음)
├─ config.go                # Config(값 구조체) + validate + String 마스킹
├─ errors.go                # 오류 계급(타입드 구조체) + 센티넬 ErrNotFound/ErrConflict/ErrForbidden
├─ tokens.go                # TokenSet(IsExpired·String 마스킹)/ValidatedToken/IntrospectionResult
├─ tokenprovider.go         # TokenProvider + ClientCredentialsTokenProvider(x/sync/singleflight)
├─ oidc.go                  # 엔드포인트 조립(네트워크 없음)
├─ jwt.go                   # Validator — go-jose 자체 강화 + DoS-safe JWKS(single-flight·rate-limit)
├─ auth.go                  # AuthClient — x/oauth2 래핑 + 수동 introspect/logout
├─ admin.go + admin_*.go    # AdminClient + 5 리소스 + Raw() + toSDKError(경계변환)
├─ client.go                # Client 통합 진입점(Auth 즉시·Admin(ctx) 지연·Close)
├─ example_test.go          # godoc 예제 · integration_test.go(//go:build integration)
└─ testdata/it-realm-realm.json  # Java/Python/Node 재사용(//go:embed)
```

**결합 규칙(Go)**: **전체가 단일 `package keycloak`**(admin을 서브패키지로 두면 `Client.Admin`이 `*AdminClient` 반환 시 admin↔root import 순환 — Go 금지 — 이 발생하므로 `admin_*.go`로 같은 패키지). `admin`은 `auth`에 의존하지 않고 `TokenProvider`(gocloak client-credentials 기본)가 유일 접착제. `gocloak`(admin)·`x/oauth2`(auth) 래핑, 오류는 경계에서 타입드 구조체(`*AdminError` 등)로 변환. **⚠️ gocloak은 네트워크 실패도 `*APIError{Code:0}`로 감싸므로** `toSDKError`는 `Code==0`→`*TransportError`, `>0`→`*AdminError`로 나눈다(그러지 않으면 전부 `AdminError{HTTP 0}`로 오분류). `admin.Raw()`가 탈출구. JWT 검증만 `go-jose/v4`로 자체 강화.

**C# / .NET** — 단일 프로젝트 `Xzawed.Keycloak.Sdk`(`dotnet/`, 솔루션 `Keycloak.Sdk.sln`, net8.0):

```
dotnet/
├─ Directory.Build.props          # net8.0·Nullable·TreatWarningsAsErrors·AnalysisLevel 8.0·패키징 props(IsTestProject!=true 게이트)
├─ Keycloak.Sdk.sln
├─ src/Xzawed.Keycloak.Sdk/
│  ├─ Masking.cs · KeycloakException.cs   # Mask() · 예외 계급(KeycloakException→KeycloakAdminException→NotFound/Conflict/Forbidden 등) + MapHttpError
│  ├─ KeycloakConfig.cs · Tokens.cs        # record + ToString()/JsonConverter<T> 이중 마스킹 · TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest
│  ├─ ITokenProvider.cs                    # ITokenProvider/ITokenSource + ClientCredentialsTokenProvider(SemaphoreSlim single-flight)
│  ├─ OidcEndpoints.cs                     # 엔드포인트 조립(네트워크 없음)
│  ├─ JwtValidator.cs                      # Microsoft.IdentityModel 자체 강화 검증(보안 핵심)
│  ├─ AuthClient.cs                        # AuthClient : ITokenSource — Duende.IdentityModel 래핑
│  ├─ Admin/                               # AdminClient + Users/Groups/Realms(타입드) + Clients/Roles(raw REST) + BearerHandler
│  ├─ KeycloakClient.cs                    # 통합 진입점(Auth 즉시·AdminAsync 지연 single-flight·IAsyncDisposable+IDisposable)
│  └─ ServiceCollectionExtensions.cs       # AddKeycloak DI 확장
├─ tests/Xzawed.Keycloak.Sdk.Tests/        # xUnit 단위 + integration/(Testcontainers.Keycloak) + testdata/it-realm-realm.json
```

**결합 규칙(C#/.NET)**: `admin`은 `auth`에 의존하지 않는다 — `ITokenProvider`가 유일 접착제(`AuthClient : ITokenSource`가 기본 소스). `Keycloak.AuthServices.Sdk`(admin)·`Duende.IdentityModel`(auth) 래핑, 예외는 경계에서 `KeycloakException` 계급으로 변환. **⚠️ admin 타입드 클라이언트는 users/groups/realm-get만 커버**하므로 clients/roles/realm-CRUD는 같은 bearer-authed `HttpClient`로 raw Admin REST(representation 재사용). `admin.Raw`(`IKeycloakClient`)가 탈출구. JWT 검증만 `Microsoft.IdentityModel.JsonWebTokens`로 자체 강화.

**PHP** — 단일 패키지 `xzawed/keycloak-sdk`(`php/`, PSR-4 `Xzawed\Keycloak\`):

```
php/
├─ composer.json               # PSR-4 Xzawed\Keycloak\ · 배포명 xzawed/keycloak-sdk · Apache-2.0
├─ phpunit.xml                 # unit/integration testsuite + source exclude(네트워크 경계)
├─ phpstan.neon                # level max + strict-rules + phpunit 확장
├─ src/
│  ├─ Masking.php · Exception/         # mask() · KeycloakException 계급(Config/Auth/Transport/TokenValidation/Admin→NotFound/Conflict/Forbidden)
│  ├─ KeycloakConfig.php               # final readonly class(검증·후행슬래시 제거·__toString 마스킹)
│  ├─ Token/                           # TokenSet/ValidatedToken/IntrospectionResult/AuthorizationRequest(값타입) + OidcEndpoints
│  ├─ TokenProvider.php · ClientCredentialsTokenProvider.php   # TokenProvider 인터페이스 + 캐시(isomorphic core)
│  ├─ Jwks/JwksStore.php               # DoS-safe JWKS(kid 캐시·미해결만 재조회·rate-limit)
│  ├─ JwtValidator.php                 # firebase/php-jwt 자체 강화 검증(보안 핵심)
│  ├─ AuthClient.php                   # league+stevenmaguire 래핑 + Internal/PkceKeycloakProvider(S256 오버라이드)
│  ├─ Admin/                           # AdminClient + Users/Clients/Realms/Roles/Groups + ErrorTranslation(경계변환)
│  └─ KeycloakClient.php               # 통합 진입점(auth 즉시·admin 지연캐시·close)
├─ examples/quickstart.php
└─ tests/{Unit,Integration}/           # PHPUnit(unit) + FullFlowIT.php(docker CLI 셸아웃, 실제 Keycloak)
```

**결합 규칙(PHP)**: `admin`은 `auth`에 의존하지 않는다(각자 독립 client-credentials 인증) — `TokenProvider` 인터페이스가 유일 접착제. `fschmtt/keycloak-rest-api-client-php`(admin)·`league/oauth2-client`+`stevenmaguire/oauth2-keycloak`(auth) 래핑, 예외는 경계에서 `KeycloakException` 계급으로 변환(`ErrorTranslation`이 fschmtt/Guzzle 예외를, `AuthClient`가 league 예외를 흡수). **⚠️ fschmtt `Users::create()`는 void 반환**(생성된 id는 `findIdByUsername()`로 후속 조회), `Clients`/`Realms`는 `create`가 아니라 **`import`**(대상 representation에 id/realm 사전 세팅 필요). `admin()->raw()`가 탈출구. JWT 검증만 `firebase/php-jwt` + 자체 `JwksStore`로 자체 강화.

**언어 중립 계약(§4)**: Java(손수 래핑)·Python(`python-keycloak` 래핑)·Node(`openid-client`+admin-client 래핑)·Go(`gocloak`+`x/oauth2` 래핑)·C#(`Keycloak.AuthServices.Sdk`+`Duende.IdentityModel` 래핑)·PHP(`fschmtt`+`league/oauth2-client` 래핑)의 출발점이 다르므로, 언어 중립 API 계약을 진실 원천으로 두고 각 언어가 구현한다. 여섯 언어 모두 하위 라이브러리 타입을 **주 소비 경로(파사드) 뒤에 숨긴다**(camelCase ↔ snake_case ↔ Go/C# PascalCase만 다르고 개념·계층은 동형 — 예: `TokenSet`/`ValidatedToken`/`IntrospectionResult`·오류 계급·`Client.auth/admin`). **예외/오류 계층은 항상 경계에서 SDK 타입으로 변환**되어 `keycloak.exceptions.*`·`jakarta.ws.rs.*`·`NetworkError`·`gocloak.APIError`·`KeycloakHttpClientException`·Guzzle `RequestException`이 공개 API로 새지 않는다. Go는 예외 대신 **error 값 + 센티넬**(`errors.Is`/`errors.As`) 관용을 쓴다(§4 허용).

**문서화된 은닉성 예외(의도적, 2026-07-03 보안감사 반영)**: 완전 은닉이 아니라 아래 지점은 하위 타입을 노출한다 — 재래핑 비용이 과다하거나 보조 표면이기 때문이다. (a) **Java·Node·Go·C#·PHP admin 파사드**는 representation 타입을 데이터 모델로 그대로 노출한다(Java `org.keycloak.representations.idm.*`, Node `@keycloak/keycloak-admin-client/lib/defs/*`, Go `gocloak.User`/`Client`/`Role`/`Group`/`RealmRepresentation`, C# `Keycloak.AuthServices.Sdk.Admin.Models.*Representation`, PHP `Fschmtt\Keycloak\Representation\*` — 안정적 Keycloak 타입 재사용, SDK 자체 DTO 재래핑은 범위 밖). Python admin은 plain `dict[str, Any]`로 통과(누출 아님). (b) **저수준 주입/구성 지점** — Java `JwtValidator.forRealm`의 Nimbus `JWSAlgorithm`, Python `JwtValidator.validate`의 joserfc `KeySet`, Node `new JwtValidator(keys, opts)`의 jose `JWTVerifyGetKey`, Go `admin.Raw()`의 `*gocloak.GoCloak`·테스트 주입용 파라미터, C# `AdminClient.Raw`의 `IKeycloakClient`·`JwtValidator`의 내부 `TokenValidationParameters` 시임 ctor, PHP `AdminClient::raw()`의 `Fschmtt\Keycloak\Keycloak`은 하위 타입을 받는다/반환한다. 정상 소비 경로(`Client.auth/admin`, `client.Auth.Validate(...)`)는 이들을 노출하지 않는다.

## 핵심 게차 (Gotchas) — 2026-07-02 검증

- ⚠️ **admin-client 버전 ≠ 서버 버전.** Keycloak 서버는 26.6.4지만 `keycloak-admin-client`는 독립 트랙 **26.0.10**이다("26.6.x admin-client"는 존재하지 않음). 하나의 클라이언트가 여러 서버 버전을 지원한다. `representation` 필드가 서버와 완전히 일치하지 않을 수 있으니 의존 필드는 실제 서버로 검증한다.
- ⚠️ **Maven Central은 Central Portal 경로만.** 구 OSSRH는 2025-06-30 종료. `central-publishing-maven-plugin:0.11.0` 사용(공식 문서 예제의 0.9.0은 낡음).
- ⚠️ **Testcontainers 2.0 모듈명 변경.** JUnit5 확장 모듈은 `org.testcontainers:testcontainers-junit-jupiter`(구 `junit-jupiter` 아님). `testcontainers-keycloak:4.2.1`은 KC 26.6 기본.
- ⚠️ **JWT 검증 강화 필수(CVE-2026-11800).** 알고리즘 핀닝(`none` 거부·헤더 신뢰 금지), iss/aud 검증, 클록 스큐 제한. Nimbus는 building block만 제공하고 안전한 기본값은 주지 않는다.
- ⚠️ **보안**: 토큰/시크릿 로깅 금지·마스킹(완전 불투명 `***`, 접두 노출 없음), TLS 검증 기본 on, 기본 인메모리 토큰 저장 + 교체 가능한 `TokenStore` SPI.
- ⚠️ **시크릿 메모리 위생은 경계가 있다.** Java `KeycloakConfig`는 시크릿을 `char[]`(방어적 clone)로 보관하나, 하위 라이브러리(Nimbus `Secret`·keycloak-admin-client, Python은 `str`)가 `String`을 요구해 사용 시점에 소거 불가 `String`으로 복사된다 — char[]는 심층방어일 뿐 end-to-end 소거 보장이 아니다(HTTP Basic 직렬화·라이브러리 내부 보존 때문). 과대광고 금지.
- ⚠️ **JWKS 재조회는 DoS-안전해야 한다(Python, 2026-07-03 감사).** 서명 위조(`BadSignatureError`)는 certs 재조회를 유발하지 않고, 키(kid) 미해결(`InvalidKeyIdError`→`TokenKeyError`)에만 재조회하며, 재조회 자체도 최소 간격(`_jwks_min_refetch`)으로 rate-limit한다 — 위조 Bearer 토큰마다 IdP를 때리는 미인증 DoS 증폭 차단. Java(Nimbus `JWKSourceBuilder`)는 캐시+RateLimited로 이미 안전.
- ⚠️ **admin 타임아웃·자원 정리.** Java `AdminClient`는 `config`의 connect/read 타임아웃을 `KeycloakBuilder.resteasyClient(...)`로 반드시 주입해야 admin 호출이 무한 대기하지 않는다(미주입=스레드 고갈 DoS). 파사드 `close()`/`aclose()`는 admin뿐 아니라 **auth 세션(requests/httpx)까지** 정리한다(미정리=FD/커넥션 풀 누수).
- ⚠️ **어떤 Java OIDC 라이브러리도 자체 "certified" 아님.** 완성 제품을 필요 시 OIDF에 인증한다.
- ⚠️ **Java 17+ javadoc은 doclint 기본 엄격.** `release` 프로파일의 `maven-javadoc-plugin`에 `<doclint>none</doclint>` + `<failOnError>false</failOnError>`를 주지 않으면 문서 경고로 `-javadoc.jar` 생성이 실패할 수 있다.
- ⚠️ **Java 런타임 타깃은 21 LTS(2026-07-03 업그레이드).** `maven.compiler.release=21` + enforcer `requireJavaVersion=[21,)`로 JDK 21 미만 빌드를 fail-fast. `maven-compiler-plugin`은 pluginManagement에서 `3.11.0`으로 명시 고정(기본값 드리프트 방지). CI(`ci.yml` build matrix·integration, `release.yml`)는 모두 JDK 21 단일 사용.
- ⚠️ **jackson-databind는 2.21.4 고정(CVE 대응, 2026-07-03).** Dependabot 7건(HIGH 2·MEDIUM 5) 대응으로 jackson-databind 계열 6종을 2.21.2→2.21.4로 상향(관리값보다 picked-higher, 수렴 유지). `jackson-annotations`는 별도 트랙·비취약이라 2.21 유지. CVE-2026-54515는 fix(2.21.5) 미출시 — 이 SDK에서 악용 불가로 문서화, 2.21.5 출시 시 상향. **보안 불변식(위반 시 노출 재개)**: SDK는 자체 `ObjectMapper`/default·polymorphic typing을 쓰지 않고 신뢰된 Keycloak 응답만 고정 representation POJO로 역직렬화한다 — default typing 활성화·커스텀 JAX-RS Jackson provider 등록·미신뢰 JSON의 다형성 역직렬화를 도입하지 말 것. 상세: [verification-log.md](docs/governance/verification-log.md).
- ⚠️ **(Node) admin-client `findOne`/`findOneByName`은 404에서 `null` 반환(선언 타입은 `undefined`).** `get()`류는 `null`/`undefined`를 모두 부재로 보고 `KeycloakNotFoundError`로 변환한다(`admin/call.ts`의 `requireFound`). `=== undefined`만 검사하면 삭제 후 조회가 NotFound 대신 `null`을 반환하는 버그 — 통합테스트가 포착했다.
- ⚠️ **(Go) gocloak은 네트워크 실패까지 `*gocloak.APIError`로 감싼다(`Code:0`).** `toSDKError`는 `Code==0`이면 `*TransportError`, `>0`이면 `*AdminError`로 나눈다 — 그러지 않으면 연결 거부/DNS 실패가 `AdminError{HTTP 0}`로 오분류되고 `errors.As(err, &TransportError)` 경로가 死코드가 된다(리뷰 포착).
- ⚠️ **(Go) go-jose는 `exp` 부재 시 만료검사를 건너뛴다.** `jwt.Validate`는 `claims.Expiry == nil`을 명시 거부해야 무만료 토큰 통과를 막는다(Java/Python 동형). `ValidateWithLeeway`만 믿으면 안 됨. JWKS 재조회는 초기(non-forced) 로드에 `forcedAt`를 소모하지 않아야 첫 키회전 재조회가 허용되고(Python `-inf` 동형), 동시 미스는 `singleflight`로 수렴한다(IdP 폭주 상한).
- ⚠️ **(Go) 최소 런타임 Go 1.25**(`x/oauth2` v0.36 요구). `go.mod`의 `go` 지시자를 1.24로 낮추면 `go mod tidy`가 다시 1.25로 올린다(의존성 요구). Validator의 JWKS `http.Client`는 `Config.ReadTimeout`을 주입해야 한다(미주입 시 `http.DefaultClient` 무한대기 — hung IdP에 영원히 블록). TLS는 Go `http.Client`가 https를 기본 검증하고 http는 투명 처리하므로 `allowInsecure` 로직 불필요(Node와 차이).
- ⚠️ **(Node) openid-client v6 함수형 API·타임아웃·TLS.** 타임아웃은 `Configuration.timeout`(초, 내장 프로퍼티)로 주입한다. admin-client 타임아웃은 `ConnectionConfig.timeout`(**ms**)로 주입(`requestOptions`는 `Omit<RequestInit,"signal">`이라 signal 주입 불가). TLS는 기본 강제 — `serverUrl`이 `http://`일 때만 `allowInsecureRequests`를 적용한다(로컬/테스트 완화, https는 강제 유지).
- ⚠️ **(Node) PKCE `exchangeCode`는 `nonce`를 반드시 전달해야 한다.** `createAuthorizationRequest`가 nonce를 실으면 Keycloak이 id_token에 담아 돌려주고, openid-client v6는 이를 자동 검증하므로 기대 nonce를 주지 않으면 "unexpected nonce"로 **전면 거부**한다(리뷰 HIGH 결함). 마스킹: `TokenSet`은 access/refresh 토큰을, `KeycloakConfig`는 `clientSecret`을 `toString`/`toJSON`/`util.inspect`에서 마스킹한다(속성 접근·스프레드는 유지). JWKS는 jose `createRemoteJWKSet`의 `cooldownDuration`으로 DoS-안전(kid 미해결 시에만 재조회).
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

## 확정 의존성 (BOM으로 고정)

| 의존성 | 좌표 | 버전 |
|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 26.0.10 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | 11.37.2 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | 10.9.1 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 4.2.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0.5 |
| 단위 테스트 | JUnit 6.1.1 · Mockito 5.23.0 | — |

**Node 확정 의존성(package.json으로 고정, major 핀)**: `@keycloak/keycloak-admin-client` **26.6.4**(admin) · `openid-client` **6.8.4**(auth, 함수형 API) · `jose` **5.10.0**(강화 JWT) · dev: `typescript` 5 · `vitest`/`@vitest/coverage-v8` 3 · `testcontainers` 11 · `eslint` 9 + `typescript-eslint` 8 · `prettier` 3 · `@types/node` 20. 런타임 deps(admin-client/openid-client/jose)는 audit clean, devDeps 일부 moderate(dockerode/testcontainers 계열, `files:["dist"]`라 소비자 미배포).

**Go 확정 의존성(go.mod, major 핀)**: `github.com/Nerzal/gocloak/v13` **v13.9.0**(admin) · `golang.org/x/oauth2` **v0.36.0**(auth 흐름) · `github.com/go-jose/go-jose/v4` **v4.1.4**(강화 JWT) · `golang.org/x/sync/singleflight`(single-flight) · test: `github.com/testcontainers/testcontainers-go` **v0.43.0**(base GenericContainer — `modules/keycloak`는 독립 태그 부재로 미사용) · `github.com/stretchr/testify` **v1.11.1**. 전부 Apache-2.0/BSD-3/MIT(호환). `go-oidc`는 제외(discovery는 규약 조립, verifier는 go-jose 자체 강화).

**C#/.NET 확정 의존성(csproj, major 핀)**:

| 의존성 | 좌표 | 버전 |
|---|---|---|
| 인증(OIDC/OAuth2) | `Duende.IdentityModel` | 8.1.0 |
| JWT(강화 검증) | `Microsoft.IdentityModel.JsonWebTokens` + `.Protocols.OpenIdConnect` | 8.19.1 |
| Admin | `Keycloak.AuthServices.Sdk` | **2.7.0**(net8 최종 — 3.0.0은 net10 전용) |
| DI 추상화 | `Microsoft.Extensions.DependencyInjection.Abstractions` | 9.0.8(AuthServices 2.7.0 요구 하한) |
| 단위 테스트 | `xUnit` 2.9.3 · `WireMock.Net` 2.11.0 · `coverlet.msbuild` 10.0.1 | — |
| 통합 테스트 | `Testcontainers.Keycloak` | 4.13.0 |

전부 Apache-2.0/MIT(호환). `IHttpClientFactory`는 미채택(단일 장수명 `HttpClient` + `SocketsHttpHandler.PooledConnectionLifetime` — 단일서버 SDK 관용).

**PHP 확정 의존성(composer.json, 정확 핀/범위 지정)**:

| 의존성 | 좌표 | 버전 |
|---|---|---|
| Admin | `fschmtt/keycloak-rest-api-client-php` | **0.42.0**(정확 핀 — pre-1.0 계열, 파괴적 변경 가능) |
| 인증(OAuth2) | `league/oauth2-client` + `stevenmaguire/oauth2-keycloak` | `^2.8` / `^6.1` |
| JWT(강화 검증) | `firebase/php-jwt` | `^7.1` |
| HTTP(PSR-18/17) | `guzzlehttp/guzzle` + `guzzlehttp/psr7` | `^7.9` / `^2.7` |
| 단위 테스트 | `phpunit/phpunit` 12 · `phpstan/phpstan` 2.2(+ strict-rules·phpunit 확장) · `friendsofphp/php-cs-fixer` 3.95 | — |
| 통합 테스트 | (docker CLI 셸아웃 — `testcontainers/testcontainers` ^1.0은 dev 의존이나 Windows native PHP 미지원으로 실사용 안 함) | — |

전부 MIT/BSD-3(Apache-2.0 호환). `jumbojett/openid-connect-php`는 세션 슈퍼글로벌·`header()` 리다이렉트를 자체 소유해 결정적 파사드와 상충 + JWT 검증 이력 우려로 기각.

## 문서 유지 규칙

작업 완료(머지/main 반영) 후 프로젝트 전체 문서(`CLAUDE.md`, `docs/`, `README.md`)를 최신화·최적화하고 커밋한다. 언어별 빌드/테스트 명령(단일 테스트 실행 포함)을 툴체인 섹션에 유지한다(Java·Python·Node·Go·C#·PHP).
