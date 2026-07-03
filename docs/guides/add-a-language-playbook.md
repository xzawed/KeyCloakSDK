# 새 언어 SDK 추가 플레이북 (Add-a-Language Playbook)

> **대상 독자:** Keycloak 폴리글랏 SDK에 **새 언어 구현**을 Java·Python과 동일한 품질로 추가하려는 구현 에이전트·리뷰어·사람 승인자.
> **선행 정독:** [언어 중립 계약 §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md) · [AI 거버넌스 프레임워크](../governance/ai-governance-framework.md) · 워크드 예제인 [Java WBS](../superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md) · [Python WBS](../superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md).

이 SDK의 언어 확장 전략은 **깊이 우선(depth-first)** 이다. 코드 생성기나 저품질 티어는 없다 — **모든 언어를 Java/Python 품질로 손수 구현**한다. 각 언어는 관용적이되(camelCase ↔ snake_case 등 표면만 다름), **개념·계층·흐름은 §4 언어 중립 계약과 동형(isomorphic)** 이어야 한다. 즉 어떤 언어를 열어도 `config → auth → jwt → admin → client`라는 같은 계층, 같은 예외 계급, 같은 보안 불변식, 같은 테스트 시나리오를 발견하게 된다.

**우선순위(권장 순서):** TypeScript/Node → Go → C# → PHP → Rust → Ruby. (Kotlin은 JVM 재사용으로 선택적 — Java 산출물을 그대로 소비 가능하므로 신규 구현이 아니라 상호운용 검증 트랙.)

이 문서는 **복붙 가능한 체크리스트 + 단계별 산출물·게이트**다. 각 단계는 독립적으로 검증 가능한 산출물로 끝나며, 통과 기준(게이트)을 명시한다. 새 언어를 시작할 때 이 6단계를 그대로 밟고, 언어별 WBS 문서를 Java/Python WBS와 같은 형식으로 파생시킨다.

---

## 6단계 절차

### 1단계 — 계약 재확인 & 기반 클라이언트 선정 (딥리서치)

새 언어의 첫 작업은 코드가 아니라 **조사와 결정**이다.

- [ ] **§4 언어 중립 계약 재정독** — 진실 원천은 항상 [설계 스펙 §4](../superpowers/specs/2026-07-02-keycloak-multilang-sdk-design.md)다. 새 언어는 이 계약을 *구현*하는 것이지 새로 설계하는 게 아니다. 명명·계층·예외 계급·값 타입(`TokenSet`/`ValidatedToken`/`IntrospectionResult`)·보안 불변식을 그대로 매핑한다.
- [ ] **기반 라이브러리 딥리서치** — 언어별로 "가장 좋은 기반"을 고른다. 성숙한 공식/준공식 클라이언트가 있으면 **감싸고**(Java=`keycloak-admin-client`, Python=`python-keycloak`), 없으면 표준 HTTP + OIDC 조립을 손수 한다. 결정 기준:
  - Admin REST 커버리지·유지보수 활성도·라이선스 호환(Apache-2.0 소비 가능).
  - OIDC/OAuth2 흐름(Authorization Code + PKCE, Client Credentials, Refresh, Logout, Introspection) 지원 여부.
  - **JWT/JOSE 라이브러리는 별도로 고른다** — 검증은 어느 언어든 자체 강화 구현이므로, 기반 클라이언트의 내장 토큰 디코더에 의존하지 **않는다**(§3단계 참조).
- [ ] **게차(Gotchas) 확인** — admin-client 버전 ≠ 서버 버전, 라이브러리별 안전 기본값 부재, DoS 증폭 경로 등. [CLAUDE.md](../../CLAUDE.md)의 "핵심 게차"를 언어에 대입해 재검토한다.
- [ ] **런타임 하한 고정** — 언어 베이스라인·빌드 도구·패키지 매니저·정적 타입 검사기·린터·포매터를 확정한다. (참고: Java = **JDK 21+** — 산출물은 `--release 21`로 컴파일되며 더 낮은 JDK에서는 `UnsupportedClassVersionError`. Python = **3.10+**.)

