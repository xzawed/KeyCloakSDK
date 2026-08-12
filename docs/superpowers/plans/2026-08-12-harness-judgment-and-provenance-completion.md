# 하네스 판정 계층·출처 완결과 잔여 결함 정리 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설치 하네스가 "무엇을 재지 않았는지"를 스스로 알게 만들고(판정 공허성 제거), 아홉 언어 전부에 대해 "방금 만든 산출물을 검증했다"를 기계로 보증한 뒤, 교차검증에서 확정된 잔여 결함을 닫는다.

**Architecture:** 세 층을 순서대로 고친다 — (1) **판정 층**(`install-matrix.mjs`)이 기대 언어 집합을 요구하게 하고, (2) **관측 층**(`consume/*-run.sh`)의 빈 칸(node·rust·dotnet)을 채우고 java 단언을 id가 아닌 URL로 옮기고, (3) **가드 층**(`scripts/test/*`)이 그 둘을 우회 불가능하게 만든다. 각 단계는 실패하는 테스트 → 최소 구현 → 실측 순으로만 진행한다(TDD). 각 Phase는 독립 PR로 머지 가능하다.

**Tech Stack:** Node 22(ESM, `node:test` 없이 자체 assert 관용), POSIX sh(dash 호환), Docker(하네스 실행), 기존 자가테스트 틀 `scripts/test/assert.sh`.

## Global Constraints

- 자가테스트는 **dash**로 통과해야 한다(CI의 `/bin/sh`). 로컬 `sh`는 bash이므로 `dash scripts/test/<t>.sh`로 재확인한다.
- 새 가드는 반드시 3요건을 함께 보고한다: (a) 변이 시 실패 (b) 복원 시 통과 (c) **가드 비활성화 시 N건 실패**(N>0, 비공허성).
- 파괴적 명령(변이검증 포함) 전에 커밋한다. 복원은 역연산으로 하고 `git diff`가 빈 출력임을 확인한다.
  ⚠️ **따라서 각 Task의 단계 순서는 "구현 → 통과 확인 → **커밋** → 변이·비공허성 측정 → (필요시 측정 결과를 커밋 메시지에 반영해 amend)"이다.** 아래 Task 본문이 커밋을 마지막 Step에 두었더라도 이 제약이 우선한다 — Task A1 리뷰에서 실제로 이 충돌이 드러났다(커밋 없는 상태에서 변이해 `git diff` 빈 출력 확인이 불가능했다).
- 외부 도구·레지스트리 동작을 서술할 때는 그 문장을 검증하는 명령의 **실측 출력**을 함께 남긴다.
- 하네스 변경은 PR CI가 돌리지 않는다(`install-all`·`score-all`은 야간·수동 전용) — 각 Task는 해당 언어 레그를 **로컬에서 실제로 돌려** 통과를 확인해야 완료다.
- 버전·좌표 문자열은 새로 하드코딩하지 않는다. SSOT는 `scripts/lib/deploy-facts.sh`와 각 언어 매니페스트이며, 가드는 거기서 파생한다.

---

## File Structure

| 파일 | 책임 | Phase |
|---|---|---|
| `harness/install/report/install-matrix.mjs` | 기대 언어 집합 대비 **부재**를 실패로 판정 | A |
| `harness/install/report/install-matrix.test.mjs` | 위 판정의 회귀 고정 | A |
| `harness/install/consume/node-run.sh` | npm 설치 출처 기록·단언 | A |
| `harness/install/consume/rust-run.sh` | cargo 설치 출처 기록·단언 | A |
| `harness/install/consume/java-run.sh` | 저장소 **URL** 기준 단언으로 교정 | A |
| `scripts/test/test-harness-registries.sh` | 우회 경로(else 분기·후행 마커·공백 패턴) 차단 | A |
| `harness/install/lib/verify-lib.sh` (신규) | `install-verify.sh`에서 순수 함수 추출(테스트 가능화) | B |
| `scripts/test/test-install-verify.sh` (신규) | 위 순수 함수의 자가테스트 + CI 배선 | B |
| `harness/install/consume/dotnet-*.{sh,Dockerfile}`·`registries/` | bagetter 레그 복구 + 출처 단언 | B |
| `harness/install/consume/kotlin-app/build.gradle.kts` | `exclusiveContent`로 구조적 격리 전환 | B |
| `harness/apps/kotlin/Dockerfile` | 핀을 SSOT에서 파생(드리프트 표현 불가능화) | B |
| `scripts/test/test-publication-claims.sh` | 게시버전 문자열 가드를 12개 문서로 확장 | C |
| `scripts/check-versions.mjs` | 하네스 앱의 **제3자 좌표** 발산 검사(rust `keycloak`) | C |
| (Phase D는 검증 결과 확정 후 확정) | Go JWKS 기본값 정합 · PHP §4 문서 정합 | D |

