# Keycloak SDK 문서 & 언어 확장 — 구현 계획 (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 사용자 승인 실행 방식: **WBS 기준 Workflow 오케스트레이션 + AI 거버넌스(G1~G6) + Loops 엔지니어링 + 딥리서치/다이나믹 워크플로우**.

**Goal:** 개발자가 어떤 언어로든 SDK를 설치·시작할 수 있는 문서(설치 가이드)와, SDK를 Java/Python 품질로 여러 언어에 반복 확장하는 전략·로드맵·플레이북을 만든다.

**Architecture:** 문서 전용 산출물. README를 간결한 front door로 두고, 깊은 내용을 `docs/guides/`(설치·플레이북)와 `docs/roadmap/`(언어 확장)로 분리한다. 신규 언어 SDK **구현은 이 계획의 범위가 아니다**(플레이북 정의만).

**Tech Stack:** Markdown 문서. 검증에 기존 툴체인 사용 — Maven 3.9.9 + JDK 21(Java 로컬 설치 실측), Python 3.10+ venv(pip 설치 실측), git. 딥리서치(웹)로 §Task 2 언어별 클라이언트 후보 재검증.

## Global Constraints

모든 태스크에 암묵 적용. 값은 [스펙](../specs/2026-07-03-keycloak-docs-and-language-expansion-design.md)에서 그대로 옮겼다.

- **문서 언어**: 한국어 (기존 `docs/`·README 일관).
- **문서 구조**: README(front door) + `docs/guides/getting-started.md` + `docs/guides/add-a-language-playbook.md` + `docs/roadmap/language-support.md`.
- **요구 런타임 표기**: Java **JDK 21+**, Python **3.10+**.
- **로컬 설치 명령(검증 대상, verbatim)**: Java `mvn -f java/pom.xml install` · Python `pip install -e python` (또는 `python -m build`).
- **좌표/배포명**: Java `io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT` · Python 배포명 `keycloak-sdk`. **둘 다 미배포**(0.1.0-SNAPSHOT, human-gated) — 배포 후 설치는 "향후"로 명시하고 미배포 경고 표기.
- **전략**: depth-first(모든 언어 동형·강화 JWT·저품질 티어 없음). 우선순위 **TS/Node → Go → C# → PHP → Rust → Ruby**(Kotlin=옵션).
- **테스트 수(현행, 문서 표기 일치)**: Java **123**(단위 117 + IT 6), Python **235**(단위 224 + IT 11).
- **거버넌스**: 태스크마다 검증 게이트 통과 후 커밋. 실패 시 Loops(RCA→조치→재측정). 완료 시 verification-log 기록.
- **커밋**: `git add -A && git commit`. 작업 브랜치는 실행 시점에 결정(feature 브랜치 권장, PR로 main 병합 — 사람 승인).
- **검증 원칙**: 문서가 주장하는 설치 명령은 **실제 실행**해 성공 확인, 인용 예제는 실재 파일 기준, 내부·상호 링크는 유효.

## File Structure (생성/수정 파일과 책임)

- `docs/guides/getting-started.md` **(생성)** — 설치(로컬 now / 배포 후) + 최소 사용 예. 언어 섹션(Java·Python).
- `docs/roadmap/language-support.md` **(생성)** — 확장 전략·step-0 배포 체크리스트·우선순위표·현황 매트릭스.
- `docs/guides/add-a-language-playbook.md` **(생성)** — 새 언어 추가 6단계 표준 절차.
- `README.md` **(수정)** — front door로 재구성(상세 QuickStart→getting-started 이관, 요약+딥링크).
- `CLAUDE.md` **(수정)** — 프로젝트 구조 트리에 신규 docs 반영.
- `CHANGELOG.md` **(수정)** — `[Unreleased]`에 문서 항목.
- `docs/governance/verification-log.md` **(수정)** — 본 문서 작업 게이트 통과 기록.

## 태스크 의존/실행 순서

Task 1·2·3은 상호 독립(병렬 가능, Workflow 팬아웃 적합). Task 4는 1~3 산출물 링크에 의존. Task 5는 전부에 의존(최종 정합·게이트).

