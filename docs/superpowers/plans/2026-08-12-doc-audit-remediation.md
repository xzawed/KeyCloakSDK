# 문서 전수 감사 후속 조치 Implementation Plan

> <!-- doc-status: complete -->
> **완료 — 권고 5개 중 3개 반영, 2개는 실측 후 기각.** 2026-08-12 문서 전수 감사(95개 문서)가
> 확정 138건·반증 9건을 냈다. 즉시항목·권고 1·2·4가 커밋됐고(`8b116e9`·`c3bb034`·`d63e3aa`),
> 감사 HIGH 잔여와 npm 취약점도 닫았다(`6b79a14`·`f459904`).
> **권고 3·5는 만들지 않기로 했다** — 둘 다 "문구가 아니라 문맥이 참/거짓을 정한다"는 같은
> 이유로 정규식이 수렴하지 않고, 게시 개수는 이미 SSOT 파생 어서션 23개가 더 강하게 덮는다.
> 기각 근거는 각 Task 절에 실측과 함께 있다 — **되살릴 조건도 적어 두었다.**
> 남은 체크박스는 없다. 이 문서는 감사 결과와 기각 근거의 보존이 목적이다.

**Goal:** 문서가 코드·리포 실상과 갈리는 것을 **인스턴스가 아니라 부류 단위로** 막는다. 감사가 찾은 138건은 11개 부류로 묶이고, 그중 네 부류(게시 상태 · 앵커 밖 버전 · 문서 내부 자기모순 · 손으로 세는 카운트)가 전체의 60%다.

**핵심 관찰:** 확정 결함의 대부분은 "아무도 안 본 자리"가 아니라 **"가드가 있는데 그 자리를 안 겨눈" 자리**였다. 게시 상태 가드는 82개 어서션을 돌리면서도 `DEPLOY.md`가 자기 자신을 네 자리에서 반박하는 것을 못 봤다. 그래서 이 계획의 작업은 대부분 **신규 가드가 아니라 기존 가드의 조준점 확대**다.

---

## 감사 방법과 결과 (재현 가능하도록 기록)

- **워크플로**: 8로트(root-consumer · guides · lang-readme · rules · governance · harness · specs · plans) × (감사 → 적대적 검증) + 통합 = 17 에이전트, 3.55M 토큰, 43분.
- **교차 검증**: Grok 독립 레그 3회(감사 2 + 토의 1). 모든 발견을 명령으로 직접 재현했다.
- **적대적 검증층이 9건을 반증**했다 — 그중 하나는 **이 저장소의 계획 문서와 사람(나) 둘 다가 믿고 있던 오류**였다(아래 ⚠️).

| 로트 | 문서 | 평균 | 최저 문서 |
|---|--:|--:|---|
| plans | 23 | 82.6 | 71 |
| lang-readme | 11 | 81.1 | 67 |
| root-consumer | 7 | 78.4 | `DEPLOY.md` 64 |
| rules | 10 | 78.2 | 65 |
| guides | 6 | 75.7 | 60 |
| specs | 23 | 72.5 | 57 |
| harness | 3 | 68.7 | **`harness/install/README.md` 50** |
| governance | 12 | **63.8** | `verification-log.md` 56 |

최고: `docs/README.md` 100 · `SECURITY.md` 97 · `.claude/rules/kotlin.md` 93.

⚠️ **반증 중 가장 중요한 것 — dotnet 하네스 레그는 깨져 있지 않다.** 계획서
[2026-08-12-harness-judgment-and-provenance-completion.md](2026-08-12-harness-judgment-and-provenance-completion.md)의 **S-B1이 틀렸다**: "`signals/dotnet.install.json`이 `installed:false`이며 2026-08-03부터 그 상태"라는 근거는 **git-ignored 로컬 스크래치**다(`git check-ignore -v harness/install/report/signals/dotnet.install.json` → `.gitignore:1:signals/`). 실제 CI는 초록이다:

```
gh run view 31561083854 → harness / success / 2026-08-12T03:45:47Z
  jobs: install-all=success · score-all=success · all-langs=success
harness.yml:86 → ./install-verify.sh go dotnet node python java php rust ruby kotlin   (9개 전부)
```