---

## Phase A — 판정 층과 관측 층의 공백 (독립 PR 1)

### 사양 (SDD)

> **S-A1**: `install-matrix.mjs --strict`는 **기대 언어 집합**을 인자로 받고, 신호가 없는 언어를 `✗ (미측정)`으로 표에 적고 실패로 판정한다. 기대 집합은 오케스트레이터가 실제로 실행한 언어 목록이며 하드코딩하지 않는다.
> **근거(실측)**: 현재 `failedLangs([])` → `[]`, `failedLangs([go만])` → `[]`. 즉 아홉 중 여덟이 아예 실행되지 않아도 `--strict`가 exit 0이다.

> **S-A2**: 아홉 언어 **전부**의 consume 레그는 SDK 자기 좌표의 실제 다운로드 출처를 `$STATUS/provenance.txt`에 기록하고, 로컬 레지스트리가 아니면 `installed.ok`를 쓰지 않는다. 현재 node·rust·dotnet은 기록도 단언도 없다(`grep -c provenance` → 0/0/0).

> **S-A3**: java 단언은 저장소 **id**가 아니라 그 id의 `<url>`을 근거로 한다. 현재는 id 이름만 보므로 `<mirror><id>central-mirror</id><url>…apache.org…</url>`처럼 **다른 이름으로 Central을 가리키는** 항목이 통과한다.

> **S-A4**: 메타 가드는 (a) `else` 분기의 `PROVENANCE_OK=1` (b) 판정 뒤의 무조건 `installed.ok` 쓰기 (c) 아무것이나 매치하는 빈 패턴 grep 을 전부 거부한다. 현재 셋 다 통과한다(외부 검토 실측).

### Task A1: `--strict`가 부재를 실패로 본다

**Files:**
- Modify: `harness/install/report/install-matrix.mjs`
- Modify: `harness/install/report/install-matrix.test.mjs`
- Modify: `harness/install/install-verify.sh` (실행한 언어 목록을 매트릭스에 전달)

**Interfaces:**
- Produces: `failedLangs(signals, expectedLangs)` — `expectedLangs`가 주어지면 신호가 없는 언어를 실패 목록에 포함한다. 미지정 시 기존 동작(하위호환).

- [ ] **Step 1: 실패하는 테스트를 쓴다**

```js
// harness/install/report/install-matrix.test.mjs 에 추가
test("기대 언어에 신호가 없으면 실패로 잡는다(부재 = 미측정)", () => {
  const ok = (lang) => ({
    lang, artifactBuilt: true, published: true, installed: true,
    quickstartOk: true, appBoot: true,
    conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 },
  });
  // 아홉을 기대했는데 go 하나만 왔다 → 나머지 여덟이 실패여야 한다
  const failed = failedLangs([ok("go")], ["go", "dotnet", "node", "python", "java", "php", "rust", "ruby", "kotlin"]);
  assert.deepEqual(failed, ["dotnet", "node", "python", "java", "php", "rust", "ruby", "kotlin"]);
  // 대조군: 기대 집합을 주지 않으면 예전 동작 그대로(하위호환)
  assert.deepEqual(failedLangs([ok("go")]), []);
  // 대조군: 전부 왔으면 빈 배열
  const all = ["go", "dotnet"].map(ok);
  assert.deepEqual(failedLangs(all, ["go", "dotnet"]), []);
});
```

- [ ] **Step 2: 실패를 확인한다**

Run: `node --test harness/install/report/install-matrix.test.mjs`
Expected: FAIL — 현재 `failedLangs`는 인자를 하나만 받아 `["dotnet", …]` 대신 `[]`를 낸다.

- [ ] **Step 3: 최소 구현**

