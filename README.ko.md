# Keycloak SDK

**하나의 API, 아홉 개 언어.** [Keycloak](https://www.keycloak.org/)을 위한 다국어(polyglot) SDK로, **인증(OIDC / OAuth2)** 과 **관리 REST API(Admin)** 를 모두 다룹니다 — 언어마다 관용적이면서도 개념·계층·흐름은 **동형(isomorphic)** 입니다.

[English](README.md) · 한국어

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Languages](https://img.shields.io/badge/languages-9-brightgreen)
![Status](https://img.shields.io/badge/status-pre--release-orange)
![Keycloak](https://img.shields.io/badge/Keycloak-26.6-informational)
![Tests](https://img.shields.io/badge/tests-877%20passing-success)

> 여기서 "다국어/polyglot"은 **프로그래밍 언어**(Java·Python·Node·Go·C#·PHP·Rust·Ruby·Kotlin)를 뜻하며, 자연어 현지화(i18n)와는 무관합니다.

---

## 지원 언어

| 언어 | 설치 *(배포 후)* | 예제 |
|---|---|---|
| **Java** 21+ | Maven `io.github.xzawed:keycloak-sdk` | [QuickStart.java](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) |
| **Python** 3.10+ | `pip install keycloak-sdk` | [quickstart.py](python/examples/quickstart.py) · [async](python/examples/async_quickstart.py) |
| **Node** 20+ (ESM) | `npm i @xzawed/keycloak-sdk` | [quickstart.ts](node/examples/quickstart.ts) |
| **Go** 1.25+ | `go get github.com/xzawed/KeyCloakSDK/go` | [example_test.go](go/example_test.go) |
| **C# / .NET** 8+ | `dotnet add package Xzawed.Keycloak.Sdk` | [getting-started](docs/guides/getting-started.md#c--net) |
| **PHP** 8.3+ | `composer require xzawed/keycloak-sdk` | [quickstart.php](php/examples/quickstart.php) |
| **Rust** 1.88+ | `cargo add keycloak-sdk` | [quickstart.rs](rust/examples/quickstart.rs) |
| **Ruby** 3.2+ | `gem install keycloak-sdk` | [quickstart.rb](ruby/examples/quickstart.rb) |
| **Kotlin** 2.2+ (JVM) | Gradle `io.github.xzawed:keycloak-sdk-kotlin` | [quickstart.kt](kotlin/examples/quickstart.kt) |

> ⚠️ **아직 공개 레지스트리에 배포되지 않았습니다** — 모든 배포는 사람 승인 게이트(human-gated)입니다. 위 명령은 *배포 후* 형태이며, 그 전에는 소스에서 빌드해 사용하세요 — [시작 가이드](docs/guides/getting-started.md) 참고.

---

## 빠른 시작 (30초)

모든 언어가 동일한 3단계 흐름을 따릅니다 — **토큰 발급 → 검증 → Admin API 호출**. Python 예:

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

아홉 개 언어 전부의 동일 흐름과 async 사용법은 **[시작 가이드](docs/guides/getting-started.md)** 에 있습니다.

---

## 기본이 안전한 설계

아홉 개 SDK 모두 **동일하게 강화된 JWT 검증**을 탑재합니다 — 라이브러리의 안전하지 않은 기본값을 그대로 쓰지 않습니다:

- 알고리즘 핀닝(`alg: none`·헤더 지정 알고리즘 거부)
- `iss` 정확일치 · `aud` 포함검사 · `exp` 필수 · 클록 스큐 제한
- DoS-안전 JWKS 재조회(rate-limit, 미해결 kid에만 재조회)

토큰·시크릿은 로그에서 마스킹되고, TLS 검증은 기본 활성이며, 각 SDK는 하위 라이브러리 타입을 일관된 파사드 뒤에 숨깁니다.

---

## 현재 상태

**아홉 개 SDK 전부 완료 · `main` 병합.** 각 언어가 **실제 Keycloak 26.6 통합테스트**와 로직 커버리지 게이트(라인 ≥ 90% / 브랜치 ≥ 85%)를 통과합니다. 남은 것은 공개 레지스트리 실배포뿐이며, 이는 사람 승인 게이트입니다([DEPLOY.md](DEPLOY.md)).

| SDK | 테스트 | 커버리지 | 특이 |
|---|---|---|---|
| Java | 138 | 게이트 90 / 85 | 기준 구현 |
| Python | 247 | 100% 강제 | sync + async(`aio`) |
| Node | 81 | 라인 100 / 브랜치 94 | ESM · async-only |
| Go | 46 | 95% | sync + `context.Context` |
| C# / .NET | 63 | 97 / 93 | async-first |
| PHP | 71 | 100% | `final readonly class` |
| Rust | 41 | 95% | edition 2024 · async |
| Ruby | 84 | 100 / 93 | Faraday 직접 admin |
| Kotlin | 106 | 99 / 86 | 코루틴 · JVM 스택 재사용 |

*통합테스트는 대부분 Testcontainers이며, PHP·Ruby는 Windows에서 docker-CLI 폴백입니다. 각 SDK의 보안 핵심은 어드버서리얼 리뷰로 검증했습니다 — [SECURITY.md](SECURITY.md) 참고. 배포 전 하드닝(OIDC nonce 재생 방지, 설정 가능한 JWT 서명 알고리즘, 의존성 CVE 감사)이 9개 SDK 전부에 적용됐습니다.*

---

## 더 알아보기

- 🚀 **[시작하기](docs/guides/getting-started.md)** — 언어별 설치·빠른 시작·async·호환성 매트릭스
- 🖥️ **[Keycloak 서버 배포](docs/guides/deploying-keycloak-server.md)** — SDK가 붙을 서버(단일 VM + Docker Compose)
- 🗺️ **[언어 지원 로드맵](docs/roadmap/language-support.md)** · 🧩 **[새 언어 추가 플레이북](docs/guides/add-a-language-playbook.md)**
- 🧪 **[테스트 하네스](harness/README.md)** — 실제 Keycloak 대상 언어 간 계약 준수·보안 프로브·스코어링
- 🤝 **[기여 안내](CONTRIBUTING.md)** · 📦 **[배포](DEPLOY.md)** · 🏗️ **[아키텍처·빌드(CLAUDE.md)](CLAUDE.md)**

---

**라이선스:** [Apache-2.0](LICENSE)
