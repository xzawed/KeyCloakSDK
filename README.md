# KeyCloak SDK — polyglot (여러 프로그래밍 언어)

Keycloak을 위한 **여러 프로그래밍 언어용 SDK**(polyglot). Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다루며, 언어마다 관용적이면서도 개념·계층·흐름이 **동형(isomorphic)** 인 SDK를 제공합니다.

> ℹ️ 여기서 "다국어/polyglot"은 **프로그래밍 언어**(Java·Python·Node·Go·C#·PHP·Rust·Ruby)를 의미합니다. 자연어 현지화(i18n)와는 무관합니다.

| 언어 | 상태 | 기반 | 배포 |
|---|---|---|---|
| **Java 21** (Maven) | ✅ 완료 · `main` 병합 (PR #1) | 공식 `keycloak-admin-client` + Nimbus OAuth2/OIDC SDK 래핑 | Maven Central `io.github.xzawed:keycloak-sdk` (human-gated) |
| **Python 3.10+** | ✅ 완료 · `main` 병합 (PR #2 sync, PR #4 async) | `python-keycloak`(admin+OIDC) 래핑 + `joserfc` 자체 JWT 검증 | PyPI `keycloak-sdk` (human-gated) |
| **Node.js 20+** (ESM) | ✅ 완료 · `main` 병합 (PR #12) | 공식 `@keycloak/keycloak-admin-client` + `openid-client` v6 래핑 + `jose` 자체 JWT 검증 | npm `@xzawed/keycloak-sdk` (human-gated) |
| **Go 1.25+** | ✅ 완료 · `main` 병합 (PR #13) | `Nerzal/gocloak` v13 + `golang.org/x/oauth2` 래핑 + `go-jose/v4` 자체 JWT 검증 | Go 모듈 `github.com/xzawed/KeyCloakSDK/go` (태그=릴리스, human-gated) |
| **C# / .NET 8+** | ✅ 완료 · `main` 병합 (PR #14) | `Duende.IdentityModel` + `Keycloak.AuthServices.Sdk` 2.7.0 래핑 + `Microsoft.IdentityModel.JsonWebTokens` 자체 JWT 검증 | NuGet `Xzawed.Keycloak.Sdk` (human-gated) |
| **PHP 8.3+** | ✅ 완료 · `main` 병합 (PR #17) | `fschmtt/keycloak-rest-api-client-php` 래핑(admin) + `league/oauth2-client`+`stevenmaguire/oauth2-keycloak` 래핑(auth) + `firebase/php-jwt` 자체 JWT 검증 | Packagist `xzawed/keycloak-sdk` (GitHub 웹훅 자동게시, human-gated) |
| **Rust 1.88+**(edition 2024) | ✅ 완료 · `main` 병합 (PR #18) | `keycloak` crate 래핑(admin) + `openidconnect` 래핑(auth) + `jsonwebtoken` 자체 JWT 검증 | crates.io `keycloak-sdk` (human-gated) |
| **Ruby 3.2+** | ✅ 완료 · `main` 병합 (PR #19) | `faraday` 직접 래핑(admin, 성숙한 gem 부재) + `rack-oauth2` 래핑(auth) + `jwt`(ruby-jwt) 자체 JWT 검증 | RubyGems `keycloak-sdk` (Trusted Publishing, human-gated) |

- **라이선스**: Apache-2.0

## 전략

> 언어마다 **가장 좋은 기반**을 사용 — 공식/성숙 클라이언트가 있으면 감싼다 — 그 위에 **일관된 파사드 + 강화된 JWT 검증**을 언어 공통 설계로 얹는다. 하위 라이브러리 타입은 파사드 뒤에 숨겨 공개 API로 노출하지 않는다.

- **Java**: 공식 `org.keycloak:keycloak-admin-client`(Admin) + Nimbus OAuth2/OIDC SDK(인증) 래핑.
- **Python**: 성숙한 `python-keycloak`의 `KeycloakAdmin`(Admin) + `KeycloakOpenID`(인증) 래핑. sync + **async(`keycloak_sdk.aio`)** 모두 제공.
- **Node.js**: 공식 `@keycloak/keycloak-admin-client`(Admin) + `openid-client` v6 함수형 API(인증) 래핑. ESM 전용·async-only.
- **Go**: `Nerzal/gocloak` v13(Admin) + `golang.org/x/oauth2`(인증) 래핑. sync + `context.Context`, 오류는 타입드 구조체 + 센티넬(`errors.Is`/`errors.As`).
- **C# / .NET**: `Keycloak.AuthServices.Sdk` 2.7.0(Admin, users/groups/realm-get 타입드 + clients/roles/realm-CRUD raw REST) + `Duende.IdentityModel`(인증) 래핑. async-first(`Task<T>`+`CancellationToken`), 예외 계급(`KeycloakException`→`KeycloakAdminException`→`KeycloakNotFoundException` 등).
- **PHP**: `fschmtt/keycloak-rest-api-client-php` 0.42.0(Admin) + `league/oauth2-client`+`stevenmaguire/oauth2-keycloak`(인증, PKCE S256 오버라이드) 래핑. `final readonly class` 값타입, 예외 계급(`KeycloakException`→`KeycloakAdminError`→`KeycloakNotFoundError` 등).
- **Rust**: `keycloak` crate =26.6.2(Admin, `reqwest12` feature로 reqwest 0.12 정렬) + `openidconnect` =4.0.1(인증, 수동 EndpointSet typestate) 래핑. async-only(tokio), `thiserror` 기반 `KeycloakError` enum, `admin`↔`auth`는 `TokenProvider` trait로만 접착.
- **Ruby**: 성숙한 admin gem이 없어 `faraday`로 Admin REST 직접 래핑(5리소스+raw) + `rack-oauth2`(인증, PKCE S256은 손수 생성) 래핑. sync-only, 예외 계급(`KeycloakSdk::Error`→`AdminError`→`NotFoundError` 등), `admin`↔`auth`는 `TokenProvider` 덕 인터페이스로만 접착.
- **JWT 검증은 여덟 언어 모두 자체 강화 구현** — 알고리즘 핀닝(`none`/미서명 거부·헤더 불신), `iss` 정확일치, **`aud` 포함검사**(실제 Keycloak 토큰의 다중 aud 대응), `exp` 필수, 클록 스큐, DoS-안전 JWKS 재조회. (Java: Nimbus JOSE, Python: joserfc, Node: jose, Go: go-jose/v4, C#: Microsoft.IdentityModel.JsonWebTokens, PHP: firebase/php-jwt + 자체 JwksStore, Rust: jsonwebtoken + 자체 JwksStore, Ruby: jwt(ruby-jwt) + 자체 JwksStore)

## 설치 & 시작

> 🚀 **전체 설치·시작 가이드 → [docs/guides/getting-started.md](docs/guides/getting-started.md)** — 언어별 요구 런타임 · 로컬/배포후 설치 · 최소 사용 예(토큰 발급 → JWT 검증 → admin CRUD)를 한곳에 정리했습니다. 아래는 요약입니다.

**요구 런타임**: Java **JDK 21+**(`--release 21` 컴파일 — 이전 JDK는 `UnsupportedClassVersionError`) · Python **3.10+** · Node.js **20+**(ESM) · Go **1.25+** · .NET **8+** · PHP **8.3+** · Rust **1.88+**(edition 2024 + let-chains 요구 MSRV) · Ruby **3.2+**.

### Java (Maven)
> ⚠️ `0.1.0-SNAPSHOT`은 아직 Maven Central 미배포(human-gated). 배포 전에는 `mvn -f java/pom.xml install -DskipITs=true`로 로컬 `~/.m2`에 설치해 사용하세요(Docker 불필요). 배포 절차는 [DEPLOY.md](DEPLOY.md) 참고.

파사드 아티팩트 하나만 추가하면 `core`/`auth`/`admin`이 따라옵니다(전이 버전 정합이 필요하면 BOM 임포트):
```xml
<dependency>
  <groupId>io.github.xzawed</groupId>
  <artifactId>keycloak-sdk</artifactId>
  <version>0.1.0-SNAPSHOT</version>
</dependency>
```

### Python (pip)
> ⚠️ `keycloak-sdk` `0.1.0`은 아직 PyPI 미배포(human-gated, PyPI Trusted Publisher). 배포 절차는 [DEPLOY.md](DEPLOY.md) 참고.
```bash
pip install -e python        # 현재(미배포) — 로컬 editable 설치
# pip install keycloak-sdk   # 배포 후
```

### Node.js (npm)
> ⚠️ `@xzawed/keycloak-sdk` `0.1.0`은 아직 npm 미배포(human-gated, npm Trusted Publishing / OIDC + provenance).
```bash
cd node && npm ci && npm run build   # 현재(미배포) — 로컬 빌드 후 npm link/파일 참조
# npm install @xzawed/keycloak-sdk    # 배포 후
```

### Go (모듈)
> ⚠️ 아직 릴리스 태그 없음(human-gated). Go는 레지스트리 없이 **태그=릴리스**(`proxy.golang.org` 자동 캐시).
```bash
cd go && go build ./... && go test ./...   # 현재(미배포) — 로컬 빌드/테스트
# go get github.com/xzawed/KeyCloakSDK/go@v0.1.0   # 태그 push 후
```

### C# / .NET (NuGet)
> ⚠️ `Xzawed.Keycloak.Sdk` `0.1.0`은 아직 NuGet 미배포(human-gated, `NUGET_API_KEY` 시크릿 필요).
```bash
cd dotnet && dotnet build && dotnet test --filter "Category!=Integration"   # 현재(미배포) — 로컬 빌드/테스트
# dotnet add package Xzawed.Keycloak.Sdk   # 배포 후
```

### PHP (Composer)
> ⚠️ `xzawed/keycloak-sdk` `0.1.0`은 아직 Packagist 미배포(human-gated — 태그 push 시 Packagist가 GitHub 웹훅으로 자동 게시, 별도 저장 시크릿 없음).
```bash
cd php && composer install && vendor/bin/phpunit --testsuite unit   # 현재(미배포) — 로컬 설치/테스트
# composer require xzawed/keycloak-sdk   # 배포 후
```

### Rust (Cargo)
> ⚠️ `keycloak-sdk` `0.1.0`은 아직 crates.io 미배포(human-gated, `CARGO_REGISTRY_TOKEN` 시크릿 필요).
```bash
cd rust && cargo build && cargo test   # 현재(미배포) — 로컬 빌드/테스트(단위 34개)
# cargo add keycloak-sdk                # 배포 후
```

### Ruby (RubyGems)
> ⚠️ `keycloak-sdk` `0.1.0`은 아직 RubyGems 미배포(human-gated, Trusted Publishing — 최초 1회는 API 키 수동 게시 또는 Trusted Publisher 사전등록 필요).
```bash
cd ruby && bundle install && bundle exec rspec   # 현재(미배포) — 로컬 설치/테스트(단위 73개)
# gem install keycloak-sdk                        # 배포 후
```

### 최소 사용 예

토큰 발급 → JWT 검증 → admin CRUD의 **언어별 최소 예제와 async 사용법**은 시작 가이드에 있습니다: **[getting-started](docs/guides/getting-started.md)**. 실행 예제는 [`java/keycloak-sdk-examples`](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) · [`python/examples/quickstart.py`](python/examples/quickstart.py)(+[async](python/examples/async_quickstart.py)) · [`node/examples/quickstart.ts`](node/examples/quickstart.ts) · [`go/example_test.go`](go/example_test.go) · [`php/examples/quickstart.php`](php/examples/quickstart.php) · [`rust/examples/quickstart.rs`](rust/examples/quickstart.rs) · [`ruby/examples/quickstart.rb`](ruby/examples/quickstart.rb) 참고(C#/.NET은 별도 예제 프로젝트 없이 getting-started의 인라인 예제 참고).

## 호환성

| SDK | 대상 Keycloak 서버 | 기반 라이브러리 |
|---|---|---|
| Java `0.1.0-SNAPSHOT` | 26.6.x (통합테스트: 실제 **26.6.4**) | `keycloak-admin-client` **26.0.10** (서버와 독립 버전 트랙 — "26.6.x admin-client"는 없음) · Nimbus `oauth2-oidc-sdk` 11.37.2 |
| Python `0.1.0` | 26.6.x (통합테스트: 실제 **26.6.4**) | `python-keycloak` **7.1.x** · `joserfc` 1.7.x · Python 3.10+ |
| Node `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**) | `@keycloak/keycloak-admin-client` **26.6.4** · `openid-client` **6.8.4** · `jose` **5.10.0** · Node 20+ |
| Go `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**) | `Nerzal/gocloak/v13` **13.9.0** · `golang.org/x/oauth2` **0.36.0** · `go-jose/v4` **4.1.4** · Go 1.25+ |
| C#/.NET `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**) | `Keycloak.AuthServices.Sdk` **2.7.0** · `Duende.IdentityModel` **8.1.0** · `Microsoft.IdentityModel.JsonWebTokens` **8.19.1** · .NET 8+ |
| PHP `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**, docker CLI 셸아웃) | `fschmtt/keycloak-rest-api-client-php` **0.42.0** · `league/oauth2-client` **^2.8** · `stevenmaguire/oauth2-keycloak` **^6.1** · `firebase/php-jwt` **^7.1** · PHP 8.3+ |
| Rust `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**, Testcontainers) | `keycloak` **=26.6.2**(`reqwest12` feature) · `openidconnect` **=4.0.1** · `jsonwebtoken` **=10.4.0** · Rust 1.88+(edition 2024) |
| Ruby `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**, docker CLI 셸아웃) | `rack-oauth2` **~>2.3** · `faraday` **~>2.0** · `jwt`(ruby-jwt) **~>3.2** · Ruby 3.2+ |

SDK 자체 SemVer는 Keycloak/하위 라이브러리 버전과 분리됩니다. 지원 서버 범위는 이 표로 안내합니다.

## 현재 상태

**Java · Python · Node.js · Go · C#/.NET SDK 완료 · `main` 병합**(Java PR #1, Python PR #2/#4, Node PR #12, Go PR #13, C#/.NET PR #14). 각 언어 전 Phase(기반→core→auth→admin→facade→통합테스트→배포&문서) 구현, **실제 Keycloak 26.6(.4) Testcontainers 통합테스트 GREEN**, 로직 커버리지 게이트(라인 ≥90%/브랜치 ≥85%) 통과. Python은 sync + async(`keycloak_sdk.aio`) 모두 제공. Node는 ESM·async-only, Go는 sync + `context.Context`, C#/.NET은 async-first(`Task<T>`+`CancellationToken`).

**PHP SDK 완료 · `main` 병합 (PR #17).** WBS Task 1~12 전체 구현(스캐폴딩 → masking/exc → config → tokens/oidc → tokenprovider → jwks → jwt → auth → admin → client → 통합테스트 → CI/문서). 단위테스트 64개 + 통합테스트(docker CLI 셸아웃, 실제 Keycloak 26.6) 3개(`FullFlowIT`) = 총 67개 GREEN, 집계 로직 커버리지 100.00%(게이트 ≥90%), `phpstan analyse`(level max)·`php-cs-fixer` 통과. 6번째 언어로 선행 5개 SDK의 게차가 선반영되어 통합테스트 신규 버그 0건.

**Rust SDK 완료 · `main` 병합됨 (PR #18).** WBS Task 1~12 전체 구현(스캐폴딩 → error → config → tokens/oidc → token_provider → jwks → jwt → auth → admin → client → 통합테스트 → CI/문서). edition 2024 · async-only(tokio). 단위테스트 34개 + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 1개(E2E `full_flow` — 전 흐름·5 admin 리소스) = 총 35개 GREEN, 로직 모듈 라인 커버리지 94.85%(게이트 ≥90%), `cargo clippy -D warnings`·`cargo fmt --check` 통과. 7번째 언어로 E2E 신규 SDK 버그 0건. 최종리뷰 fix wave(1건)로 admin이 캐싱 `ClientCredentialsTokenProvider`를 쓰도록 수정(§4 캐시 불변식 복원) + `config.scopes` threading.

**Ruby SDK 완료 · `main` 병합됨 (PR #19).** WBS Task 1~12 전체 구현(스캐폴딩 → errors/masking → config → tokens/oidc/http → token_provider → jwks → jwt → auth → admin → client → 통합테스트 → CI/문서). sync-only · 예외 계급 관용. 단위테스트 73개 + 통합테스트(docker CLI 셸아웃, 실제 Keycloak 26.6) 1개(E2E `full_flow`) = 총 74개 GREEN, 로직 모듈 커버리지 라인 100.0%/브랜치 93.48%(게이트 ≥90/≥85), `rubocop` 무경고·`bundler-audit` 통과. 8번째(마지막) 언어로 E2E 신규 SDK 버그 0건(PHP·Rust에 이은 세 번째 무결함 사례). admin에 성숙한 gem이 없어 `faraday`로 Admin REST를 직접 구현.

**남은 것은 실배포뿐**(Maven Central·PyPI·npm·Go 모듈 태그·NuGet·Packagist·crates.io·RubyGems, 사람 계정/키/토큰 필요 — [DEPLOY.md](DEPLOY.md)).

- 📄 설계 스펙: [Java·Python 멀티랭 설계](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) · [Python](docs/superpowers/specs/2026-07-03-keycloak-python-sdk-design.md) · [Python async](docs/superpowers/specs/2026-07-03-keycloak-python-async-design.md) · [C#/.NET](docs/superpowers/specs/2026-07-04-keycloak-dotnet-sdk-design.md) · [PHP](docs/superpowers/specs/2026-07-06-keycloak-php-sdk-design.md) · [Rust](docs/superpowers/specs/2026-07-06-keycloak-rust-sdk-design.md) · [Ruby](docs/superpowers/specs/2026-07-06-keycloak-ruby-sdk-design.md)
- 🗂️ 구현 계획(WBS): [docs/superpowers/plans/](docs/superpowers/plans/)
- 📝 검증 로그: [Java](docs/governance/verification-log.md) · [Python](docs/governance/verification-log-python.md) · [Node](docs/governance/verification-log-node.md) · [Go](docs/governance/verification-log-go.md) · [C#/.NET](docs/governance/verification-log-dotnet.md) · [PHP](docs/governance/verification-log-php.md) · [Rust](docs/governance/verification-log-rust.md) · [Ruby](docs/governance/verification-log-ruby.md)

## 개발자 안내

기여·테스트·검증 게이트(머지 전 통과 항목·로컬 명령·PR 체크리스트)는 [CONTRIBUTING.md](CONTRIBUTING.md), 프로젝트 구조·아키텍처·빌드 명령·게차(gotchas)는 [CLAUDE.md](CLAUDE.md), 배포 절차는 [DEPLOY.md](DEPLOY.md)를 참고하세요.

- 🚀 **설치·시작**: [docs/guides/getting-started.md](docs/guides/getting-started.md)
- 🖥️ **Keycloak *서버* 배포**(SDK가 붙을 서버 — 단일 VM + Docker Compose 프로덕션): [docs/guides/deploying-keycloak-server.md](docs/guides/deploying-keycloak-server.md)
- 🗺️ **지원 언어·확장 로드맵**(depth-first · Java·Python·Node·Go·C#·PHP·Rust·Ruby 완료 — 8개 언어): [docs/roadmap/language-support.md](docs/roadmap/language-support.md)
- 🧩 **새 언어 추가 플레이북**(Java/Python/Node/Go/C#/PHP/Rust/Ruby 품질로 반복): [docs/guides/add-a-language-playbook.md](docs/guides/add-a-language-playbook.md)

## 가상 사용자 테스트 하네스 (Virtual-User Harness)

문서·유닛/통합테스트와 별개로, 폴리글랏 SDK들이 **실제로 동일하게 동작하는지** 언어 간에 실측 비교하기 위한 하네스가 [`harness/`](harness/README.md)에 있다. 실제 Keycloak 26.6(`it-realm` — 언어별 통합테스트와 동일 realm)을 Docker Compose로 띄우고, 각 언어 SDK로 작성된 동일 [HTTP 계약](harness/contract/CONTRACT.md)(v2 — auth 확장 4엔드포인트 + admin 5리소스)의 샘플 앱을 구동해 검증한다. **8개 언어(Go·C#·Node·Python·Java·PHP·Rust·Ruby) 샘플 앱이 모두 완료**됐다(`harness/apps/{go,dotnet,node,python,java,php,rust,ruby}` — 각각 net/http·ASP.NET Core·Express 5·FastAPI·Spring Boot·Slim 4·axum·Rack/Puma 관용 프레임워크, 호스트 포트 8090~8097).

두 가지 실행 경로가 있다:

```bash
cd harness && ./run.sh go dotnet node python java                          # 레거시 k6 부하 실측·비교만 → harness/report/RESULTS.md
cd harness && ./verify.sh go dotnet node python java php rust ruby         # 8언어 종합 검증·스코어링 → harness/report/SCORECARD.md
```

`verify.sh`는 언어별로 Keycloak 기동 → 앱 빌드·기동 → **conformance**(`conformance/conformance.mjs`, 계약 준수 assert) → **security**(`security/probe.mjs`, JWT 하드닝 공격 프로브 — alg=none·HS/RS confusion·미지kid·flood 등) → k6 성능을 실행하고, 전 언어 종료 후 **suites**(`suites/run-suite.sh`, 각 SDK 자체 단위테스트+커버리지+린트를 툴체인 이미지에서 실행)를 집계한 뒤, `report/score.mjs`가 **4차원 가중 스코어카드**(기능 30%·보안 30%·커버리지 20%·성능/동형성 20%, 등급 A≥90/B≥80/C≥70/D<70)를 `report/SCORECARD.md`로 산출한다. 한 언어의 앱 빌드/헬스체크 실패는 격리되고 나머지 언어는 계속 진행한다(⚠️ 성능·동형성 차원은 k6 실측 미연동 — conformance 통과율 근사, 후속 작업). CI는 [`.github/workflows/harness.yml`](.github/workflows/harness.yml)에서 PR/푸시엔 빠른 Go 스모크 게이트(`mvp-go`)를, 야간(schedule 03:00 UTC)·수동(workflow_dispatch)엔 5언어 k6 비교(`all-langs`)와 8언어 종합 검증·스코어링(`score-all`, `SCORECARD.md`+`signals/` 아티팩트)을 실행한다.