```js
export function failedLangs(signals, expectedLangs) {
  const failed = signals.filter((s) => { /* 기존 본문 그대로 */ }).map((s) => s.lang);
  if (!expectedLangs) return failed;                       // 하위호환: 기대 집합 미지정
  const seen = new Set(signals.map((s) => s.lang));
  // ⚠️ 부재는 "통과"가 아니라 "재지 않았다"이다 — 판정이 그것을 구분하지 못하면
  // 레지스트리가 안 떠서 여덟 언어가 통째로 빠진 실행도 초록이 된다(실측: failedLangs([]) === []).
  const missing = expectedLangs.filter((l) => !seen.has(l));
  return [...failed, ...missing];
}
```

- [ ] **Step 4: 통과를 확인한다**

Run: `node --test harness/install/report/install-matrix.test.mjs`
Expected: PASS (기존 테스트 포함 전부)

- [ ] **Step 5: 오케스트레이터가 기대 집합을 넘긴다**

`install-verify.sh`의 매트릭스 호출에 실행 언어를 넘긴다:
```sh
node report/install-matrix.mjs --strict --expect "$(printf '%s ' "${LANGS[@]}")"
```
`install-matrix.mjs`는 `--expect`를 공백 분리로 파싱해 `failedLangs(signals, expected)`에 넘기고, 표에는 부재 언어를 `✗ 미측정` 행으로 그린다.

- [ ] **Step 6: 실측 — 부재를 만들어 본다**

```bash
cd harness/install && mv report/signals/go.install.json /tmp/ \
  && node report/install-matrix.mjs --strict --expect "go python"; echo "exit=$?"   # 1 이어야 한다
mv /tmp/go.install.json report/signals/ && git diff --stat   # 빈 출력
```

- [ ] **Step 7: 비공허성 — 새 코드를 지우면 몇 건이 실패하는가**

`failedLangs`의 `missing` 병합을 지운 뒤 `node --test …` 실패 건수를 기록한다(0이면 이 테스트는 아무것도 지키지 않는다).

- [ ] **Step 8: 커밋**

```bash
git add harness/install/report/install-matrix.mjs harness/install/report/install-matrix.test.mjs harness/install/install-verify.sh
git commit -m "fix(harness): 부재를 통과로 읽던 판정 — 기대 언어 집합을 요구한다"
```

### Task A2: node 레그의 출처 기록·단언

**Files:**
- Modify: `harness/install/consume/node-run.sh`
- Modify: `scripts/test/test-harness-registries.sh` (대상 언어 목록 6 → 8)

**Interfaces:**
- Consumes: A1의 판정(변경 없음)
- Produces: `node-run.sh`가 `$STATUS/provenance.txt`에 tarball URL을 남기고 `PROVENANCE_OK` 게이트를 통과할 때만 `installed.ok`를 쓴다.

- [ ] **Step 1: 관측 지점을 실측으로 정한다(추측 금지)**

```bash
docker run --rm node:22-alpine sh -c \
  'npm install --registry https://registry.npmjs.org --json --dry-run @xzawed/keycloak-sdk@0.1.0-rc.2 2>/dev/null | head -40'
```
`npm install --json`의 `added[].resolved`(또는 `npm ls --json`의 `resolved`)가 실제 tarball URL을 담는지 확인하고, **출력을 그대로** 커밋 메시지에 남긴다.

- [ ] **Step 2: 가드에 node를 추가해 실패를 확인한다**

`scripts/test/test-harness-registries.sh`의 `for L in python java kotlin ruby php go` → `… node rust`로 넓히고 `assert_eq "6" "$prov_langs"` → `"8"`로 바꾼다.
Run: `sh scripts/test/test-harness-registries.sh`
Expected: FAIL — node·rust에 `provenance.txt`/`PROVENANCE_OK`가 없다(언어당 2건씩 4건).

- [ ] **Step 3: node-run.sh 구현**

`npm install` 뒤 `npm ls --json @xzawed/keycloak-sdk`(또는 Step 1이 확정한 지점)에서 `resolved`를 뽑아 `$STATUS/provenance.txt`에 쓰고, `$REG` 접두 전부일치 + tarball 양성조건으로 게이트한다(python-run.sh와 동형).

- [ ] **Step 4: 가드 통과 확인**

Run: `sh scripts/test/test-harness-registries.sh` → 통과(단, rust는 Task A3에서 채우므로 이 시점엔 rust 2건이 남는다 — A2·A3는 같은 PR에서 연속 수행한다)

- [ ] **Step 5: 레그 실측**

