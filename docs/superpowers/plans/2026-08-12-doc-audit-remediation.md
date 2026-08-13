# 문서 전수 감사 후속 조치 Implementation Plan

> <!-- doc-status: complete -->
> **완료 — 권고 5개 중 3개 반영, 2개는 실측 후 기각.** 2026-08-12 문서 전수 감사(95개 문서)가
> 확정 138건·반증 9건을 냈다. 즉시항목·권고 1·2·4가 커밋됐고(`8b116e9`·`c3bb034`·`d63e3aa`),
> 감사 HIGH 잔여와 npm 취약점도 닫았다(`6b79a14`·`f459904`).
> **권고 3·5는 만들지 않기로 했다** — 둘 다 "문구가 아니라 문맥이 참/거짓을 정한다"는 같은
> 이유로 정규식이 수렴하지 않고, 게시 개수는 이미 SSOT 파생 어서션 23개가 더 강하게 덮는다.
> 이어진 **문서 압축 검토(08-13)도 3건 중 2건이 실측으로 기각**됐다 — 중복으로 보이던 것이
> 가드의 조준점이거나(①) 생태계 고유 사실이었다(③).
> 기각 근거는 각 Task 절에 실측과 함께 있다 — **되살릴 조건도 적어 두었다.**
> 남은 체크박스는 없다. 이 문서는 감사 결과와 기각 근거의 보존이 목적이다.
> 여기서 반복된 "만들기 전에 재고, 안 만들기로 할 수 있다"는 절차 자체는
> [작업 루프](../../governance/working-loop.md)에 있다.

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

### 문서 압축 검토 (2026-08-13) — 3건 중 1건 반영, 2건 기각

감사와 별개로 "중복·불필요·코드와 다른 서술"을 다시 훑어 압축 후보 3건을 뽑았다. 착수 전에 셋 다 실측했고, **가장 큰 두 건이 실측으로 기각됐다** — 둘 다 "중복으로 보이는 것이 중복이 아니었다".

- [x] **② `docs/roadmap/language-support.md` 압축**(`11ce621`) — ✅ Done 행이 게차 교본과 스냅샷 핀을 재서술하고 있었다. 27.0KB → 19.4KB(**7,684B 절감**). 기각 근거만 남기고 핀·게차는 `CLAUDE.md`/`.claude/rules/`로 포인터. ⚠️ **.NET의 "구 `IdentityModel*`(비-Duende) 아카이브 궤도" 기각 근거는 리포 전체에서 이 파일에만 있다**(`grep -rn 'archive trajectory' | wc -l` → 1) — 압축하면서 그 사실을 행 안에 명시했다.

#### ~~① 언어 README ↔ getting-started 퀵스타트 중복 제거~~ — **기각(2026-08-13 실측)**

9개 `<lang>/README.md`(5.1–6.7KB)의 퀵스타트가 `getting-started.md`와 같은 흐름을 반복한다. 합치면 ~12KB가 준다. 만들지 않기로 한 이유 둘:

**(1) 그 코드펜스가 가드의 조준점이다.** `test-publication-claims.sh:44-62`는 배너뿐 아니라 **README 코드펜스 안의 핀된 버전**을 `DF_PUBLISHED` 파생 기대값과 대조한다. 주석이 그 이유를 적고 있다 — `java/README.md`가 실제로 낡은 좌표를 권한 적이 있고, "레지스트리는 README를 버전마다 고정하므로 이 실수를 고치려면 좌표 하나를 더 태워야 한다". 예제를 옮기면 **검사할 대상이 사라진다** = 가드가 덮는 면적이 준다.

**(2) 레지스트리 페이지에는 `getting-started.md`가 없다.** PyPI·npm·crates.io·NuGet은 패키지에 담긴 README **한 장**만 보여 준다. 그래서 이 README들의 링크는 전부 절대 URL이다(`grep -c 'https://github.com/xzawed/KeyCloakSDK/blob/main/' python/README.md` → 7). 상대링크가 깨지는 표면을 이미 누군가 계산해 둔 흔적이고, 퀵스타트를 링크로 바꾸면 소비자가 처음 보는 화면이 "다른 데 가서 보세요"가 된다.

