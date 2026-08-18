# Keycloak SDK

**[Keycloak](https://www.keycloak.org/)을 다루는 하나의 SDK 모양, 9개 언어로.** 토큰을 발급하고, 안전하게 검증하고, 관리 REST API(Admin)를 호출합니다 — 눈앞의 서비스가 Java든 Python이든 Node·Go·C#·PHP·Rust·Ruby·Kotlin이든 개념·계층·흐름은 동일합니다.

**누구를 위한 것인가:** 여러 언어로 된 서비스 뒤에서 Keycloak을 운영하면서, 스택마다 클라이언트를 새로 익히고 JWT 검증을 매번 다시 결정하고 싶지는 않은 팀.

[English](README.md) · 한국어

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Languages](https://img.shields.io/badge/languages-9-brightgreen)
![Status](https://img.shields.io/badge/status-0.1.0%20(pre--1.0)-blue)
![Keycloak](https://img.shields.io/badge/Keycloak-26.6-informational)

> 여기서 "다국어/polyglot"은 **프로그래밍 언어**를 뜻하며, 자연어 현지화(i18n)와는 무관합니다.
>
> ⚠️ **아홉 언어 전부 정식 `0.1.0`이 공개 레지스트리에 게시됐습니다** — 모든 배포는 사람 승인 게이트이고, 라인은 아직 pre-1.0입니다. 설치 명령은 [설치](#설치)에, 붙일 임시 서버는 [지금 바로 써보기](#지금-바로-써보기)에 있습니다.

---

## `python-keycloak` / `gocloak` / 공식 클라이언트를 그냥 쓰면 되지 않나?

실제로 그것들을 계속 씁니다 — 이 SDK는 각 생태계에서 **가장 좋은 클라이언트를 대체하지 않고 감쌉니다**. 그 위에, 그 클라이언트들이 사용자에게 떠넘기는 세 가지를 더합니다:

- **기본값부터 강화된 JWT 검증.** 감싸는 라이브러리들은 느슨한 기본값을 주거나 building block만 줍니다. 여기서는 알고리즘 핀닝·`iss` 정확일치·`aud` 검사·`exp` 필수·클록 스큐 제한·rate-limit JWKS 재조회가 아홉 언어 모두에서 기본값입니다(.NET의 재조회 트리거는 더 넓습니다 — [자세히](#기본이-안전한-설계)).
- **전체 서비스군에 걸친 하나의 사고 모델.** 동일한 `auth` / `admin` 파사드, 동일한 토큰·검증 타입, 동일한 오류 계층 — Go 서비스와 PHP 서비스를 같은 체크리스트로 리뷰할 수 있습니다.
- **뺏어가는 것은 없음.** 파사드가 못 덮는 것이 있으면 `raw` 탈출구로 감싼 클라이언트에 그대로 접근합니다.

---

## 코드 모양

모든 언어가 동일한 3단계를 따릅니다 — **토큰 발급 → 검증 → Admin API 호출**. Python 예:

```python
from keycloak_sdk import KeycloakClient, KeycloakConfig

config = KeycloakConfig(
    server_url="https://keycloak.example.com",
    realm="my-realm",
    client_id="my-client",
    client_secret="…",              # 환경변수/시크릿 매니저에서 로드
)

with KeycloakClient.create(config) as kc:
    token  = kc.auth.client_credentials_token()      # 1. 토큰 발급
    claims = kc.auth.validate(token.access_token)     # 2. 검증(자체 강화)
    users  = kc.admin.users.search(first=0, max=10)   # 3. Admin API 호출
```

`validate()`는 토큰의 `aud`가 기대 audience(기본값은 client id)를 포함하는지 확인합니다. *다른* audience로 발급된 토큰은 그 기대 audience를 설정하기 전까지 거부됩니다(SDK 설정으로, 또는 Keycloak의 audience 매퍼로). 나머지 여덟 언어의 동일 흐름과 async 사용법은 **[시작 가이드](docs/guides/getting-started.md)** 에 있습니다.

---

## 설치

```bash
pip install keycloak-sdk                              # Python
npm install @xzawed/keycloak-sdk                      # Node
go get github.com/xzawed/KeyCloakSDK/go@v0.1.0        # Go
dotnet add package Xzawed.Keycloak.Sdk                # C# / .NET
composer require xzawed/keycloak-sdk                  # PHP
cargo add keycloak-sdk                                # Rust
gem install keycloak-sdk                              # Ruby
```

JVM은 빌드 파일에 좌표를 추가합니다:

```
io.github.xzawed:keycloak-sdk:0.1.0                   # Java   (Maven Central)
io.github.xzawed:keycloak-sdk-kotlin:0.1.0            # Kotlin (Maven Central)
```

빌드 도구별 전체 스니펫(Maven XML · Gradle Kotlin DSL · `Gemfile` · `Cargo.toml`)은 [시작 가이드](docs/guides/getting-started.md)에 있습니다.

## 지금 바로 써보기

붙을 Keycloak **서버**가 먼저 필요합니다 — 이것은 클라이언트 라이브러리이고, 서버는 별개 제품입니다:

```bash
# 1) 붙을 Keycloak 서버
docker run -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:26.6 start-dev
```

그다음 realm에 **서비스 계정을 활성화한 confidential 클라이언트**를 만드세요 — 예제가 받는 `client_id` / `client_secret`이 바로 그 한 쌍입니다. 버리는 컨테이너가 아니라 실서버가 필요하면 [Keycloak 서버 배포](docs/guides/deploying-keycloak-server.md)를 보세요.

릴리스본이 아니라 SDK 자체를 개발하려면 클론에서 설치합니다 — Python 예시이며, 모든 언어의 동등 절차는 [시작 가이드](docs/guides/getting-started.md)에 있습니다:

```bash
git clone https://github.com/xzawed/KeyCloakSDK.git
pip install -e KeyCloakSDK/python
```

---

## 지원 언어

| 언어 | 런타임 · 관용 | 패키지 *(아홉 전부 공개 레지스트리에 게시됨)* | 패키지 README | 예제 |
|---|---|---|---|---|
| **Java** | JDK 21+ · 블로킹 | `io.github.xzawed:keycloak-sdk` (Maven Central) | [java/README.md](java/README.md) | [QuickStart.java](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) |
| **Python** | 3.10+ · sync + async(`aio`) | `keycloak-sdk` (PyPI) | [python/README.md](python/README.md) | [quickstart.py](python/examples/quickstart.py) · [async](python/examples/async_quickstart.py) |
| **Node** | 22+ · ESM · async-only | `@xzawed/keycloak-sdk` (npm) | [node/README.md](node/README.md) | [quickstart.ts](node/examples/quickstart.ts) |
| **Go** | 1.25+ · sync + `context.Context` | `github.com/xzawed/KeyCloakSDK/go` | [go/README.md](go/README.md) | [example_test.go](go/example_test.go) |
| **C# / .NET** | 8+ · async-first | `Xzawed.Keycloak.Sdk` (NuGet) | [dotnet/README.md](dotnet/README.md) | [getting-started](docs/guides/getting-started.md#c--net) |
| **PHP** | 8.3+ · `final readonly class` | `xzawed/keycloak-sdk` (Packagist) | [php/README.md](php/README.md) | [quickstart.php](php/examples/quickstart.php) |
| **Rust** | 1.88+ (edition 2024) · async(tokio) | `keycloak-sdk` (crates.io) | [rust/README.md](rust/README.md) | [quickstart.rs](rust/examples/quickstart.rs) |
| **Ruby** | 3.2+ · sync-only | `keycloak-sdk` (RubyGems) | [ruby/README.md](ruby/README.md) | [quickstart.rb](ruby/examples/quickstart.rb) |
| **Kotlin** | 2.2+ / JDK 21+ · 코루틴 | `io.github.xzawed:keycloak-sdk-kotlin` (Maven Central) | [kotlin/README.md](kotlin/README.md) | [quickstart.kt](kotlin/examples/quickstart.kt) |

---

## 무엇이 동일하고, 무엇이 다른가

- **인증: 일곱 오퍼레이션은 아홉에 모두 있다** — client-credentials 토큰 · 인가 요청(PKCE S256) · 코드 교환 · refresh · introspect · logout · validate. 시그니처는 같지 않습니다: PHP·Rust는 `redirectUri`를 설정에서 읽고, Python 시작점은 `authorization_url`입니다. 아홉 모두 인가 요청에서 nonce를 발급하고, 호출자가 그 nonce를 `exchange*`에 넘기면 `id_token`을 검증합니다(인자는 아홉 모두 옵셔널 — 생략하면 id_token 검증을 건너뜁니다). 값 타입 이름은 전부 `TokenSet` / `ValidatedToken` / `IntrospectionResult`이되 필드 집합은 조금 다릅니다(`expires_in`은 Java·Python·Kotlin에 없고, PHP·Ruby는 `expiresAt` 부재를 미만료로 봅니다). Go·Rust는 error 값을 반환하고, 나머지 일곱은 `Keycloak*` 예외 계층을 던집니다.
- **Admin: 리소스 다섯도, 이제 연산 다섯도 같다.** 아홉 모두 users · clients · realms · roles · groups 에 생성·조회·목록·갱신·삭제를 노출합니다 — **모든 언어가 25/25**이고, 그 밖은 `raw` 탈출구로 갑니다. 남은 차이는 커버리지가 아니라 모양입니다: Rust만 파사드가 평평하고(`admin.update_role(name, rep)`) 나머지는 중첩(`admin.roles().update(…)`)이며, 목록 페이지네이션은 Rust·Go에서 명시적입니다. 정확한 표는 [Admin capability matrix](docs/guides/getting-started.md#admin-capability-matrix)입니다.

---

## 기본이 안전한 설계

아홉 개 SDK 모두 **같은 클레임 검사 규칙**(알고리즘 핀닝, `iss` 정확일치, `aud` 포함검사, `exp` 필수, 클록 스큐 제한)을 탑재합니다 — 하위 라이브러리 기본값이 아닙니다. JWKS 재조회 rate-limit은 아홉 공통이고, **「미해결 kid에만」은 여덟 언어**입니다. .NET은 `Microsoft.IdentityModel`의 `ConfigurationManager`가 서명 실패도 키 회전으로 보아 재조회하므로, rate-limit이 증폭 상한입니다 — [dotnet/README.md](dotnet/README.md).

토큰·시크릿은 로그·직렬화에서 마스킹되고, TLS 검증은 기본 활성입니다. 인증 경로의 파사드 뒤에는 SDK 타입만 둡니다. admin representation과 `raw()`는 문서화된 예외입니다([Admin capability matrix](docs/guides/getting-started.md#admin-capability-matrix)).

---

## 현재 상태

아홉 개 SDK 전부 기능 완료·`main` 병합 상태입니다. 각각 **실제 Keycloak 26.6 서버**로 검증되며(Testcontainers, PHP·Ruby는 docker CLI 셸아웃), 로직 모듈에 라인 ≥ 90% 커버리지 게이트가 걸려 있습니다. 여섯 언어는 브랜치 ≥ 85%도 강제하고, Go·PHP·Rust는 라인만 봅니다. 각 SDK의 보안 핵심은 어드버서리얼 리뷰를 거쳤고, 설정 가능한 JWT 서명 알고리즘과 의존성 CVE 감사는 아홉 전부에 적용됐습니다. OIDC nonce/`id_token` 재생 방지는 **아홉 전부**입니다: `create*`는 항상 nonce를 만들어 인가 URL에 싣고, 호출자가 그 값을 `exchange*`에 넘기면 `id_token`을 서명·`iss`·`aud`·`exp`까지 검증한 뒤 nonce 클레임을 대조합니다. nonce 인자를 생략하면 id_token 검증을 건너뛰는 것은 아홉 공통 패턴이지 Ruby만의 예외가 아닙니다.

전부 **pre-1.0** 입니다. 아홉 전부 정식 릴리스를 공개 레지스트리에 게시했습니다 — 하나하나가 사람 태그 게이트를 거쳤고, 각각 앞서 릴리스 후보를 한 번씩 태웠습니다(그 RC들은 레지스트리에 그대로 남습니다). 설치 명령은 [설치](#설치)에, 각 언어가 실제로 실은 버전과 감싸는 라이브러리는 [호환성 표](docs/guides/getting-started.md#compatibility)에 있습니다. 릴리스 절차는 [DEPLOY.md](DEPLOY.md), 보안 정책과 여기서 pre-1.0이 뜻하는 바는 [SECURITY.md](SECURITY.md)를 보세요.

---

## 문서

- 🚀 **[시작하기](docs/guides/getting-started.md)** — 언어별 설치·실행 가능한 예제·async·호환성 매트릭스
- 🖥️ **[Keycloak 서버 배포](docs/guides/deploying-keycloak-server.md)** — SDK가 붙을 서버(단일 VM + Docker Compose)
- 🔒 **[보안 정책](SECURITY.md)** — 취약점 신고·하드닝 범위·지원 버전
- 🗺️ **[언어 지원 로드맵](docs/roadmap/language-support.md)** — 지금 있는 언어와 앞으로 올 수 있는 언어
- 📦 **[배포](DEPLOY.md)** — 아홉 언어의 사람 승인 게이트 릴리스 절차

기여: [CONTRIBUTING.md](CONTRIBUTING.md) · [개발 환경 설정](docs/guides/development-setup.md)(`node scripts/doctor.mjs`가 이 PC에 빠진 것을 알려줍니다) · [새 언어 추가 플레이북](docs/guides/add-a-language-playbook.md) · [언어 간 테스트 하네스](harness/README.md). 내부 아키텍처·메인테이너 노트는 [CLAUDE.md](CLAUDE.md)에, 설계 스펙·계획서·검증 로그 전체는 [문서 지도](docs/README.md)에 있습니다.

---

**라이선스:** [Apache-2.0](LICENSE)