```bash
cd harness/install && ./install-verify.sh node
cat report/status/node/provenance.txt          # verdaccio 호스트여야 한다
node -e "console.log(require('./report/signals/node.install.json'))"   # installed·appBoot·26/26·9/9
```

- [ ] **Step 6: 커밋** — `git commit -m "test(harness): node 레그가 SDK를 어디서 받았는지 기록·단언한다 (#167)"`

### Task A3: rust 레그의 출처 기록·단언

**Files:** Modify `harness/install/consume/rust-run.sh`

- [ ] **Step 1: 관측 지점 실측** — `cargo build --offline` 트리에서 `cargo metadata --format-version 1`의 `packages[] | select(.name=="keycloak-sdk") | .source`가 로컬 레지스트리를 가리키는지 확인하고 출력을 남긴다. (`registries/rust-cargo-config.toml`의 `replace-with = "local"`이 이미 구조적 격리이므로 이 단계는 **그 격리가 실제로 발동했는지**를 증거로 남기는 일이다.)
- [ ] **Step 2:** 가드가 rust 2건으로 실패하는 것을 확인(A2 Step 2에서 이미 확장됨)
- [ ] **Step 3:** `rust-run.sh`에 기록·게이트 추가(다른 언어와 동형)
- [ ] **Step 4:** `sh scripts/test/test-harness-registries.sh` 통과(8개 언어)
- [ ] **Step 5:** `./install-verify.sh rust` 실측 — provenance가 `local` 소스, 신호 26/26·9/9
- [ ] **Step 6:** 커밋

### Task A4: java 단언을 저장소 URL 기준으로

**Files:** Modify `harness/install/consume/java-run.sh`

- [ ] **Step 1: 재현** — `java-settings.xml` 사본에 `<mirror><id>central-mirror</id><url>https://repo.maven.apache.org/maven2</url><mirrorOf>central</mirrorOf></mirror>`를 넣고, 현재 로직이 `_repo_ids`에 그 id를 포함시켜 `>central-mirror=` 기록을 통과시키는지 확인한다(거짓 통과 재현).
- [ ] **Step 2: 구현** — id마다 같은 블록의 `<url>`을 함께 뽑아, **로컬 레지스트리 호스트**(오케스트레이터가 주입하는 `REGISTRY_URL`의 호스트)와 일치하는 id만 후보로 삼는다.
- [ ] **Step 3: 대조군** — 원래 settings.xml에서 `mvn-repo`가 계속 뽑히는지, 위조 mirror가 거부되는지 둘 다 확인
- [ ] **Step 4:** `./install-verify.sh java` 실측 통과
- [ ] **Step 5:** 커밋

### Task A5: 메타 가드의 남은 우회 세 경로 차단

**Files:** Modify `scripts/test/test-harness-registries.sh`

- [ ] **Step 1: 세 변이를 재현한다**(각각 사본 트리에서, 현재 가드가 통과함을 먼저 보인다)
  1. `else` 분기에서 `PROVENANCE_OK=0` → `=1`
  2. 판정 블록 뒤에 무조건 `: > "$STATUS/installed.ok"` 한 줄 추가
  3. 근거 grep을 `grep -q '' "$STATUS/provenance.txt"`(아무것이나 매치)로 교체
- [ ] **Step 2: 구현** — (1) `PROVENANCE_OK=1`이 `else`와 같은 블록에 오면 거부 (2) `installed.ok` 쓰기는 **마지막 것**까지 게이트 뒤여야 한다(`tail -1`) (3) 근거 grep의 패턴이 비어 있으면 거부
- [ ] **Step 3:** 세 변이가 각각 1건 이상 실패하는지 확인하고 건수를 기록
- [ ] **Step 4:** 정상 트리에서 전건 통과 + `dash`로 재확인
- [ ] **Step 5:** 커밋

---

## Phase B — 하네스 복구·단순화 (독립 PR 2)

### 사양 (SDD)

