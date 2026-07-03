# 검증 로그 (Verification Log)

[AI 거버넌스 프레임워크](ai-governance-framework.md)에 따른 태스크별 정량 검증 기록. WBS → 커밋 → 검증기록 추적용. 최신 항목이 위로 온다.

**게이트 범례**: G1 빌드 · G2 단위테스트(통과율) · G3 커버리지(라인/브랜치, 목표 90/85) · G4 스펙리뷰 · G5 Codex 교차검증 · G6 보안

| 판정 기호 | 의미 |
|---|---|
| ✅ | 통과 |
| 🔁 | 루프 후 통과 (반복 횟수 기재) |
| ⛔ | 미달·에스컬레이션 |
| — | 해당 없음 |

---

## Phase 0 — 기반 준비

### 0.1 툴체인 설치·검증
- **결과**: ✅ Microsoft OpenJDK 17.0.19 + Apache Maven 3.9.9 설치·검증 (`mvn -v` 확인).
- **비고**: 하네스 셸이 프로파일을 소싱하지 않아, 표준 빌드 프리픽스(인라인 JAVA_HOME/PATH)를 채택. 프레임워크 §6 참조.

### 0.5 Codex 사전 계획검증 (pre-flight)
- **결과**: ✅ Codex(GPT-5) 독립 검토 완료 — Critical 3, Important 5, Minor 2 발견, 전부 반영.
- **Critical**: ① admin 토큰 주입 방식(`authorization(String)`은 자동갱신 불가) → **사람 재정**: 기본=네이티브 client-credentials 그랜트 + 고급=TokenProvider 필터(둘 다 제공). ② 툴체인 프리픽스 PowerShell 변형 추가. ③ `git commit -am` → `git add -A` 규약.
- **Important**: 4.1 테스트 목 주입(withKeycloak 팩토리), 3.4 `HttpClient` 제거(Nimbus HTTPRequest 타임아웃), 3.6 JWKS API 정밀화(nimbus 10.9.1), JaCoCo 모듈별 skip 명시, enforcer(의존성 수렴) 추가.
- **Minor**: SDK `AuthorizationRequest`→`AuthorizationUrlRequest`(Nimbus 충돌), 7.4 push→feature 브랜치+PR.
- **Codex 확인(정상)**: Nimbus 기본 API(AuthenticationRequest.Builder, CodeChallenge.compute, TokenRequest, TokenResponse.parse, ClientSecretBasic, BearerAccessToken.getLifetime), testcontainers-junit-jupiter:2.0.5 좌표.
- **판정**: 계획 보정 완료 → Task 1.1 실행 승인.

## Phase 1 — 기반 (Foundation)

### 1.1 부모 POM & 멀티모듈 reactor
- **커밋**: 969dc47..aab4a49
- **G1 빌드**: ✅ (`mvn validate` SUCCESS, 6 모듈) / **G2 테스트**: — (코드 없음) / **G3 커버리지**: — (코드 없음)
- **G4 스펙리뷰**: ✅ (diff가 브리프와 일치, 좌표·버전 정확, bom stub) / **G5 Codex**: ✅ CONFIRMED / **G6 보안**: ✅
- **루프**: 없음 (enforcer 수렴 1회 통과) / **모델**: 구현=sonnet, G5=Codex(GPT-5)

### 1.2 BOM 모듈 · 1.3 CI 골격
- **커밋**: df25381..a25cdeb (1.2 dece405, 1.3 a25cdeb)
- **G1 빌드**: ✅ (`mvn install -DskipITs` SUCCESS, 6/6 모듈, enforcer 수렴 통과) / **G2/G3**: — (코드 없음)
- **G4 스펙리뷰**: ✅ (BOM 좌표·CI 매트릭스 정확) / **G5 Codex**: ✅ CONFIRMED / **G6 보안**: ✅
- **루프**: 없음 / **모델**: 구현=sonnet, G5=Codex(GPT-5)
- **비고**: PyYAML이 `on:`을 boolean 키로 강제하는 건 YAML1.1 관례상 표시일 뿐, GitHub Actions 파서는 정상 처리(문제 아님).

**✅ Phase 1 (기반) 완료.**

## Phase 2 — core 모듈