로컬 bagetter 기동 실패는 이 PC의 Docker Desktop 문제이지 리포 결함이 아니다. **Task B1(dotnet 레그 복구)은 재검토 대상이다.**

---

## 완료된 것 (이번 세션)

- [x] **즉시항목** — `harness/install/README.md:28`의 "always exits 0" 제거(`8b116e9`). 스크립트는 `exit "$MATRIX_RC"`이고 이 문장은 **9개 릴리스 워크플로의 사전 게이트 의미론을 반대로** 알려주고 있었다.
- [x] **권고 2** — 손으로 센 테스트 수 제거(`8b116e9`). 에이전트가 실제로 스위트를 돌려 잰 결과 주장 993 vs 실측 1014, 9개 중 7개 오류였고 `.NET`은 한 파일에 세 값(58·71·실측 73)이었다. `docs/roadmap/language-support.md:76`이 이미 "hand-maintained 금지"를 정책으로 선언하고 있었다.
- [x] **게시 상태 사실 오류** — `DEPLOY.md` 3자리 · `docs/roadmap/language-support.md` 머리말+매트릭스 4행 · Kotlin vanniktech를 미입증→입증 이동(`8b116e9`).
- [x] **두 축 혼동** — `.claude/rules/ci.md:36`·`harness/install/README.md:44`가 격리 모델(6/3)과 출처 단언(8/1)을 한 문장에 묶어 node·rust에 게이트가 없는 것처럼 읽혔다(`8b116e9`). 가드 코드는 이미 8을 알고 있었다(`test-harness-registries.sh:324`).
- [x] **권고 1** — 게시상태 가드를 5자리로 확대(`c3bb034`, 82→88 어서션). 변이 5종 전부 잡힘, 가드 OFF에서 전부 통과(비공허성).
- [x] **권고 4** — 보안 기본값 단일 진실 가드 신설(`d63e3aa`, 30 어서션). `ruby/README.ko.md:72`가 JWKS 재조회 기본값을 `10.0`(코드는 30)이라 **3배 낮게** 알려주고 있었다. 변이 5종 전부 잡힘. 비공허성: 커밋 전 `grep -rln 'efetch\|RefreshInterval' scripts/ .github/workflows/` → **0건**.

---

## 잔여 작업

### Task R3: 문서 내부 수치 자기일치 린트 (확정 16건)

한 파일 안에서 같은 종류의 수치가 여러 번 나오면 전부 같아야 한다. 감사가 찾은 실례: `getting-started.md`가 .NET 테스트 수를 한 파일에서 세 값으로 말했고, `DEPLOY.md`가 게시 개수를 네 자리에서 다르게 말했다(둘 다 이번 세션에 인스턴스는 고쳤으나 부류는 열려 있다).

- [ ] **Step 1:** 대상 수치 종류를 셋으로 한정한다 — (a) 게시 언어 개수 (b) 테스트 수 (c) 런타임 하한. 넷째부터는 오탐이 급증한다(같은 파일의 서로 다른 파라미터가 우연히 같은 값을 갖는 경우 — 실제로 clock skew와 JWKS 재조회가 둘 다 30초라 변이검증에서 혼동이 있었다).
- [ ] **Step 2:** 실패하는 테스트 먼저 — 픽스처에 "한 파일 안 두 값" 케이스를 만든다.
- [ ] **Step 3:** `scripts/check-docs.mjs`에 검사 추가. 자가테스트는 기존 `scripts/test/test-check-docs.sh` 패턴 재사용.
- [ ] **Step 4:** 변이 3요건 보고 + `--min-facts`/`--min-anchors` 영향 확인.
- [ ] **Step 5:** 커밋.

### ~~Task R5: 금칙 문구 린트~~ — **기각(2026-08-13 실측)**

후보 7종(`webhook.*Packagist` · `coverlet.msbuild` · `golangci-lint-action` · `always exits 0` · mask의 `앞 3자` · `Node 20+` · `=26.6.2`)을 리포 전체에 걸어 히트를 하나씩 열어 봤더니 **대부분이 올바른 서술**이었다:

| 히트 | 판정 |
|---|---|
| `.claude/rules/dotnet.md`의 `coverlet.msbuild` 2건 | 둘 다 "**더 이상 쓰지 않는다**"는 설명 — 금지 대상이 아니라 금지 사유 기록 |
| `docs/roadmap/language-support.md`의 `Node 20+` | `openid-client` v6의 요구사항 서술이고 **같은 줄이 "The SDK requires Node 22+"** 라 적는다 |
| 같은 파일의 `jose 6.2.4` 등 해석값 | 50행에 **"⚠️ Candidate · point-in-time snapshot caution"** 이 명시돼 있다 |

소비자·운영 문서로 스코프를 좁혀도 걸러지지 않는다 — 위 히트가 **전부 그 스코프 안**이다. 문구 자체가 아니라 **문맥**(설명인가 주장인가 · 캐비앳이 있는가)이 참/거짓을 가르므로, 정규식으로는 수렴하지 않는다. 하네스 메타 가드가 "정적으로 임의 POSIX 셸의 의미를 증명하려다 수렴하지 않은" 것(S-B0)과 같은 부류다.

**대신 유효한 것**: 캐비앳 없이 해석값을 적는 자리를 없애거나(`CLAUDE.md`의 jose 셀을 `해석값은 lockfile 참조`로 바꾼 방식) 표에 point-in-time 캐비앳을 붙이는 것(`getting-started` 호환성 표). 이건 가드가 아니라 편집이고, `6b79a14`에서 했다.

### ~~Task R3: 문서 내부 수치 자기일치 린트~~ — **기각(2026-08-13 실측)**

착수 전에 공허성을 쟀고, 두 가지가 함께 나왔다.

**(1) 검사할 것이 남아 있지 않다.** 소비자·운영 문서에서 게시 개수를 주장하는 자리를 전수로 뽑으니 **11자리 전부 일치**한다(8 게시 / 1 미게시): `DEPLOY.md` 3·416(×2)·466(×2) · `README.md:112` · `getting-started.md:5`(×2) · `language-support.md:17`(×2). 테스트 수는 소비자 문서에서 전부 지웠고(`8b116e9`), 런타임 하한은 doc-guard 앵커가 9개 언어를 이미 덮는다.

**(2) 이 린트를 만들었다면 오탐을 냈다.** 같은 스캔이 `DEPLOY.md:9`의 `seven consecutive nights`를 잡는다 — **CI가 빨갰던 밤 수**이지 게시 개수가 아니다. 한 파일 안 "seven"과 "eight"을 모순으로 판정했을 것이다. 권고 5를 기각한 것과 **같은 부류**(문구가 아니라 문맥이 의미를 정한다)이고, `dotnet/README.md`에서 clock skew와 JWKS 재조회가 둘 다 30초라 변이검증이 한 번 틀렸던 것도 같은 뿌리다.

**이미 더 나은 것이 있다.** `test-publication-claims.sh`의 SSOT 파생 어서션 23개가 위 11자리를 전부 덮는다 — 문서를 **다른 문서의 산문**과 대조하는 것보다 `DF_PUBLISHED`라는 **진실 원천**과 대조하는 쪽이 구조적으로 강하다. 자기일치는 "둘 다 틀린 경우"를 통과시키지만 SSOT 대조는 통과시키지 않는다.

⚠️ **되살릴 조건**: 게시 개수 외의 수치(예: 언어 수 9, 리소스 5, 오퍼레이션 7)가 SSOT 없이 여러 문서에 흩어져 드리프트가 실측될 때. 그때도 문맥 문제는 그대로이므로 **자리 명시(`claim_at` 관용)** 가 정규식 스캔보다 낫다.

### 확정됐으나 미수정인 개별 결함 (감사 HIGH 잔여)