> **S-B1**: dotnet install 레그가 초록으로 복귀한다. 현재 `signals/dotnet.install.json` = `{"installed":false,"error":"registry: bagetter 기동(docker compose up) 실패"}`이며 **2026-08-03부터 그 상태**다. 복구 후에는 다른 여덟과 같은 출처 단언을 갖는다.
> **S-B2**: kotlin 레그는 `--info` 로그 스크래핑 대신 Gradle `exclusiveContent`로 SDK 좌표를 로컬 저장소에만 묶는다(구조적 격리). 스크래핑 코드와 `--info` 플래그(로그 194배)를 제거한다.
> **S-B3**: `harness/apps/kotlin`의 SDK 핀은 빌드 시 SSOT에서 파생되어 **드리프트가 표현 불가능**해진다.
> **S-B4**: `install-verify.sh`의 순수 로직(`ver_for_lang`·기대 언어 집합·상태 초기화)은 Docker 없이 실행 가능한 자가테스트를 갖는다.

### Task B1: dotnet 레그 복구
- [ ] Step 1: `cd harness/install && docker compose -f compose.install.yml up bagetter` 를 직접 돌려 **실패 원문**을 확보한다(이미지 태그? 헬스체크? 포트?).
- [ ] Step 2: 원인에 맞춘 최소 수정(이미지 핀 갱신 또는 헬스체크 조건 완화 — 원문이 결정한다)
- [ ] Step 3: `./install-verify.sh dotnet` 실측 통과
- [ ] Step 4: 출처 단언 추가(A2와 동형; NuGet은 `packageSourceMapping`이 이미 격리이므로 관측은 `dotnet list package --include-transitive`/복원 로그에서 취한다 — 지점은 실측으로 정한다)
- [ ] Step 5: 가드 대상 9개 언어로 확장 + 커밋

### Task B2: kotlin `exclusiveContent` 전환
- [ ] Step 1: 사본에서 `exclusiveContent`가 fail-closed임을 재현(빈 로컬 저장소 → Central에 그 좌표가 실재해도 해석 실패)
- [ ] Step 2: `kotlin-app/build.gradle.kts`에 적용
- [ ] Step 3: `kotlin-run.sh`에서 `--info`·스크래핑·URL 파생 제거, provenance는 "격리 하에 해석 성공" 사실로 기록
- [ ] Step 4: `./install-verify.sh kotlin` 실측 + 로그 크기 전후 비교 기록
- [ ] Step 5: 커밋

### Task B3: 하네스 앱 핀을 SSOT에서 파생
- [ ] Step 1: `harness/apps/kotlin/Dockerfile`에 SDK 버전 치환 단계 추가(`consume/kotlin-run.sh`가 이미 쓰는 관용과 동형, 치환 실패 시 loud fail)
- [ ] Step 2: `harness/apps/java/pom.xml`도 같은 방식이 가능한지 판단(Maven은 `versions:set` 또는 property) — 불가하면 그 사실과 이유를 기록
- [ ] Step 3: `check-versions.mjs`의 harnessPins 검사는 **유지**한다(파생이 깨졌을 때의 이중 안전망)
- [ ] Step 4: kotlin 레그 실측 통과 + 커밋

### Task B0: 메타 가드를 **런타임 행동 테스트**로 옮긴다 (Phase A 잔여에서 승격)

> **S-B0**: 메타 가드는 consume 스크립트의 셸 **텍스트를 정적으로 분석**한다. Phase A에서 두 라운드에 걸쳐 7종 우회를 닫았지만, 적대적 재리뷰가 곧바로 4종을 더 찾았다 — `PROVENANCE_OK="1"`(따옴표라 정확일치 매처에 안 잡힘) · `[ … ] || PROVENANCE_OK=1`(`||`는 clause 분리 대상이 아님) · `REG=""` 그림자(변수명은 남아 근거 검사 통과, 실행 시엔 무조건 참) · 근거 grep을 "하나라도 로컬"로 약화(변수명은 그대로). **정적으로 임의 POSIX 셸의 의미를 증명하려는 시도라 수렴하지 않는다.**
> 대신 게이트를 **실행**해 판정한다: 합성 `provenance.txt`(로컬 URL + 외부 URL 혼재)를 주고 `PROVENANCE_OK`가 `0`이 되는지, 전부 로컬이면 `1`이 되는지 확인한다. 문법 회피에 면역이고 위 4종을 전부 잡는다.

