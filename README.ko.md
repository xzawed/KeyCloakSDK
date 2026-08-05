# Keycloak SDK

**[Keycloak](https://www.keycloak.org/)을 다루는 하나의 SDK 모양, 아홉 개 언어로.** 토큰을 발급하고, 안전하게 검증하고, 관리 REST API(Admin)를 호출합니다 — 눈앞의 서비스가 Java든 Python이든 Node·Go·C#·PHP·Rust·Ruby·Kotlin이든 개념·계층·흐름은 동일합니다.

**누구를 위한 것인가:** 여러 언어로 된 서비스 뒤에서 Keycloak을 운영하면서, 스택마다 클라이언트를 새로 익히고 JWT 검증을 매번 다시 결정하고 싶지는 않은 팀.

[English](README.md) · 한국어

![License](https://img.shields.io/badge/license-Apache--2.0-blue)
![Languages](https://img.shields.io/badge/languages-9-brightgreen)
![Status](https://img.shields.io/badge/status-pre--release-orange)
![Keycloak](https://img.shields.io/badge/Keycloak-26.6-informational)

> 여기서 "다국어/polyglot"은 **프로그래밍 언어**를 뜻하며, 자연어 현지화(i18n)와는 무관합니다.
>
> ⚠️ **PHP·Python·.NET·Rust는 첫 릴리스 후보(RC)가 공개 레지스트리에 게시됐고, 나머지 다섯 언어는 아직 레지스트리에 없습니다** — 모든 배포는 사람 승인 게이트입니다. 아래 내용은 지금 당장 클론해서 그대로 돌아갑니다: [지금 바로 써보기](#지금-바로-써보기) 참고.

---

## `python-keycloak` / `gocloak` / 공식 클라이언트를 그냥 쓰면 되지 않나?

실제로 그것들을 계속 씁니다 — 이 SDK는 각 생태계에서 **가장 좋은 클라이언트를 대체하지 않고 감쌉니다**. 그 위에, 그 클라이언트들이 사용자에게 떠넘기는 세 가지를 더합니다:

- **기본값부터 강화된 JWT 검증.** 감싸는 라이브러리들은 느슨한 기본값을 주거나 building block만 줍니다. 여기서는 알고리즘 핀닝·`iss` 정확일치·`aud` 검사·`exp` 필수·클록 스큐 제한·DoS-안전 JWKS 재조회가 아홉 언어 모두에서 기본값입니다 — [자세히](#기본이-안전한-설계).
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

## 지금 바로 써보기

레지스트리 설치는 아직 첫 RC(PHP · Python · .NET · Rust)뿐이지만 — 어느 쪽이든, 클론만 하면 전체 경로가 그대로 동작합니다:

```bash
# 1) 붙을 Keycloak 서버
docker run -p 8080:8080 \
  -e KC_BOOTSTRAP_ADMIN_USERNAME=admin -e KC_BOOTSTRAP_ADMIN_PASSWORD=admin \
  quay.io/keycloak/keycloak:26.6 start-dev

# 2) SDK를 소스에서 설치 — Python 예시이며, 모든 언어에 동등한 절차가 있습니다
git clone https://github.com/xzawed/KeyCloakSDK.git
pip install -e KeyCloakSDK/python
```

그다음 realm에 서비스 계정을 활성화한 confidential 클라이언트를 만드세요 — 예제가 받는 `client_id` / `client_secret`이 바로 그 한 쌍입니다. 언어별 로컬 설치(Maven · Gradle · npm · go · dotnet · composer · cargo · bundler)와 실행 가능한 예제는 [시작 가이드](docs/guides/getting-started.md)에 있습니다.

---

## 지원 언어

| 언어 | 런타임 · 관용 | 패키지 *(레지스트리 게시 여부: [현재 상태](#현재-상태) 참고)* | 예제 |
|---|---|---|---|
| **Java** | JDK 21+ · 블로킹 | `io.github.xzawed:keycloak-sdk` (Maven Central) | [QuickStart.java](java/keycloak-sdk-examples/src/main/java/io/github/xzawed/keycloak/examples/QuickStart.java) |
| **Python** | 3.10+ · sync + async(`aio`) | `keycloak-sdk` (PyPI) | [quickstart.py](python/examples/quickstart.py) · [async](python/examples/async_quickstart.py) |
| **Node** | 22+ · ESM · async-only | `@xzawed/keycloak-sdk` (npm) | [quickstart.ts](node/examples/quickstart.ts) |
| **Go** | 1.25+ · sync + `context.Context` | `github.com/xzawed/KeyCloakSDK/go` | [example_test.go](go/example_test.go) |
| **C# / .NET** | 8+ · async-first | `Xzawed.Keycloak.Sdk` (NuGet) | [getting-started](docs/guides/getting-started.md#c--net) |
| **PHP** | 8.3+ · `final readonly class` | `xzawed/keycloak-sdk` (Packagist) | [quickstart.php](php/examples/quickstart.php) |
| **Rust** | 1.88+ (edition 2024) · async(tokio) | `keycloak-sdk` (crates.io) | [quickstart.rs](rust/examples/quickstart.rs) |
| **Ruby** | 3.2+ · sync-only | `keycloak-sdk` (RubyGems) | [quickstart.rb](ruby/examples/quickstart.rb) |
| **Kotlin** | 2.2+ / JDK 21+ · 코루틴 | `io.github.xzawed:keycloak-sdk-kotlin` (Maven Central) | [quickstart.kt](kotlin/examples/quickstart.kt) |

---

## 무엇이 동일하고, 무엇이 다른가

- **인증·JWT 검증: 아홉 언어 모두 동일.** 동일한 7개 오퍼레이션 — client-credentials 토큰 · 인가 요청(PKCE S256) · 코드 교환 · refresh · introspect · logout · validate — 과 동일한 `TokenSet` / `ValidatedToken` / `IntrospectionResult` 모양, 동일한 검증 규칙입니다. 다른 것은 명명 관례와 오류 관용뿐입니다: Go·Rust는 error 값을 반환하고, 나머지 일곱은 `Keycloak*` 예외 계층을 던집니다.
- **Admin: 커버리지는 같고, 모양은 같지 않다.** 아홉 언어 모두 동일한 5개 리소스 — users · clients · realms · roles · groups — 를 노출하며 각각 생성·조회·삭제가 가능하고 `raw` 탈출구가 있습니다. 그 이상은 감싼 클라이언트를 따라갑니다: **Rust는 평평하고**(`admin.users.create(…)`가 아니라 `admin.create_user(…)`), **Rust·PHP에는 `update()`가 없으며**, PHP는 clients·realms의 생성을 `import()`로 부르고, list/search 지원은 리소스마다 다릅니다. 메서드가 있으리라 가정하기 전에 해당 언어의 예제를 확인하세요.

---

## 기본이 안전한 설계

아홉 개 SDK 모두 **동일한 JWT 검증 규칙**을 탑재합니다 — 하위 라이브러리 기본값이 아닙니다:

- 알고리즘 핀닝(`alg: none`·헤더 지정 알고리즘 거부)
- `iss` 정확일치 · `aud` 포함검사 · `exp` 필수 · 클록 스큐 제한
- DoS-안전 JWKS 재조회(rate-limit, 미해결 kid에만 재조회)

토큰·시크릿은 로그·직렬화에서 마스킹되고, TLS 검증은 기본 활성이며, 각 SDK는 하위 라이브러리 타입을 일관된 파사드 뒤에 두어 사용자 코드로 새지 않게 합니다.

---

## 현재 상태

아홉 개 SDK 전부 기능 완료·`main` 병합 상태입니다. 각각 **실제 Keycloak 26.6 서버**로 검증되며(Testcontainers, PHP·Ruby는 docker CLI 셸아웃), 로직 모듈에 라인 ≥ 90% / 브랜치 ≥ 85% 커버리지 게이트가 걸려 있습니다. 각 SDK의 보안 핵심은 어드버서리얼 리뷰를 거쳤고, 배포 전 하드닝(OIDC nonce 재생 방지, 설정 가능한 JWT 서명 알고리즘, 의존성 CVE 감사)이 아홉 언어 전부에 적용됐습니다.

전부 **pre-1.0(`0.1.0` 라인)** 입니다. 아홉 중 넷은 첫 릴리스 후보(RC)를 공개 레지스트리에 게시했습니다 — Packagist `xzawed/keycloak-sdk` 0.1.0-rc.1 · PyPI `keycloak-sdk` 0.1.0rc1 · NuGet `Xzawed.Keycloak.Sdk` 0.1.0-rc.1 · crates.io `keycloak-sdk` 0.1.0-rc.1 — 나머지 다섯(Java · Node · Go · Ruby · Kotlin)은 미게시이며 사람 태그 게이트 뒤에 있습니다. 절차는 [DEPLOY.md](DEPLOY.md), 보안 정책과 여기서 pre-1.0이 뜻하는 바는 [SECURITY.md](SECURITY.md)를 보세요.

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