### 2.1~2.5 (예외·Config·TokenSet·SPI·마스킹)
- **커밋**: 4da4ec6..bdd1f9b (2.1 9425934, 2.2 800f1e1, 2.3 8e55933, 2.4 7a7f420, 2.5 0209856, 커버리지보강 bdd1f9b)
- **G1 빌드**: ✅ / **G2 테스트**: ✅ (23/23) / **G3 커버리지**: ✅ **라인 100% / 브랜치 90.9%** (≥90/85)
- **G4 스펙리뷰**: ✅ 준수 / **품질**: Approved (Critical/Important 0) / **G5 Codex**: ✅ CONFIRMED / **G6 보안**: ✅ (toString 마스킹 검증)
- **루프**: 없음 / **모델**: 구현=sonnet, 리뷰=sonnet, G5=Codex(GPT-5)
- **Minor(최종리뷰 트리아지 대상)**: ① Builder `isBlank()` 분기 미테스트(Builder 분기 66%, 모듈 aggregate는 게이트 통과) ② getClientSecret() 반환배열 변이 미검증 ③ TokenSet equals/hashCode 부재 → InMemoryTokenStoreTest는 참조동일성으로 통과(취약) ④ 짧은 시크릿 약한 마스킹(스펙대로) ⑤ Javadoc 부재·조밀한 스타일.

**✅ Phase 2 (core) 완료.**

## Phase 3 — auth 모듈

### 3a (3.1~3.5: 메타데이터·PKCE·AuthCode·ClientCred·Refresh/Logout)
- **커밋**: 130518e..d40ea63 (6db7bf3,cb4ce57,2079c59,6c66c8a,623adac + Important fix d40ea63)
- **G1**: ✅ / **G2**: ✅ (10/10) / **G4**: ✅ Approved / **G5 Codex**: ✅ CONFIRMED / **G6**: ✅
- **Nimbus**: 전이 nimbus-jose-jwt 10.9→10.9.1 exclusion(enforcer 수렴); logout은 Nimbus LogoutRequest(프론트채널)이 Keycloak과 안 맞아 백채널 POST 수동구성(3자 검증). AuthClient는 G3에서 제외(Phase6 통합).
- **루프**: 🔁 1회 (Important: 수동 logout 와이어포맷 단위테스트 부재 → buildLogoutRequest 추출 + 4개 테스트, d40ea63, Codex 재확인 CONFIRMED)

### 3b (3.6~3.8: JWT검증·Introspection·TokenProvider) — 보안 핵심
- **커밋**: d40ea63..8a08a42 (77f71e1,4b139f4,665bc40 + 보안fix 15fcaec + 테스트강화 8a08a42)
- **G1**: ✅ / **G2**: ✅ (23/23) / **G3**: ✅ 라인 ~97% / 브랜치 90% (AuthClient 제외 기준) / **G4**: ✅ Approved / **G5 Codex**: ✅ CONFIRMED / **G6**: ✅
- **JOSE**: nimbus-jose-jwt 10.9.1 API가 plan과 정확히 일치(편차 0), 바이트코드 검증.
- **루프**: 🔁 2회 (보안 게이트) —
  - **반복1**: Codex가 `alg=none`/PlainJWT 우회 가능성 지적(Critical), Claude 리뷰어는 바이트코드로 "Nimbus가 기본 거부" 확인. **컨트롤러 경험적 재정**: 유효 iss/aud/exp plain JWT로 테스트 → **거부됨 확인**(코드 안전). 그래도 명시적 `SignedJWT` 강제(심층방어) + 비-vacuous 테스트 추가(15fcaec).
  - **반복2**: Codex가 HS256 회귀테스트 약함 지적(랜덤 시크릿) → **RSA 공개키를 HMAC 시크릿으로 쓴 고전 알고리즘 혼동 공격** 시뮬레이션으로 강화, **거부됨 증명**(8a08a42, Codex CONFIRMED).
- **Minor(최종리뷰)**: AuthClient.validate() 배선(Set.of(RS256)·audience=clientId) 단위 미테스트 → Phase6 6.2 통합에서 커버; 광범위 catch(plan 지시).
- **모델**: 구현=sonnet, 리뷰=sonnet, G5=Codex(GPT-5)

**✅ Phase 3 (auth) 완료. 보안 게이트 루프 2회 수렴.**

## Phase 4 — admin 모듈