- [ ] **Step 1:** 각 consume 스크립트의 게이트 블록을 실행 가능하게 만든다 — 센티널 주석(`# >>> provenance-gate` / `# <<< provenance-gate`)으로 감싸거나, 공유 함수로 추출한다. **동작은 바꾸지 않는다**(주석/추출만).
- [ ] **Step 2: 실패하는 테스트 먼저** — 8개 언어 각각에 대해 표를 만든다: (입력 provenance 내용, 기대 PROVENANCE_OK). 최소 4행: 전부 로컬 → 1 · 외부 한 줄 혼재 → 0 · 빈 파일 → 0 · 아티팩트 줄 없이 메타데이터만 → 0.
- [ ] **Step 3:** 테스트가 게이트 블록을 추출해 스텁 환경(`$STATUS`·`$REG` 등)에서 실행하도록 구현한다.
- [ ] **Step 4:** Phase A가 파킹한 4종 우회를 이 테스트에 걸어 **전부 잡히는지** 확인한다(정적 가드는 못 잡던 것들이다).
- [ ] **Step 5:** 정적 가드는 **남긴다**(둘은 다른 것을 지킨다 — 정적은 "게이트가 존재하고 판정에 배선됐다", 런타임은 "게이트가 실제로 옳게 판정한다").
- [ ] **Step 6:** 8개 언어 레그를 실제로 돌려 무회귀 확인 후 커밋.

### Task B4: `install-verify.sh` 자가테스트
- [ ] Step 1: 순수 함수를 `harness/install/lib/verify-lib.sh`로 추출(`install-verify.sh`는 소싱만)
- [ ] Step 2: `scripts/test/test-install-verify.sh` 작성 — 최소 케이스: 순서 의존 버전 누수 회귀(`java kotlin ruby php go` 순에서 go가 `0.1.0`), `--version` 명시 우선, 잘못된 버전 표기 거부
- [ ] Step 3: 실패 확인 → 추출 → 통과 확인
- [ ] Step 4: `repo-hygiene.yml`에 배선(`test-selftest-hygiene.sh`가 배선을 강제하므로 누락 시 CI가 잡는다)
- [ ] Step 5: 커밋

---

## Phase C — 문서·좌표 SSOT (독립 PR 3)

### 사양 (SDD)

> **S-C1**: 게시버전 문자열을 담은 **모든** 소비자 문서가 `df_published_version`과 대조된다. 현재 대상은 `getting-started.md` 호환성 표와 `DEPLOY.md` 설치 좌표뿐이고, 실측상 12개 문서가 버전 문자열을 갖는다(README×2·SECURITY·언어별 README 9).
> **S-C2**: 하네스 앱이 SDK와 **공유해야 하는 제3자 좌표**(rust `keycloak` crate)의 표기 발산을 가드가 잡는다. 현재 `rust/Cargo.toml`은 `~26.6.2`, `harness/apps/rust/Cargo.toml`과 `harness/install/quickstart/rust/Cargo.toml`은 `=26.6.2`이며, 두 파일의 주석은 "SDK와 동일해야 한다"고 적고 있다.

### Task C1: 게시버전 가드 확장
- [ ] Step 1: 12개 문서 각각에서 "버전을 주장하는 자리"를 열거하고, 그중 **소비자가 복사해 가는 자리**만 대상으로 정한다(변경 이력·인용문 제외)
- [ ] Step 2: 대상 자리마다 드리프트를 넣어 현재 가드가 통과함을 보인다(공허성 증명)
- [ ] Step 3: `test-publication-claims.sh`를 확장(파일·패턴을 표로 두고 `df_published_version`에서 파생)
- [ ] Step 4: 각 드리프트가 잡히는지 + 정상 트리 통과 + 비공허성 건수 기록
- [ ] Step 5: 커밋

### Task C2: 제3자 좌표 발산 가드
- [ ] Step 1: 현재 발산을 실측으로 보인다(`grep -n 'keycloak = ' rust/Cargo.toml harness/apps/rust/Cargo.toml harness/install/quickstart/rust/Cargo.toml`)
- [ ] Step 2: 테스트 먼저 — 픽스처에서 SDK가 `~26.7.0`인데 하네스가 `=26.6.2`면 실패해야 한다
- [ ] Step 3: `check-versions.mjs`에 "공유 제3자 좌표" 검사 추가(하네스 핀 검사와 같은 계급 = `harnessErrors`)
- [ ] Step 4: 현 상태를 어느 쪽으로 정렬할지 결정하고(SDK 쪽 `~`로 통일 권장) 실제로 정렬 + rust 레그 실측
- [ ] Step 5: 커밋

---

## Phase D — SDK·문서 정합 (독립 PR 4)