---

### Task 1: Getting-Started 가이드 (설치 + 최소 사용 예)

**Files:**
- Create: `docs/guides/getting-started.md`
- Verify against: `java/keycloak-sdk-examples/src/main/java/...`, `python/examples/quickstart.py`, `python/examples/async_quickstart.py`

**Interfaces:**
- Produces: `docs/guides/getting-started.md` (Task 4 README가 링크; Task 5 정합 검사 대상).
- Consumes: 없음.

- [ ] **Step 1: 파일 골격 작성** — `docs/guides/getting-started.md`에 다음 구조로 생성:
  - 제목 + "이 문서는 설치와 첫 사용을 다룬다. 두 SDK 모두 현재 미배포(0.1.0-SNAPSHOT, human-gated)이므로 로컬 설치를 우선 안내한다." 경고 배지.
  - `## 요구 런타임` 표: Java=JDK 21+, Python=3.10+ (Docker는 통합테스트에만).
  - `## Java` — 4블록(아래 Step 2).
  - `## Python` — 4블록(아래 Step 3).
  - `## 다음 단계` — [언어 확장 로드맵](../roadmap/language-support.md), [add-a-language 플레이북](add-a-language-playbook.md) 링크.

- [ ] **Step 2: Java 섹션 작성** — 4블록:
  - **요구 런타임**: JDK 21+ (`--release 21` 컴파일; 이전 JDK에서 `UnsupportedClassVersionError`).
  - **로컬 설치(now)**: `mvn -f java/pom.xml install` → `~/.m2`에 설치. 소비 프로젝트 의존성:
    ```xml
    <dependency>
      <groupId>io.github.xzawed</groupId>
      <artifactId>keycloak-sdk</artifactId>
      <version>0.1.0-SNAPSHOT</version>
    </dependency>
    ```
  - **배포 후 설치(future)**: 동일 좌표를 Maven Central에서. **⚠️ 현재 미배포** — [DEPLOY.md](../../DEPLOY.md)·[로드맵 step-0](../roadmap/language-support.md).
  - **최소 사용 예**: `KeycloakClient` 생성 → client-credentials 토큰 → `client.auth().validate(...)` JWT 검증 → admin CRUD 1개(예: `client.admin().users().create(...)`). 코드는 `java/keycloak-sdk-examples`의 실제 API에 맞춰 작성하고 해당 예제 파일을 링크.

- [ ] **Step 3: Python 섹션 작성** — 4블록:
  - **요구 런타임**: Python 3.10+.
  - **로컬 설치(now)**: `pip install -e python` (또는 `cd python && python -m build` 후 wheel 설치).
  - **배포 후 설치(future)**: `pip install keycloak-sdk`. **⚠️ 현재 미배포**.
  - **최소 사용 예**: `KeycloakClient`(sync) — client-credentials → `validate` → admin CRUD 1개. `keycloak_sdk.aio`(async) 한 줄 언급 + [async_quickstart.py](../../python/examples/async_quickstart.py) 링크. 코드는 `python/examples/quickstart.py` 실제 API 기준.

- [ ] **Step 4: 검증 — 로컬 설치 명령 실측(G1/G2)** — Java 로컬 설치가 실제 성공하는지 확인:
  Run: `JAVA_HOME='/c/Program Files/Eclipse Adoptium/jdk-21.0.8.9-hotspot' PATH="/c/Users/dirtc/tools/apache-maven-3.9.9/bin:$PATH" mvn -f java/pom.xml -q -DskipTests -DskipITs=true install`
  Expected: `BUILD SUCCESS`, 아티팩트가 `~/.m2/repository/io/github/xzawed/`에 설치됨.
  Run(Python): `cd python && /d/Source/KeyCloakSDK/python/.venv/Scripts/python.exe -m pip install -e . --dry-run` (또는 실제 `-e .`).
  Expected: 설치 계획/성공, 오류 없음.