**산출물:** 언어별 WBS 문서(Java/Python WBS와 동일 형식) 초안 — 기반 라이브러리·버전 고정·툴체인·베이스라인·Global Constraints를 §4에서 전사한 표.
**게이트:** 사람이 기반 라이브러리 선정과 베이스라인을 승인. WBS 초안이 §4 항목을 빠짐없이 매핑(자체 검토 표).

---

### 2단계 — 계층 구현 (config → auth → jwt → admin → client)

Java `core`/`auth`/`admin`/`keycloak-sdk`, Python `config.py`/`auth.py`/`jwt.py`/`admin/`/`client.py`와 **동형인 계층**을 순서대로 TDD로 쌓는다. 각 하위 태스크는 실패 테스트 → 구현 → 통과 → 커밋.

- [ ] **config** — 불변 설정 객체 + 검증. 필수값(`serverUrl`/`realm`/`clientId`) 누락 시 `KeycloakConfigError` 계열. 시크릿은 언어가 허용하는 최상의 위생(Java `char[]` 방어 복제, 그 외 언어는 불변 문자열 + 마스킹). `toString()`/`repr` 마스킹. 타임아웃·클록 스큐·스코프 기본값 고정.
- [ ] **oidc 엔드포인트** — `{serverUrl}/realms/{realm}` 규약 기반 URL 조립(네트워크 없이). issuer·token·authorization·introspection·end_session·jwks.
- [ ] **auth (OIDC 래핑)** — 기반 클라이언트의 OIDC 표면을 얇게 감싼다. Authorization Code + **PKCE**(S256), Client Credentials, Refresh, Logout, Introspection, 그리고 `TokenSet`으로의 응답 매핑. 네트워크 경계이므로 로직은 매핑 헬퍼에 두고 단위 검증, 실제 호출은 통합 테스트로.
- [ ] **jwt (자체 강화 검증 — 🔴 최우선 정확도 태스크)** — 기반 라이브러리에 의존하지 않고 언어의 JOSE 라이브러리로 직접 구현. 다음 불변식을 **모두** 만족:
  - **알고리즘 핀닝** — 허용 알고리즘(`RS256` 등)을 명시. 토큰 헤더의 `alg`를 신뢰하지 않는다.
  - **`none`/미서명 거부**.
  - **issuer 정확 일치**(`==`).
  - **audience 포함 검사** — `aud`가 문자열이면 동등, 리스트면 포함(다중 aud 수용).
  - **exp/nbf + 클록 스큐**(기본 30s).
  - **JWKS 재조회 DoS-안전** — 서명 위조는 certs 재조회를 유발하지 않고, kid 미해결에만 재조회하며, 재조회 자체를 최소 간격으로 rate-limit. 위조 Bearer마다 IdP를 때리는 미인증 DoS 증폭을 차단.
- [ ] **admin (파사드 + raw())** — 기반 admin 클라이언트를 감싼 리소스 파사드(`users`/`clients`/`realms`/`roles`/`groups`). **`raw()` 탈출구**로 하위 클라이언트를 노출(고급 사용자용). admin 호출에는 **config의 타임아웃을 반드시 주입**한다(미주입 = 무한 대기·스레드 고갈 DoS).
- [ ] **client (통합 진입점)** — `auth`는 **즉시**, `admin`은 **지연** 초기화(공개 클라이언트가 secret 없이 `auth`만 사용 가능). 컨텍스트 매니저/`AutoCloseable`로 `close()`/`aclose()` 제공 — admin뿐 아니라 **auth 세션(HTTP 커넥션 풀)까지** 정리(미정리 = FD/커넥션 누수).