### 사양 (SDD)

> **S-D1**: JWKS 최소 재조회 간격의 기본값은 **정의 자리가 언어당 하나**여야 한다. 2026-07-31 정렬 커밋은 아홉 개의 *config* 파일만 만졌고 **JWKS 스토어/검증기 생성자의 2차 기본값은 남겨 두었다**. 실측:
> ```
> go/jwt.go:46                     opts.minRefetch = 60 * time.Second   (소비자 도달 불가 — withDefaults가 선행, 미노출)
> php/src/Jwks/JwksStore.php:28    $minRefetchIntervalSeconds = 60      (public final class — 소비자 도달 가능)
> ruby/lib/.../jwks_store.rb:11    min_refetch: 10.0                    (public class — 정렬 전 값 그대로)
> ```
> 어떤 언어도 2차 자리를 테스트하지 않으며(변이 실측: go의 60을 999로 바꿔도 `ok`), 리포 전체에 이 불변식을 겨누는 가드가 없다(`grep -rn "efetch" scripts/ .github/workflows/` → 0건).

> **S-D2**: `ruby/README.ko.md:72`가 소비자에게 `jwks_min_refetch` 기본값을 **`10.0`** 이라고 알려준다. 영문 미러 `ruby/README.md:70`은 30초라고 적는다. CLAUDE.md의 문서 언어 규칙상 두 README는 **동일 구조의 미러**여야 하므로 이는 미러 파손이자 소비자 오도다.

> **S-D3**: CLAUDE.md §4의 "**아홉 언어 공통** — `TokenProvider`가 유일한 접착제"는 실제로 **5개 언어에만** 참이다(Node·Rust·Ruby·.NET·Go). Java·Kotlin·PHP·Python은 admin이 토큰을 자체 소유하며, 그중 **PHP·Python은 §4 이탈 표에 행이 없다**. Python은 `TokenProvider` 추상 자체가 존재하지 않는다(`grep -rn TokenProvider python/src/` → 0건). PHP `Admin/AdminClient.php`의 유일한 생성자는 `KeycloakConfig`만 받아 **소비자가 토큰 소스를 주입할 수단이 없다**.
> 추가로 `docs/superpowers/specs/2026-07-06-keycloak-php-sdk-design.md:67`은 "fschmtt `TokenStorageInterface`에 우리 `ClientCredentialsTokenProvider` 배선"이라고 **없는 사실**을 적고 있으며, 같은 문서 `:70`이 스스로 반박한다.

### Task D1: 2차 기본값 제거(정의 자리를 언어당 하나로)

**Files:** Modify `ruby/lib/keycloak_sdk/jwks_store.rb`, `php/src/Jwks/JwksStore.php`, `go/jwt.go` · Test: `ruby/spec/unit/jwks_store_spec.rb`, `php/tests/Unit/Jwks/JwksStoreTest.php`, `go/jwt_test.go`

- [ ] **Step 1: 실패하는 테스트(ruby)** — 인자를 **생략**했을 때의 기본값을 고정한다
```ruby
it "기본 min_refetch는 config 기본값과 같다(2차 정의 자리 금지)" do
  store = described_class.new(jwks_url: "https://idp/jwks", http: http_double)
  expect(store.min_refetch).to eq(KeycloakSdk::Config::DEFAULT_JWKS_MIN_REFETCH)
end
```
- [ ] **Step 2: 실패 확인** — `cd ruby && bundle exec rspec spec/unit/jwks_store_spec.rb` → `10.0 != 30.0`
- [ ] **Step 3: 구현** — 2차 리터럴을 지우고 config의 상수를 참조한다(PHP·Go도 동형: 상수/설정에서 읽거나 인자 필수화)
- [ ] **Step 4: 통과 확인 + 세 언어 각각의 기존 테스트 전건 통과**
- [ ] **Step 5: 비공허성** — 상수를 999로 바꾸면 세 언어에서 각각 몇 건이 실패하는지 기록
- [ ] **Step 6: 커밋**

### Task D2: 불변식을 리포 가드로 승격

**Files:** Modify `scripts/check-docs.mjs` 또는 신규 `scripts/test/test-jwks-refetch-invariant.sh`