### 4a (4.1 AdminClient · 4.2 AdminExceptions)
- **커밋**: 11f82b9..e44a23e (4.1 bfad857, 4.2 9f471b9 + fix e44a23e)
- **G1**: ✅ / **G2**: ✅ (12/12) / **G3**: ✅ AdminExceptions 100% 라인/100% 브랜치 (AdminClient 제외) / **G4**: ✅(수정후) / **G5 Codex**: ✅ CONFIRMED(수정후) / **G6**: ✅
- **의존성**: keycloak-admin-client 26.0.10 도입 → enforcer 수렴 위해 부모 POM에 10개 핀(8개는 keycloak-client-parent:26.0.10과 정확히 일치, 2개[commons-io·jakarta.activation]는 상위버전 선택·주석표기). 모두 업그레이드(다운그레이드 0).
- **루프**: 🔁 1회 (Critical 2건) —
  - **Critical①**: 고급 생성자 `AdminClient(cfg, TokenProvider)`가 `KeycloakBuilder.build()`의 grantType/자격증명 필수 요구로 **모든 호출 실패**(실제 jar로 경험 확인, Codex+리뷰어 일치). **사용자 재정: MVP에서 제거**. 기본 네이티브 그랜트 생성자만 유지.
  - **Critical②**: admin `mvn verify` 커버리지 red(AdminExceptions 56%/50%) → 403·default·safeBody 전 분기 테스트로 100%/100% 달성.
  - +Important: 기본 생성자 null clientSecret 가드(→KeycloakConfigException).
- **Minor(최종리뷰)**: AdminExceptions가 원인예외로 jakarta.ws.rs 타입을 `getCause()`에 보존(디버깅용, 주 API엔 미노출; plan 지시).
- **모델**: 구현=sonnet, 리뷰=sonnet, G5=Codex(GPT-5)

### 4b (4.3~4.7: users·clients·realms·roles·groups 파사드)
- **커밋**: e941133..51b2c47 (4.3 1841ace, 4.4 57e8368, 4.5 c798515, 4.6 ea2d155, 4.7 55719a9 + Critical fix 51b2c47)
- **G1**: ✅ / **G2**: ✅ (43/43) / **G3**: ✅ 100% 라인/100% 브랜치 (AdminExceptions+5파사드; AdminClient 제외) / **G4**: ✅(수정후) / **G5 Codex**: ✅(재정후) / **G6**: ✅ (jakarta 타입 공개 시그니처 미노출)
- **admin-client API 편차**(javap 검증, 공개 시그니처 미노출): update는 get(id).update(rep); RealmsResource는 realm(name).toRepresentation()/.remove(); RolesResource.deleteRole; GroupsResource add()/group(id)/groups(first,max); CreatedResponseUtil.getCreatedId.
- **루프**: 🔁 1회 (Critical) + 재정 1건 —
  - **재정(Codex 오탐)**: Codex가 `RealmsResource.realm(String)` 부재 주장 → **javap로 존재 확인**, 코드 정상 → 기각.
  - **Critical(리뷰어가 Codex 놓친 것 포착)**: `UsersResource/ClientsResource.delete`가 `Response` 반환 delegate라 JAX-RS 프록시가 비-2xx에 예외 미발생 → 실패 삭제가 조용히 성공. **수정**: Response status 확인 후 비-2xx면 translate로 던짐 + 5개 파사드 delete 실패 테스트 추가(43 테스트).
- **모델**: 구현=sonnet, 리뷰=sonnet, G5=Codex(GPT-5)

**✅ Phase 4 (admin) 완료. 루프 2회 + 재정 1회. 이중검증 상호보완 확인.**

## Phase 5 — facade 모듈

### 5.1 KeycloakClient
- **커밋**: 8978e62..c204475 (2e7a015 + test강화 c204475)
- **G1**: ✅ / **G2**: ✅ (3/3) / **G3**: ✅ 100% 라인 (분기 없음) / **G4**: ✅ / **G5 Codex**: ✅(수정후) / **G6**: ✅
- **루프**: 🔁 1회 (테스트 품질) — Codex가 close() 위임 미검증·non-null만 확인(vacuous) 지적 → 목 주입 시드 추가, `verify(admin).close()`로 위임 증명(no-op이면 실패).
- **모델**: 구현=sonnet, G5=Codex(GPT-5)

**✅ Phase 5 (facade) 완료.**

## Phase 6 — 통합 테스트 (Testcontainers, 실제 Keycloak 26.6.4)