**전 계층 공통 규칙:**
- **하위 타입 은닉** — 기반 라이브러리 타입은 주 소비 경로(파사드) 뒤에 숨긴다. 문서화된 은닉성 예외([CLAUDE.md](../../CLAUDE.md) §아키텍처)만 허용(안정적 representation 타입 재사용, 저수준 주입/구성 지점).
- **예외 경계 변환** — 기반 라이브러리 예외는 **항상 경계에서 SDK 예외로 변환**한다. 예외 계급은 언어 관용을 따른다 — 모두 `Keycloak` 접두 + 언어별 접미로, Java `Keycloak*Exception`(예: `KeycloakNotFoundException`·`KeycloakConflictException`·`KeycloakForbiddenException`·`KeycloakAdminException`·`KeycloakAuthException`·`KeycloakTransportException`), Python `Keycloak*Error`(예: `KeycloakNotFoundError`·`KeycloakConflictError`·`KeycloakForbiddenError`·`KeycloakAdminError`·`KeycloakAuthError`·`KeycloakTransportError`). 하위 예외 타입이 공개 API로 새지 않는다.
- **결합 규칙** — `admin`은 `auth`를 직접 알지 못한다. 접착제는 `TokenProvider` 인터페이스(또는 각자 독립 client-credentials 인증)뿐.

**산출물:** 5개 계층의 구현 + 각 계층 단위 테스트, 계층별 커밋(WBS id 포함).
**게이트:** G1(빌드) + G2(단위 100%) 계층별 통과. 예외/타입 은닉 리뷰 통과(G4/G6).

---

### 3단계 — 보안 불변식 + CI 강제

2단계에서 구현한 보안 속성을 **CI가 회귀를 막도록** 고정한다. 리뷰로만 지키는 속성은 언젠가 깨진다 — 자동 게이트로 못박는다.

- [ ] **마스킹(완전 불투명)** — 토큰/시크릿은 로그·`toString`/`repr`·예외 메시지에 절대 노출 금지. 마스킹은 **접두 노출 없는 완전 불투명 `***`**. 단위 테스트로 강제(원문이 문자열 표현에 포함되지 않음).
- [ ] **TLS 검증 기본 on** — no-op 설정 옵션 금지(저장만 하고 전송에 미연결이면 오해 소지 — 제거). 기본 검증 유지.
- [ ] **JWKS DoS-안전** — 2단계 jwt의 재조회 rate-limit·조건부 재조회를 단위 테스트로 고정(위조 서명이 재조회를 유발하지 않음, kid 미해결만 재조회, 최소 간격 준수).
- [ ] **admin 타임아웃 주입** — config 타임아웃이 실제 HTTP 클라이언트에 전달되는지 검증.
- [ ] **default typing 금지** — 정적 타입 언어는 strict 모드(예: `mypy --strict`, 컴파일 경고 격상). 암묵적 any/느슨한 타입을 CI에서 거부.
- [ ] **린터 보안 룰셋** — 언어의 보안 린트(bandit/`ruff S`, gosec, ESLint security 등)를 CI 필수 잡으로.

**산출물:** 보안 단위 테스트 세트 + CI에 통합된 린터·타입 검사·포맷 검사 잡.
**게이트:** G6(보안) — 토큰/시크릿 로그·내부 타입 누출 0. CI에서 strict 타입·보안 린트·마스킹 테스트가 필수(머지 차단) 잡.

---

### 4단계 — 테스트 패리티 매트릭스

새 언어는 Java(123개)·Python(235개)와 **같은 시나리오**를 검증해야 한다. 개수는 언어별로 다를 수 있으나(테스트 관용구 차이), **커버되는 시나리오 집합은 동형**이어야 한다.

| 층위 | 내용 | 참고(Java / Python) |
|---|---|---|
| **단위** | PKCE 생성, 설정 검증·기본값, 토큰 응답 파싱(`from_response`), 만료·클록 스큐 판정, JWT 강화(alg 핀·none 거부·iss·aud·exp/nbf), **예외 경계 매핑**(404→`KeycloakNotFoundError`/`KeycloakNotFoundException` 등), 마스킹 | Java 117 / Python 224(sync 135 + async 89) |
| **통합(Testcontainers)** | **실제 Keycloak 26.6** 컨테이너 + realm import. client-credentials 토큰 발급, `validate`(다중 aud 수용), introspect, user/client CRUD, `raw()` 탈출구, delete 후 조회 → `KeycloakNotFoundError`/`KeycloakNotFoundException` | Java 6(SmokeIT·AuthFlowIT·AdminOpsIT) / Python 11(sync 6 + async 5) |
| **커버리지 게이트** | 로직 모듈 라인/브랜치 임계값. 네트워크 경계 클래스(`auth`/`admin` 생성)는 통합으로 검증하고 커버리지에서 omit/exclude | Java 라인 ≥90%/브랜치 ≥85% (JaCoCo) · Python 로직 100% 강제(`--cov-fail-under`, 경계 omit) |