- [ ] **Step 5: 검증 — 예제 정합·링크(G4)** — 인용한 API/메서드가 실제 examples에 존재하는지 grep으로 확인, 상대 링크 대상이 실재하는지 확인.
  Run: `grep -rn "users()\|validate\|clientCredentials\|KeycloakClient" java/keycloak-sdk-examples python/examples`
  Expected: 인용 API가 예제에 존재(불일치 시 문서를 실제 API에 맞춰 수정 — Loops).

- [ ] **Step 6: Commit**
  ```bash
  git add docs/guides/getting-started.md
  git commit -m "docs(guide): getting-started — 설치(로컬/배포후) + 최소 사용 예 (Java·Python)"
  ```

---

### Task 2: 언어 확장 로드맵 (전략·step-0 배포·우선순위·현황)

**Files:**
- Create: `docs/roadmap/language-support.md`
- Verify against: `DEPLOY.md`, `.github/workflows/release.yml`, `.github/workflows/python-release.yml`

**Interfaces:**
- Produces: `docs/roadmap/language-support.md` (Task 1·4가 링크).
- Consumes: 없음.

- [ ] **Step 1: 딥리서치 — 언어별 클라이언트 재검증** — 우선순위 6개 언어 각각의 auth/admin 클라이언트 후보를 딥리서치(유지보수 상태·최근 릴리스·OIDF 인증 여부·라이선스 Apache/MIT 호환)로 검증. 승인된 `deep-research` 스킬 또는 다이나믹 Workflow(언어별 finder + 적대적 verify) 사용.
  후보(스펙 §6.3): TS/Node=`openid-client`+`@keycloak/keycloak-admin-client` · Go=`coreos/go-oidc`+`gocloak` · C#=`IdentityModel`+`Keycloak.Net` · PHP=`jumbojett/OpenID-Connect-PHP` · Rust=`openidconnect` · Ruby=`omniauth`계.
  산출: 언어별 {선정 클라이언트, 유지보수 상태, 라이선스, 대안, 주의사항}.
  Expected: 각 후보의 현행성 확인 또는 대체 후보 확정.

- [ ] **Step 2: 문서 작성 — 전략 + step-0 배포** — `docs/roadmap/language-support.md`:
  - `## 전략` — depth-first, 동형(§4 계약 링크), 최고 클라이언트 래핑 + 자체 강화 JWT.
  - `## step-0 — 기존 SDK 실배포(사람 게이트)` — 체크리스트:
    - Java→Maven Central: `io.github.xzawed` 네임스페이스 검증 · GPG 키(공개키 배포) · Central Portal 토큰(4 시크릿) · `v*` 태그 push → `.github/workflows/release.yml`. 사전검증: `mvn -f java/pom.xml -Prelease -DskipTests -Dgpg.skip=true package`.
    - Python→PyPI: Trusted Publisher(OIDC) 등록 · `py-v*` 태그 → `.github/workflows/python-release.yml`. 사전검증: `python -m build`.
    - 절차 상세는 [DEPLOY.md](../../DEPLOY.md) 링크.

- [ ] **Step 3: 문서 작성 — 우선순위표 + 현황 매트릭스** — Step 1 딥리서치 결과 반영:
  - `## 우선순위` 표: 순위·언어·auth 클라이언트·admin 클라이언트·비고(유지보수/라이선스). 기준 문장(생태계 수요 × 성숙 클라이언트) 명시.
  - `## 현황 매트릭스` 표: 언어 × [설계·구현·단위·통합·CI·배포]. Java(✅×5, 배포 human-gated) · Python(✅×5 +async, 배포 human-gated) · TS/Node~Ruby(계획).

- [ ] **Step 4: 검증 — 딥리서치 사실성·링크(G4/G6)** — 표의 클라이언트/라이선스 주장이 Step 1 딥리서치 근거와 일치하는지, 참조 파일(`release.yml`·`python-release.yml`·`DEPLOY.md`) 존재·경로 유효 확인.
  Run: `ls .github/workflows/release.yml .github/workflows/python-release.yml DEPLOY.md`
  Expected: 3개 존재. 표 수치·상태가 현행(Java 123·Python 235·미배포)과 일치.

- [ ] **Step 5: Commit**
  ```bash
  git add docs/roadmap/language-support.md
  git commit -m "docs(roadmap): 언어 확장 전략·step-0 배포·우선순위(딥리서치)·현황 매트릭스"
  ```

