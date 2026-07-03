# 언어 지원 로드맵 (Language Support Roadmap)

이 문서는 Keycloak 폴리글랏 SDK의 **언어 확장 전략과 우선순위**를 정의한다. 현재 지원 언어는 **Java**와 **Python** 두 가지이며, 두 언어 모두 설계·구현·단위·통합·CI가 완료되고 실배포만 사람 게이트로 남아 있다. 이 로드맵은 (1) 언어 확장의 원칙, (2) 기존 두 SDK를 실제로 배포하기 위한 사전 단계(step-0), (3) 다음 확장 언어의 우선순위와 후보 클라이언트, (4) 언어별 현황 매트릭스를 정리한다.

"다국어(polyglot)"는 **여러 프로그래밍 언어**를 뜻하며 자연어 현지화(i18n)와 무관하다.

## 전략

- **깊이 우선(depth-first).** 언어를 넓게 벌리기보다, 착수한 언어를 **Java/Python과 동일한 품질**까지 완성한 뒤 다음 언어로 넘어간다. 코드 생성(codegen)으로 찍어낸 저품질 티어를 만들지 않는다 — 모든 언어는 손수 설계·검증한다(단위+통합 테스트, CI, 하드닝된 JWT 검증 포함).
- **동형(isomorphic) 설계.** 언어마다 관용적이되 개념·계층·흐름은 동형이다. 언어 중립 API 계약을 **진실 원천**으로 두고 각 언어가 구현한다 — [설계 스펙 §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) 참조. camelCase ↔ snake_case 같은 관용 차이만 허용하고 개념·명명·계층은 일치시킨다.
- **최선의 기반을 감싼다 + JWT는 자체 강화.** 언어마다 가장 성숙한 인증(OIDC/OAuth2)·관리(Admin REST) 클라이언트를 파사드 뒤에 감싸되, **JWT 검증만은 어느 언어에서도 라이브러리 기본값을 신뢰하지 않고** 자체 강화 계층을 얹는다: 알고리즘 핀닝, `none`/미서명 거부, `iss` 정확일치, `aud` 포함검사, 클록 스큐 제한, DoS-안전 JWKS 재조회(CVE-2026-11800 계열 대응).
- **결합 규칙 유지.** `admin`은 `auth`를 직접 알지 못하고, 둘은 공유 `TokenProvider`(언어별 인터페이스/trait)로만 이어진다 — 하위 라이브러리 교체가 소비자에게 파급되지 않게 한다.
- **예외 경계 변환.** 하위 라이브러리의 예외/에러 타입은 항상 파사드 경계에서 SDK 예외 타입으로 변환되어 공개 API로 새지 않는다(문서화된 은닉성 예외는 설계 스펙 §4 참조).

## step-0 — 기존 SDK 실배포 (사람 게이트)

새 언어로 확장하기 전, **이미 완성된 Java·Python SDK를 실제로 배포**하는 것이 최우선 로드맵 항목이다. 두 SDK는 현재 `0.1.0-SNAPSHOT`(미배포)이며, 배포는 되돌릴 수 없으므로(같은 좌표/버전 재배포 불가) 반드시 dry-run으로 산출물을 먼저 검증한다. 전체 절차는 [DEPLOY.md](../../DEPLOY.md)를 따른다.

> **로컬 설치(미배포 상태)**: 두 SDK 모두 아직 퍼블릭 레지스트리에 없으므로 `pip install keycloak-sdk`/Maven Central 좌표 해석은 **아직 동작하지 않는다**. 로컬 검증은 다음으로 한다 — Java: `mvn -f java/pom.xml install -DskipITs=true`(Docker 불필요 · → 좌표 `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT`), Python: `pip install -e python`(또는 `cd python && python -m build`, 배포명 `keycloak-sdk`).

### Java → Maven Central (`v*` 태그 → `.github/workflows/release.yml`)