감사에서 **두 예제가 실제로 갈린 건 0건**이다 — 드리프트가 실측되지 않은 중복에 가드 면적을 지불하지 않는다.

⚠️ **되살릴 조건**: 두 예제가 실제로 갈린 사례가 나올 때. 그때도 정답은 삭제가 아니라 **한쪽을 생성원으로 삼고 다른 쪽을 파생**시키는 것이다(가드 조준점은 파생 결과에 그대로 남는다).

#### ~~③ pre-1.0 정책 문단 중복 제거~~ — **기각(2026-08-13 실측, 근거가 착수 전 가설과 다름)**

같은 문단이 9개 README에 있어 "복붙 3KB"로 보였다. **실측하니 복붙이 아니었다.**

```
$ for f in java python node go dotnet php rust ruby kotlin; do
    grep "This SDK is \*\*pre-1.0\*\*" "$f/README.md" | wc -c; done
376 ×8, rust 0
$ grep -n "pre-1.0" rust/README.md
83: This crate is **pre-1.0**. … and note that Cargo's default caret requirement
    treats `0.x` minors as incompatible, so `cargo update` will not cross one for you. …
```

8개는 동일하지만 **Rust는 생태계 고유 사실을 담고 있다**. `0.x` 마이너를 캐럿이 넘지 않는 것은 Cargo의 동작이고 npm·pip은 다르다 — `CLAUDE.md` 규율 5의 "자매 생태계의 동작을 대칭으로 가정하지 않는다"가 정확히 이 자리다. 공통 문단으로 접었으면 **그 문장이 지워졌을 것**이고, 그건 압축이 아니라 사실 손실이다.

남은 8개(3,008B)만 접는 것도 (①-2)와 같은 이유로 하지 않는다 — 레지스트리 페이지에서 SemVer 계약은 링크 뒤가 아니라 본문에 있어야 한다.

⚠️ **되살릴 조건**: 이 문단이 세 번째 자리(예: 각 언어 패키지 메타데이터 description)까지 번져 손으로 맞추기 시작할 때. 그때는 삭제가 아니라 `deploy-facts.sh` 같은 SSOT에서 **생성**한다.

### CLAUDE.md 압축 (2026-08-14) — 레버 6종 측정 · 2종 집행 · 4종 기각

`CLAUDE.md`가 58,764/58,764B로 **여유 0**이 되어(한 줄도 못 넣는 상태) 압축 조사를 했다. 사용자 제안은 "언어별 분류·인덱싱"이었고, Grok 독립 레그 1회 + 워크플로 26에이전트(레버 6종 × 3렌즈 적대적 반증)로 대조했다.

**절별 실측**(`awk`로 `##` 경계 절단, Grok이 독립 재현해 일치):

| 절 | 실측 | 설계 §4.1 예산 | 델타 |
|---|--:|--:|--:|
| 확정 의존성 | 14,293 | **5.0 KB** | **+9.3 KB** |
| 핵심 게차 | 16,192 | 14.0 KB | +2.2 KB |
| 문서 유지 규칙 | 4,860 | 2.0 KB | +2.9 KB |
| 아키텍처 | 7,578 | 8.0 KB | 예산 안 |
| 작업 규율 | 5,335 | *없음* | 설계 이후 추가 |

#### 래칫 주석의 "줄일 수 없다" 주장 판정

- **"doc-guard 표 ≈11 KB는 줄일 수 없다 / 유일하게 기계 대조되는 문서 사실"** → **거짓, 실측 반증.** `tableAt`([check-docs.mjs:436-453](../../../scripts/check-docs.mjs))이 읽는 것은 *행의 첫 백틱(좌표)* 과 *마지막 셀(버전)* 뿐이다. 격리 트리에서 원본 14,293B와 최소형 2,144B가 **둘 다** 같은 facts/anchors를 내고 변이 2종을 동일하게 잡았다. "유일하게"도 거짓(`test-publication-claims.sh:159-161`·`checkCardinality`도 이 파일을 본다).
- **"게차 스텁 79건 ≈12 KB는 줄일 수 없다"** → **부분참.** 건수 79는 바닥이지만 바이트는 아니다(접미 `상세: …` 반복만 2,559B).
- **"목표 34 KB"** → 도달 불가. 「작업 규율」 5.3KB가 그 예산 *이후* 추가됐다.
- ⚠️ **앵커는 CLAUDE.md 밖에서도 세어진다** — 앵커 스캔이 `walk(ROOT)`([:661](../../../scripts/check-docs.mjs))이라 리포 전체다. 루트에 임시 `_anchor-probe.md`를 두고 실측: 46 facts/18 anchors → **47/19**(프로브는 역연산 제거, `git diff` 빈 출력 확인).