---

### Task 3: Add-a-language 플레이북 (6단계 표준 절차)

**Files:**
- Create: `docs/guides/add-a-language-playbook.md`
- Verify against: `docs/superpowers/plans/2026-07-02-keycloak-java-sdk-wbs.md`, `docs/superpowers/plans/2026-07-03-keycloak-python-sdk-wbs.md`, `docs/governance/ai-governance-framework.md`

**Interfaces:**
- Produces: `docs/guides/add-a-language-playbook.md` (Task 1·2가 링크).
- Consumes: 없음.

- [ ] **Step 1: 문서 작성 — 6단계 절차** — `docs/guides/add-a-language-playbook.md`에 스펙 §7의 6단계를 "복붙 가능한 체크리스트 + 단계별 산출물·게이트"로:
  1. 계약 재확인 & 클라이언트 선정(딥리서치) — 산출: 선정 근거.
  2. 계층 구현(동형): `config`→`auth`(OIDC 래핑)→`jwt`(alg 핀·`none` 거부·iss 정확·aud 포함·클록 스큐·JWKS DoS-safe)→`admin`(파사드+`raw()`)→`client`(auth 즉시·admin 지연). 하위타입 은닉·예외 경계변환·`close()`.
  3. 보안 불변식: 마스킹(완전 불투명)·TLS on·JWKS 재조회 DoS-safe·admin 타임아웃 주입·(해당 시) default typing 금지 + CI 강제.
  4. 테스트 패리티 매트릭스: 단위(PKCE·설정·토큰파싱·예외매핑) + Testcontainers 통합(실제 Keycloak, Java/Python과 동일 시나리오) + 커버리지 게이트.
  5. CI·배포·문서: 빌드/린트/타입/테스트 CI + 태그 드리븐 배포(human-gated) + getting-started 언어 섹션 + verification-log.
  6. 거버넌스 게이트 G1~G6([ai-governance-framework](../governance/ai-governance-framework.md)) + Codex 이중검증 + Loops.

- [ ] **Step 2: 문서 작성 — 게이트 매핑 표 + 참조** — 각 단계 → 산출물 → 대응 게이트(G1~G6) 매핑 표. 기존 Java/Python WBS를 "실제 사례" 링크로 제시(신규 언어가 참고).

- [ ] **Step 3: 검증 — 기존 사례 정합·링크(G4)** — 플레이북이 기술한 계층/불변식이 실제 Java/Python 구조와 일치하는지 교차확인(스펙 §4 계약과 모순 없음), 참조 링크 유효.
  Run: `grep -rniE "JwtValidator|TokenProvider|raw\(\)|mask|TLS" java/keycloak-sdk-core java/keycloak-sdk-auth python/src/keycloak_sdk | head`
  Expected: 플레이북이 참조한 개념이 실제 코드에 존재(불일치 시 수정 — Loops).

- [ ] **Step 4: Commit**
  ```bash
  git add docs/guides/add-a-language-playbook.md
  git commit -m "docs(guide): add-a-language 플레이북 — 6단계 표준 절차 + G1~G6 매핑"
  ```

---

### Task 4: README front-door 재구성

**Files:**
- Modify: `README.md` (기존 `## QuickStart` 상세를 getting-started로 이관, 요약+딥링크)

**Interfaces:**
- Consumes: Task 1·2·3의 산출 문서(링크 대상).
- Produces: 간결한 README(Task 5 최종 링크 검사 대상).

- [ ] **Step 1: QuickStart 이관** — README `## QuickStart`의 상세 Java/Python(sync/async) 코드 블록을 제거하고, 대신:
  - `## 설치 & 시작` — 언어별 1줄 설치 스니펫(Java `mvn install`·Python `pip install -e python`) + "전체 가이드 → [docs/guides/getting-started.md](docs/guides/getting-started.md)".
  - 요구 런타임 1줄(Java 21+·Python 3.10+).
  - 상세 예제는 getting-started·`examples/`로 링크.

