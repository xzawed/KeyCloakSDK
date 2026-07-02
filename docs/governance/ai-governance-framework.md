# AI 거버넌스 · 이중검증 · 루프 엔지니어링 실행 체계

- **작성일**: 2026-07-02
- **적용 대상**: KeyCloakSDK Java MVP 구현 (WBS 계획서 실행)
- **상태**: 활성

이 문서는 [WBS 계획서](../superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md)를 **정량 품질 게이트 + Codex 이중검증 + 미달 시 루프 엔지니어링 + AI 거버넌스** 아래에서 실행하기 위한 규약이다. 모든 태스크 실행은 이 체계를 따른다.

---

## 1. 역할·권한 (직무 분리 + 모델 독립성)

| 주체 | 역할 | 권한/책임 |
|---|---|---|
| **사람 (xzawed)** | 최종 책임자 (Accountable) | 계획 충돌 재정, 게이트 오버라이드, **브랜치 머지·Maven Central 배포 최종 승인** |
| **Claude (컨트롤러)** | SDD 오케스트레이션 | 태스크 디스패치, 리뷰 재정, 감사 기록 유지 |
| **Claude 구현 에이전트** | TDD 구현 (태스크별 신규) | 실패 테스트→구현→통과→커밋, 자체 리뷰 |
| **Claude 리뷰 에이전트** | 스펙+품질 게이트 (태스크별 신규) | 스펙 준수·코드 품질 판정 |
| **Codex (GPT-5) 독립검증자** | 모델-독립 교차검증 | 게이트 G5, RCA 공동진단, 최종 리뷰 참여 |

**직무 분리 원칙**: 구현자 ≠ 리뷰어 ≠ 검증자. 검증자는 **다른 모델(Codex)** — 동일 모델의 상관된 맹점(correlated blind spot)을 상쇄한다. 자기 코드 자기 승인 금지.

---

## 2. 정량 품질 게이트 (태스크마다 전부 통과해야 완료)

| 게이트 | 지표 | 임계값 | 측정 수단 |
|---|---|---|---|
| **G1 빌드** | 컴파일 에러 수 | 0 | `mvn compile` |
| **G2 단위테스트** | 통과율 | 100% | `mvn test` |
| **G3 커버리지** | 라인 / 브랜치 | **≥ 90% / ≥ 85%** | JaCoCo `jacoco:check` |
| **G4 스펙 준수** | 미해결 Critical/Important | 0, 리뷰어 ✅ | Claude 리뷰 에이전트 |
| **G5 Codex 교차검증** | 미해결 불일치 | 0, 판정 "confirmed" | Codex CLI (전 태스크) |
| **G6 보안** | 토큰/시크릿 로그·내부타입 누출 | 0 | 리뷰어 + Codex |

- **G3 대상**: 로직 모듈(core, auth, admin 파사드의 순수 로직). 통합 전용 코드(Testcontainers 필요)는 Phase 6에서 별도 평가하며 G3 라인 커버리지 계산에서 제외(`jacoco` exclude 또는 통합 리포트 분리).
- **G5 깊이**: **모든 태스크**. Codex가 태스크 diff를 독립 검토하여 정합성·스펙 부합을 판정한다.

---

## 3. 루프 엔지니어링 (지표 미달 시 피드백 루프)

```
[측정] → 임계값 비교
  ≥ 임계값 → PASS → 다음 게이트/태스크
  < 임계값 → [루프]:
     ① RCA (근본 원인 분석) — Claude + Codex 공동 진단, 원인 기록
     ② 시정조치 — fix 서브에이전트 (원인 대상 최소 변경)
     ③ 재검증 — G1~G6 재실행 (해당 커버 테스트 + 지표)
     ④ 재측정 → 임계값 재비교
   [경계] 게이트당 최대 3회 반복 → 초과 시 사람에게 에스컬레이션
```

- 모든 루프 반복은 감사 로그에 기록: **이전 지표 → 조치 → 이후 지표 → RCA 요약**.
- 무한 루프 방지: 게이트당 3회 초과 시 중단하고 원인을 사람에게 보고.

---

## 4. 감사 추적 · 재현성 (Traceability)

