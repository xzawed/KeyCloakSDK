# Keycloak SDK — 설치 가이드 & 언어 확장 전략 (Design Spec)

> <!-- doc-status: complete -->
> **✅ 완료 — 이 설계는 구현됐다. 기록으로 읽어라.** 여기 적힌 "할 것"은 이미 한 것이고, 결정의
> *근거*가 이 문서의 가치다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [문서 지도](../../README.md)에 있다.

- **작성일**: 2026-07-03
- **선행 스펙**: [2026-07-02-keycloak-multilang-sdk-design.md](2026-07-02-keycloak-multilang-sdk-design.md) — 언어 중립 계약(§4)이 이 스펙의 진실 원천
- **라이선스**: Apache-2.0

---

## 1. 개요 (Overview)

두 가지를 확립한다. **(1)** 어떤 언어 개발자든 SDK를 **설치·시작**할 수 있는 명확한 경로(현재 로컬 설치, 배포 후 표준 패키지 매니저)를 제공하는 문서. **(2)** SDK를 **가급적 많은 언어**로 확장하되 각 언어를 Java/Python과 **동일한 고품질(depth-first)**로 반복 추가하는 전략·로드맵·플레이북.

산출물은 **문서**다. 개별 언어 SDK 구현은 이 스펙의 범위가 아니라, 이 스펙이 정의하는 **플레이북**을 따라 언어마다 별도 spec→plan→구현 사이클로 수행한다.

### 핵심 원칙

- **depth-first, 저품질 티어 없음**: 모든 언어는 언어 중립 계약(§4)에 동형이며, 그 언어 최고의 성숙한 기존 클라이언트를 래핑하고, JWT 검증만 자체 강화한다. codegen 남발·community 저품질 SDK 티어를 두지 않는다.
- **설치 우선(install-first)**: "개발자들이 혜택"의 실제 관문은 **배포**다. 로드맵의 step-0는 기존 Java/Python 실배포다(실행은 사람 게이트).
- **문서는 front door + depth 분리**: README는 간결한 진입점, 깊은 내용은 `docs/`.

---

## 2. 목표 & 성공기준

- **G-1 (설치)**: 신규 개발자가 README 진입 후 자기 언어의 *설치 → 첫 토큰 발급 → JWT 검증 → admin 호출 1개*까지 도달 가능. 로컬 설치(현재)와 배포 후 설치(향후)가 모두 명시됨.
- **G-2 (전략)**: 언어 확장 우선순위·기준·현황 매트릭스가 문서화되고, step-0 배포가 실행 가능한 체크리스트로 존재.
- **G-3 (반복성)**: 새 언어 기여자가 add-a-language 플레이북만으로 Java/Python 품질 바(동형 계층·강화 JWT·패리티 테스트·커버리지 게이트·CI·배포)를 재현 가능.
- **검증 가능성**: 가이드의 모든 설치 명령·예제 코드는 실제로 동작(로컬 설치 명령 실행 확인, 예제는 컴파일/실행), 문서 내 링크는 유효.

## 3. 범위 (Scope) & 비목표

### 범위 (이번 산출물)
- 설치/시작 가이드 (기존 Java·Python 대상, 로컬 + 배포후)
- 언어 확장 로드맵 (전략·우선순위·현황 매트릭스·step-0 배포 체크리스트)
- add-a-language 플레이북 (표준 절차)
- README를 front door로 재구성

### 비목표
- 신규 언어 SDK의 실제 구현 (플레이북 정의만; 구현은 언어별 후속 사이클)
- 실제 배포 **실행** (체크리스트·사전검증까지; 최종 게이트 통과는 사람)
- docs 사이트(MkDocs/Docusaurus) 구축 (미출시 0.x엔 과투자 — 향후 재검토)
- Keycloak 서버/SPI 개발

---

## 4. 문서 아키텍처

**하이브리드**: README = 간결한 front door, 깊은 내용 = `docs/`.

```
README.md                                  # front door: 언어별 설치 스니펫 + 5분 QuickStart + 딥링크
docs/
├─ guides/
│  ├─ getting-started.md                   # 설치(로컬 now / 배포 후) + 인증·Admin 첫 호출 (언어 섹션)
│  └─ add-a-language-playbook.md           # 새 언어 추가 표준 절차
└─ roadmap/
   └─ language-support.md                  # 확장 전략·우선순위·현황 매트릭스·step-0 배포
CHANGELOG.md                               # (기존) 언어 태그로 신규 언어 항목 기록
```