- [ ] **Step 2: 확장/기여 링크 추가** — README `## 개발자 안내`(또는 신규 `## 로드맵·기여`)에 [언어 확장 로드맵](docs/roadmap/language-support.md)·[add-a-language 플레이북](docs/guides/add-a-language-playbook.md) 링크 추가. 기존 `## 호환성`·`## 현재 상태` 표는 유지.

- [ ] **Step 3: 검증 — 링크 유효(G4)** — README의 신규 상대 링크가 모두 실재 파일을 가리키는지 확인.
  Run: `grep -oE '\]\(([^)]+\.md)\)' README.md | sed -E 's/\]\(|\)//g' | while read f; do [ -e "$f" ] && echo "OK $f" || echo "MISSING $f"; done`
  Expected: 모든 링크 `OK`(MISSING 0). 상대경로는 README 기준.

- [ ] **Step 4: Commit**
  ```bash
  git add README.md
  git commit -m "docs(readme): front door 재구성 — 상세 QuickStart→getting-started 이관 + 가이드/로드맵 링크"
  ```

---

### Task 5: 문서 정합 · 거버넌스 로그 (최종 게이트)

**Files:**
- Modify: `CLAUDE.md` (프로젝트 구조 트리), `CHANGELOG.md`, `docs/governance/verification-log.md`

**Interfaces:**
- Consumes: Task 1~4 전체 산출.
- Produces: 최종 정합된 문서 집합 + 게이트 로그.

- [ ] **Step 1: CLAUDE.md 구조 반영** — 프로젝트 구조/문서 섹션에 신규 `docs/guides/`·`docs/roadmap/` 및 3개 문서를 추가(설치 가이드·로드맵·플레이북 링크).

- [ ] **Step 2: CHANGELOG 항목** — `[Unreleased]`에 `### Added` 추가: "(Docs) 설치/시작 가이드·언어 확장 로드맵·add-a-language 플레이북 신설, README front door 재구성."

- [ ] **Step 3: 전체 링크·일관성 스윕(G4)** — 신규 3개 문서 + README의 모든 상대 링크 유효성, 테스트 수(Java 123·Python 235)·요구 런타임·미배포 상태 표기가 문서 간 불일치 없는지 확인.
  Run: `grep -roE '\]\(([^)]+\.md[^)]*)\)' README.md docs/guides docs/roadmap | sed -E 's/.*\]\(//; s/\).*//; s/#.*//' | sort -u | while read f; do :; done` — 각 문서 디렉터리 기준 상대경로 존재 확인(스크립트는 실행자가 디렉터리별로 확인).
  Expected: broken link 0, 수치/상태 표기 일치.

- [ ] **Step 4: verification-log 기록(G1~G6 종합)** — `docs/governance/verification-log.md`에 본 문서 작업 항목 추가: 산출물 목록, 검증 결과(로컬 설치 실측·예제 정합·링크 유효·딥리서치 근거), Loops 이력(있으면).

- [ ] **Step 5: Commit**
  ```bash
  git add CLAUDE.md CHANGELOG.md docs/governance/verification-log.md
  git commit -m "docs: 문서 정합(CLAUDE 구조·CHANGELOG) + 문서 작업 검증로그"
  ```

---

## Self-Review (계획 ↔ 스펙 대조)

- **스펙 커버리지**: §5 설치가이드→Task 1 · §6 로드맵(전략·step-0·우선순위·매트릭스)→Task 2 · §7 플레이북→Task 3 · §4 문서구조(README front door)→Task 4 · §8 거버넌스·§9 검증→각 Task의 검증 Step + Task 5. 누락 없음.
- **플레이스홀더**: 각 Step에 실제 명령·구조·검증 기대값 명시. "적절히 작성" 류 없음(문서 산출물이라 최종 prose는 실행 시 생성하되, 섹션·명령·좌표는 verbatim 지정).
- **타입/명칭 일관**: 파일 경로·좌표(`io.github.xzawed:keycloak-sdk:0.1.0-SNAPSHOT`)·명령(`mvn -f java/pom.xml install`)·우선순위(TS/Node→…→Ruby)가 스펙·Global Constraints와 일치.