- **진척 원장**: `.superpowers/sdd/progress.md` (gitignore) — 태스크 완료·커밋 해시. 컴팩션 복구용.
- **검증 로그**: [`verification-log.md`](verification-log.md) (커밋) — 태스크별 지표(커버리지·테스트 수·통과율), Codex 판정, 루프 이력, RCA. **WBS → 커밋 → 검증기록** 완전 추적.
- **커밋 규약**: 각 커밋 메시지에 WBS id 포함 (계획서에 이미 반영).
- **재현성**: 의존성 버전 BOM 고정, Keycloak 컨테이너 태그 고정(`quay.io/keycloak/keycloak:26.6`), 툴체인 버전 고정(JDK 17.0.19, Maven 3.9.9).

---

## 5. 거버넌스 통제 (Guardrails)

- **브랜치 격리**: 구현은 `feature/java-sdk-mvp`에서만. main 직접 구현 금지. 완료 후 PR로 머지(사람 승인).
- **되돌릴 수 없는 작업은 사람 승인 필수**: Maven Central 배포(Phase 7.2 `deploy`)는 에이전트 자동 실행 금지. GPG 키·Portal 토큰은 CI 시크릿으로만.
- **비밀 취급**: 코드·로그·커밋에 토큰/시크릿 금지 (마스킹 유틸 + 리뷰로 강제).
- **최소권한 모델 선택**: 역할별 최저 적정 모델 사용(전사 코드=저가, 판단=표준, 최종설계리뷰=최고).
- **에스컬레이션 의무**: 서브에이전트 BLOCKED/계획 모순/게이트 3회 초과는 무시 금지 — 사람에게 보고.

---

## 6. 툴체인 (고정)

빌드/테스트는 로컬에 설치된 툴체인으로 실행한다. 하네스 셸은 프로파일을 소싱하지 않으므로 **명령마다 환경을 인라인 지정**한다.

**표준 빌드 프리픽스 (Bash):**
```bash
JAVA_HOME='/c/Program Files/Microsoft/jdk-17.0.19.10-hotspot' \
PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" \
mvn <args>
```
**PowerShell 변형:**
```powershell
$env:JAVA_HOME='C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot'; $env:Path='C:\Users\dirtc\tools\apache-maven-3.9.9\bin;' + $env:Path; mvn <args>
```
- JDK: Microsoft OpenJDK **17.0.19** (`C:\Program Files\Microsoft\jdk-17.0.19.10-hotspot`)
- Maven: **3.9.9** (`C:\Users\dirtc\tools\apache-maven-3.9.9`)
- ⚠️ 위 경로는 이 개발 머신 전용 — 리포지토리에 커밋하지 않는다(포터블 아님). CI는 `setup-java`가 제공하는 JAVA_HOME 사용.

**커밋 규약**: 신규 파일 누락 방지를 위해 커밋은 항상 `git add -A && git commit -m "..."` 형식을 쓴다. `git commit -am`은 untracked 파일을 스테이징하지 못하므로 **금지**. 구현은 `feature/java-sdk-mvp`에만 push하고 main에는 PR로 머지(사람 승인).

---

## 7. 태스크 실행 절차 (요약)

각 WBS 태스크는 다음 순서로 실행한다:

1. **디스패치**: 태스크 브리프(요구사항)만 담아 구현 서브에이전트 디스패치 (모델은 태스크 복잡도에 맞춤).
2. **구현**: TDD (실패 테스트 → 구현 → 통과 → 커밋), 자체 리뷰.
3. **G1–G3 측정**: 빌드·단위테스트·커버리지.
4. **G4 리뷰**: Claude 리뷰 에이전트 (스펙+품질).
5. **G5 Codex 교차검증**: Codex가 diff 독립 검토.
6. **G6 보안 체크**.
7. **판정**: 전 게이트 PASS → 검증 로그 기록 → 완료. 미달 → §3 루프.
8. **다음 태스크** (사이에 사람 확인 없이 연속 실행; BLOCKED·모순·3회 초과 시에만 중단).

Phase 완료 시 Phase 게이트(전 태스크 green + 통합테스트) 확인. 전체 완료 시 Codex 포함 전체 브랜치 최종 리뷰 → PR(사람 승인).