### 6.1 하네스+realm · 6.2 인증 E2E · 6.3 관리 E2E
- **커밋**: 0a2d3e4..d8e7022 (auth fix b8c0998, 6.1 c0481d6, 6.2 eda01c4, 6.3 d8e7022)
- **G1**: ✅ (전체 reactor `clean verify` BUILD SUCCESS) / **G2**: ✅ 전 단위 + **IT 3클래스 6검사 통과** (SmokeIT 1, AuthFlowIT 3, AdminOpsIT 2) / **G6**: ✅
- **인프라 이슈 2건 해결(RCA→수정)**:
  - Keycloak `--import-realm`은 파일명이 `<realm>-realm.json`이어야 함 → `test-realm.json`이 realm `it-realm`과 불일치해 컨테이너 exit 1 → **`it-realm-realm.json`으로 개명**.
  - IDE 백그라운드 컴파일러의 stale `AuthFlowIT.class`(필드 descriptor가 default-package `AuthClient`) → `NoClassDefFoundError` → **`mvn clean`으로 해소**.
- 🔴 **통합테스트가 발견한 실제 SDK 버그(Critical)**: 실제 Keycloak client-credentials 토큰의 `aud`는 **다중 값**(`["it-client","realm-management"]`)인데, `JwtValidator`가 `exactMatchClaims`에 audience를 넣어 **정확 일치**를 요구 → 정상 토큰 거부(`BadJWTException: aud rejected`). 단위테스트는 단일 aud라 은폐됨. **수정**(b8c0998): audience를 requiredAudience(포함검사)로만, issuer만 정확일치. 다중 aud 회귀테스트 2개 추가. **E2E로 수용 확인 + 불일치 aud 거부 확인**.
- **G5 Codex**: ⚠️ 이 세션에서 Codex CLI 반복 타임아웃(환경 일시 저하)으로 이 픽스 단독 재검증 미완. **대체 검증**: (a) 실제 Keycloak 26.6.4 E2E 통과(가장 강한 증거), (b) 비-vacuous 단위 회귀테스트(다중 aud 수용=yes, 불일치 aud 거부=yes), (c) 변경 의미 명확. Phase 3에서 원본 JwtValidator는 Codex 2회 루프 심층검증 완료.
- **모델**: 구현/수정=sonnet, RCA=controller(경험적 컨테이너 진단)

**✅ Phase 6 (통합) 완료. SDK가 실제 Keycloak 26.6.4로 end-to-end 동작. 통합이 프로덕션 aud 버그 1건 발견·수정.**

## Phase 7 — 배포 & 문서

### 7.1 release 프로파일 · 7.2 릴리스 CI · 7.3 examples · 7.4 문서
- **커밋**: 7.1 c6a9d61, 7.2 74ca1c2, 7.3 03c69ba, 7.4 db82837
- **G1**: ✅ 최종 `clean verify -DskipITs` BUILD SUCCESS (7 reactor entries) / **G2**: ✅ 단위 94/94 / **G3**: ✅ 전 로직모듈 게이트 통과 / **G6**: ✅ (deploy는 human-gated, 서명키/토큰 CI 시크릿)
- 7.1 release 프로파일: sources+javadoc(core/auth/admin/keycloak-sdk), gpg, central-publishing 0.11.0. javadoc doclint none(Java17 엄격). `-Prelease package`로 jar 생성 확인(서명·배포 없이).
- 7.3 examples: QuickStart(컴파일만), deploy/jacoco skip, parent modules에 추가.
- 7.4: README(설치·QuickStart·호환매트릭스·상태), CLAUDE.md(구현완료·테스트수 100) 갱신.
- **모델**: 구현=sonnet

**✅ Phase 7 (배포·문서) 완료.**

---

## 최종 전체 브랜치 리뷰 (opus) + 수정

