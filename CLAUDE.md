# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 프로젝트 개요

Keycloak을 위한 **다국어(polyglot) SDK** — "다국어"는 **여러 프로그래밍 언어**(Java·Python·Node·향후 확장)를 뜻하며 자연어 현지화(i18n)와 무관하다. Keycloak의 두 API 표면 — **인증(OIDC/OAuth2)** 과 **관리 REST API(Admin)** — 을 모두 다룬다. 언어마다 관용적이되 개념·계층·흐름은 **동형(isomorphic)** 이도록 설계한다.

- **기준 언어**: Java 21 · Maven (첫 구현; 초기 Java 17 → 21 LTS 런타임 업그레이드 반영)
- **2번째 언어**: Python 3.10+ · `python-keycloak` 래핑 + `joserfc` 자체 JWT 검증 (`feature/python-sdk`)
- **3번째 언어**: Node.js 20+ · TypeScript(ESM·async-only) · `@keycloak/keycloak-admin-client` + `openid-client` v6 래핑 + `jose` 자체 JWT 검증 (`feature/node-sdk`)
- **라이선스**: Apache-2.0 · **groupId**: `io.github.xzawed` · Python 배포명: `keycloak-sdk` · npm 배포명: `@xzawed/keycloak-sdk`

**핵심 전략**: 언어마다 가장 좋은 기반을 사용한다 — 공식/성숙 클라이언트가 있으면 감싼다(Java는 `keycloak-admin-client`, Python은 `python-keycloak`, Node는 공식 `@keycloak/keycloak-admin-client` + `openid-client`) — 그 위에 **일관된 파사드 + 인증 래퍼**를 언어 공통 설계로 얹는다. JWT 검증은 세 언어 모두 자체 강화 구현(algorithm pinning·iss 정확일치·aud 포함검사·클록 스큐·DoS-안전 JWKS 재조회)이다.

## 현재 상태

**Java MVP 완료 — `main` 병합됨 (PR #1).** WBS Phase 1~7(기반 → core → auth → admin → facade → 통합테스트 → 배포&문서) 전체 구현. 전 모듈 단위테스트 + Testcontainers 기반 통합테스트(실제 Keycloak 26.6.4)까지 GREEN(`mvn -f java/pom.xml clean verify`). Maven Central 배포 프로파일(`-Prelease`)과 태그 드리븐 릴리스 CI는 준비되었으나, 실제 배포는 사람이 `v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**Python SDK 완료 — `main` 병합됨 (PR #2 sync, PR #4 async).** WBS Phase 1~7 전체 구현 + `keycloak_sdk.aio` 비동기 미러(python-keycloak `a_*` 래핑, sync `JwtValidator` 재사용). 단위테스트 224개(sync 135 + async 89) + Testcontainers 통합테스트(실제 Keycloak 26.6.4) 11개(sync 6 + async 5) GREEN(로직 커버리지 100% 강제, `mypy --strict`, `ruff`). 하드닝(품질·CI 통합잡·ruff·DEPLOY.md)은 PR #3으로 병합됨. PyPI Trusted Publisher(OIDC) 릴리스 CI 준비됨, 실제 배포는 사람이 `py-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다.

**Node.js/TypeScript SDK 완료 — `feature/node-sdk`(main PR 예정).** WBS Task 1~12 전체 구현(스캐폴딩 → config → 핵심타입 → token-provider → oidc-metadata → JwtValidator → auth → admin → client+배럴 → 통합테스트 → CI → 문서). ESM 전용·async-only·strict TypeScript. 단위테스트 71개 + Testcontainers 통합테스트(실제 Keycloak 26.6) 5개 = 총 76개 GREEN(로직 모듈 라인 100%/브랜치 94% — 네트워크 경계 `auth.ts`/`admin/**`/`index.ts` omit), `tsc`(strict)·`eslint` 통과. 착수 전 딥리서치로 라이브러리 API 확정, 12태스크 계층별 커밋, 완료 후 4-차원 다중에이전트 어드버서리얼 리뷰(정확성·보안·동형성·테스트)로 7건 확정 결함 수정(HIGH: exchangeCode nonce). npm Trusted Publishing(OIDC + provenance) 릴리스 CI 준비됨, 실제 배포는 사람이 `node-v*` 태그를 push해야 트리거되는 승인 게이트(human-gated, 미실행) 상태다. **남은 로드맵(사람 게이트)**: Maven Central 실배포(`io.github.xzawed` 네임스페이스 검증 + GPG/Portal 토큰) · PyPI 실배포(`keycloak-sdk` Trusted Publisher 설정) · npm 실배포(`@xzawed/keycloak-sdk` Trusted Publisher 설정). 배포 절차는 [DEPLOY.md](DEPLOY.md) 참고.

- 설계 스펙: [docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md](docs/superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) — **구현 전 반드시 정독**
- 구현 계획(WBS): [docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md](docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md)(Java) · [docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md](docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md)(Python) · [docs/superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md](docs/superpowers/plans/2026-07-04-keycloak-node-sdk-wbs.md)(Node)
- 실행 거버넌스: [docs/governance/ai-governance-framework.md](docs/governance/ai-governance-framework.md) (Codex 이중검증·G1~G6 게이트·루프 엔지니어링)
- 검증 로그: [docs/governance/verification-log.md](docs/governance/verification-log.md) — 태스크별 게이트 통과 이력
- 설치·시작: [docs/guides/getting-started.md](docs/guides/getting-started.md) · Keycloak 서버 배포(단일 VM+Compose): [docs/guides/deploying-keycloak-server.md](docs/guides/deploying-keycloak-server.md) · 언어 확장 로드맵: [docs/roadmap/language-support.md](docs/roadmap/language-support.md) · 새 언어 추가 플레이북: [docs/guides/add-a-language-playbook.md](docs/guides/add-a-language-playbook.md)
- **테스트 수(Java)**: 단위테스트 117개(core 34 · auth 34 · admin 43 · keycloak-sdk 6) + 통합테스트(Testcontainers) 6개(SmokeIT 1 · AuthFlowIT 3 · AdminOpsIT 2) = **총 123개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85%) 통과. (surefire/failsafe 실측 기준 — Phase 7의 94는 최종리뷰 Wave A/B 이전 수치)
- **테스트 수(Python, main)**: 단위테스트 224개(sync 135 + `aio` async 89) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 11개(sync 6 + async 5) = **총 235개**, 로직 모듈 커버리지 **100% 강제**(`--cov-fail-under=100`, 경계모듈 omit), `mypy --strict`·`ruff`(보안 S/bandit 포함 확장 룰셋)·`ruff format` 통과.
- **테스트 수(Node, `feature/node-sdk`)**: 단위테스트 71개(config 5 · masking 2 · errors 3 · tokens 6 · oidc-metadata 1 · token-provider 4 · jwt 7 · auth 15 · admin 17 · client 11) + 통합테스트(Testcontainers, 실제 Keycloak 26.6) 5개(E2E) = **총 76개**, 커버리지 게이트(로직 모듈 라인 ≥90%/브랜치 ≥85% — 실측 라인 100%/브랜치 94%, 네트워크 경계 `auth.ts`/`admin/**`/`index.ts` omit) 통과, `tsc`(strict)·`eslint` 통과.

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