- [ ] 단위 테스트로 위 시나리오를 전부 커버(목/스텁으로 네트워크 격리).
- [ ] Testcontainers 하네스 + realm JSON(`<realm>-realm.json`, `--import-realm` 규약) — **Java의 `it-realm-realm.json` 재사용 가능**(confidential client + service account + audience 매퍼).
- [ ] 커버리지 게이트를 빌드에 강제(미달 = 빌드 실패). 경계 클래스 omit 규칙 명시.

**산출물:** 단위 + 통합 테스트 스위트, 커버리지 게이트가 걸린 빌드.
**게이트:** G2(단위 100%) + G3(커버리지 임계값) + 통합 테스트 GREEN(Docker). 시나리오 패리티를 Java/Python 매트릭스와 대조한 표로 리뷰.

---

### 5단계 — CI · 배포(태그 드리븐 human-gated) · 문서

- [ ] **CI 매트릭스** — 지원 런타임 버전 전부(예: Java 21+, Python 3.10~3.13에 준하는 언어별 매트릭스)에서 빌드 + 단위 + 타입 + 린트. 통합 테스트는 Docker 필요라 별도 잡/로컬.
- [ ] **로컬 설치 경로** — 게시 전에도 소비자가 로컬로 쓸 수 있어야 한다. 현재 두 언어 모두 **미게시(human-gated 릴리스)** 상태이므로 로컬 설치만 동작한다:
  - Java: `mvn -f java/pom.xml install -DskipITs=true` → 좌표 `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT`
  - Python: `pip install -e python` (또는 `cd python && python -m build`) → 배포명 `keycloak-sdk`
  - 새 언어도 동일하게 "로컬 설치 → 예제 실행"이 게시 없이 동작하도록 한다.
- [ ] **태그 드리븐 릴리스 (사람 승인 게이트)** — 실제 배포는 사람이 태그를 push할 때만 트리거되는 워크플로로. 기존 사례: [`.github/workflows/release.yml`](../../.github/workflows/release.yml)(Java, `v*` 태그 → Maven Central), [`.github/workflows/python-release.yml`](../../.github/workflows/python-release.yml)(Python, `py-v*` 태그 → PyPI Trusted Publisher/OIDC). 새 언어는 언어별 태그 접두사 + 해당 레지스트리(npm/Go proxy/NuGet/Packagist/crates.io/RubyGems)로 같은 패턴을 따른다. 전체 절차는 [DEPLOY.md](../../DEPLOY.md).
  - ⚠️ **되돌릴 수 없는 배포는 에이전트 자동 실행 금지** — 자격증명은 CI 시크릿/OIDC로만, 태그 push는 사람이.
- [ ] **문서** — getting-started에 새 언어 섹션(설치·QuickStart·언어 간 매핑표·호환 매트릭스), README, 그리고 [CLAUDE.md](../../CLAUDE.md)의 구조 트리·빌드 명령·테스트 수 갱신. 태스크별 게이트 이력은 [검증 로그](../governance/verification-log.md)에 기록.

**산출물:** CI 워크플로 + 릴리스 워크플로(미실행, 준비됨) + 갱신된 문서 + 검증 로그 엔트리.
**게이트:** CI GREEN. 릴리스 워크플로는 준비 상태(사람 게이트, 미실행). 문서가 실제 구현·테스트 수와 일치(불일치 0).

---

### 6단계 — 거버넌스 G1~G6 + Codex 이중검증 + 루프

모든 태스크는 [AI 거버넌스 프레임워크](../governance/ai-governance-framework.md)를 따른다. **직무 분리**: 구현자 ≠ 리뷰어 ≠ 검증자, 검증자는 **다른 모델(Codex/GPT-5)** 로 상관된 맹점을 상쇄한다.