- **대안 기각**: README-only(비대), docs-site(과투자).
- README는 상세 QuickStart를 getting-started로 이관하고 요약 + 링크만 남긴다(스캔 가능성 유지).

---

## 5. 산출물 1 — 설치/시작 가이드 (`docs/guides/getting-started.md`)

언어별(현재 Java·Python) 4블록 구조:

1. **요구 런타임**: Java **JDK 21+**(아티팩트 `--release 21`), Python **3.10+**.
2. **로컬 설치 (now, 미배포 상태)**:
   - Java: `mvn -f java/pom.xml install` → 소비 프로젝트에서 `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT` 의존성.
   - Python: `pip install -e python` 또는 `python -m build` 후 wheel 설치.
3. **배포 후 설치 (future)**: Maven 의존성 좌표 / `pip install keycloak-sdk`. **⚠️ 미배포 배지**로 현재 불가함을 명시.
4. **최소 사용 예 (동형 시나리오)**: client-credentials 토큰 발급 → JWT 검증 → admin CRUD 1개. 기존 `examples/`(java `keycloak-sdk-examples`, python `quickstart.py`) 발췌·링크. 언어 간 **동일 개념·흐름**임을 나란히 보여 동형성을 실증.

가이드는 언어 확장 시 동일 4블록으로 섹션을 추가한다(플레이북과 정합).

---

## 6. 산출물 2 — 언어 확장 로드맵 (`docs/roadmap/language-support.md`)

### 6.1 전략
depth-first. 모든 언어: 언어 중립 계약(§4) 동형 + 그 언어 최고의 성숙 클라이언트 래핑(auth/admin) + 자체 강화 JWT(alg 핀·`none` 거부·iss 정확일치·aud 포함검사·클록 스큐·JWKS DoS-safe). 하위 타입은 파사드 뒤 은닉, 예외는 경계에서 SDK 타입 변환.

### 6.2 step-0 — 기존 SDK 실배포 (사람 게이트)
[DEPLOY.md](../../../DEPLOY.md) 기반 단계별 체크리스트로 정리:
- **Java → Maven Central**: `io.github.xzawed` 네임스페이스 검증 · GPG 키(공개키 배포) · Central Portal 토큰 · `v*` 태그 push.
- **Python → PyPI**: `keycloak-sdk` Trusted Publisher(OIDC) 등록 · `py-v*` 태그 push.
- 실행은 사람이 게이트를 통과할 때. 문서·사전검증(로컬 `-Prelease package` / `python -m build`)까지 준비.

### 6.3 우선순위 (안 — 실행 시 딥리서치로 재검증)
기준: **생태계 수요 × 성숙한 Keycloak/OIDC 클라이언트 존재**. 아래 래핑 후보는 **후보**이며, 각 언어 사이클 착수 시 딥리서치로 유지보수 상태·인증 여부·라이선스를 **재검증**한 뒤 확정한다.

| 순위 | 언어 | 래핑 후보 (auth / admin) |
|---|---|---|
| 1 | **TypeScript/Node** | `openid-client`(OIDF 인증) / 공식 `@keycloak/keycloak-admin-client` |
| 2 | **Go** | `coreos/go-oidc` + `golang.org/x/oauth2` / `gocloak` |
| 3 | **C#/.NET** | `IdentityModel` / `Keycloak.Net` (또는 admin REST 직접) |
| 4 | **PHP** | `jumbojett/OpenID-Connect-PHP` / admin REST |
| 5 | **Rust** | `openidconnect` 크레이트 / admin REST |
| 6 | **Ruby** | OIDC(`omniauth`계) / keycloak gem |

- Kotlin은 JVM에서 Java SDK 재사용 가능 → 관용 래퍼는 **옵션**(우선순위 밖).
- 순위는 로드맵 문서에서 조정 가능한 표로 유지(사용자·수요 변화 반영).

### 6.4 현황 매트릭스
언어 × [설계 · 구현 · 단위테스트 · 통합테스트 · CI · 배포] 상태 표. 현재: Java(전부 ✅, 배포 human-gated), Python(전부 ✅ + async, 배포 human-gated), 그 외(계획).