## 아키텍처

폴리글랏 모노레포. Java 구현이 `java/`에서, Python 구현이 `python/`에서, Node 구현이 `node/`에서 완료됐다(각각 독립 빌드).

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

**언어 중립 계약(§4)**: Java(손수 래핑)·Python(`python-keycloak` 래핑)·Node(`openid-client`+admin-client 래핑)의 출발점이 다르므로, 언어 중립 API 계약을 진실 원천으로 두고 각 언어가 구현한다. 세 언어 모두 하위 라이브러리 타입을 **주 소비 경로(파사드) 뒤에 숨긴다**(camelCase ↔ snake_case만 다르고 개념·계층·명명은 동형 — 예: `TokenSet`/`ValidatedToken`/`IntrospectionResult`·`Keycloak*Error`·`KeycloakClient.auth/admin`). **예외/exceptions 계층은 항상 경계에서 SDK 타입으로 변환**되어 `keycloak.exceptions.*`·`jakarta.ws.rs.*`·`NetworkError`가 공개 API로 새지 않는다.

**문서화된 은닉성 예외(의도적, 2026-07-03 보안감사 반영)**: 완전 은닉이 아니라 아래 지점은 하위 타입을 노출한다 — 재래핑 비용이 과다하거나 보조 표면이기 때문이다. (a) **Java·Node admin 파사드**는 representation 타입을 데이터 모델로 그대로 노출한다(Java `org.keycloak.representations.idm.*`, Node `@keycloak/keycloak-admin-client/lib/defs/*` — 안정적 Keycloak 타입 재사용, SDK 자체 DTO 재래핑은 범위 밖). Python admin은 plain `dict[str, Any]`로 통과(누출 아님). (b) **저수준 주입/구성 지점** — Java `JwtValidator.forRealm`의 Nimbus `JWSAlgorithm`, Python `JwtValidator.validate`의 joserfc `KeySet`, Node `new JwtValidator(keys, opts)`의 jose `JWTVerifyGetKey`·테스트 주입용 생성자 파라미터는 하위 타입을 받는다. 정상 소비 경로(`KeycloakClient.auth/admin`, `client.auth.validate(...)`)는 이들을 노출하지 않는다.

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
- ⚠️ **(Node) openid-client v6 함수형 API·타임아웃·TLS.** 타임아웃은 `Configuration.timeout`(초, 내장 프로퍼티)로 주입한다. admin-client 타임아웃은 `ConnectionConfig.timeout`(**ms**)로 주입(`requestOptions`는 `Omit<RequestInit,"signal">`이라 signal 주입 불가). TLS는 기본 강제 — `serverUrl`이 `http://`일 때만 `allowInsecureRequests`를 적용한다(로컬/테스트 완화, https는 강제 유지).
- ⚠️ **(Node) PKCE `exchangeCode`는 `nonce`를 반드시 전달해야 한다.** `createAuthorizationRequest`가 nonce를 실으면 Keycloak이 id_token에 담아 돌려주고, openid-client v6는 이를 자동 검증하므로 기대 nonce를 주지 않으면 "unexpected nonce"로 **전면 거부**한다(리뷰 HIGH 결함). 마스킹: `TokenSet`은 access/refresh 토큰을, `KeycloakConfig`는 `clientSecret`을 `toString`/`toJSON`/`util.inspect`에서 마스킹한다(속성 접근·스프레드는 유지). JWKS는 jose `createRemoteJWKSet`의 `cooldownDuration`으로 DoS-안전(kid 미해결 시에만 재조회).

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

## 문서 유지 규칙

작업 완료(머지/main 반영) 후 프로젝트 전체 문서(`CLAUDE.md`, `docs/`, `README.md`)를 최신화·최적화하고 커밋한다. 언어별 빌드/테스트 명령(단일 테스트 실행 포함)을 툴체인 섹션에 유지한다(Java·Python·Node).