- [ ] **Step 1:** 아홉 언어의 기본값 정의 자리를 열거하는 테이블을 하나 만들고(파일·정규식), 그 값이 전부 같은지 검사하는 테스트를 **먼저** 쓴다
- [ ] **Step 2:** 현재 트리에서 실패하는지 확인(D1 이전이면 3건 실패 — D1 이후엔 통과해야 한다)
- [ ] **Step 3:** 구현 + `repo-hygiene.yml` 배선
- [ ] **Step 4:** 변이 — 한 언어의 값을 바꾸면 잡히는지 + 가드 비활성화 시 실패 건수
- [ ] **Step 5:** 커밋

### Task D3: ruby README 미러 복구

- [ ] **Step 1:** `ruby/README.ko.md:72`의 `10.0` → `30.0`으로 고치고, 영문 미러와 **같은 구조인지** 두 파일을 나란히 확인
- [ ] **Step 2:** 같은 부류 재스캔 — 아홉 언어 README에서 기본값을 주장하는 자리를 전부 뽑아 실제 코드값과 대조(수치가 다른 것이 더 있는지)
- [ ] **Step 3:** 발견분 수정 + 재스캔 명령·히트 수를 커밋에 기록
- [ ] **Step 4:** 커밋

### Task D4: §4 계약 문서를 코드에 맞춘다

- [ ] **Step 1:** `CLAUDE.md`의 "아홉 언어 공통" 문장을 사실대로 고친다 — provider가 유일 접착제인 언어(Node·Rust·Ruby·.NET·Go)와 admin이 토큰을 자체 소유하는 언어(Java·Kotlin·PHP·Python)를 나눈다
- [ ] **Step 2:** §4 이탈 표에 **PHP·Python 행 추가**(PHP: fschmtt `GrantType::clientCredentials`, 소비자 주입 수단 없음 / Python: `TokenProvider` 추상 자체가 없음, python-keycloak `KeycloakAdmin`이 자체 그랜트)
- [ ] **Step 3:** `docs/superpowers/specs/2026-07-06-keycloak-php-sdk-design.md:67`의 거짓 문장을 `:70`과 일치하도록 정정
- [ ] **Step 4:** `docs/governance/verification-log-php.md:69`의 "TokenProvider만 접착제" 과장 정정
- [ ] **Step 5:** `check-docs.mjs` 앵커로 기계 대조가 가능한 부분이 있는지 판단(§4 표는 산문이라 스코프 밖일 수 있다 — 그러면 그 사실을 명시한다)
- [ ] **Step 6:** 커밋

⚠️ **D4는 "코드를 문서에 맞추는" 선택지도 있다** — PHP는 fschmtt `Builder::withTokenStorage()` 시임이 실재하므로 배선이 가능하다. 그러나 그것은 동작 변경이고 통합 테스트가 필요하다. **기본 선택은 문서 정정**이며, 배선은 별도 결정으로 남긴다.

---

## Phase E — 사람 게이트 (계획만, 에이전트 수행 불가)

- **Go 첫 게시**: `git tag go/v0.1.0-rc.1 && git push origin go/v0.1.0-rc.1`. 선행조건은 충족됐다(#167 출처 단언·file GOPROXY 관측). 되돌릴 수 없다 — 회수 수단은 후속 릴리스의 `retract`뿐.
- **`dispatch-release.yml` 활성화**: GitHub App 생성 → `RELEASE_APP_ID`/`RELEASE_APP_PRIVATE_KEY` 등록 → `tags-create.json` bypass에 App(Integration) 추가(⚠️ **`tags-create.json`에만** — 나머지 둘에 넣으면 태그 불변성의 유일한 서버측 집행 지점이 무너진다).

---

## Self-Review

- **사양 커버리지**: S-A1→A1, S-A2→A2·A3(+B1의 dotnet), S-A3→A4, S-A4→A5, S-B1→B1, S-B2→B2, S-B3→B3, S-B4→B4, S-C1→C1, S-C2→C2. Phase D는 검증 미완이라 사양을 비워 두었다(placeholder가 아니라 **명시적 미확정**).
- **관측 지점 미확정 3곳**(node·rust·dotnet)은 각 Task의 Step 1에서 **실측으로 정하도록** 절차를 박아 두었다 — 추측으로 코드를 쓰지 않기 위함이다.
- **타입/이름 일관성**: `failedLangs(signals, expectedLangs)` · `$STATUS/provenance.txt` · `PROVENANCE_OK` 세 이름이 모든 Task에서 동일하다.
