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

## 종합 (Java MVP 전 Phase 완료)
- **총 100 테스트** = 단위 94 (core 23·auth 25·admin 43·sdk 3) + 통합 6 (Testcontainers 실제 KC 26.6.4).
- 커버리지 게이트(로직 라인≥90/브랜치≥85) 전 모듈 통과. 네트워크 경계(AuthClient/AdminClient)는 통합으로 검증.
- **거버넌스 루프 성과**: Codex 사전검증(Critical 3), admin 고급생성자 제거(사용자 재정), admin delete Response 버그(리뷰어가 Codex 놓친 것 포착), RealmsResource 오탐(javap 재정), JWT 보안 루프 2회, **통합이 다중 aud 프로덕션 버그 발견·수정**. 이중검증 상호보완 실증.

<!--
태스크 기록 템플릿 (완료 시 아래 형식으로 추가):

### <WBS id> <태스크명>
- **커밋**: <base7>..<head7>
- **G1 빌드**: ✅ / **G2 테스트**: ✅ (N/N) / **G3 커버리지**: 라인 __% / 브랜치 __%
- **G4 스펙리뷰**: ✅ (Critical 0, Important 0) / **G5 Codex**: ✅ confirmed / **G6 보안**: ✅
- **루프**: 없음 (또는 🔁 N회 — RCA: ___ → 조치: ___ → 재측정: ___)
- **모델**: 구현=___, 리뷰=___
-->