- **Claude opus 홀리스틱 리뷰**: 판정 **MERGEABLE-WITH-FIXES**, Critical 0. 보안 코어(JWT·TLS·마스킹·스레드안전) 견고 확인. per-task가 놓친 횡단 이슈 3건(Important) 포착.
- **G5 Codex 최종**: 이 세션 Codex CLI 반복 타임아웃(환경 저하)으로 최종 단독 재검증 미완. Phase 0~5 매 태스크 Codex 교차검증(실제 결함 다수 포착) + 실제 Keycloak E2E로 대체 검증.
- **사용자 재정**: Important 3건 모두 배포 전 수정.
- **Wave A** (4760f64,858da01,b9f5df8,0e0a37d): I.1 `validate()`→SDK `ValidatedToken`(Nimbus 미노출) · I.2 `exchangeCode` 구현(Authorization Code 완성) · I.3 no-op `tlsVerification` 제거 · M.6 TokenSet null 가드 · M.7 JWKS 타임아웃. core 100%/91.7%, auth 91.6%/87.5%.
- **Wave B** (0fd6260,ff6d4ea,2c0aaf6): M.1 KeycloakClient admin 지연초기화(공개 클라이언트 지원) · M.2 create 파사드 Response 누수 수정 · M.3 AdminExceptions 패키지 전용화. admin 100%/100%, keycloak-sdk 100%/100%.
- **최종 게이트**: `mvn -f java/pom.xml clean verify` (Docker 포함) → **BUILD SUCCESS**, 7모듈, IT 3/3(ValidatedToken 반영 후 AuthFlowIT 재통과), 전 커버리지 게이트 통과.

**✅ 브랜치 병합 준비 완료.**

## 종합 (Java MVP 전 Phase 완료)
- **총 123 테스트** = 단위 117 (core 34·auth 34·admin 43·sdk 6) + 통합 6 (Testcontainers 실제 KC 26.6.4). — Phase 7 시점 94에서 최종리뷰 Wave A/B가 테스트를 추가해 117로 증가(위 각 Phase의 per-task 수치는 그 시점의 역사적 기록이며 여기 종합이 최종 실측).
- 커버리지 게이트(로직 라인≥90/브랜치≥85) 전 모듈 통과. 네트워크 경계(AuthClient/AdminClient)는 통합으로 검증.
- **거버넌스 루프 성과**: Codex 사전검증(Critical 3), admin 고급생성자 제거(사용자 재정), admin delete Response 버그(리뷰어가 Codex 놓친 것 포착), RealmsResource 오탐(javap 재정), JWT 보안 루프 2회, **통합이 다중 aud 프로덕션 버그 발견·수정**. 이중검증 상호보완 실증.

## Java 런타임 업그레이드 17 → 21 LTS (2026-07-03, App Modernization)

- **범위**: Java 런타임 타깃을 17 → 21 LTS로 상향. 빌드/CI/문서에 한정하며 **SDK 동작·공개 API·소스는 불변**. GitHub App Modernization 세션 `20260703110900`의 승인된 4-스텝 계획(`.github/modernize/java-upgrade/20260703110900/plan.md`) 실행.
- **변경**:
  - `java/pom.xml`: `maven.compiler.release` 17→21 · enforcer `requireJavaVersion` `[17,)`→`[21,)` · `maven-compiler-plugin` `3.11.0` pluginManagement 명시 고정(기본값 드리프트 방지).
  - CI: `.github/workflows/ci.yml` build matrix `['17','21']`→`['21']` + integration 잡 `17`→`21`; `.github/workflows/release.yml` `17`→`21`.
  - 문서: CLAUDE/README/DEPLOY/CONTRIBUTING/거버넌스 프레임워크 베이스라인 21 반영. 2026-07-02 스펙·WBS는 최초 계획의 역사적 기록으로 보존하되 상단에 21 업그레이드 note 추가.
- **검증** (before/after, run tests before-and-after 옵션 true):
  - **G0 사전 baseline (Microsoft OpenJDK 17.0.19)**: `mvn -f java/pom.xml clean test` → 단위 **117 GREEN**(0 실패/0 에러) — 변경 전 기준선 확보.
  - **G1 업그레이드 후 단위 (Eclipse Temurin 21.0.8)**: `mvn -f java/pom.xml clean test` → **BUILD SUCCESS**, 단위 **117 GREEN**(core 34·auth 34·admin 43·sdk 6). `release=21` 컴파일·enforcer `[21,)` 통과.
  - **G3/최종 (Temurin 21.0.8, Docker/Testcontainers 실제 KC 26.6)**: `mvn -f java/pom.xml clean verify` → **BUILD SUCCESS**, 7모듈 전부 SUCCESS. 단위 117 + **IT 6**(AdminOpsIT 2·AuthFlowIT 3·KeycloakContainerSmokeIT 1) = **총 123 GREEN**. JaCoCo 라인≥90/브랜치≥85 전 모듈 통과, DependencyConvergence 통과.