#### 집행

- [x] **의존성 표의 "왜 이 선택인가" 3열 삭제** — 79행에서 −6,043B, **facts/anchors 불변(46/18)**. 구조 검증: 줄 수·빈 줄·역슬래시 전부 동일, 파이프 −79(=변환 행 수). 상주가 필요한 사실 4건만 게차 스텁으로 옮겼다 — 워크플로는 8건이라 했으나 대조하니 Python joserfc는 `.claude/rules/python.md:34`에, Go의 "1.25를 강제하는 것은 `x/oauth2`"는 `go.md:25`에 이미 있었다. **`PR #57`(C# DI 10.x 보류)은 리포 전체에서 그 셀에만 있었다**(grep: CLAUDE 1 · rules 0 · docs 0).
- [x] **dotnet 앵커 사각 폐쇄** — 앵커는 뒤따르는 **첫 표만** 소유하는데(빈 줄에서 끊긴다) dotnet은 표가 둘이었고, 두 번째에 **프로덕션 의존성**이 있었다. 표를 합쳐 `min=2 → 5`, **facts 46 → 49**. 3요건: (a) `2.7.0→2.8.0` 변이 → `::error::CLAUDE.md:317 … 문서=2.8.0 실제=2.7.0` (b) 복원 → 바이트 동일·통과 (c) **변경 전 상태에 같은 변이를 넣으면 통과했다**(무보호 실증).
- [x] **내부 중복 제거** — 같은 9쌍 라이브러리 열거가 세 곳(개요 목록·핵심 전략·§4)이었고 둘을 접었다. 배포명 열거는 「현재 상태」 표로 접되 **레지스트리 라벨을 표에 복원**했다(`keycloak-sdk`가 Python·Rust·Ruby 셋에 동일해 라벨 없이는 구분 불가).
- [x] **래칫 주석 정정 + 하한 상향** — 반증된 주장을 삭제하고 근거를 적었다. `--min-facts` 46 → **49**(`repo-hygiene.yml`·`CLAUDE.md`·이 문서). doc-budget은 실측 + 1KB 여유.

**결과: 58,764B → 53,378B (−5,386B), 가드 커버리지 +3 facts.**

#### 기각 (전부 되살릴 조건 포함)

<details><summary><b>사용자 원제안 — 게차 스텁 언어별 그룹화</b> (상주성·가드 2렌즈 반증)</summary>

**이미 구현돼 있다.** `(언어)` 태그 + 언어별 포인터가 설계 §4.3의 "스텁은 루트, 상세는 하위"다. 압축으로 재해석하면 순이득 1,761~2,424B인데(제 재구성 −2,424B, 반증자 교정 −1,761B; Grok의 +320B는 접미를 유지한 다른 변형을 잰 값이다) 대가가 무겁다:

- **목적이 이미 달성돼 있다** — 태그별 최대 연속블록 합이 **73/79 = 92.4%**. 실제 재배치되는 줄은 6줄뿐이고 재배치 1줄당 ~133B를 낸다. 손익분기가 그룹당 2건이라 Java(1건)·Python(1건)은 **순손실**이고 언어가 늘 때마다 순손실 소제목이 하나 는다.
- 태그↔포인터 79/79 일치라는 **라우팅 이중화**가 사라져 오라우팅 폭발 반경이 1줄 → 최대 14줄(C#·Kotlin).
- `.claude/rules/java.md:30`·`python.md:40`이 "**태그 없는** 프로젝트 공통 항목이라 루트에 있다"를 식별 술어로 쓴다 — 태그를 지우면 이 역방향 다리가 공허해진다.
- 스텁 형태를 검사하는 가드가 **0건**이라 계약 파기가 조용히 통과한다.

⚠️ **되살릴 조건**: 설계 §4.3/§10-4의 스텁 계약을 편집이 아니라 **스펙 개정으로 먼저 바꾸고**, 그 시점에 (1) 최대 연속블록 비율이 92.4%에서 유의하게 떨어지고 (2) 순손실 그룹(현 Java·Python)이 사라지며 (3) rules의 "태그 없는 항목" 역참조 술어가 다른 식별자로 대체됐을 때. 셋을 동시에 만족하지 못하면 하지 않는다.

**살아 있는 변형**: 그룹화하지 않고 **접미만 제거 + 절 머리 규약 한 줄**(태그·평평한 목록 유지)은 −2,312B로 값이 거의 같으면서 grep 가능성·줄 자기완결성을 잃지 않는다. 이번엔 하지 않았다(잃는 것이 라우팅 이중화 1겹이라 별도 판단이 필요하다).
</details>

<details><summary><b>확정 의존성 절 전체를 <code>docs/reference/</code>로 이관</b> (−14,070B — 최대 레버, 2렌즈 반증)</summary>

기계적으로는 **작동한다**(앵커 이동 실증, 오류가 새 파일 경로·줄번호를 찍음). 그런데도 기각한 이유:

1. **이미 심리되어 닫힌 질문이다** — [설계 §10-1b](../specs/2026-07-23-docs-restructure-design.md): "2026-07-23 결정: **유지** + 근거 열 추가". 유지 사유는 애초에 가드가 아니라 **상주성**이었다(§4.1: "삭제하면 사람이 문서만으로 버전을 확인하지 못하는 손실만 남는다"). 레버가 실증한 "가드는 안 깨진다"는 그 결정이 이미 참으로 전제한 명제다.
2. **이관으로 거짓이 되는 문장이 11건**이고 **전부 CI 초록**이다 — `language-support.md:50`("Pins … live in CLAUDE.md's dependency tables")과 `:54-60` 7행 · `CONTRIBUTING.md:11` · `development-setup.md:172` · `.claude/rules/go.md:33`.
3. **`checkLinks`가 CLAUDE.md의 링크를 하나도 안 본다** — 정규식이 선두 `/`·`./`·`../`를 요구하는데 이 파일의 링크 20개는 전부 맨상대경로다. 새 포인터는 오타가 나도 영구히 초록이다.

⚠️ **되살릴 조건**: (1) §10-1b를 명시적으로 supersede하는 스펙 개정 (2) `checkLinks`가 맨상대경로를 잡도록 수정 (3) 위 11개 문장을 기계 대조하는 가드 신설 (4) `docs/**`가 상주 로드 경로에 편입. 넷을 다 만족하면 3열 삭제분과 겹치므로 잔여만 다시 잰다.
</details>

<details><summary><b>CLAUDE.md를 생성물로 (SSOT에서 조립)</b> (3렌즈 전부 반증 — 순효과 음수)</summary>

- **산수**: 생성이 손편집을 넘어 만드는 값은 게차 −51B·의존성 0B인데 DO-NOT-EDIT 배너 + BEGIN/END 마커 11쌍이 **+1,221B**라 순 **+1,170B 비용**이다.
- **가드**: 매니페스트에서 값을 파생하면 `doc-facts`가 **자기대조**가 되어, `openidconnect 4.0.1→4.0.2` 변이에 대해 대조 체제의 exit 1이 파생 체제에서 exit 0으로 바뀌는데 **출력 문구가 글자 하나 다르지 않다**. 그것도 `main` 룰셋 `PRIMARY`의 required 체크 2개 중 하나에서.
- **선례**: 설계 §5.8이 단방향 `--fix`를 "세탁 위험"으로 표시하고 선행조건까지 갖춰 놓고도 구현하지 않았고, Task B3이 "실패 표면이 줄지 않고 는다"로 파생을 기각했다.

⚠️ **되살릴 조건**: 루트 스텁과 rules 불릿이 텍스트로 동일해지고(현 정규화 매칭 61/79·정확일치 8/79), 카디널리티가 1:1이 되며(현 루트 79 vs rules 114), doc-guard가 대조하는 사실이 매니페스트 **바깥** 원천으로 옮겨져 생성이 자기대조가 아니게 될 때.
</details>

<details><summary><b>§4(b) 은닉성 표 압축 · 3절 병합 · 툴체인 3열 삭제</b> (각 2렌즈 반증)</summary>

- **§4(b) 격자(1,400B)**: git이 기록한 **재발 자리**다 — `65a371e`(아키텍처 9블록 축약) **19분 뒤** `078e30d`가 "축약에서 유실된 사실 2건 복원"을 냈고, 그 커밋이 "Ruby SSRF 하드닝 사실이 소실됐다"를 기록한다. 더 공격적이던 그 압축조차 §4/§4(b)는 byte-identical로 남겼다. 리포 유일 사실도 있다(Node `JWTVerifyGetKey` 전체 grep 1건).
- **3절 병합(714B)**: 헤딩 2개가 사라지는데 `harness/suites/go.sh:10`(라이브 스크립트)을 포함해 9~10곳이 「툴체인 섹션」을 **이름으로** 인용한다. 게다가 같은 압축이 **이미 죽은 포인터를 하나 만들었다** — go.sh:10이 가리키는 게이트 계산은 이미 툴체인 절에 없고 `rules/go.md:24`로 내려갔다.
- **툴체인 3열(250B)**: 게차 절 압축과 **순서 의존**이고, 두 포인터는 기능이 다르다(게차=이 게차의 상세 / 툴체인=이 언어의 명령 전집).

⚠️ **되살릴 조건**: 각각 — `checkLinks` 수정 + 유일 사실 2건 선보존 / 「현재 상태」 표 27셀을 `deploy-facts.sh`와 기계 대조로 먼저 묶고 「툴체인 섹션」 인용 9~10곳 정리 / 게차 절 최종 형태 확정 후.
</details>

⚠️ **상호배타 주의**: 게차의 중복 스텁 20건 삭제안(−2,485B)은 위 3열 삭제와 **함께 하면 안 된다** — 20건 중 18건의 "중복 자리"가 바로 그 3열이었다. 둘 다 하면 사실이 리포에서 소실된다.

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

⚠️ **어서션 수를 여기 적지 않는다** — 매 커밋 변하므로 적는 순간 낡는다. 각 스크립트가 말미에
`N passed, M failed`를 찍으니 **`M`이 0인지만** 본다(하한은 CI의 `--min-facts`/`--min-anchors`가
지킨다).

```bash
git log --oneline -6

# 셸 가드 — 인터프리터는 각 파일의 shebang을 따른다.
# ⚠️ test-install-verify.sh만 bash다(배열 사용). 나머지는 sh이고 CI의 /bin/sh는 dash이므로
#    로컬 검증도 dash로 한다 — 로컬 `sh`는 bash라 통과해도 CI에서 갈릴 수 있다.
for t in publication-claims security-defaults provenance-gate \
         harness-registries selftest-hygiene; do
  dash "scripts/test/test-$t.sh"
done
bash scripts/test/test-install-verify.sh

node scripts/check-docs.mjs . --strict --min-facts=49 --min-anchors=18
node --test harness/install/report/install-matrix.test.mjs \
            harness/report/score.test.mjs harness/security/verdict.test.mjs
```

가드 전건 목록과 CI 배선은 `.github/workflows/repo-hygiene.yml`이 진실 원천이다
(`test-selftest-hygiene.sh`가 **배선 누락 자체를 실패로 만든다** — 위 목록은 발췌다).

### 병행 진행 중인 다른 계획

[하네스 판정·출처 완결 계획](2026-08-12-harness-judgment-and-provenance-completion.md)의 Phase B~E가 남아 있다. ⚠️ 그 계획의 **S-B1(dotnet 레그 실패)은 위에 적은 이유로 틀렸다** — Task B1에 손대기 전에 CI 상태를 먼저 확인할 것. Task B0(런타임 행동 테스트)는 이번 세션에 임시로 쓴 "게이트 블록을 sed로 추출해 dash로 실행" 방식(`a96232c`·`d63e3aa`의 변이검증)을 저장소 테스트로 승격하는 일이고, 그 방식이 정적 가드가 못 잡는 결함을 **두 번** 실증했다.
