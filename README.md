# KeyCloak SDK — polyglot (여러 프로그래밍 언어)

Keycloak을 위한 **여러 프로그래밍 언어용 SDK**(polyglot). Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다루며, 언어마다 관용적이면서도 개념·계층·흐름이 **동형(isomorphic)** 인 SDK를 제공합니다.

> ℹ️ 여기서 "다국어/polyglot"은 **프로그래밍 언어**(Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin)를 의미합니다. 자연어 현지화(i18n)와는 무관합니다.

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
| **Kotlin 2.2+**(JVM) | ✅ 완료 · `main` 병합 (PR #23) | JVM 자매 Java SDK 스택(`keycloak-admin-client`+Nimbus OAuth2/OIDC SDK) 재래핑 + 코루틴(`suspend`) 관용 | Maven Central `io.github.xzawed:keycloak-sdk-kotlin` (human-gated) |

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
- **Kotlin**: JVM 자매 Java SDK와 동일한 검증 스택(`org.keycloak:keycloak-admin-client`+Nimbus `oauth2-oidc-sdk`+`nimbus-jose-jwt`) 재사용, 코루틴(`suspend`+`runInterruptible(Dispatchers.IO)`) 관용으로 재래핑. data class 값타입, sealed 예외 계층(`KeycloakException`), `explicitApi()`로 public API 가시성 엄격 강제. `admin`↔`auth`는 `TokenProvider`(`fun interface`)로만 접착.
- **JWT 검증은 아홉 언어 모두 자체 강화 구현** — 알고리즘 핀닝(`none`/미서명 거부·헤더 불신), `iss` 정확일치, **`aud` 포함검사**(실제 Keycloak 토큰의 다중 aud 대응), `exp` 필수, 클록 스큐, DoS-안전 JWKS 재조회. (Java: Nimbus JOSE, Python: joserfc, Node: jose, Go: go-jose/v4, C#: Microsoft.IdentityModel.JsonWebTokens, PHP: firebase/php-jwt + 자체 JwksStore, Rust: jsonwebtoken + 자체 JwksStore, Ruby: jwt(ruby-jwt) + 자체 JwksStore, Kotlin: nimbus-jose-jwt(Java와 동일 라이브러리, 코루틴 래핑))

## 설치 & 시작

> 🚀 **전체 설치·시작 가이드 → [docs/guides/getting-started.md](docs/guides/getting-started.md)** — 언어별 요구 런타임 · 로컬/배포후 설치 · 최소 사용 예(토큰 발급 → JWT 검증 → admin CRUD)를 한곳에 정리했습니다. 아래는 요약입니다.

**요구 런타임**: Java **JDK 21+**(`--release 21` 컴파일 — 이전 JDK는 `UnsupportedClassVersionError`) · Python **3.10+** · Node.js **20+**(ESM) · Go **1.25+** · .NET **8+** · PHP **8.3+** · Rust **1.88+**(edition 2024 + let-chains 요구 MSRV) · Ruby **3.2+** · Kotlin **2.2+**(JDK 21+, JVM 자매 Java SDK와 동일 런타임).

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

### Kotlin (Gradle)
> ⚠️ `io.github.xzawed:keycloak-sdk-kotlin` `0.1.0`은 아직 Maven Central 미배포(human-gated, Central Portal — `kotlin-v*` 태그 push 시 스테이징 후 사람이 수동 release).
```bash
gradle -p kotlin build && gradle -p kotlin test   # 현재(미배포) — 로컬 빌드/테스트(단위 100개)
# implementation("io.github.xzawed:keycloak-sdk-kotlin:0.1.0")   # 배포 후 (Gradle Kotlin DSL)
```

### 최소 사용 예

토큰 발급 → JWT 검증 → admin CRUD의 **언어별 최소 예제와 async 사용법**은 시작 가이드에 있습니다: **[getting-started](docs/guides/getting-started.md)**. 실행 예제는 [`java/keycloak-sdk-examples`](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) · [`python/examples/quickstart.py`](python/examples/quickstart.py)(+[async](python/examples/async_quickstart.py)) · [`node/examples/quickstart.ts`](node/examples/quickstart.ts) · [`go/example_test.go`](go/example_test.go) · [`php/examples/quickstart.php`](php/examples/quickstart.php) · [`rust/examples/quickstart.rs`](rust/examples/quickstart.rs) · [`ruby/examples/quickstart.rb`](ruby/examples/quickstart.rb) · [`kotlin/examples/quickstart.kt`](kotlin/examples/quickstart.kt) 참고(C#/.NET은 별도 예제 프로젝트 없이 getting-started의 인라인 예제 참고).

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
| Kotlin `0.1.0` | 26.6.x (통합테스트: 실제 **26.6**, Testcontainers) | `keycloak-admin-client` **26.0.10** · `oauth2-oidc-sdk` **11.37.2** · `nimbus-jose-jwt` **10.9.1**(Java와 동일 JVM 스택) · Kotlin 2.2.20+ / JDK 21+ |

SDK 자체 SemVer는 Keycloak/하위 라이브러리 버전과 분리됩니다. 지원 서버 범위는 이 표로 안내합니다.

## 현재 상태

**9개 언어 SDK 전부 완료 · `main` 병합.** 각 언어가 전 Phase(기반 → core → auth → admin → facade → 통합테스트 → 배포&문서)를 구현하고, **실제 Keycloak 26.6(.4) 통합테스트가 GREEN**이며, 로직 커버리지 게이트(라인 ≥90% / 브랜치 ≥85%)를 통과합니다. JWT 검증은 아홉 언어 모두 자체 강화 구현입니다([§전략](#전략)).

| SDK | PR | 테스트 (단위 + 통합) | 로직 커버리지 | 특이 |
|---|---|---|---|---|
| Java | #1 | 123 (117 + 6) | 게이트 라인 90 / 브랜치 85 | 기준 구현 |
| Python | #2 · #4 | 235 (224 + 11) | 로직 100% 강제 | sync + async(`aio`) |
| Node | #12 | 76 (71 + 5) | 라인 100 / 브랜치 94 | ESM · async-only |
| Go | #13 | 41 (40 + 1) | 95.2% | sync + `context.Context` |
| C# / .NET | #14 | 59 (58 + 1) | 97.34 / 93.47 | async-first |
| PHP | #17 | 67 (64 + 3) | 100% | `final readonly class` |
| Rust | #18 | 35 (34 + 1) | 94.85% | edition 2024 · async |
| Ruby | #19 | 74 (73 + 1) | 100 / 93.48 | faraday 직접 admin |
| Kotlin | #23 | 101 (100 + 1) | 99.24 / 85.71 | 코루틴 · JVM 스택 재사용 |

> 통합테스트는 대부분 **Testcontainers**(실제 Keycloak 26.6)이며, PHP·Ruby는 Windows testcontainers 미지원으로 **docker CLI 셸아웃** 폴백입니다(CI ubuntu에선 동일 동작). 각 SDK의 보안 핵심(JwtValidator 등)은 opus 어드버서리얼 리뷰로 검증했습니다(예: Kotlin **SECURE** 판정 — 19 공격 프로브·악용 가능 0).

**남은 것은 실배포뿐**(Maven Central(Java·Kotlin)·PyPI·npm·Go 모듈 태그·NuGet·Packagist·crates.io·RubyGems, 사람 계정/키/토큰 필요 — [DEPLOY.md](DEPLOY.md)).

- 📄 설계 스펙: [Java·Python 멀티랭 설계](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) · [Python](docs/superpowers/specs/2026-07-03-keycloak-python-sdk-design.md) · [Python async](docs/superpowers/specs/2026-07-03-keycloak-python-async-design.md) · [C#/.NET](docs/superpowers/specs/2026-07-04-keycloak-dotnet-sdk-design.md) · [PHP](docs/superpowers/specs/2026-07-06-keycloak-php-sdk-design.md) · [Rust](docs/superpowers/specs/2026-07-06-keycloak-rust-sdk-design.md) · [Ruby](docs/superpowers/specs/2026-07-06-keycloak-ruby-sdk-design.md) · [Kotlin](docs/superpowers/specs/2026-07-07-keycloak-kotlin-sdk-design.md)
- 🗂️ 구현 계획(WBS): [docs/superpowers/plans/](docs/superpowers/plans/)
- 📝 검증 로그: [Java](docs/governance/verification-log.md) · [Python](docs/governance/verification-log-python.md) · [Node](docs/governance/verification-log-node.md) · [Go](docs/governance/verification-log-go.md) · [C#/.NET](docs/governance/verification-log-dotnet.md) · [PHP](docs/governance/verification-log-php.md) · [Rust](docs/governance/verification-log-rust.md) · [Ruby](docs/governance/verification-log-ruby.md) · [Kotlin](docs/governance/verification-log-kotlin.md)

## 개발자 안내

기여·테스트·검증 게이트(머지 전 통과 항목·로컬 명령·PR 체크리스트)는 [CONTRIBUTING.md](CONTRIBUTING.md), 프로젝트 구조·아키텍처·빌드 명령·게차(gotchas)는 [CLAUDE.md](CLAUDE.md), 배포 절차는 [DEPLOY.md](DEPLOY.md)를 참고하세요.

- 🚀 **설치·시작**: [docs/guides/getting-started.md](docs/guides/getting-started.md)
- 🖥️ **Keycloak *서버* 배포**(SDK가 붙을 서버 — 단일 VM + Docker Compose 프로덕션): [docs/guides/deploying-keycloak-server.md](docs/guides/deploying-keycloak-server.md)
- 🗺️ **지원 언어·확장 로드맵**(depth-first · Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin 완료 — 9개 언어): [docs/roadmap/language-support.md](docs/roadmap/language-support.md)
- 🧩 **새 언어 추가 플레이북**(Java/Python/Node/Go/C#/PHP/Rust/Ruby/Kotlin 품질로 반복): [docs/guides/add-a-language-playbook.md](docs/guides/add-a-language-playbook.md)

## 가상 사용자 테스트 하네스 (Virtual-User Harness)

문서·유닛/통합테스트와 별개로, 폴리글랏 SDK들이 **실제로 동일하게 동작하는지** 언어 간에 실측 비교하기 위한 하네스가 [`harness/`](harness/README.md)에 있습니다. 실제 Keycloak 26.6(`it-realm` — 언어별 통합테스트와 동일 realm)을 Docker Compose로 띄우고, 각 언어 SDK로 작성된 동일 [HTTP 계약](harness/contract/CONTRACT.md)(v2 — auth 확장 4엔드포인트 + admin 5리소스)의 샘플 앱을 구동해 검증합니다. **9개 언어(Go·C#·Node·Python·Java·PHP·Rust·Ruby·Kotlin) 샘플 앱이 모두 완료**됐습니다(`harness/apps/{go,dotnet,node,python,java,php,rust,ruby,kotlin}` — 각각 net/http·ASP.NET Core·Express 5·FastAPI·Spring Boot·Slim 4·axum·Rack/Puma·Ktor/Netty 관용 프레임워크, 호스트 포트 8090~8098).

두 가지 실행 경로가 있습니다:

```bash
cd harness && ./run.sh go dotnet node python java                          # 레거시 k6 부하 실측·비교만 → harness/report/RESULTS.md
cd harness && ./verify.sh go dotnet node python java php rust ruby kotlin  # 9언어 종합 검증·스코어링 → harness/report/SCORECARD.md
```

`verify.sh`는 언어별로 Keycloak 기동 → 앱 빌드·기동 → **conformance**(`conformance/conformance.mjs`, 계약 준수 assert) → **security**(`security/probe.mjs`, JWT 하드닝 공격 프로브 — alg=none·HS/RS confusion·미지kid·flood 등) → k6 성능을 실행하고, 전 언어 종료 후 **suites**(`suites/run-suite.sh`, 각 SDK 자체 단위테스트+커버리지+린트를 툴체인 이미지에서 실행)를 집계한 뒤, `report/score.mjs`가 **4차원 가중 스코어카드**(기능 30%·보안 30%·커버리지 20%·성능/동형성 20%, 등급 A≥90/B≥80/C≥70/D<70)를 `report/SCORECARD.md`로 산출합니다. 한 언어의 앱 빌드/헬스체크 실패는 격리되고 나머지 언어는 계속 진행합니다(성능·동형성 차원은 **k6 연동됨** — k6 summary의 validate p95를 언어간 상대점수[최우수=100·k배=100/k]로 반영, k6 미측정 언어는 동형성만 무벌점). CI는 [`.github/workflows/harness.yml`](.github/workflows/harness.yml)에서 PR/푸시엔 빠른 Go 스모크 게이트(`mvp-go`)를, 야간(schedule 03:00 UTC)·수동(workflow_dispatch)엔 5언어 k6 비교(`all-langs`)와 9언어 종합 검증·스코어링(`score-all`, `SCORECARD.md`+`signals/` 아티팩트)을 실행합니다.

### 설치·동작 검증 하네스 (Install-&-Operate)

위 하네스가 SDK를 **소스 경로**로 소비하는 것과 달리, [`harness/install/`](harness/install/README.md)는 실배포 없이 **각 SDK를 "게시된 패키지처럼" Docker 로컬 레지스트리에서 설치**하고 실 Keycloak에 대해 동작(quickstart + conformance + security)까지 검증합니다 — 배포 산출물의 설치 경로(매니페스트·메타데이터·의존성 해석)를 실배포 전 최종 확인합니다.

```bash
cd harness/install && ./install-verify.sh          # 전 9개 언어 → harness/install/report/INSTALL-MATRIX.md
```

각 언어의 로컬 레지스트리(node=Verdaccio·python=pypiserver·go=file GOPROXY·dotnet=BaGetter·java=nginx 정적 .m2·ruby=gem-index·php=Satis·rust=cargo-local-registry·kotlin=nginx 정적 .m2(mvn-repo-kotlin, Gradle))에서 **실제 설치 명령과 동일**(소스 URL만 로컬)하게 설치하고, 소스 트리 없는 클린 컨테이너에서 부팅·동작합니다. **9/9 언어 로컬 실측 전 셀 GREEN**(conformance 26/26·security 9/9). CI는 `install-all` 잡(야간/수동·`INSTALL-MATRIX.md` 아티팩트)으로 실행합니다.