- **브랜치**: `appmod/java-upgrade-20260703110900`. **회귀 0** — 업그레이드 전후 테스트 수·통과 상태 동일(123/123).

## jackson-databind CVE 대응 (2026-07-03, Dependabot 7건)

- **트리거**: PR #7 push 시 Dependabot이 `java/pom.xml`의 `com.fasterxml.jackson.core:jackson-databind`(당시 2.21.2)에 대해 **7건** 경보(HIGH 2 · MEDIUM 5). 전부 동일 아티팩트.
- **조치**: jackson-databind 계열 **6종**(jackson-core·jackson-databind·jackson-datatype-jdk8·jackson-datatype-jsr310·jackson-jakarta-rs-base·jackson-module-jakarta-xmlbind-annotations) `2.21.2` → **`2.21.4`**. keycloak-client-parent:26.0.10 관리값(2.21.2)보다 상향("picked higher", 2.21.x 시리즈 내 유지). `jackson-annotations`는 별도 버전 트랙·CVE 대상 아님이라 **2.21 유지**. **소스(.java) 무변경**.
- **CVE별 결과** (다중에이전트 트리아지: CVE별 analyst + 적대적 skeptic 반증 검증, 만장일치 "악용불가"):

| CVE | Sev | 2.21.4로 패치 | 이 SDK 악용가능성 |
|---|---|---|---|
| CVE-2026-54512 (PolymorphicTypeValidator 우회) | HIGH | ✅ | 불가 |
| CVE-2026-54513 (BasicPTV `allowIfSubTypeIsArray` 우회) | HIGH | ✅ | 불가 |
| CVE-2026-54514 (InetSocketAddress 역직렬화 eager DNS·SSRF) | MEDIUM | ✅ | 불가 |
| CVE-2026-54516 (renamed `@JsonIgnore` setter → private field 기입) | MEDIUM | ✅ | 불가 |
| CVE-2026-54517 (`@JsonView` 우회 — setterless creator) | MEDIUM | ✅ | 불가 |
| CVE-2026-54518 (`@JsonView` 우회 — `@JsonUnwrapped` creator) | MEDIUM | ✅ | 불가 |
| CVE-2026-54515 (case-insensitive → per-property `@JsonIgnoreProperties` 우회) | MEDIUM | ❌ (fix=2.21.5 미출시) | 불가 |