- [x] `.claude/rules/php.md` — 포터블 PHP 경로·버전이 실제와 다르고 Xdebug·pcov가 없어 커버리지 명령이 실행되지 않던 것을 고쳤다(`6b79a14`). 값을 갱신하는 대신 `KCSDK_PHP` 한 변수에서 파생시키고 패치 버전은 적지 않는다(부류 J 재발 방지). 교정 후 문서 그대로 실행해 확인했다.
- [x] 앵커 밖 해석버전 — `CLAUDE.md`의 jose 해석값·WireMock, `getting-started` 호환성 표(`6b79a14`). jose는 갱신하지 않고 **스냅샷을 적지 않는 쪽**으로 바꿨다.
- [x] npm dev 전이 취약점 2건(high) — `nanoid`·`brace-expansion`(`f459904`). 소비자 무영향(`files:["dist"]`·전부 dev 스코프)이지만 CI 잡이 토큰을 보므로 닫았다. 런타임 3종 무변경, 패키지 수 387→387.
- [ ] `docs/governance/` 검증 로그 9개 — PR 머지·태그 게시 후에도 "미실행/PR 예정"을 현재형으로 유지(H10~H14). append-only 정책과 충돌하지 않는 해법은 **절 단위 `as-of` 날짜** 부여다.
- [ ] `docs/superpowers/specs/2026-07-06-keycloak-php-sdk-design.md:67` — fschmtt `TokenStorageInterface`에 `ClientCredentialsTokenProvider`를 배선한다고 적지만 `AdminClient::__construct`는 `KeycloakConfig`만 받는다(계획서 Task D4와 같은 건).
- [ ] `docs/superpowers/specs/2026-07-06-keycloak-rust-sdk-design.md:29` — "reqwest 0.13.4 / reqwest13 feature"인데 실제는 `0.12` + `reqwest12`.

---

## 다른 PC에서 이어받을 때

### 환경 게차 (이번 세션에 실측으로 드러난 것)

- ⚠️ **`harness/install/report/`의 `signals/`·`INSTALL-MATRIX.md`는 git-ignored 로컬 스크래치다.** CI 상태를 여기서 추론하지 말 것 — `gh run list --workflow=harness.yml` / `gh run view <id> --json jobs`로 볼 것. 이 혼동이 이번 세션에 실제로 잘못된 보고를 낳았고 계획서 S-B1에도 남아 있다.
- ⚠️ **이 PC(Windows)의 `python`은 스텁이다** — `python --version`이 `Python` 한 줄만 출력하고 heredoc 스크립트가 **조용히 무동작**한다. 변이검증 스크립트는 `node`로 쓸 것. 실제로 이 때문에 "가드가 변이를 못 잡는다"는 거짓 측정이 한 번 나왔다(적용 로그 부재로 발견).
- ⚠️ **셸 가드는 `dash`로 재확인할 것**(CI의 `/bin/sh`). 로컬 `sh`는 bash다.
- ⚠️ **`assert_ok`는 명령만 받는다** — 메시지 인자를 주면 그것까지 명령으로 해석해 실패한다. 메시지를 남기려면 `assert_eq`에 "ok" 문자열을 만들어 넘긴다(`test-security-defaults.sh`의 `ok_if` 참고).
- 하네스 레그 로컬 실행에는 Docker가 필요하다. kotlin 레그 실측 소요 약 3분(Keycloak 기동 → publish → consume 이미지 빌드 → install/quickstart/boot → conformance/security).

### 현재 상태 확인 명령

```bash
git log --oneline -6
sh   scripts/test/test-publication-claims.sh    # 88 passed, 0 failed
sh   scripts/test/test-security-defaults.sh     # 30 passed, 0 failed
sh   scripts/test/test-harness-registries.sh    # 59 passed, 0 failed
dash scripts/test/test-selftest-hygiene.sh      # 42 passed, 0 failed
node scripts/check-docs.mjs . --strict --min-facts=46 --min-anchors=18
node --test harness/install/report/install-matrix.test.mjs
```

### 병행 진행 중인 다른 계획

[하네스 판정·출처 완결 계획](2026-08-12-harness-judgment-and-provenance-completion.md)의 Phase B~E가 남아 있다. ⚠️ 그 계획의 **S-B1(dotnet 레그 실패)은 위에 적은 이유로 틀렸다** — Task B1에 손대기 전에 CI 상태를 먼저 확인할 것. Task B0(런타임 행동 테스트)는 이번 세션에 임시로 쓴 "게이트 블록을 sed로 추출해 dash로 실행" 방식(`a96232c`·`d63e3aa`의 변이검증)을 저장소 테스트로 승격하는 일이고, 그 방식이 정적 가드가 못 잡는 결함을 **두 번** 실증했다.
