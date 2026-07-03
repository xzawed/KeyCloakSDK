# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Keycloak을 위한 **다국어 SDK**. Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다룬다. 언어마다 관용적이되 개념·계층·흐름은 **동형(isomorphic)** 이도록 설계한다.

- **기준 언어**: Java 17 · Maven (첫 구현)
- **2번째 언어**: Python 3.10+ · `python-keycloak` 래핑 + `joserfc` 자체 JWT 검증 (`feature/python-sdk`)
- **라이선스**: Apache-2.0 · **groupId**: `io.github.xzawed` · Python 배포명: `keycloak-sdk`

**핵심 전략**: 언어마다 가장 좋은 기반을 사용한다 — 공식/성숙 클라이언트가 있으면 감싼다(Java는 `keycloak-admin-client`, Python은 `python-keycloak`) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다. JWT 검증은 두 언어 모두 자체 강화 구현(algorithm pinning·iss 정확일치·aud 포함검사·클록 스큐)이다.

## 현재 상태

**Java MVP 완료 — `main` 병합됨 (PR #1).** WBS Phase 1~7(기반 → core → auth → admin → facade → 통합테스트 → 배포&문서) 전체 구현. 전 모듈 단위테스트 + Testcontainers 기반 통합테스트(실제 Keycloak 26.6.4)까지 GREEN(`mvn -f java/pom.xml clean verify`). Maven Central 배포 프로파일(`-Prelease`)과 태그 드리븐 릴리스 CI는 준비되었으나, 실제 배포는 사람이 `v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**Python SDK 완료 — `main` 병합됨 (PR #2).** WBS Phase 1~7 전체 구현(아래 아키텍처·툴체인 섹션 참고). 단위테스트 124개 + Testcontainers 통합테스트(실제 Keycloak 26.6.4) 6개 GREEN(로직 커버리지 100%, `mypy --strict`). PyPI Trusted Publisher(OIDC) 릴리스 CI 준비됨, 실제 배포는 사람이 `py-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다. **남은 로드맵(사람 게이트)**: Maven Central 실배포(`io.github.xzawed` 네임스페이스 검증 + GPG/Portal 토큰) · PyPI 실배포(`keycloak-sdk` Trusted Publisher 설정).

- 설계 스펙: [docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) — **구현 전 반드시 정독**
- 구현 계획(WBS): [docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md](docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md)(Java) · [docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md](docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md)(Python)
- 실행 거버넌스: [docs/governance/ai-governance-framework.md](docs/governance/ai-governance-framework.md) (Codex 이중검증·G1~G6 게이트·루프 엔지니어링)
- 검증 로그: [docs/governance/verification-log.md](docs/governance/verification-log.md) — 태스크별 게이트 통과 이력
- **테스트 수(Java)**: 단위테스트 94개(core 23 · auth 25 · admin 43 · keycloak-sdk 3) + 통합테스트(Testcontainers) 6개(SmokeIT 1 · AuthFlowIT 3 · AdminOpsIT 2) = **총 100개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%) 통과.
- **테스트 수(Python)**: `main`(PR #2, sync만) 단위테스트 120개 + 통합테스트 6개 = 126개. `feature/python-async` 브랜치(미병합)에서 `keycloak_sdk.aio` async 미러 추가 — 단위테스트 216개(sync 120 + async 96) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 11개(sync 6 + async 5) = **총 227개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%) 통과.

### Java 툴체인 (빌드 명령)

하네스 셸은 프로파일을 소싱하지 않으므로 mvn 명령마다 환경을 인라인 지정한다:
```bash
JAVA_HOME='/c/Program Files/Microsoft/jdk-17.0.19.10-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml <goal>
```
- 전체 빌드+검증: `mvn -f java/pom.xml verify` (커버리지 게이트 90/85 포함)
- 단위테스트만: `mvn -f java/pom.xml test -DskipITs=true`
- 단일 테스트: `mvn -f java/pom.xml test -pl <module> -Dtest=<ClassName>#<method>`
- 통합테스트(Docker 필요): `mvn -f java/pom.xml verify`
- examples 모듈만 컴파일: `mvn -f java/pom.xml -pl keycloak-sdk-examples -am compile`
- 배포(release) 산출물 로컬 검증(서명·배포 없이): `mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package` — core/auth/admin/keycloak-sdk 각각 `*-sources.jar`/`*-javadoc.jar` 생성 확인
- 실제 `deploy`(Maven Central 배포)는 로컬에서 실행하지 않는다 — `v*` 태그 push 시 `.github/workflows/release.yml`에서만 시크릿과 함께 실행(사람 승인 게이트)
- JDK 17.0.19 · Maven 3.9.9 (머신 전용 경로 — 리포지토리에 커밋 안 함, CI는 setup-java 사용)

### Python 툴체인 (빌드 명령)

가상환경은 `python/.venv`에 있다(리포지토리에 커밋 안 함). 명령은 `python/`에서 실행하거나 절대경로의 venv 인터프리터를 직접 호출한다:
```bash
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m pytest -m "not integration"   # 단위테스트(main 120개 · feature/python-async 216개)
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m pytest -m integration            # 통합테스트(Docker 필요, testcontainers)
cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m mypy src                          # 정적 타입 검사(strict)
```
- 로컬 배포 빌드 검증(업로드 없이): `cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m build` → `dist/keycloak_sdk-0.1.0-py3-none-any.whl` + `.tar.gz` 생성 확인
- 실제 PyPI 배포는 로컬에서 실행하지 않는다 — `py-v*` 태그 push 시 `.github/workflows/python-release.yml`에서 PyPI Trusted Publisher(OIDC, 저장 시크릿 없음)로 실행(사람 승인 게이트)
- 패키지 `keycloak_sdk`(배포명 `keycloak-sdk`)는 PEP 561 `py.typed` 마커를 포함 — 소비자 측 mypy도 타입 검사 가능

## 아키텍처

폴리글랏 모노레포. Java MVP 구현이 `java/`에서, Python SDK 구현이 `python/`에서 완료됐다(각각 독립 빌드).

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

**언어 중립 계약(§4)**: Java(손수 래핑)와 Python(`python-keycloak` 래핑)의 출발점이 다르므로, 언어 중립 API 계약을 진실 원천으로 두고 각 언어가 구현한다. 두 언어 모두 하위 라이브러리 타입을 **파사드 뒤에 숨기고** 공개 API로 노출하지 않는다(camelCase ↔ snake_case만 다르고 개념·계층·명명은 동형).

## 핵심 게차 (Gotchas) — 2026-07-02 검증

- ⚠️ **admin-client 버전 ≠ 서버 버전.** Keycloak 서버는 26.6.4지만 `keycloak-admin-client`는 독립 트랙 **26.0.10**이다("26.6.x admin-client"는 존재하지 않음). 하나의 클라이언트가 여러 서버 버전을 지원한다. `representation` 필드가 서버와 완전히 일치하지 않을 수 있으니 의존 필드는 실제 서버로 검증한다.
- ⚠️ **Maven Central은 Central Portal 경로만.** 구 OSSRH는 2025-06-30 종료. `central-publishing-maven-plugin:0.11.0` 사용(공식 문서 예제의 0.9.0은 낡음).
- ⚠️ **Testcontainers 2.0 모듈명 변경.** JUnit5 확장 모듈은 `org.testcontainers:testcontainers-junit-jupiter`(구 `junit-jupiter` 아님). `testcontainers-keycloak:4.2.1`은 KC 26.6 기본.
- ⚠️ **JWT 검증 강화 필수(CVE-2026-11800).** 알고리즘 핀닝(`none` 거부·헤더 신뢰 금지), iss/aud 검증, 클록 스큐 제한. Nimbus는 building block만 제공하고 안전한 기본값은 주지 않는다.
- ⚠️ **보안**: 토큰/시크릿 로깅 금지·마스킹, TLS 검증 기본 on, 기본 인메모리 토큰 저장 + 교체 가능한 `TokenStore` SPI.
- ⚠️ **어떤 Java OIDC 라이브러리도 자체 "certified" 아님.** 완성 제품을 필요 시 OIDF에 인증한다.
- ⚠️ **Java 17 javadoc은 doclint 기본 엄격.** `release` 프로파일의 `maven-javadoc-plugin`에 `<doclint>none</doclint>` + `<failOnError>false</failOnError>`를 주지 않으면 문서 경고로 `-javadoc.jar` 생성이 실패할 수 있다.

## 확정 의존성 (BOM으로 고정)

| 의존성 | 좌표 | 버전 |
|---|---|---|
| Keycloak admin-client | `org.keycloak:keycloak-admin-client` | 26.0.10 |
| OAuth2/OIDC SDK | `com.nimbusds:oauth2-oidc-sdk` | 11.37.2 |
| JOSE/JWT | `com.nimbusds:nimbus-jose-jwt` | 10.9.1 |
| 통합 테스트 | `com.github.dasniko:testcontainers-keycloak` | 4.2.1 |
| Testcontainers | `org.testcontainers:testcontainers` (+ `-junit-jupiter`) | 2.0.5 |
| 단위 테스트 | JUnit 6.1.1 · Mockito 5.23.0 | — |

## 문서 유지 규칙

작업 완료(머지/main 반영) 후 프로젝트 전체 문서(`CLAUDE.md`, `docs/`, `README.md`)를 최신화·최적화하고 커밋한다. 특히 `java/` 모듈이 생성되면 빌드/테스트 명령(단일 테스트 실행 포함)을 이 문서에 추가한다.