- **악용불가 공통 근거**: SDK는 자체 `ObjectMapper`를 만들지 않고, default/polymorphic typing을 켜지 않으며(`activateDefaultTyping`/`@JsonTypeInfo` 부재), `@JsonView`/`@JsonIgnore`를 보안 경계로 사용하지 않는다. Jackson은 keycloak-admin-client/RESTEasy `jackson2-provider`가 **신뢰된 first-party Keycloak 응답**을 고정 concrete `org.keycloak.representations.idm.*` POJO로 역직렬화할 때만 전이적으로 쓰인다(미신뢰 JSON·다형성 베이스 타입 역직렬화 없음). JWT 검증은 Nimbus JOSE(비-Jackson). 손상/멀티테넌트 IdP·MITM(TLS 미검증)·에코된 공격자 필드값 등 엣지케이스도 추가 권한을 주지 못함(적대적 반증 전부 실패). → 2.21.4 bump은 **심층방어(defense-in-depth)**이며 활성 취약점 차단이 아님.
- **CVE-2026-54515 처리**: 릴리스된 fix 없음(2.21.4도 여전히 취약범위, 2.21.x fix=2.21.5 미출시; 타 라인 fix는 2.18.9/2.22.1/3.1.4). 이 SDK에서 악용 불가하므로 "vulnerable code path not reachable(우리 사용맥락에서 미도달)"로 문서화·처리. **2.21.5가 Maven Central에 올라오면 6종 일괄 상향**(annotations는 자체 트랙 유지). 2.22+/3.x로의 강제 상향은 keycloak-admin-client 26.0.10/RESTEasy 6.2.15 호환성 확인 전까지 지양. **추적: [이슈 #8](https://github.com/xzawed/KeyCloakSDK/issues/8)**.
- **유지 불변식(향후 위반 시 노출 재개)**: default/polymorphic typing 활성화 금지, 커스텀 JAX-RS Jackson provider/`ContextResolver` 등록 금지, 미신뢰 JSON을 `Object`/다형성 베이스로 역직렬화 금지, TLS 검증 on 유지.
- **검증**: `mvn -f java/pom.xml clean verify`(JDK 21, Docker/Testcontainers) → **BUILD SUCCESS**, enforcer **DependencyConvergence 통과**, **123 GREEN**(회귀 0), `dependency:tree`로 resolved `jackson-databind 2.21.4`·`jackson-core 2.21.4`·`jackson-annotations 2.21` 확인.

## 문서 & 언어 확장 (설치 가이드·로드맵·플레이북) (2026-07-03, WBS·Workflow·거버넌스)

- **산출물**: `docs/guides/getting-started.md`(설치·최소 사용 예) · `docs/roadmap/language-support.md`(전략·step-0 실배포·우선순위(딥리서치)·현황 매트릭스) · `docs/guides/add-a-language-playbook.md`(6단계 표준 절차 + G1~G6 매핑) · README front door 재구성. spec `aef3b1f` → WBS plan `7d45d99`.
- **실행 방식**: 브레인스토밍 → writing-plans → feature 브랜치 `docs/install-guide-and-language-expansion`. Task 1~3 문서 내용은 다중에이전트 Workflow(6개 언어 딥리서치 → 초안 → 적대적 검증 → 확정, 15 에이전트)로 생성, 권위 연산(파일 적용·설치 실측·링크·커밋)은 인라인(ground truth).
- **Ground-truth 검증(G1/G2/G4)**:
  - **API 정합**: getting-started의 Java/Python 예제 메서드를 실제 소스·examples와 grep 대조 — 전부 존재(`clientCredentialsToken`·`validate`·`users().create(UserRepresentation)→String`·`search(String,int,int)`·`Secrets.mask`·Python `client_credentials_token`·`users.create(dict)->str`·`search(first,max)`·`mask(str|None)`).
  - **로컬 설치 실측**: `mvn -f java/pom.xml install -DskipITs=true` → `~/.m2`에 `keycloak-sdk-0.1.0-SNAPSHOT.jar` 설치·커버리지 게이트 통과 확인.
  - **링크**: 신규 3개 문서 32링크 + README 20링크 전부 유효.
- **Loops(발견→시정→재측정)**:
  1. 워크플로 스크립트 `(await parallel()).filter` 파싱 버그(Promise에 `.filter`) → await 분리 후 재실행.
  2. finalize 에이전트가 getting-started 앞에 잡담(preamble) 부착 → 추출 시 첫 H1 이전 스트립.
  3. 문서의 `mvn install`이 Docker ITs를 요구(설치 마찰) → `-DskipITs=true`로 정정(getting-started·roadmap·playbook·README 일괄, 실측으로 확인).
  4. roadmap §6.3/§10 인용이 2026-07-02 스펙을 가리킴(파일은 존재하나 섹션 귀속 오류) → 2026-07-03 스펙으로 정정.
  5. README 리팩터 중 `### Python (pip)` 중복 → 병합.
- **딥리서치**: 6개 언어 클라이언트(유지보수·OIDF 인증·라이선스) 검증 — `keycloak-connect` deprecated·단일 유지자 리스크·Duende 패키지 ID 전환·`fschmtt` pre-1.0 등 반영, "작성시점 스냅샷(illustrative-as-of-drafting)" 경고로 하드넘버 과인용 방지(착수 시 재검증 원칙).
- **커밋**(브랜치 `docs/install-guide-and-language-expansion`): getting-started `e36dac8` · roadmap `1da50a6` · playbook `929a886` · README `abd34ee` · 정합/로그(본 커밋) → PR(사람 승인 머지).

<!--
태스크 기록 템플릿 (완료 시 아래 형식으로 추가):

### <WBS id> <태스크명>
- **커밋**: <base7>..<head7>
- **G1 빌드**: ✅ / **G2 테스트**: ✅ (N/N) / **G3 커버리지**: 라인 __% / 브랜치 __%
- **G4 스펙리뷰**: ✅ (Critical 0, Important 0) / **G5 Codex**: ✅ confirmed / **G6 보안**: ✅
- **루프**: 없음 (또는 🔁 N회 — RCA: ___ → 조치: ___ → 재측정: ___)
- **모델**: 구현=___, 리뷰=___
-->