- [ ] **G1~G6 게이트** — 태스크마다 전부 통과해야 완료:
  - **G1 빌드**(컴파일 에러 0) · **G2 단위테스트**(100%) · **G3 커버리지**(임계값) · **G4 스펙 준수**(미해결 Critical/Important 0, 리뷰어 승인) · **G5 Codex 교차검증**(불일치 0, 판정 "confirmed") · **G6 보안**(토큰/시크릿·내부 타입 누출 0).
- [ ] **Codex 이중검증(G5)** — 모든 태스크 diff를 Codex가 독립 검토. 자기 코드 자기 승인 금지.
- [ ] **루프 엔지니어링** — 게이트 미달 시 RCA(Claude+Codex 공동 진단) → 시정(최소 변경) → 재검증(G1~G6) → 재측정. **게이트당 최대 3회**, 초과 시 사람에게 에스컬레이션. 모든 반복은 "이전 지표 → 조치 → 이후 지표 → RCA"로 검증 로그에 기록.
- [ ] **거버넌스 가드레일** — `feature/<lang>-sdk` 브랜치 격리, main은 PR(사람 승인), 배포는 사람 승인, 비밀 취급(마스킹+리뷰), 재현성(의존성 BOM/lockfile 고정, Keycloak 컨테이너 태그 고정, 툴체인 버전 고정).

**산출물:** 게이트 통과 이력이 기록된 검증 로그, Codex "confirmed" 판정, PR.
**게이트:** 전 게이트 GREEN + Codex 포함 전체 브랜치 최종 리뷰 → PR(사람 승인 머지).

---

## 단계 ↔ 게이트 매핑

| 단계 | 핵심 산출물 | 필수 게이트 | 측정 수단 |
|---|---|---|---|
| 1. 계약 재확인 & 클라이언트 선정 | 언어 WBS 초안, 기반 라이브러리 결정 | G4(스펙 매핑) + 사람 승인 | §4 대조 표, 사람 리뷰 |
| 2. 계층 구현 | config/auth/jwt/admin/client + 단위 | G1·G2·G4·G6 | 빌드·단위·타입 은닉/예외 변환 리뷰 |
| 3. 보안 불변식 + CI 강제 | 보안 테스트 + strict/보안 린트 잡 | **G6** | 마스킹·JWKS DoS·타임아웃 테스트, CI 필수 잡 |
| 4. 테스트 패리티 매트릭스 | 단위 + Testcontainers 통합 | G2·G3 + 통합 GREEN | 커버리지 게이트, 시나리오 패리티 표 |
| 5. CI·배포·문서 | CI + 태그 드리븐 릴리스(미실행) + 문서 | CI GREEN + 문서 일치 | 매트릭스 빌드, 로컬 설치 검증, 문서 대조 |
| 6. 거버넌스 | 검증 로그, Codex 판정, PR | **G1~G6 전부** + Codex confirmed | 게이트 측정 + 루프 + 사람 승인 |

---

## 실제 사례 (워크드 예제)

이 플레이북은 다음 두 완성 구현에서 귀납한 것이다. 새 언어 WBS를 쓸 때 **형식·세밀도·자체 검토 표**를 그대로 본뜬다:

- **Java (기준 언어, 손수 래핑):** [docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md](../superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md) — 6개 Maven 모듈, `core`에 `TokenProvider`로 auth/admin 결합, JaCoCo 90/85 게이트, `v*` 태그 → Maven Central. 단위 117 + 통합 6 = **123개**.
- **Python (2번째 언어, `python-keycloak` 래핑):** [docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md](../superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md) — `src/` 레이아웃 단일 패키지 + `aio` async 미러, `joserfc` 자체 JWT 검증, 로직 커버리지 100% 강제, `py-v*` 태그 → PyPI Trusted Publisher. 단위 224 + 통합 11 = **235개**.

두 사례가 증명하는 핵심: **출발점(손수 래핑 vs 성숙 라이브러리 래핑)이 달라도 §4 계약을 진실 원천으로 두면 결과가 동형이 된다.** 새 언어도 그 계약을 구현하는 것이지 다시 설계하는 것이 아니다.