---

## 7. 산출물 3 — Add-a-language 플레이북 (`docs/guides/add-a-language-playbook.md`)

Java/Python이 실제로 거친 사이클을 표준 절차로 성문화(각 단계는 거버넌스 게이트와 매핑):

1. **계약 재확인 & 클라이언트 선정**: 언어 중립 계약(§4) 확인 → 딥리서치로 그 언어 최고의 auth/admin 클라이언트 선정(유지보수·인증·라이선스 검증).
2. **계층 구현(동형)**: `config` → `auth`(OIDC 래핑) → `jwt`(자체 강화) → `admin`(파사드, `raw()` 탈출구) → `client`(통합 진입점, auth 즉시·admin 지연). 하위 타입 은닉·예외 경계 변환·수명주기 `close()`.
3. **보안 불변식**: 토큰/시크릿 마스킹(완전 불투명) · TLS 검증 기본 on · JWKS 재조회 DoS-safe · admin 타임아웃 주입 · (해당 시) default/polymorphic 역직렬화 금지. 언어별 대응 + **CI 강제**(가능한 항목).
4. **테스트 패리티 매트릭스**: 단위(순수 로직: PKCE·설정·토큰파싱·예외매핑) + Testcontainers 통합(실제 Keycloak, 동일 시나리오). Java/Python과 **동일 시나리오 세트**. 커버리지 게이트(로직 모듈 고커버리지).
5. **CI·배포·문서**: 빌드·린트·타입·테스트 CI + 태그 드리븐 배포 워크플로(human-gated) + getting-started 언어 섹션 + verification-log.
6. **거버넌스 게이트**: G1(빌드)~G6(보안) 준용, Codex 이중검증, 루프 엔지니어링(게이트 실패 시 RCA→조치→재측정).

플레이북은 "복붙 가능한 체크리스트 + 각 단계 산출물·게이트" 형식으로 작성한다.

---

## 8. 실행 거버넌스 (Execution Governance)

이 산출물의 **구현(문서 작성)** 은 다음을 준수한다(사용자 승인 사항):

- **WBS 기준**: writing-plans 스킬로 이 스펙을 WBS(작업 분해)로 전개, 태스크 단위로 실행·추적.
- **Workflow 오케스트레이션**: 문서 생성·검증을 다중에이전트 Workflow로 병렬화하고, 각 산출물을 **적대적 검증**(finder→verify) 후 합성. 딥리서치·다이나믹 워크플로우 사용 승인됨.
- **AI 거버넌스**: [ai-governance-framework.md](../../governance/ai-governance-framework.md)의 G1~G6 게이트·Codex 이중검증·에스컬레이션 의무 적용.
- **Loops 엔지니어링**: 각 문서 산출물은 "생성 → 검증(링크·명령·예제 실행) → RCA 루프 → 재측정"으로 게이트 통과까지 반복. 통과 이력은 verification-log에 기록.
- **딥리서치 적용점**: §6.3 언어별 클라이언트 선정 검증(유지보수 상태·인증·라이선스), §5 배포 후 설치 명령의 정확성.

## 9. 검증 (Verification)

- **설치 명령 실측**: 로컬 설치 명령(`mvn install`, `pip install -e`)을 실제 실행해 성공 확인.
- **예제 동작**: 가이드에 인용된 예제는 컴파일/실행되는 코드(기존 examples 기준)여야 함.
- **링크 체크**: 문서 내부·상호 링크 유효성 검사.
- **일관성**: 테스트 수·버전·요구 런타임이 CLAUDE.md·verification-log 등과 불일치 없음.
- **거버넌스 로그**: 문서 산출물별 게이트 통과를 verification-log에 기록.

## 10. 결정·열린 항목

- **결정됨**: 문서 구조(하이브리드), depth-first 전략, 배포=step-0(가이드는 로컬+배포후), 언어 우선순위 1위 TS/Node.
- **실행 시 확정**: §6.3 각 언어 래핑 클라이언트(딥리서치 재검증 후), docs 사이트 도입 시점(향후).
- **열린 항목**: 신규 언어의 리포지토리 배치(모노레포 유지 vs 언어별 분리)는 **첫 신규 언어(TS/Node) 사이클 착수 시 별도 결정** — 이번 문서 범위 밖.