- [ ] **네임스페이스 검증(1회)**: [central.sonatype.com](https://central.sonatype.com)에 GitHub 계정(`xzawed`)으로 로그인 → `io.github.xzawed` 네임스페이스 검증/프로비저닝.
- [ ] **Central Portal 토큰 발급(1회)**: Account → Generate User Token → username/password 확보.
- [ ] **GPG 서명키(1회)**: `gpg --gen-key` 생성 → 키서버에 공개키 배포(`--send-keys`) → 개인키 armored 내보내기(`private.asc`).
- [ ] **GitHub Secrets 4종 등록**: `MAVEN_GPG_PRIVATE_KEY`, `MAVEN_GPG_PASSPHRASE`, `CENTRAL_TOKEN_USER`, `CENTRAL_TOKEN_PW`. (미설정 시 워크플로는 deploy 스텝에서 인증 실패로 종료.)
- [ ] **로컬 사전 검증(서명·배포 없이)**:
  ```bash
  mvn -f java/pom.xml -Prelease -DskipTests -Dgpg.skip=true package
  # → core/auth/admin/keycloak-sdk 각 target/에 *-sources.jar / *-javadoc.jar 생성 확인
  ```
- [ ] **배포 트리거**: `git tag v0.1.0 && git push origin v0.1.0` → `release.yml`이 **태그값으로 버전 set(`-SNAPSHOT` 제거)** 후 `-Prelease deploy` 실행 → Central Portal Deployments에서 Publish. (main POM은 계속 `-SNAPSHOT`; **태그가 릴리스 버전을 결정** — Central은 SNAPSHOT을 거부하므로 이 자동 치환이 필수.)

### Python → PyPI (`py-v*` 태그 → `.github/workflows/python-release.yml`)

- [ ] **Trusted Publisher 설정(1회, 시크릿 불필요)**: [pypi.org Publishing](https://pypi.org/manage/account/publishing/)에서 **Pending Publisher로 반드시 미리 등록**(`keycloak-sdk`가 아직 PyPI에 없으므로 계정 레벨 "Add a pending publisher") — Owner `xzawed` · Repo `KeyCloakSDK` · Workflow `python-release.yml` · Environment 비움. OIDC 인증이라 저장 토큰이 없다.
- [ ] **로컬 사전 검증(업로드 없이)**:
  ```bash
  cd python && python -m build
  # → dist/keycloak_sdk-0.1.0-py3-none-any.whl + .tar.gz 생성 확인
  ```
- [ ] **배포 트리거**: `git tag py-v0.1.0 && git push origin py-v0.1.0` → `python-release.yml`이 verify(ruff·mypy·pytest) 통과 후 build + publish 실행.

> ⚠️ 버전을 올릴 때는 Java `java/pom.xml`(및 모듈) `<version>`, Python `python/pyproject.toml` `[project].version`을 함께 올리고 태그(`v*`/`py-v*`)를 그에 맞춘다. SemVer는 SDK 자체 API 기준이며 Keycloak/의존 라이브러리 버전과 분리한다.

## 확장 우선순위

**선정 기준**: 생태계 수요 × 성숙한 클라이언트 가용성(활발히 유지되고 라이선스가 Apache-2.0 호환). 아래 각 언어의 auth·admin 클라이언트는 **확정이 아니라 후보이며, 착수 시 딥리서치로 유지보수·인증(OIDF 등)·라이선스를 재검증해 확정한다**([설계 스펙 §6.3·§10](../superpowers/specs/2026-07-03-keycloak-docs-and-language-expansion-design.md)). 모든 경우 JWT 검증은 자체 강화 계층으로 얹는다(라이브러리 기본값 미신뢰).

> ⚠️ **후보 · 시점 스냅샷 주의.** 아래 표의 버전 핀(예: `openid-client` v6, `gocloak` v14, `fschmtt` 0.42.x), MSRV 수치, 툴체인/서버 대상 버전, 아카이브 날짜, OIDF 인증 여부, 유지보수 상태, CVE 언급은 **모두 이 문서 작성 시점의 예시(illustrative-as-of-drafting)**이며 저장소에서 검증되지 않는다. 각 언어 사이클 착수 시점에 딥리서치로 **반드시 재검증**한 뒤 확정한다 — 그 사이 최신 버전/유지보수/인증 상태가 바뀔 수 있다. 이 표는 방향성(어떤 계열의 클라이언트를 후보로 두는지)만 고정하고, 하드 넘버는 확정 사실로 인용하지 않는다.

| 순위 | 언어 | auth 클라이언트 후보 (감쌈) | admin 클라이언트 후보 (감쌈) | 유지보수 / 라이선스 · 주의점 (착수 시 재검증) |
|---|---|---|---|---|
| 1 | **TypeScript / Node.js** | `openid-client`(panva) 함수형 API + `jose`로 강화 검증 계층 | `@keycloak/keycloak-admin-client`(공식) | 작성 시점 활발 · MIT/Apache-2.0 호환. `openid-client`는 OIDF 인증 RP 계열(Basic·FAPI). ⚠️ **`keycloak-connect`(구 공식 Node 어댑터)는 deprecated** — 사용 금지(`nest-keycloak-connect`가 전이 의존). 최신 메이저는 함수형 API·ESM·Node 20+·WebCrypto/Fetch 요구 — 메이저 핀. admin-client는 서버 버전을 npm 트랙으로 추종(과거 postinstall/패키징 이슈 보고 사례) — 착수 시 버전 핀 + CI `npm install` 확인. `keycloak-js`/`oidc-client-ts`는 브라우저/SPA용이라 서버 파사드에 부적합. |
| 2 | **Go** | `coreos/go-oidc/v3` + `golang.org/x/oauth2`(인증 하드 요구 시 `zitadel/oidc/v3`) + go-jose 자체 강화 | `Nerzal/gocloak` | 작성 시점 보통~활발 · Apache-2.0 호환 계열(Apache-2.0 / BSD-3 / dual). ⚠️ `go-oidc`는 OIDF 미인증·릴리스 저빈도(감싸서 자체 검증 얹기 좋음); 인증이 하드 요구면 활발한 `zitadel/oidc` 선택. `gocloak`은 생성 struct DTO·`gocloak.APIError`를 노출 — 파사드 뒤로 숨기고 경계에서 예외 변환. representation 필드·툴체인/서버 대상 버전은 실서버로 검증. 정체된 포크는 회피. |
| 3 | **C# / .NET** | `Duende.IdentityModel`(+native는 `Duende.IdentityModel.OidcClient`) + `Microsoft.IdentityModel.JsonWebTokens`로 강화 | `Keycloak.AuthServices.Sdk`(NikiforovAll) | 작성 시점 활발 · Apache-2.0 / MIT. `OidcClient`는 OIDF 인증 RP 계열(native, RFC 8252). ⚠️ 구 `IdentityModel*` 리포는 아카이브 방향 → **`Duende.*` 패키지 ID로 타깃**(클라이언트 라이브러리는 무료 Apache-2.0, 상용 IdentityServer와 별개). 서버측 토큰/introspection 헬퍼는 base `Duende.IdentityModel`에 있음. 공식 Keycloak .NET SDK 없음 — `Keycloak.AuthServices`는 활발하나 단일 유지자(키맨 리스크), 테스트된 서버 버전에 핀. `Keycloak.Net`은 뒤처진 포크로 비권장. |
| 4 | **PHP** | `jumbojett/openid-connect-php` (ID 토큰 검증은 자체 강화기로 대체) · 순수 OAuth2 폴백: `league/oauth2-client` + `stevenmaguire/oauth2-keycloak` | `fschmtt/keycloak-rest-api-client-php` | 작성 시점 활발 · Apache-2.0 / MIT. ⚠️ `jumbojett`의 역사적 약점은 JWT/ID 토큰 검증(과거 CVE 이력) — **자체 강화기 오버라이드 필수**, OIDF 미인증. admin은 반드시 `fschmtt` 사용(`stevenmaguire`는 auth 전용, Admin REST 없음). `fschmtt`는 pre-1.0 계열 — 파괴적 변경 가능, 버전 핀 + 파사드 경계 변환 유지. representation 필드는 실서버 검증. `jumbojett` 정체 대비 벤더링/폴백(league 경로) 확보. |
| 5 | **Rust** | `openidconnect`(ramosbugs) RP 플로우 + jsonwebtoken/josekit 자체 강화 계층 | `keycloak` crate(kilork) | 작성 시점 활발 · MIT / dual MIT·Unlicense(모두 Apache-2.0 호환). OIDF 미인증(완성 제품을 필요 시 OIDF 인증 — Java와 동일 정책). ⚠️ `openidconnect`는 단일 유지자·릴리스 저빈도 — 버전 핀 + 강화 JWT 계층 독립 유지. `keycloak` crate는 자동생성 representation struct 노출 — Java admin-client와 동일한 문서화된 은닉성 예외(파사드 뒤로 숨기되 데이터 모델로 통과, `keycloak::KeycloakError`는 경계에서 변환). MSRV·Admin REST 대상 버전은 착수 시 확인해 워크스페이스 MSRV를 높은 쪽으로 맞춘다. auth와 admin은 공유 `TokenProvider` trait로 분리. |
| 6 | **Ruby** | `openid_connect` gem(nov, 인증 RP 코어) + 자체 강화 JWT 계층 | `keycloak-admin`(looorent) | 작성 시점 활발 · 모두 MIT(Apache-2.0 호환). `openid_connect`는 OIDF 인증 RP 레퍼런스의 기반. ⚠️ OmniAuth 전략(`omniauth_openid_connect`)보다 **raw `openid_connect` gem을 코어로 감싼다** — 후자는 Rack 미들웨어(Rails 지향)·저속 릴리스, 전자는 discovery/JWKS/token 프리미티브 제공. Rails 소비자용으로 `omniauth_openid_connect` 어댑터는 선택 제공. `keycloak-admin`은 gem 버전만 배포(representation 필드는 서버 변화 추종, 최근 KC의 writable 프로필 속성 전달 요구 등) — 핀 + 실서버 검증. |

> **Kotlin(선택)**: 신규 클라이언트 없이 **JVM(Java) SDK 재사용**으로 관용적 Kotlin 표면을 얹을 수 있어, 별도 순위가 아닌 저비용 옵션으로 둔다.

## 현황 매트릭스

| 언어 | 설계 | 구현 | 단위 | 통합 | CI | 배포 |
|---|---|---|---|---|---|---|
| **Java** | ✅ | ✅ | ✅ (117) | ✅ (6, Testcontainers) | ✅ | 🔒 사람 게이트 (총 123) |
| **Python** | ✅ | ✅ (+ `aio` async 미러) | ✅ (224) | ✅ (11, Testcontainers) | ✅ | 🔒 사람 게이트 (총 235) |
| **TypeScript / Node.js** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |
| **Go** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |
| **C# / .NET** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |
| **PHP** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |
| **Rust** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |
| **Ruby** | 계획 | 계획 | 계획 | 계획 | 계획 | 계획 |

**범례**: ✅ 완료 · 🔒 준비됨·사람 게이트(태그 push 대기) · 계획 미착수. Java 총 123개(단위 117 + 통합 6), Python 총 235개(단위 224 + 통합 11)는 실측 기준이며 두 언어 모두 실제 Keycloak 26.6.4에 대한 Testcontainers 통합테스트를 포함한다. 신규 언어는 착수 시 동일한 6개 열을 모두 채운 뒤에만 "완료"로 간주한다(depth-first).
