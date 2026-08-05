# PR 0 — 검증 게이트를 진짜로 만들기 · 구현 계획

> <!-- doc-status: complete -->
> **✅ 완료된 계획 — 기록이다. 실행하지 말 것.** 아래 체크박스는 **전부 미체크로 남아 있지만 할 일이
> 아니다** — 실행 당시 갱신되지 않았을 뿐 작업은 끝났다. 바로 아래의 "For agentic workers" 지시도
> 그때의 것이라 지금은 유효하지 않다. 지금 상태는 [CLAUDE.md](../../../CLAUDE.md) ·
> [구현 이력](../../governance/history.md) · [문서 지도](../../README.md)에 있다.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 하네스와 CI의 검증 게이트가 실제로 실패를 거부하도록 고치고, 각 게이트가 "고의로 깨뜨리면 빨개진다"를 변이 테스트로 증명한다.

**Architecture:** 지금 CI가 초록인 이유가 코드 품질 때문인지 게이트 무력화 때문인지 구별할 수 없다. 세 종류의 무력화가 있다 — (1) 실패 신호를 계약에 담지 않음(suite 스크립트가 테스트 종료코드를 버림), (2) 실패를 성공으로 오분류함(security 프로브가 5xx를 방어 성공으로 셈), (3) 실패를 종료코드로 전파하지 않음(`|| true`, 무조건 `exit 0`, fail-open 커버리지 게이트). 순서가 중요하다: 먼저 실행 가능하게 만들고(실행비트), 실제 CI 결과를 **관측**한 뒤, 게이트를 조인다. 관측 전에 조이면 무엇이 원래 깨져 있었는지 알 수 없다.

**Tech Stack:** bash (POSIX + bash 확장) · Node.js 20 내장 테스트 러너(`node --test`) · GitHub Actions · Docker(Alpine/musl 컨테이너)

## Global Constraints

- 리포는 **아직 배포된 적이 없다**(`git tag -l` = 0). 소비자 0명.
- **I1**: 모든 게이트는 변이 테스트(고의 파손 → 빨개짐 확인 → 되돌림)로 증명한 뒤에만 신뢰한다.
- **I3**: 수정에는 실패하는 테스트가 선행한다. RED를 눈으로 확인하고 GREEN으로 만든다.
- 하네스의 모든 앱·레지스트리 컨테이너는 **Alpine(musl)** 베이스다. Debian/glibc 이미지는 Windows Docker Desktop의 DNS 프록시와 충돌한다.
- 루트 `.gitattributes`가 `*.sh text eol=lf`를 강제한다. 셸 스크립트를 CRLF로 저장하지 말 것.
- Windows 로컬에서는 `core.fileMode`가 무시되므로 파일시스템 `chmod`는 git 인덱스에 반영되지 않는다. **반드시 `git update-index --chmod=+x`를 쓴다.**
- 로컬(Windows Docker Desktop)은 바인드마운트 소유권을 마스킹한다. 소유권 관련 수정은 **로컬에서 검증할 수 없고** `workflow_dispatch`로 실제 Linux CI를 돌려야 한다(잡 1회 약 18분).
- 브랜치: `fix/pr0-verification-gates` (main에서 분기). push는 사람이 지시할 때만.
- 커밋 메시지는 한국어 conventional commit.

## 참조

- 설계: [docs/superpowers/specs/2026-07-10-pre-release-hardening-design.md](../specs/2026-07-10-pre-release-hardening-design.md) §4
- 근거 CI 실행: `gh run view 28993852934`(2026-07-09 야간), `28916638431`(07-08)

---

## File Structure

### 신규 생성

| 파일 | 책임 |
|---|---|
| `harness/security/verdict.mjs` | HTTP 상태코드 → 거부/통과/크래시 판정. 순수 함수만. probe.mjs가 import한다. |
| `harness/security/verdict.test.mjs` | 위 함수의 단위 테스트. |
| `.github/workflows/repo-hygiene.yml` | 리포 위생 가드. 현재는 "추적되는 모든 `*.sh`는 실행비트를 가진다" 한 가지. push/PR마다 실행. |

### 수정

| 파일 | 변경 |
|---|---|
| `harness/suites/{go,node,python,dotnet,php,rust,ruby,java,kotlin}.sh` | 종료코드를 파싱해 `"testsPassed"` 필드를 JSON 신호에 추가 |
| `harness/report/score.mjs` | 커버리지 크레딧을 `su.ran && su.testsPassed`로 게이팅 |
| `harness/report/score.test.mjs` | `testsPassed:false`면 커버리지 0점임을 검증 |
| `harness/security/probe.mjs` | `expectReject` 판정을 `verdict.mjs`에 위임, 5xx는 크래시로 집계 |
| `harness/install/report/install-matrix.mjs` | `--strict` 플래그: 매트릭스에 `✗`가 있으면 exit 1 |
| `harness/install/report/install-matrix.test.mjs` | `--strict` 판정 함수 테스트 |
| `harness/install/install-verify.sh` | 무조건 `exit 0` 제거, 매트릭스 실패를 종료코드로 전파 |
| `harness/install/publish/java.sh` | 산출물 추출을 `docker cp` → tar 스트림으로 교체 + 소유권 진단·정규화 |
| `harness/install/publish/php.sh` | satis 컨테이너에 `safe.directory` 예외 주입 |
| `harness/verify.sh` | 언어별 실패를 누적해 종료코드로 전파 |
| `.github/workflows/php-ci.yml` | 커버리지 게이트의 fail-open(`statements==0` → 100%) 제거 |
| 추적되는 `*.sh` 14개 | 실행비트(100644 → 100755) |

---

## Task 1: 실행비트 부여 + CI 회귀 가드

`harness/verify.sh`가 모드 `100644`로 커밋되어 있어 `.github/workflows/harness.yml:58`의 `./verify.sh …`가 리눅스 러너에서 `exit 126`(Permission denied)으로 즉사한다. 야간 `score-all` 잡은 도입(PR #20) 이래 **한 번도 성공한 적이 없다**. `harness/suites/kotlin.sh`는 `run-suite.sh:30`의 `[ -x … ]` 테스트를 통과하지 못해 **조용히 스킵**된다. `scripts/release-readiness.sh`는 `DEPLOY.md`가 `./scripts/…`로 실행하라고 안내하는데 Linux/macOS에서 실패한다.

이 태스크가 먼저 와야 이후 태스크가 CI에서 관측 가능해진다.

**Files:**
- Create: `.github/workflows/repo-hygiene.yml`
- Modify (mode only): 아래 14개 파일

**Interfaces:**
- Produces: 리눅스에서 `./harness/verify.sh`가 실행 가능해진다. Task 3의 CI 관측이 이에 의존한다.

- [ ] **Step 1: 실패하는 가드를 손으로 실행해 RED를 확인한다**

Run:
```bash
cd /d/Source/KeyCloakSDK
git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }'
```

Expected: 아래 14줄이 출력된다(순서 무관).
```
.scamanager/install-hook.sh
harness/install/consume/kotlin-run.sh
harness/install/lib.sh
harness/install/publish/kotlin.sh
harness/suites/kotlin.sh
harness/verify.sh
scripts/lib/deploy-facts.sh
scripts/release-readiness.sh
scripts/release-trigger.sh
scripts/test/assert.sh
scripts/test/test-deploy-facts.sh
scripts/test/test-deploy-md.sh
scripts/test/test-release-readiness.sh
scripts/test/test-release-trigger.sh
```

- [ ] **Step 2: 가드 워크플로를 추가한다**

Create `.github/workflows/repo-hygiene.yml`:

```yaml
name: repo-hygiene

on:
  push:
  pull_request:

jobs:
  shell-exec-bits:
    # 추적되는 모든 *.sh는 실행비트(100755)를 가져야 한다.
    #
    # 왜 예외 없이 전부인가: `harness/install/lib.sh`와 `scripts/lib/deploy-facts.sh`는
    # `.`(source)로만 쓰이므로 원칙적으로 실행비트가 필요 없다. 그러나 "source 전용"과
    # "실행 전용"을 사람이 구분해 유지하는 규칙은 반드시 썩는다 — 실제로 이 리포에서
    # `harness/verify.sh`(명백한 실행 스크립트)가 100644로 커밋되어 야간 CI가 3개월간
    # exit 126으로 죽어 있었다. 예외 없는 규칙이 유지 비용이 0이고, source되는 파일에
    # 실행비트가 붙어도 해롭지 않다.
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: 추적되는 *.sh 의 실행비트 확인
        run: |
          NON_EXEC="$(git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }')"
          if [ -n "$NON_EXEC" ]; then
            echo "::error::실행비트가 없는 셸 스크립트가 있습니다. \`git update-index --chmod=+x <file>\` 로 고치세요."
            echo "$NON_EXEC" | sed 's/^/  /'
            exit 1
          fi
          echo "추적되는 *.sh $(git ls-files -- '*.sh' | wc -l)개 전부 실행비트 있음"
```

- [ ] **Step 3: 14개 파일에 실행비트를 부여한다**

Windows에서 파일시스템 `chmod`는 git 인덱스에 반영되지 않는다. `git update-index`를 쓴다.

Run:
```bash
cd /d/Source/KeyCloakSDK
git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }' | while read -r f; do
  git update-index --chmod=+x "$f"
done
```

- [ ] **Step 4: 가드가 통과하는지 확인한다(GREEN)**

Run:
```bash
cd /d/Source/KeyCloakSDK
git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }'
echo "non-exec 파일 수: $(git ls-files -s -- '*.sh' | awk '$1 == "100644"' | wc -l)"
```

Expected:
```
non-exec 파일 수: 0
```

- [ ] **Step 5: 커밋**

`git update-index --chmod=+x`는 이미 인덱스를 바꿨으므로 해당 파일들은 별도 `git add` 없이 스테이징되어 있다.

```bash
git add .github/workflows/repo-hygiene.yml
git commit -m "fix(ci): 셸 스크립트 실행비트 14개 부여 + 회귀 가드

harness/verify.sh가 100644로 커밋되어 야간 score-all 잡이 ./verify.sh에서
exit 126으로 즉사해 왔다(PR #20 도입 이래 3회 연속 실패, SCORECARD가 CI에서
단 한 번도 생성된 적 없음). harness/suites/kotlin.sh는 run-suite.sh의 [ -x ]
게이트를 통과하지 못해 조용히 ran:false로 스킵됐고, scripts/release-readiness.sh는
DEPLOY.md가 안내하는 ./scripts/… 호출이 리눅스에서 실패한다.

Windows는 core.fileMode를 무시하므로 git update-index --chmod=+x 로 인덱스 모드를
직접 바꿨다. 재발 방지를 위해 repo-hygiene 워크플로가 push/PR마다 추적되는 모든
*.sh의 모드를 검사한다."
```

---

## Task 2: java/php install publish의 CI 전용 실패 수정

2026-07-08·07-09 야간 CI 아티팩트 `INSTALL-MATRIX.md` 두 건 모두에서 java·php가 `publish` 단계 `✗`다. 로컬(Windows Docker Desktop)은 바인드마운트 소유권을 마스킹해 통과하므로 드러나지 않았다.

**java의 실제 실패 로그** (run 28993852934, install-all 잡):
```
[INFO] BUILD SUCCESS
[publish/java] 3/4 빌드 산출물(staging-m2) 추출
mkdir /home/runner/work/KeyCloakSDK/KeyCloakSDK/harness/install/publish/out/java/staging-m2/com: permission denied
[publish/java] 예상 산출물 누락: io/github/xzawed/keycloak-sdk-parent/0.1.0/keycloak-sdk-parent-0.1.0.pom
… (8종 전부 누락)
[publish/java] 필수 아티팩트 누락 — 게시 실패로 간주
```

**php의 실제 실패 로그**:
```
In Git.php line 54:
  The repository at "/build/php-src" does not have the correct ownership and git refuses to use it:
  fatal: detected dubious ownership in repository at '/build/php-src'
  To add an exception for this directory, call:
      git config --global --add safe.directory /build/php-src
[publish/php] satis build 실패
```

**⚠️ java의 정확한 메커니즘은 미확정이다.** 오류 문구는 `docker cp`(Go의 `os.MkdirAll`)가 낸 것이지 coreutils `mkdir`이 낸 것이 아니다. 바로 앞줄의 `mkdir -p "$STAGING_DIR"`(java.sh)는 성공한 것으로 보이는데, 그렇다면 `staging-m2`는 runner 소유여서 쓰기 가능해야 한다. 누가 그 디렉터리(또는 그 부모 `publish/out`)를 root 소유로 만드는지는 CI 로그로 확정해야 한다. 따라서 이 태스크는 **진단 출력을 먼저 넣고**, 모든 가설을 덮는 수정을 함께 적용한다.

**Files:**
- Modify: `harness/install/publish/java.sh` (3/4 추출 단계)
- Modify: `harness/install/publish/php.sh:70` (satis build)

**Interfaces:**
- Produces: 리눅스 CI에서 `install-verify.sh java` · `install-verify.sh php`가 publish 단계를 통과한다. Task 8(install-all strict)이 이에 의존한다 — 이걸 먼저 고치지 않고 strict를 켜면 CI가 즉시 빨개진다.

- [ ] **Step 1: java.sh 추출 단계에 진단 + tar 스트림 + 소유권 정규화를 적용한다**

`harness/install/publish/java.sh`에서 아래 블록을 찾는다:

```bash
log "3/4 빌드 산출물(staging-m2) 추출"
# mkdir을 빌드 시작 전이 아니라 여기(docker cp 직전)에서 한다: 이 하네스는 harness/install/publish/out/
# 아래를 여러 언어 태스크가 각자의 서브디렉터리(out/java, out/dotnet, out/php ...)에 병행해 쓰는 공유
# 트리다. mkdir과 docker cp 사이에 90초+ 걸리는 mvn 빌드가 끼어 있으면 그 창 동안 디렉터리가(다른
# 작업의 광범위한 정리 등으로) 사라질 여지가 실측으로 확인됐다 — mkdir을 추출 직전으로 옮겨 그 창을 사실상
# 없앤다.
mkdir -p "$STAGING_DIR"
docker cp "$BUILDER_CONTAINER:/work/staging-m2/." "$(hostpath "$STAGING_DIR")/"
```

아래로 교체한다:

```bash
log "3/4 빌드 산출물(staging-m2) 추출"
# mkdir을 빌드 시작 전이 아니라 여기(추출 직전)에서 한다: 이 하네스는 harness/install/publish/out/
# 아래를 여러 언어 태스크가 각자의 서브디렉터리(out/java, out/dotnet, out/php ...)에 병행해 쓰는 공유
# 트리다. mkdir과 추출 사이에 90초+ 걸리는 mvn 빌드가 끼어 있으면 그 창 동안 디렉터리가(다른
# 작업의 광범위한 정리 등으로) 사라질 여지가 실측으로 확인됐다 — mkdir을 추출 직전으로 옮겨 그 창을 사실상
# 없앤다.
#
# ⚠️ 리눅스 CI 전용 게차: 이 공유 트리(publish/out)는 다른 언어의 publish 스크립트가 루트로 도는
# 컨테이너에 바인드마운트로 넘긴다(예: dotnet.sh의 `-o /out`). 그 결과 out/ 이하가 root 소유가 되어
# runner(uid 1001)가 하위 디렉터리를 만들지 못하고, `docker cp`가
# `mkdir …/staging-m2/com: permission denied`로 실패한다(2026-07-08·07-09 야간 CI 실측).
# Windows Docker Desktop은 바인드마운트 소유권을 마스킹하므로 로컬에서는 재현되지 않는다.
#
# 두 가지로 막는다:
#  (1) 추출 직전에 out/ 트리의 소유권을 현재 사용자로 정규화한다(리눅스에서만 의미가 있다).
#  (2) `docker cp`(호스트 경로에 직접 mkdir) 대신 **tar 스트림**으로 받아 호스트 `tar`가 현재 사용자
#      권한으로 풀게 한다. 이렇게 하면 추출이 컨테이너가 만든 소유권에 의존하지 않는다.
OUT_ROOT="$INSTALL_DIR/publish/out"
log "[publish/java] 추출 전 소유권 진단 (uid=$(id -u) gid=$(id -g))"
ls -ld "$OUT_ROOT" "$OUT_ROOT/java" "$STAGING_DIR" 2>&1 | sed 's/^/  /' || true

if [ "$(uname -s)" = "Linux" ]; then
  log "[publish/java] out/ 트리 소유권 정규화 (root 컨테이너 → $(id -u):$(id -g))"
  docker run --rm -v "$(hostpath "$OUT_ROOT"):/out" alpine:3.20 \
    chown -R "$(id -u):$(id -g)" /out || log "[publish/java] 소유권 정규화 실패(무시하고 계속)"
fi

mkdir -p "$STAGING_DIR"
find "$STAGING_DIR" -mindepth 1 -delete

# `docker cp <container>:<path> -` 는 tar 아카이브를 stdout으로 스트림한다. 호스트 tar가 현재
# 사용자 권한으로 풀므로 컨테이너 측 소유권(root)이 호스트에 전파되지 않는다.
# --strip-components=1 은 아카이브 최상위 `staging-m2/` 를 벗긴다.
if ! docker cp "$BUILDER_CONTAINER:/work/staging-m2" - | tar -x --strip-components=1 -C "$STAGING_DIR"; then
  log "[publish/java] 산출물 추출 실패(tar 스트림)"
  exit 1
fi
```

- [ ] **Step 2: php.sh satis 실행에 safe.directory 예외를 주입한다**

`harness/install/publish/php.sh:70`을 찾는다:

```bash
if ! docker run --rm -v "$(hostpath "$WORK_DIR"):/build" "$SATIS_IMAGE" build satis.json output; then
```

아래로 교체한다:

```bash
# ⚠️ 리눅스 CI 전용 게차: satis는 /build/php-src를 git 저장소로 읽는데, 바인드마운트된 디렉터리의
# 소유자(호스트 runner uid)와 컨테이너 프로세스 uid가 달라 git이 `detected dubious ownership`으로
# 거부한다(2026-07-08·07-09 야간 CI 실측). Windows Docker Desktop은 소유권을 마스킹해 로컬에서는
# 재현되지 않는다. GIT_CONFIG_COUNT/KEY/VALUE 환경변수(git ≥ 2.31)로 safe.directory 예외를 주입한다 —
# 이미지에 파일을 굽거나 --global 설정을 실행할 필요가 없다.
if ! docker run --rm \
    -e GIT_CONFIG_COUNT=1 \
    -e GIT_CONFIG_KEY_0=safe.directory \
    -e GIT_CONFIG_VALUE_0='*' \
    -v "$(hostpath "$WORK_DIR"):/build" "$SATIS_IMAGE" build satis.json output; then
```

- [ ] **Step 3: 로컬에서 회귀가 없는지 확인한다**

로컬(Windows)에서는 원래 통과했으므로 여기서 확인하는 것은 **수정이 로컬을 깨뜨리지 않았는가**뿐이다. CI 전용 결함의 해소는 Task 3에서 확인한다.

Run (Docker 필요, 약 8분):
```bash
cd /d/Source/KeyCloakSDK/harness/install && ./install-verify.sh java php
```

Expected: `report/INSTALL-MATRIX.md`의 java·php 행이 모두 `✓ ✓ ✓ ✓ ✓ 26/26 9/9`.

Run:
```bash
cat /d/Source/KeyCloakSDK/harness/install/report/INSTALL-MATRIX.md
```

- [ ] **Step 4: 커밋**

```bash
git add harness/install/publish/java.sh harness/install/publish/php.sh
git commit -m "fix(install-harness): java/php publish의 리눅스 CI 전용 소유권 실패 수정

야간 CI(2026-07-08·07-09) INSTALL-MATRIX.md 두 건 모두에서 java·php가 publish
단계 ✗였으나, 잡이 설계상 exit 0이라 조용히 초록으로 표시됐다.

- java: 공유 트리 publish/out 이 root 소유 컨테이너 마운트로 오염되어 docker cp가
  mkdir …/staging-m2/com: permission denied 로 실패. 추출 전 소유권을 정규화하고,
  docker cp를 tar 스트림으로 바꿔 호스트 tar가 현재 사용자 권한으로 풀게 한다.
- php: satis 컨테이너의 git이 /build/php-src 를 dubious ownership으로 거부.
  GIT_CONFIG_COUNT/KEY/VALUE 로 safe.directory 예외를 주입한다.

Windows Docker Desktop은 바인드마운트 소유권을 마스킹해 로컬에서는 둘 다 재현되지
않는다. 실제 해소 확인은 workflow_dispatch로 install-all 잡을 돌려 수행한다."
```

---

## Task 3: 첫 CI 관측 — 무엇이 원래 깨져 있었는지 기록한다

게이트를 조이기 전에 **지금 실제로 무엇이 실패하는지** 알아야 한다. Task 1로 `verify.sh`가 처음으로 실행 가능해졌고, Task 2로 install publish가 고쳐졌다. 이 상태에서 야간 잡을 수동 실행해 진짜 결과를 본다.

이 태스크는 코드를 바꾸지 않는다. **관측과 기록**이 산출물이다.

**Files:**
- Create: `docs/superpowers/plans/2026-07-10-pr0-baseline-observation.md` (관측 결과 기록)

**Interfaces:**
- Consumes: Task 1(실행비트), Task 2(publish 수정)
- Produces: Task 8·9의 strict 게이트가 켜졌을 때 CI가 빨개질지 초록일지에 대한 사실. 예상 밖 실패가 있으면 그건 PR 1~6의 결함이며 여기서 발견한다.

- [ ] **Step 1: 브랜치를 push하고 harness 워크플로를 수동 실행한다**

```bash
git push -u origin fix/pr0-verification-gates
gh workflow run harness.yml --ref fix/pr0-verification-gates
```

- [ ] **Step 2: 실행이 끝날 때까지 기다린다 (약 60분 — install-all 90분 타임아웃)**

```bash
RUN_ID=$(gh run list --workflow=harness.yml --branch fix/pr0-verification-gates --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID"
```

- [ ] **Step 3: 잡별 결과와 아티팩트를 회수한다**

```bash
gh run view "$RUN_ID" --json jobs --jq '.jobs[] | "\(.name)\t\(.conclusion)"'
gh run download "$RUN_ID" -n install-matrix -D /tmp/pr0-obs/install
gh run download "$RUN_ID" -n scorecard    -D /tmp/pr0-obs/score
gh run download "$RUN_ID" -n signals      -D /tmp/pr0-obs/signals
cat /tmp/pr0-obs/install/INSTALL-MATRIX.md
cat /tmp/pr0-obs/score/SCORECARD.md
```

Expected: `score-all` 잡이 **처음으로** `exit 126` 없이 진행되고 `SCORECARD.md`가 생성된다. `INSTALL-MATRIX.md`의 java·php 행이 `✓`.

- [ ] **Step 4: 관측 결과를 문서로 기록한다**

Create `docs/superpowers/plans/2026-07-10-pr0-baseline-observation.md`:

```markdown
# PR 0 기준선 관측 (Task 3)

- 실행: `gh run view <RUN_ID>` · 브랜치 `fix/pr0-verification-gates` · 날짜 <YYYY-MM-DD>
- 목적: 게이트를 조이기 **전** 하네스가 실제로 무엇을 보고하는지 기록한다.

## 잡 결과

| 잡 | 결론 | 비고 |
|---|---|---|
| mvp-go | | |
| all-langs | | |
| score-all | | **최초 실행** — 이전 3회는 exit 126 |
| install-all | | java·php publish 수정 후 최초 |

## INSTALL-MATRIX.md (원문 붙여넣기)

## SCORECARD.md (원문 붙여넣기)

## 발견된 실제 실패

<여기에 나열. 각 항목이 PR 1~6 중 어디에 속하는지 표시. 없으면 "없음"이라고 쓴다.>

## 결론

Task 8·9에서 strict 게이트를 켜면 이 실행 기준으로 CI가 <초록|빨강>이 될 것이다.
```

- [ ] **Step 5: 커밋**

```bash
git add docs/superpowers/plans/2026-07-10-pr0-baseline-observation.md
git commit -m "docs(plan): PR 0 기준선 관측 — 게이트를 조이기 전 CI 실제 결과 기록

Task 1(실행비트)로 verify.sh가 처음으로 실행 가능해지고 Task 2(publish 소유권)로
install-all이 고쳐진 상태에서, 야간 잡을 수동 실행해 하네스가 실제로 무엇을
보고하는지 기록한다. 게이트를 먼저 조이면 원래 깨져 있던 것과 새로 깨진 것을
구별할 수 없다."
```

---

## Task 4: score.mjs가 테스트 실패를 커버리지 0점으로 처리한다

`harness/report/score.mjs:20`의 커버리지 크레딧은 오직 `su.ran`에만 걸려 있는데, suite 스크립트 9개 전부가 그 값을 `true` 리터럴로 출력한다. 어느 언어의 단위테스트가 깨져도 커버리지 만점이 유지되고 SCORECARD 등급이 변하지 않는다.

먼저 소비자(score.mjs)를 고친다. 생산자(suite 스크립트)는 Task 5에서 고친다. 이 순서인 이유: `su.testsPassed`가 `undefined`인 기존 신호는 falsy이므로 커버리지 0점이 되어, Task 5 이전에는 스코어카드가 **의도적으로** 보수적으로 나온다. 반대 순서면 잠깐 동안 게이트가 여전히 무력한 상태가 남는다.

**Files:**
- Modify: `harness/report/score.mjs:19-24`
- Test: `harness/report/score.test.mjs`

**Interfaces:**
- Consumes: 없음
- Produces: `scoreLang(s)`는 `s.suite.testsPassed !== true`이면 `coverage: 0`을 반환한다. Task 5의 suite 스크립트가 이 필드를 채운다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`harness/report/score.test.mjs` 끝에 추가:

```javascript
// ── 테스트가 실패하면 커버리지 크레딧을 주지 않는다 (PR 0, I1) ─────────────────
// suite 스크립트가 단위테스트 종료코드를 버리던 시절에는 테스트가 깨져도 coverageLine이
// 그대로 보고되어 만점이 유지됐다. testsPassed:false면 커버리지 차원은 0이어야 한다.
const testsFailed = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, testsPassed: false },
  perf: null,
});
assert.strictEqual(testsFailed.coverage, 0, "테스트 실패 시 커버리지 0점이어야 한다");

const testsPassed = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true, testsPassed: true },
  perf: null,
});
assert.ok(testsPassed.coverage >= 90, "테스트 통과 시 커버리지 크레딧이 주어져야 한다");

// testsPassed 필드가 아예 없는(구버전) 신호도 크레딧을 받지 못한다 — fail-closed.
const legacySignal = scoreLang({
  conformance: { passed: 20, failed: 0 }, security: { defended: 6, total: 6 },
  suite: { coverageLine: 100, coverageBranch: 95, lintClean: true, ran: true },
  perf: null,
});
assert.strictEqual(legacySignal.coverage, 0, "testsPassed 부재 신호는 fail-closed여야 한다");
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `node --test harness/report/score.test.mjs`

Expected: FAIL. `AssertionError: 테스트 실패 시 커버리지 0점이어야 한다` (기대 0, 실제 99).

> ⚠️ **Step 3 이후 기존 `perfect` 케이스는 반드시 깨진다.** 실측으로 확인했다: `perfect`에는 `testsPassed`가 없으므로 커버리지가 99 → 0이 되고, `overall = 100×0.30 + 100×0.30 + 0×0.20 + 100×0.20 = 80` → `grade("B")`. 기존 assert `perfect.overall >= 90 && grade(perfect.overall) === "A"`가 실패한다. 따라서 Step 4는 조건부가 아니라 **필수**다.

- [ ] **Step 3: score.mjs를 고친다**

`harness/report/score.mjs:19-24`의 다음 블록을 찾는다:

```javascript
  const coverage = su.ran
    ? (branch > 0
        ? Math.min(100, line * 0.6 + branch * 0.3 + lint * 0.1)
        : Math.min(100, line * 0.9 + lint * 0.1))
    : 0;
```

아래로 교체한다:

```javascript
  // 커버리지 크레딧은 (a) suite가 실제로 돌았고 (b) 그 단위테스트가 통과했을 때만 준다.
  // testsPassed가 없거나 false면 0점 — fail-closed다. suite 스크립트가 종료코드를 버리던
  // 시절에는 테스트가 깨져도 coverageLine이 그대로 보고되어 만점이 유지됐다(PR 0, I1).
  const coverage = (su.ran && su.testsPassed === true)
    ? (branch > 0
        ? Math.min(100, line * 0.6 + branch * 0.3 + lint * 0.1)
        : Math.min(100, line * 0.9 + lint * 0.1))
    : 0;
```

- [ ] **Step 4: 기존 테스트 케이스를 보정한다**

`harness/report/score.test.mjs`의 기존 `perfect`·`weak` 케이스에서 `suite: { … ran: true }`를 `suite: { … ran: true, testsPassed: true }`로 바꾼다. 이 두 케이스는 "테스트가 통과한 언어"를 모델링하는 것이 의도이므로 필드 추가가 올바른 보정이다.

- [ ] **Step 5: 테스트가 통과하는지 확인한다**

Run: `node --test harness/report/score.test.mjs`

Expected:
```
# pass 1
# fail 0
```

- [ ] **Step 6: 커밋**

```bash
git add harness/report/score.mjs harness/report/score.test.mjs
git commit -m "fix(harness): 테스트 실패 시 커버리지 크레딧을 0점으로 (fail-closed)

score.mjs의 커버리지 차원이 su.ran에만 걸려 있었고 suite 스크립트 9개 전부가 그
값을 true 리터럴로 출력해, 어느 언어의 단위테스트가 깨져도 커버리지 만점이 유지되고
SCORECARD 등급이 변하지 않았다.

su.testsPassed === true 를 추가 조건으로 요구한다. 필드가 없는 구버전 신호도 0점이다
(fail-closed). 생산자(suite 스크립트)는 다음 커밋에서 이 필드를 채운다."
```

---

## Task 5: 9개 suite 스크립트가 testsPassed를 emit한다

7개 스크립트(`go` `node` `python` `dotnet` `php` `rust` `ruby`)는 이미 `___TESTEXIT=$?`를 출력하지만 아무도 파싱하지 않는다. `python`·`php`·`ruby`는 `___INSTALLEXIT`도 출력한다(의존성 설치 실패도 무음이었다). `java`·`kotlin`은 `___BUILDEXIT`만 있고 그것을 `lintClean`에 소비하므로 테스트 실패와 린트 실패가 구분되지 않는다.

**Files:**
- Modify: `harness/suites/go.sh:69` · `node.sh:54` · `python.sh:76` · `dotnet.sh:64` · `php.sh:71` · `rust.sh:66` · `ruby.sh:63` · `java.sh:63` · `kotlin.sh:76`

**Interfaces:**
- Consumes: Task 4의 `scoreLang`이 `su.testsPassed`를 읽는다.
- Produces: 각 suite JSON 신호에 `"testsPassed": true|false` 필드.

- [ ] **Step 1: `___TESTEXIT`이 있는 7개 스크립트를 고친다**

`go.sh`·`node.sh`·`rust.sh`·`dotnet.sh` — 각 파일에서 `LINTCLEAN` 계산 직후, 마지막 `echo "{…}"` 직전에 아래를 삽입한다(각 파일의 언어 이름만 다르다):

```bash
# 단위테스트 종료코드. 이 값을 버리면 테스트가 깨져도 커버리지 만점이 유지된다(PR 0, I1).
# 마커가 아예 없으면(컨테이너가 중간에 죽은 경우) 실패로 간주한다 — fail-closed.
TESTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___TESTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${TESTEXIT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi
```

그리고 마지막 `echo` 줄의 `\"ran\":true`를 `\"testsPassed\":${TESTSPASSED},\"ran\":true`로 바꾼다. 예를 들어 `go.sh:69`는:

```bash
echo "{\"lang\":\"go\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

`node.sh:54`:
```bash
echo "{\"lang\":\"node\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

`rust.sh:66`:
```bash
echo "{\"lang\":\"rust\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

`dotnet.sh:64`:
```bash
echo "{\"lang\":\"dotnet\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

- [ ] **Step 2: `___INSTALLEXIT`도 있는 3개 스크립트를 고친다**

`python.sh`·`php.sh`·`ruby.sh` — 의존성 설치가 실패하면 테스트는 아예 돌지 않았으므로 그것도 실패다. `LINTCLEAN` 계산 직후에 삽입:

```bash
# 단위테스트 종료코드 + 의존성 설치 종료코드. 설치가 실패하면 테스트는 돌지도 않았으므로 실패다.
# 마커가 아예 없으면 실패로 간주한다 — fail-closed.
TESTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___TESTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
INSTALLEXIT=$(printf '%s\n' "$OUT" | grep -oE '___INSTALLEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${TESTEXIT:-1}" = "0" ] && [ "${INSTALLEXIT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi
```

마지막 `echo` 줄:

`python.sh:76`:
```bash
echo "{\"lang\":\"python\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

`php.sh:71`:
```bash
echo "{\"lang\":\"php\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

`ruby.sh:63`:
```bash
echo "{\"lang\":\"ruby\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

- [ ] **Step 3: java.sh에 테스트 종료코드를 분리해 넣는다**

`java.sh`는 `mvn verify -DskipITs=true` 한 번으로 빌드·테스트·커버리지 게이트를 모두 돌리고 그 종료코드를 `___BUILDEXIT`로 내보내 `lintClean`에 쓴다. 테스트 실패와 컴파일 실패를 구분할 수 없다. surefire 요약 행에서 실패·오류 수를 직접 센다.

`java.sh`의 `docker run` 스크립트 안, `echo "___BUILDEXIT=$?"` 다음 줄에 아무것도 추가하지 않는다(컨테이너 쪽 변경 없음). 호스트 쪽 파싱만 추가한다 — `BUILDEXIT` 계산(46-47행) 직후에 삽입:

```bash
# surefire의 모듈별 "Results:" 요약 행에서 Failures/Errors 합계를 센다. mvn verify는
# 커버리지 게이트 실패로도 0이 아닌 종료코드를 내므로 BUILDEXIT만으로는 "테스트가 통과했는가"를
# 알 수 없다(테스트 실패와 린트/게이트 실패가 구분되지 않는다).
# 요약 행이 하나도 없으면(빌드가 테스트 단계 전에 죽음) 실패로 간주한다 — fail-closed.
SUMMARY_LINES=$(printf '%s\n' "$OUT" | grep -cE 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$')
FAILCOUNT=$(printf '%s\n' "$OUT" | grep -E 'Tests run: [0-9]+, Failures: [0-9]+, Errors: [0-9]+, Skipped: [0-9]+$' \
  | grep -oE 'Failures: [0-9]+|Errors: [0-9]+' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')
if [ "${SUMMARY_LINES:-0}" -gt 0 ] && [ "${FAILCOUNT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi
```

`java.sh:63`의 마지막 `echo`:
```bash
echo "{\"lang\":\"java\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

- [ ] **Step 4: kotlin.sh에 테스트 종료코드를 분리해 넣는다**

`kotlin.sh`도 `___BUILDEXIT` 하나로 gradle 전체를 판정한다. gradle이 이미 `___UNIT=<개수>`를 내보내고 있으므로, 컨테이너 스크립트에서 테스트 태스크만 따로 실행해 종료코드를 내보낸다.

`kotlin.sh`의 `docker run` 스크립트 안에서 `echo "___BUILDEXIT=$?"` 바로 다음 줄에 추가:

```bash
  ./gradlew test --console=plain >/tmp/test.log 2>&1
  echo "___TESTEXIT=$?"
  cat /tmp/test.log
```

호스트 쪽, `BUILDEXIT` 계산(58-59행) 직후에 삽입:

```bash
# gradle 전체(build/koverVerify/ktlintCheck)의 종료코드는 lintClean에 쓰고, 단위테스트만 따로
# 돌린 종료코드로 testsPassed를 판정한다. 마커가 없으면 실패로 간주한다 — fail-closed.
TESTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___TESTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${TESTEXIT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi
```

`kotlin.sh:76`의 마지막 `echo`:
```bash
echo "{\"lang\":\"kotlin\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
```

> ⚠️ `gradle --stop`을 인플라이트로 실행하면 진행 중 빌드를 죽인다. 컨테이너 안에서 gradle을 두 번 순차 실행하는 것은 안전하다(같은 데몬 재사용).

- [ ] **Step 5: 9개 스크립트가 유효한 JSON을 내는지 확인한다**

가장 빠른 두 언어로 확인한다(Docker 필요, 각 2~4분).

Run:
```bash
cd /d/Source/KeyCloakSDK/harness
bash suites/go.sh   | tail -1 | node -e 'const s=require("fs").readFileSync(0,"utf8"); const j=JSON.parse(s); console.log(j); if (typeof j.testsPassed !== "boolean") { console.error("testsPassed 없음/타입 오류"); process.exit(1); }'
bash suites/node.sh | tail -1 | node -e 'const s=require("fs").readFileSync(0,"utf8"); const j=JSON.parse(s); console.log(j); if (typeof j.testsPassed !== "boolean") { console.error("testsPassed 없음/타입 오류"); process.exit(1); }'
```

Expected: 두 줄 모두 `testsPassed: true`가 포함된 객체가 출력되고 exit 0.

- [ ] **Step 6: 커밋**

```bash
git add harness/suites/*.sh
git commit -m "fix(harness): 9개 suite 스크립트가 testsPassed를 emit한다

7개(go/node/python/dotnet/php/rust/ruby)는 이미 ___TESTEXIT을 출력하고 있었으나
리포 어디에서도 파싱되지 않았고, 마지막 줄은 \"ran\":true 를 리터럴로 박아 넣었다.
python/php/ruby는 ___INSTALLEXIT(의존성 설치 실패)도 무음이었다.

java/kotlin은 mvn/gradle 전체 종료코드를 lintClean에 소비해 테스트 실패와 린트
실패가 구분되지 않았다 — java는 surefire 요약 행의 Failures+Errors 합계로,
kotlin은 ./gradlew test 를 따로 돌린 종료코드로 판정한다.

마커가 없으면 실패로 간주한다(fail-closed)."
```

---

## Task 6: security 프로브가 5xx를 방어 성공으로 세지 않는다

`harness/security/probe.mjs:27`의 `expectReject`가 `r.status !== 200`으로 판정한다. 주석마저 "200이 아니면 방어 성공(정상은 401)"이라고 적혀 있다. 앱의 `/validate`가 500으로 크래시해도 보안 9/9 만점이 나온다. 공격 프로브가 앱을 죽이는 것은 방어가 아니라 **더 나쁜 결과**다.

**Files:**
- Create: `harness/security/verdict.mjs`
- Create: `harness/security/verdict.test.mjs`
- Modify: `harness/security/probe.mjs` (import + `expectReject` + 신호 JSON에 `crashes` 추가)

**Interfaces:**
- Produces:
  - `export const REJECT_STATUSES = [400, 401];`
  - `export function classify(status)` → `"rejected"` | `"accepted"` | `"crashed"` | `"unexpected"`
  - `export const isDefended = (status) => classify(status) === "rejected";`
  - probe.mjs가 쓰는 신호 JSON에 `crashes: number` 필드 추가.

> ✅ **새 파일이 컨테이너에 들어가는지 확인했다.** `probe.mjs`는 두 하네스 모두에서 **디렉터리 전체 마운트**로 실행된다 — `verify.sh`는 `-v "$PWD/security:/s"`, `install-verify.sh`는 6곳에서 `-v "$(hostpath "$harness_dir/security"):/s"`. 따라서 같은 디렉터리에 만드는 `verdict.mjs`가 자동으로 `/s/verdict.mjs`로 들어가고 `import "./verdict.mjs"`가 해석된다. 별도 Dockerfile/마운트 변경이 필요 없다.
>
> ⚠️ `install-verify.sh`는 `node /s/probe.mjs || true`로 프로브 실패를 삼킨다(6곳). 이 `|| true`는 Task 8에서 도입하는 `failedLangs()`가 신호 JSON의 `security.defended < security.total`을 검사하므로 **매트릭스 단계에서 잡힌다**. 따라서 여기서는 손대지 않는다.

- [ ] **Step 1: 실패하는 테스트를 쓴다**

Create `harness/security/verdict.test.mjs`:

```javascript
import assert from "node:assert";
import { classify, isDefended, REJECT_STATUSES } from "./verdict.mjs";

// 정상 거부 — Keycloak 검증 실패는 401, 잘못된 요청은 400.
assert.strictEqual(classify(401), "rejected");
assert.strictEqual(classify(400), "rejected");
assert.ok(isDefended(401));
assert.ok(isDefended(400));

// 통과 = BYPASS. 공격 토큰이 수락됐다.
assert.strictEqual(classify(200), "accepted");
assert.ok(!isDefended(200));

// 5xx = 크래시. 프로브가 앱을 죽였다 — 방어가 아니다.
assert.strictEqual(classify(500), "crashed");
assert.strictEqual(classify(502), "crashed");
assert.ok(!isDefended(500), "500은 방어 성공이 아니다");

// 그 밖의 상태(404 라우팅 실수, 429 등)는 방어로 세지 않는다.
assert.strictEqual(classify(404), "unexpected");
assert.ok(!isDefended(404));

assert.deepStrictEqual(REJECT_STATUSES, [400, 401]);

console.log("verdict.test.mjs: 모든 assert 통과");
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `node --test harness/security/verdict.test.mjs`

Expected: FAIL — `Cannot find module './verdict.mjs'`

- [ ] **Step 3: verdict.mjs를 만든다**

Create `harness/security/verdict.mjs`:

```javascript
// 적대적 프로브의 응답 상태코드를 판정한다. probe.mjs가 이 함수만 쓰도록 분리한 이유는
// probe.mjs가 컨테이너에서 실행되는 스크립트라 단위 테스트가 불가능하기 때문이다.
//
// ⚠️ 역사: 원래 판정은 `status !== 200`(200이 아니면 전부 방어 성공)이었다. 그 결과
// /validate가 500으로 크래시해도 보안 만점이 나왔다. 공격 프로브가 앱을 죽이는 것은
// 방어가 아니라 더 나쁜 결과다.

/** 토큰이 정상적으로 거부됐음을 의미하는 상태코드. Keycloak 검증 실패는 401, malformed는 400. */
export const REJECT_STATUSES = [400, 401];

/**
 * @param {number} status
 * @returns {"rejected"|"accepted"|"crashed"|"unexpected"}
 */
export function classify(status) {
  if (REJECT_STATUSES.includes(status)) return "rejected";
  if (status === 200) return "accepted";
  if (status >= 500) return "crashed";
  return "unexpected";
}

/** 방어 성공은 오직 명시적 거부뿐이다. 크래시도, 예상 밖 상태도 아니다. */
export const isDefended = (status) => classify(status) === "rejected";
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `node --test harness/security/verdict.test.mjs`

Expected:
```
# pass 1
# fail 0
```

- [ ] **Step 5: probe.mjs가 verdict.mjs를 쓰도록 고친다**

`harness/security/probe.mjs`의 import 블록(2~3행)에 추가:

```javascript
import { classify, isDefended } from "./verdict.mjs";
```

`probe.mjs:27`의 다음 줄을 찾는다:

```javascript
// "거부되어야 함" = 200이 아니면 방어 성공(정상은 401). 200이면 BYPASS(방어 실패).
const expectReject = async (name, token) => { const r = await validate(token); rec(name, r.status !== 200, `status=${r.status}`); };
```

아래로 교체한다:

```javascript
// "거부되어야 함" = 명시적 거부(400/401)만 방어 성공이다. 200이면 BYPASS(방어 실패),
// 5xx면 CRASH(프로브가 앱을 죽였다 — 방어가 아니라 더 나쁜 결과), 그 밖은 예상 밖 상태다.
const expectReject = async (name, token) => {
  const r = await validate(token);
  const verdict = classify(r.status);
  rec(name, isDefended(r.status), `status=${r.status} verdict=${verdict}`);
};
```

`probe.mjs:113`의 신호 파일 기록을 찾는다:

```javascript
  const defended = probes.filter(p => p.defended).length;
  fs.writeFileSync(`/out/${LANG}.security.json`, JSON.stringify({ lang: LANG, probes, defended, total: probes.length }, null, 2));
  console.log(`[security ${LANG}] ${defended}/${probes.length} defended`);
  process.exit(defended < probes.length ? 1 : 0);
```

아래로 교체한다:

```javascript
  const defended = probes.filter(p => p.defended).length;
  // detail 문자열에 심어둔 verdict로 크래시 수를 센다. 방어 실패 중에서도 "앱이 죽었다"는
  // "공격 토큰이 수락됐다"와 성격이 다르므로 신호에 따로 남긴다.
  const crashes = probes.filter(p => /verdict=crashed/.test(p.detail)).length;
  fs.writeFileSync(`/out/${LANG}.security.json`, JSON.stringify({ lang: LANG, probes, defended, crashes, total: probes.length }, null, 2));
  console.log(`[security ${LANG}] ${defended}/${probes.length} defended, ${crashes} crashed`);
  process.exit(defended < probes.length ? 1 : 0);
```

> `forged-kid flood stays rejected (no crash)` 프로브(probe.mjs:108-110)는 `expectReject`를 쓰지 않고 자체 루프에서 `r.status === 200`만 검사한다. 그 프로브는 이번 태스크에서 손대지 않는다 — 이름과 달리 5xx를 잡지 못하지만, 수정은 PR 6(부정 테스트 보강)의 범위다. 이 사실을 아래 커밋 메시지에 남긴다.

- [ ] **Step 6: 두 테스트가 모두 통과하는지 확인한다**

Run:
```bash
cd /d/Source/KeyCloakSDK
node --test harness/security/verdict.test.mjs
node --check harness/security/probe.mjs && echo "probe.mjs 문법 OK"
```

Expected: 테스트 `# pass 1 / # fail 0`, 그리고 `probe.mjs 문법 OK`.

- [ ] **Step 7: 커밋**

```bash
git add harness/security/verdict.mjs harness/security/verdict.test.mjs harness/security/probe.mjs
git commit -m "fix(harness): security 프로브가 5xx를 방어 성공으로 세지 않는다

expectReject의 판정이 status !== 200 이었다(주석마저 '200이 아니면 방어 성공'이라고
적혀 있었다). /validate가 500으로 크래시해도 보안 9/9 만점이 나왔다. 공격 프로브가
앱을 죽이는 것은 방어가 아니라 더 나쁜 결과다.

판정을 명시 허용목록(400/401)으로 좁히고, 5xx는 crashed로 분류해 신호에 crashes
카운터를 남긴다. 판정 로직은 컨테이너에서 도는 probe.mjs에서 verdict.mjs로 분리해
단위 테스트를 붙였다.

⚠️ 잔여: 'forged-kid flood stays rejected (no crash)' 프로브는 expectReject를 쓰지
않고 자체 루프에서 status === 200 만 검사하므로 여전히 5xx를 놓친다. 이름과 달리
크래시를 잡지 못한다 — PR 6(부정 테스트 보강)에서 다룬다."
```

---

## Task 7: php-ci 커버리지 게이트의 fail-open 제거

`.github/workflows/php-ci.yml:32`의 게이트는 `$p = $t ? $c/$t*100 : 100;`이다. clover 리포트의 `statements`가 0이면(리포트가 비었거나 생성 실패) 커버리지가 **100%로 계산되어 게이트를 통과한다**. 전형적 fail-open이다.

**Files:**
- Modify: `.github/workflows/php-ci.yml` (coverage gate 스텝)

**Interfaces:**
- Consumes: 없음
- Produces: 없음 (독립 태스크)

- [ ] **Step 1: 현재 동작을 재현해 fail-open을 확인한다**

PHP 포터블 설치를 쓴다.

Run:
```bash
export PATH="/c/Users/dirtc/tools/php:$PATH"
cd /tmp && cat > empty-clover.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<coverage generated="0"><project timestamp="0"><metrics statements="0" coveredstatements="0"/></project></coverage>
XML
php -r '$x=simplexml_load_file("/tmp/empty-clover.xml");$m=$x->project->metrics;$c=(int)$m["coveredstatements"];$t=(int)$m["statements"];$p=$t? $c/$t*100:100;printf("line coverage: %.2f%%\n",$p);exit($p>=90?0:1);'
echo "exit=$?"
```

Expected: `line coverage: 100.00%` 그리고 `exit=0` — 커버리지 데이터가 하나도 없는데 게이트를 통과한다.

- [ ] **Step 2: php-ci.yml의 게이트를 고친다**

`.github/workflows/php-ci.yml`에서 `coverage gate` 스텝을 찾는다:

```yaml
      - name: coverage gate
        run: |
          php -r '$x=simplexml_load_file("clover.xml");$m=$x->project->metrics;$c=(int)$m["coveredstatements"];$t=(int)$m["statements"];$p=$t? $c/$t*100:100;printf("line coverage: %.2f%%\n",$p);exit($p>=90?0:1);'
```

아래로 교체한다:

```yaml
      - name: coverage gate
        # ⚠️ fail-open 금지: statements가 0이면(clover 리포트가 비었거나 생성 실패) 커버리지를
        # 100%로 계산해 게이트를 통과시키던 버그가 있었다. 측정 실패는 통과가 아니라 실패다.
        run: |
          php -r '
            $f = "clover.xml";
            if (!is_file($f)) { fwrite(STDERR, "clover.xml 없음 — 커버리지 측정 실패\n"); exit(1); }
            $x = simplexml_load_file($f);
            if ($x === false || !isset($x->project->metrics)) { fwrite(STDERR, "clover.xml 파싱 실패\n"); exit(1); }
            $m = $x->project->metrics;
            $c = (int)$m["coveredstatements"];
            $t = (int)$m["statements"];
            if ($t <= 0) { fwrite(STDERR, "statements=0 — 커버리지가 측정되지 않았다(fail-closed)\n"); exit(1); }
            $p = $c / $t * 100;
            printf("line coverage: %.2f%% (%d/%d statements)\n", $p, $c, $t);
            exit($p >= 90 ? 0 : 1);
          '
```

- [ ] **Step 3: 고친 로직으로 세 케이스를 검증한다**

Run:
```bash
export PATH="/c/Users/dirtc/tools/php:$PATH"
cd /tmp

# (1) statements=0 → 실패해야 한다
php -r '$f="/tmp/empty-clover.xml"; $x=simplexml_load_file($f); $m=$x->project->metrics; $t=(int)$m["statements"]; if ($t<=0) { fwrite(STDERR,"statements=0 — fail-closed\n"); exit(1);} exit(0);'
echo "empty → exit=$? (기대: 1)"

# (2) 커버리지 95% → 통과해야 한다
cat > good-clover.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<coverage generated="0"><project timestamp="0"><metrics statements="100" coveredstatements="95"/></project></coverage>
XML
php -r '$x=simplexml_load_file("/tmp/good-clover.xml");$m=$x->project->metrics;$c=(int)$m["coveredstatements"];$t=(int)$m["statements"];if($t<=0){exit(1);}$p=$c/$t*100;printf("line coverage: %.2f%%\n",$p);exit($p>=90?0:1);'
echo "95% → exit=$? (기대: 0)"

# (3) 커버리지 80% → 실패해야 한다
cat > low-clover.xml <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<coverage generated="0"><project timestamp="0"><metrics statements="100" coveredstatements="80"/></project></coverage>
XML
php -r '$x=simplexml_load_file("/tmp/low-clover.xml");$m=$x->project->metrics;$c=(int)$m["coveredstatements"];$t=(int)$m["statements"];if($t<=0){exit(1);}$p=$c/$t*100;printf("line coverage: %.2f%%\n",$p);exit($p>=90?0:1);'
echo "80% → exit=$? (기대: 1)"

# (4) 파일 없음 → 실패해야 한다
php -r 'if(!is_file("/tmp/nonexistent-clover.xml")){fwrite(STDERR,"clover.xml 없음\n");exit(1);} exit(0);'
echo "missing → exit=$? (기대: 1)"
```

Expected:
```
empty → exit=1 (기대: 1)
line coverage: 95.00%
95% → exit=0 (기대: 0)
line coverage: 80.00%
80% → exit=1 (기대: 1)
missing → exit=1 (기대: 1)
```

- [ ] **Step 4: 커밋**

```bash
git add .github/workflows/php-ci.yml
git commit -m "fix(ci): php 커버리지 게이트의 fail-open 제거

\$p = \$t ? \$c/\$t*100 : 100; — clover의 statements가 0이면(리포트가 비었거나 생성
실패) 커버리지를 100%로 계산해 게이트를 통과시켰다. 측정 실패는 통과가 아니다.

clover.xml 부재·파싱 실패·statements=0 세 경우를 모두 실패로 바꾸고, 통과 시
분모/분자를 함께 출력해 사후 검증이 가능하게 한다."
```

---

## Task 8: install-verify.sh가 부분 실패를 종료코드로 전파한다

`harness/install/install-verify.sh`는 마지막 줄이 무조건 `exit 0`이고, 매트릭스 생성마저 `node report/install-matrix.mjs || true`다. 그 결과 2026-07-08·07-09 야간 CI에서 java·php가 `✗`였는데도 `install-all` 잡이 **success**로 표시됐다.

부분 실패 격리(한 언어가 실패해도 나머지 언어를 계속 검증)는 유지한다. 종료코드에만 반영한다. 판정 로직은 매트릭스가 결과 담체이므로 `install-matrix.mjs`에 둔다.

**Files:**
- Modify: `harness/install/report/install-matrix.mjs` (판정 함수 export + `--strict` 플래그)
- Modify: `harness/install/report/install-matrix.test.mjs` (판정 함수 테스트)
- Modify: `harness/install/install-verify.sh` (마지막 3줄)

**Interfaces:**
- Consumes: Task 2 (java/php publish 수정). 이걸 먼저 하지 않고 strict를 켜면 CI가 즉시 빨개진다.
- Produces:
  - `export function failedLangs(signals)` → 실패한 언어 이름 배열
  - `node report/install-matrix.mjs --strict` → 실패 언어가 있으면 exit 1

- [ ] **Step 1: 실패하는 테스트를 쓴다**

`harness/install/report/install-matrix.test.mjs` 끝에 추가:

```javascript
import { failedLangs } from "./install-matrix.mjs";

// 모든 단계가 ✓인 언어는 실패가 아니다.
const ok = {
  lang: "go", artifactBuilt: true, published: true, installed: true,
  quickstartOk: true, appBoot: true,
  conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 },
};
assert.deepStrictEqual(failedLangs([ok]), []);

// publish에서 죽은 언어는 실패다 (2026-07-08·07-09 CI의 java/php).
const publishFailed = {
  lang: "java", artifactBuilt: false, published: false, installed: false,
  quickstartOk: false, appBoot: false,
  conformance: { passed: 0, failed: 0 }, security: { defended: 0, total: 0 },
  error: "publish: publish/java.sh 실패",
};
assert.deepStrictEqual(failedLangs([publishFailed]), ["java"]);

// 설치·부팅은 됐지만 conformance가 깨진 언어도 실패다.
const conformanceFailed = {
  lang: "node", artifactBuilt: true, published: true, installed: true,
  quickstartOk: true, appBoot: true,
  conformance: { passed: 25, failed: 1 }, security: { defended: 9, total: 9 },
};
assert.deepStrictEqual(failedLangs([conformanceFailed]), ["node"]);

// 보안 프로브가 하나라도 뚫린 언어도 실패다.
const securityFailed = {
  lang: "php", artifactBuilt: true, published: true, installed: true,
  quickstartOk: true, appBoot: true,
  conformance: { passed: 26, failed: 0 }, security: { defended: 8, total: 9 },
};
assert.deepStrictEqual(failedLangs([securityFailed]), ["php"]);

// 여러 언어가 섞여도 실패 언어만 뽑는다.
assert.deepStrictEqual(failedLangs([ok, publishFailed, conformanceFailed]), ["java", "node"]);

console.log("install-matrix.test.mjs: failedLangs 테스트 통과");
```

- [ ] **Step 2: 테스트를 돌려 실패를 확인한다**

Run: `node --test harness/install/report/install-matrix.test.mjs`

Expected: FAIL — `SyntaxError: The requested module './install-matrix.mjs' does not provide an export named 'failedLangs'`

- [ ] **Step 3: install-matrix.mjs에 판정 함수와 --strict를 추가한다**

`harness/install/report/install-matrix.mjs`의 `mark`/`ratio` 정의 근처에 추가한다:

```javascript
/**
 * 매트릭스의 어느 셀이라도 ✗ 이거나 conformance/security가 만점이 아닌 언어를 실패로 본다.
 * 매트릭스가 결과 담체다 — 이 판정이 install-all 잡의 종료코드를 결정한다.
 *
 * @param {Array<object>} signals
 * @returns {string[]} 실패한 언어 이름(신호 순서 유지)
 */
export function failedLangs(signals) {
  return signals
    .filter((s) => {
      const stages = [s.artifactBuilt, s.published, s.installed, s.quickstartOk, s.appBoot];
      if (stages.some((v) => v !== true)) return true;
      const cf = s.conformance ?? { passed: 0, failed: 0 };
      if ((cf.failed ?? 0) > 0 || (cf.passed ?? 0) === 0) return true;
      const sec = s.security ?? { defended: 0, total: 0 };
      if ((sec.total ?? 0) === 0 || (sec.defended ?? 0) < sec.total) return true;
      return false;
    })
    .map((s) => s.lang);
}
```

그리고 `main()`(또는 매트릭스를 파일로 쓰는 마지막 부분) 끝에 추가한다:

```javascript
  // --strict: 매트릭스에 ✗가 하나라도 있으면 exit 1. 부분실패 격리(다른 언어를 계속 검증)는
  // 유지하되, 잡 종료코드로는 반드시 드러나야 한다. 이 플래그가 없던 시절 install-all 잡은
  // java/php가 publish 단계에서 죽어도 success로 표시됐다(2026-07-08·07-09 실측).
  if (process.argv.includes("--strict")) {
    const failed = failedLangs(signals);
    if (failed.length > 0) {
      console.error(`[install-matrix] 실패한 언어: ${failed.join(", ")}`);
      process.exit(1);
    }
    console.log(`[install-matrix] ${signals.length}개 언어 전부 통과`);
  }
```

> ✅ 확인됨: `install-matrix.mjs`는 `export function main()`을 가지며 그 안에서 `const signals = loadSignals(__dirname);`으로 신호를 읽고 `buildMatrix(signals)`로 매트릭스를 만든 뒤 `fs.writeFileSync(outPath, md)`한다. 위 블록은 그 `writeFileSync` **직후**에 넣는다(실패해도 매트릭스 파일은 남아야 CI 아티팩트로 진단할 수 있다).

- [ ] **Step 3b: LANG_ORDER에 kotlin을 추가한다**

계획을 세우며 발견한 별개의 결함이다. `install-matrix.mjs:8`의 정렬 순서에 9번째 언어가 빠져 있다:

```javascript
const LANG_ORDER = ["go", "dotnet", "node", "python", "java", "php", "rust", "ruby"];
```

`sortSignals`의 `rank()`는 `LANG_ORDER.indexOf(lang)`가 `-1`이면 `LANG_ORDER.length`를 반환하므로 kotlin은 "미상 언어"로 취급되어 항상 맨 끝에 정렬된다. 매트릭스 행 순서만 어긋나므로 정확성 문제는 아니지만, 9개 언어 매트릭스에 9번째 언어가 등재되지 않은 것은 PR #26(Kotlin 하네스 편입)의 누락이다. 같은 파일을 고치는 김에 닫는다.

```javascript
const LANG_ORDER = ["go", "dotnet", "node", "python", "java", "php", "rust", "ruby", "kotlin"];
```

`harness/install/report/install-matrix.test.mjs`에 순서 회귀 테스트를 추가한다:

```javascript
// kotlin은 9번째 언어다. LANG_ORDER에 없으면 "미상 언어"로 맨 끝에 정렬된다(PR #26 누락).
const rows = buildMatrix([
  { lang: "kotlin", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } },
  { lang: "go", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } },
]);
const goIdx = rows.indexOf("| go |");
const kotlinIdx = rows.indexOf("| kotlin |");
assert.ok(goIdx > 0 && kotlinIdx > goIdx, "go가 kotlin보다 먼저 정렬되어야 한다(LANG_ORDER 등재 확인)");
```

- [ ] **Step 4: 테스트가 통과하는지 확인한다**

Run: `node --test harness/install/report/install-matrix.test.mjs`

Expected:
```
# pass 1
# fail 0
```

- [ ] **Step 5: install-verify.sh가 종료코드를 전파하게 한다**

`harness/install/install-verify.sh`의 마지막 4줄을 찾는다:

```bash
log "== 설치 매트릭스 생성 =="
node report/install-matrix.mjs || true
log "== 완료 — report/INSTALL-MATRIX.md =="
exit 0
```

아래로 교체한다:

```bash
log "== 설치 매트릭스 생성 =="
# --strict: 매트릭스에 ✗가 있으면 exit 1. 부분실패 격리(위 루프가 실패 언어를 건너뛰고 계속
# 진행하는 것)는 유지하고, 최종 종료코드에만 반영한다. 이전에는 여기가 `|| true` + 무조건
# `exit 0`이라 java/php가 publish 단계에서 죽어도 CI 잡이 초록이었다(2026-07-08·07-09 실측).
MATRIX_RC=0
node report/install-matrix.mjs --strict || MATRIX_RC=$?
log "== 완료 — report/INSTALL-MATRIX.md (exit=${MATRIX_RC}) =="
exit "$MATRIX_RC"
```

- [ ] **Step 6: 로컬에서 통과·실패 두 경우를 확인한다**

통과 경로(Docker 필요, 약 4분):
```bash
cd /d/Source/KeyCloakSDK/harness/install && ./install-verify.sh go; echo "exit=$?"
```
Expected: `exit=0`, 매트릭스의 go 행이 전부 `✓`.

실패 경로(신호를 직접 오염시켜 판정만 확인 — 컨테이너 불필요):
```bash
cd /d/Source/KeyCloakSDK/harness/install
cp report/signals/go.install.json /tmp/go.install.json.bak
node -e 'const fs=require("fs");const p="report/signals/go.install.json";const j=JSON.parse(fs.readFileSync(p,"utf8"));j.published=false;fs.writeFileSync(p,JSON.stringify(j,null,2));'
node report/install-matrix.mjs --strict; echo "exit=$? (기대: 1)"
cp /tmp/go.install.json.bak report/signals/go.install.json
node report/install-matrix.mjs --strict; echo "exit=$? (기대: 0)"
```
Expected:
```
[install-matrix] 실패한 언어: go
exit=1 (기대: 1)
[install-matrix] 1개 언어 전부 통과
exit=0 (기대: 0)
```

- [ ] **Step 7: 커밋**

```bash
git add harness/install/report/install-matrix.mjs harness/install/report/install-matrix.test.mjs harness/install/install-verify.sh
git commit -m "fix(install-harness): 부분 실패를 종료코드로 전파 (조용한 초록 제거)

install-verify.sh의 마지막 줄이 무조건 exit 0이었고 매트릭스 생성마저 || true 였다.
2026-07-08·07-09 야간 CI에서 java·php가 publish 단계 ✗였는데도 install-all 잡이
success로 표시됐다.

판정을 install-matrix.mjs의 failedLangs()로 옮기고(매트릭스가 결과 담체다) --strict
플래그로 종료코드를 낸다. 어떤 단계든 ✗이거나 conformance/security가 만점이 아니면
실패다. 부분실패 격리(다른 언어를 계속 검증)는 그대로 유지한다.

같은 파일의 별개 결함도 닫는다: LANG_ORDER에 kotlin이 빠져 있어 9번째 언어가 '미상'
으로 맨 끝에 정렬됐다(PR #26 누락)."
```

---

## Task 9: verify.sh가 언어별 실패를 종료코드로 전파한다

`harness/verify.sh`는 conformance·security·k6·`run-suite.sh`를 전부 `|| true`로 감싸고, 앱 빌드 실패와 healthz 타임아웃은 `continue`로 넘긴다. 어떤 언어가 어떻게 깨져도 초록이다.

k6(성능)만은 예외로 둔다 — 성능은 언어간 **상대** 점수이지 절대 임계가 아니므로 게이트가 아니다.

**Files:**
- Modify: `harness/verify.sh`

**Interfaces:**
- Consumes: Task 1(실행비트 — 없으면 verify.sh 자체가 실행 불가), Task 3(관측 — 무엇이 원래 깨져 있는지 알아야 한다), Task 5(suite가 testsPassed를 emit), Task 6(probe가 5xx를 잡는다)
- Produces: `./verify.sh <langs>`가 실패 언어가 있으면 exit 1.

- [ ] **Step 1: run-suite.sh가 실패를 알리게 한다**

`harness/suites/run-suite.sh`의 루프 끝(각 언어의 신호 JSON을 출력한 뒤)에 실패 누적을 추가한다. 파일 마지막의 `done` 뒤에 아래를 추가:

```bash
# 어떤 언어의 단위테스트라도 실패했거나 suite가 아예 돌지 못했으면 0이 아닌 코드로 끝낸다.
# verify.sh가 이 코드를 받아 전체 실행의 종료코드에 반영한다.
FAILED_SUITES=""
for L in "$@"; do
  RAN=$(node -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(j.ran===true&&j.testsPassed===true?"ok":"bad");}catch(e){console.log("bad");}' "report/signals/$L.suite.json")
  [ "$RAN" = "ok" ] || FAILED_SUITES="$FAILED_SUITES $L"
done
if [ -n "$FAILED_SUITES" ]; then
  echo "== [suite] 실패:$FAILED_SUITES =="
  exit 1
fi
echo "== [suite] 전 언어 통과 =="
```

- [ ] **Step 2: verify.sh가 실패를 누적하게 한다**

`harness/verify.sh`에서 `for L in "${LANGS[@]}"; do` 루프 **직전**에 추가:

```bash
# 언어별 실패를 누적한다. 부분실패 격리(한 언어가 깨져도 나머지를 계속 검증)는 유지하고
# 최종 종료코드에만 반영한다. k6(성능)는 게이트가 아니다 — 언어간 상대 점수일 뿐 절대 임계가 없다.
FAILED_LANGS=""
```

루프 안의 두 `continue` 지점을 고친다. 앱 빌드 실패:

```bash
  if ! docker compose --profile apps up -d --build "app-$L"; then echo "{\"lang\":\"$L\",\"error\":\"build/up failed\"}" > "report/signals/$L.error.json"; FAILED_LANGS="$FAILED_LANGS $L"; continue; fi
```

healthz 타임아웃:

```bash
  if ! timeout 120 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done"; then echo "{\"lang\":\"$L\",\"error\":\"healthz timeout\"}" > "report/signals/$L.error.json"; FAILED_LANGS="$FAILED_LANGS $L"; docker compose --profile apps stop "app-$L" >/dev/null 2>&1; continue; fi
```

conformance·security의 `|| true`를 실패 누적으로 바꾼다:

```bash
  echo "== [$L] conformance =="
  docker run --rm --network "$NET" -v "$PWD/conformance:/c" -v "$PWD/report/signals:/out" \
    -e "BASE=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" node:20-alpine node /c/conformance.mjs \
    || FAILED_LANGS="$FAILED_LANGS $L"
  echo "== [$L] security =="
  docker run --rm --network "$NET" -v "$PWD/security:/s" -v "$PWD/report/signals:/out" \
    -e "BASE=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" node:20-alpine node /s/probe.mjs \
    || FAILED_LANGS="$FAILED_LANGS $L"
```

k6는 `|| true`를 그대로 둔다(주석만 명시):

```bash
  echo "== [$L] k6 성능 =="
  # k6는 게이트가 아니다 — 성능은 언어간 상대 점수(최우수 대비)이지 절대 임계가 없다.
  # 측정 실패는 perf=null로 폴백되어 동형성 차원만 반영된다(무벌점).
  docker run --rm --network "$NET" -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
    -e "BASE_URL=http://app-$L:8090" -e KC_URL=http://keycloak:8080 -e "LANG=$L" grafana/k6 run /scripts/scenarios.js || true
```

파일 마지막 4줄을 찾는다:

```bash
echo "== SDK 스위트 집계 =="
./suites/run-suite.sh "${LANGS[@]}" || true
echo "== 스코어링 =="
node report/score.mjs "${LANGS[@]}"
echo "== 완료 — report/SCORECARD.md =="
```

아래로 교체한다:

```bash
echo "== SDK 스위트 집계 =="
./suites/run-suite.sh "${LANGS[@]}" || FAILED_LANGS="$FAILED_LANGS suite"
echo "== 스코어링 =="
node report/score.mjs "${LANGS[@]}"
echo "== 완료 — report/SCORECARD.md =="

# 실패한 언어(또는 suite)가 하나라도 있으면 0이 아닌 코드로 끝낸다. SCORECARD.md는 이미
# 생성됐으므로 CI 아티팩트로 회수 가능하다 — 실패해도 진단 자료는 남는다.
if [ -n "$FAILED_LANGS" ]; then
  # 중복 제거(한 언어가 conformance·security 양쪽에서 실패할 수 있다)
  UNIQ=$(printf '%s\n' $FAILED_LANGS | sort -u | tr '\n' ' ')
  echo "== 실패: $UNIQ =="
  exit 1
fi
echo "== 전 언어 통과 =="
```

- [ ] **Step 3: 한 언어로 통과 경로를 확인한다**

Run (Docker 필요, 약 6분):
```bash
cd /d/Source/KeyCloakSDK/harness && ./verify.sh go; echo "exit=$?"
```

Expected: `== 전 언어 통과 ==` 그리고 `exit=0`. `report/SCORECARD.md`에 go 행이 있다.

- [ ] **Step 4: 커밋**

```bash
git add harness/verify.sh harness/suites/run-suite.sh
git commit -m "fix(harness): verify.sh가 언어별 실패를 종료코드로 전파

conformance·security·run-suite.sh를 전부 || true 로 감싸고, 앱 빌드 실패와 healthz
타임아웃을 continue로 넘겨 어떤 언어가 어떻게 깨져도 초록이었다.

부분실패 격리(한 언어가 깨져도 나머지를 계속 검증)는 유지하고 최종 종료코드에만
반영한다. run-suite.sh도 testsPassed를 확인해 실패를 알린다.

k6(성능)만 게이트에서 제외한다 — 언어간 상대 점수일 뿐 절대 임계가 없고, 미측정은
동형성 차원만 반영되어 무벌점이다."
```

---

## Task 10: 변이 증명 — 게이트가 실제로 거부하는지 확인한다

I1의 이행이다. 각 게이트를 고의로 깨뜨려 빨개지는지 확인하고 되돌린다. **이 태스크를 거치지 않은 게이트는 신뢰하지 않는다.**

**Files:**
- Create: `docs/superpowers/plans/2026-07-10-pr0-mutation-proof.md` (증명 로그)

**Interfaces:**
- Consumes: Task 1·4·5·6·7·8·9 전부

- [ ] **Step 1: 실행비트 가드 — chmod -x 하면 CI가 잡는가**

```bash
cd /d/Source/KeyCloakSDK
git update-index --chmod=-x harness/verify.sh
git ls-files -s -- '*.sh' | awk '$1 == "100644" { print $4 }'
```
Expected: `harness/verify.sh` 한 줄. (가드가 이 출력을 보고 exit 1 한다.)

되돌린다:
```bash
git update-index --chmod=+x harness/verify.sh
git ls-files -s -- '*.sh' | awk '$1 == "100644"' | wc -l
```
Expected: `0`

- [ ] **Step 2: 커버리지 게이트 — 테스트가 깨지면 0점인가**

컨테이너 없이 `scoreLang`을 직접 호출해 확인한다.

```bash
cd /d/Source/KeyCloakSDK
node -e '
import("./harness/report/score.mjs").then(({ scoreLang, grade }) => {
  const base = { conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 }, perf: null };
  const pass = scoreLang({ ...base, suite: { coverageLine: 99, coverageBranch: 86, lintClean: true, ran: true, testsPassed: true } });
  const fail = scoreLang({ ...base, suite: { coverageLine: 99, coverageBranch: 86, lintClean: true, ran: true, testsPassed: false } });
  console.log("testsPassed=true  → coverage", pass.coverage, "overall", pass.overall, grade(pass.overall));
  console.log("testsPassed=false → coverage", fail.coverage, "overall", fail.overall, grade(fail.overall));
  if (fail.coverage !== 0) { console.error("FAIL: 테스트 실패인데 커버리지가 0이 아니다"); process.exit(1); }
  if (fail.overall >= pass.overall) { console.error("FAIL: 등급이 하락하지 않았다"); process.exit(1); }
  console.log("변이 증명 통과: 테스트 실패 → 커버리지 0점, 등급 하락");
});
'
```
Expected:
```
testsPassed=true  → coverage 96 overall 99 A
testsPassed=false → coverage 0 overall 79 D
변이 증명 통과: 테스트 실패 → 커버리지 0점, 등급 하락
```

- [ ] **Step 3: security 프로브 — 500이 방어로 세지지 않는가**

```bash
cd /d/Source/KeyCloakSDK
node -e '
import("./harness/security/verdict.mjs").then(({ classify, isDefended }) => {
  const cases = [200, 400, 401, 404, 500, 502];
  for (const s of cases) console.log(String(s).padEnd(4), classify(s).padEnd(11), "defended =", isDefended(s));
  if (isDefended(500)) { console.error("FAIL: 500이 방어로 집계된다"); process.exit(1); }
  if (isDefended(200)) { console.error("FAIL: 200(BYPASS)이 방어로 집계된다"); process.exit(1); }
  if (!isDefended(401)) { console.error("FAIL: 401이 방어로 집계되지 않는다"); process.exit(1); }
  console.log("변이 증명 통과: 5xx·200 모두 방어 아님, 401만 방어");
});
'
```
Expected:
```
200  accepted    defended = false
400  rejected    defended = true
401  rejected    defended = true
404  unexpected  defended = false
500  crashed     defended = false
502  crashed     defended = false
변이 증명 통과: 5xx·200 모두 방어 아님, 401만 방어
```

- [ ] **Step 4: install 매트릭스 — ✗가 있으면 exit 1인가**

Task 8 Step 6에서 이미 확인했다. 재실행해 로그를 남긴다.

```bash
cd /d/Source/KeyCloakSDK/harness/install
node -e '
import("./report/install-matrix.mjs").then(({ failedLangs }) => {
  const ok = { lang: "go", artifactBuilt: true, published: true, installed: true, quickstartOk: true, appBoot: true, conformance: { passed: 26, failed: 0 }, security: { defended: 9, total: 9 } };
  const bad = { ...ok, lang: "java", published: false };
  console.log("정상만      →", JSON.stringify(failedLangs([ok])));
  console.log("publish 실패 →", JSON.stringify(failedLangs([ok, bad])));
  if (failedLangs([ok, bad]).length !== 1) { console.error("FAIL"); process.exit(1); }
  console.log("변이 증명 통과: ✗ 언어를 정확히 집어낸다");
});
'
```
Expected:
```
정상만      → []
publish 실패 → ["java"]
변이 증명 통과: ✗ 언어를 정확히 집어낸다
```

- [ ] **Step 5: verify.sh — 실제 앱을 깨뜨리면 빨개지는가 (E2E)**

가장 중요한 증명이다. Node 앱의 단위테스트 하나를 고의로 실패시키고 `verify.sh node`를 돌린다.

```bash
cd /d/Source/KeyCloakSDK
# 고의 파손: 반드시 실패하는 assert를 추가
cat >> node/test/unit/config.test.ts <<'TS'

// 변이 증명용 — 커밋하지 않는다.
it('MUTATION PROOF: 이 테스트는 반드시 실패한다', () => {
  expect(1).toBe(2)
})
TS

cd harness && ./verify.sh node; echo "verify.sh exit=$?"
```
Expected: `verify.sh exit=1`, 출력에 `== [suite] 실패: node ==`, 그리고 `report/signals/node.suite.json`의 `testsPassed`가 `false`, `report/SCORECARD.md`의 node 커버리지 열이 `0`.

되돌린다:
```bash
cd /d/Source/KeyCloakSDK
git checkout -- node/test/unit/config.test.ts
git status --short node/
```
Expected: 출력 없음(워킹트리 클린).

> ⚠️ `verify.sh node` 는 Docker로 Keycloak과 앱을 띄우고 suite 컨테이너까지 돌리므로 약 8분 걸린다. 실패 경로도 SCORECARD.md를 생성한 뒤 exit 1 하므로 산출물 확인이 가능하다.

- [ ] **Step 6: 증명 로그를 문서로 남긴다**

Create `docs/superpowers/plans/2026-07-10-pr0-mutation-proof.md`:

```markdown
# PR 0 변이 증명 (I1)

각 게이트를 고의로 깨뜨려 실제로 거부하는지 확인한 기록이다. 이 문서 없이 게이트를
신뢰하지 않는다.

| 게이트 | 변이 | 기대 | 실제 | 통과 |
|---|---|---|---|---|
| 실행비트 가드 | `git update-index --chmod=-x harness/verify.sh` | 가드가 파일을 나열하고 exit 1 | | |
| 커버리지 크레딧 | `testsPassed: false` | coverage 0점, 등급 하락 | | |
| security 판정 | status 500 | `defended=false`, `verdict=crashed` | | |
| install 매트릭스 | `published: false` | `failedLangs` = `["java"]` | | |
| verify.sh E2E | node 단위테스트 1개 실패 | `exit 1`, node coverage 0 | | |

## 원문 출력

<각 스텝의 실제 출력을 붙여넣는다.>

## 되돌림 확인

`git status --short` 결과가 비어 있음을 확인했다: <예/아니오>
```

- [ ] **Step 7: 커밋**

```bash
git add docs/superpowers/plans/2026-07-10-pr0-mutation-proof.md
git commit -m "docs(plan): PR 0 변이 증명 — 게이트가 실제로 거부함을 확인

I1(게이트는 반증 가능해야 한다)의 이행 기록. 실행비트 가드·커버리지 크레딧·security
판정·install 매트릭스·verify.sh E2E 다섯 게이트를 각각 고의로 깨뜨려 빨개지는지
확인하고 되돌렸다.

이 문서 없이는 CI가 초록인 이유가 코드 품질 때문인지 게이트 무력화 때문인지
구별할 수 없다."
```

---

## Task 11: 최종 CI 검증

모든 게이트가 켜진 상태에서 실제 CI가 초록인지 확인한다. Task 3의 기준선 관측과 대조한다.

- [ ] **Step 1: push하고 harness 워크플로를 수동 실행한다**

```bash
git push origin fix/pr0-verification-gates
gh workflow run harness.yml --ref fix/pr0-verification-gates
RUN_ID=$(gh run list --workflow=harness.yml --branch fix/pr0-verification-gates --limit 1 --json databaseId --jq '.[0].databaseId')
gh run watch "$RUN_ID"
```

- [ ] **Step 2: 네 잡의 결론을 확인한다**

```bash
gh run view "$RUN_ID" --json jobs --jq '.jobs[] | "\(.name)\t\(.conclusion)"'
```

Expected:
```
shell-exec-bits   success
mvp-go            skipped   (schedule/dispatch 실행이므로)
all-langs         success
score-all         success
install-all       success
```

`score-all`과 `install-all`이 이제 **의미 있게** 초록이다 — 실패를 거부할 수 있는 상태에서 통과했다는 뜻이다.

- [ ] **Step 3: 산출물이 실제로 생성됐는지 확인한다**

```bash
gh run download "$RUN_ID" -n scorecard -D /tmp/pr0-final
gh run download "$RUN_ID" -n install-matrix -D /tmp/pr0-final
cat /tmp/pr0-final/SCORECARD.md
cat /tmp/pr0-final/INSTALL-MATRIX.md
```

Expected: `SCORECARD.md`가 9개 언어 행을 가진다(CI에서 최초 생성). `INSTALL-MATRIX.md`가 9/9 `✓`.

- [ ] **Step 4: 기준선 관측 문서를 갱신한다**

`docs/superpowers/plans/2026-07-10-pr0-baseline-observation.md`에 "게이트 적용 후" 섹션을 추가하고, Task 3의 기준선과 비교해 무엇이 달라졌는지 한 문단으로 적는다.

- [ ] **Step 5: 커밋 및 PR 생성**

```bash
git add docs/superpowers/plans/2026-07-10-pr0-baseline-observation.md
git commit -m "docs(plan): PR 0 최종 CI 검증 결과 — 게이트 적용 전후 비교"
gh pr create --base main --head fix/pr0-verification-gates \
  --title "fix(harness,ci): PR 0 — 검증 게이트를 진짜로 만들기" \
  --body-file - <<'EOF'
설계: `docs/superpowers/specs/2026-07-10-pre-release-hardening-design.md` §4

## 문제

이 프로젝트가 광고하는 "4차원 검증·A등급 스코어카드"는 상당 부분 아무것도 거부하지 못한다.

- `harness/verify.sh`가 실행비트 없이 커밋되어 야간 `score-all` 잡이 **도입 이래 매번 exit 126으로 즉사**했다. CI에서 SCORECARD가 생성된 적이 없다.
- `harness/suites/*.sh` 9개 전부가 단위테스트 종료코드를 버리고 `"ran":true`를 리터럴로 출력한다. 어느 언어의 테스트가 깨져도 커버리지 만점이다.
- `harness/security/probe.mjs`가 200이 아닌 **모든** 응답을 방어 성공으로 센다. `/validate`가 500으로 크래시해도 보안 만점이다.
- `install-verify.sh`가 무조건 `exit 0`이다. 2026-07-08·07-09 야간 CI에서 java·php가 publish 단계 `✗`였는데도 잡이 success였다.
- `php-ci.yml`의 커버리지 게이트가 `statements == 0`일 때 100%로 fail-open한다.

## 변경

| 커밋 | 내용 |
|---|---|
| 실행비트 | 14개 `*.sh`에 +x, `repo-hygiene` 가드 추가 |
| java/php publish | 리눅스 CI 전용 소유권 실패 수정(tar 스트림 + `safe.directory`) |
| 기준선 관측 | 게이트를 조이기 **전** CI 실제 결과 기록 |
| 커버리지 크레딧 | `testsPassed !== true` → 0점 (fail-closed) |
| suite 계약 | 9개 스크립트가 `testsPassed` emit |
| security 판정 | 400/401만 방어, 5xx는 `crashed` |
| php 커버리지 게이트 | fail-open 제거 |
| install 매트릭스 | `--strict` → `✗` 있으면 exit 1 |
| verify.sh | 언어별 실패를 종료코드로 전파 (k6는 게이트 아님) |
| 변이 증명 | 다섯 게이트를 고의로 깨뜨려 빨개짐 확인 |

## 검증

- 변이 증명 로그: `docs/superpowers/plans/2026-07-10-pr0-mutation-proof.md`
- 기준선/최종 CI 대조: `docs/superpowers/plans/2026-07-10-pr0-baseline-observation.md`
- `harness` 워크플로 수동 실행에서 `score-all`·`install-all`이 **처음으로 의미 있게** 초록

## 후속

PR 1~6(결함 클래스별 수정)은 이 PR이 병합된 뒤에 착수한다. 게이트가 진짜가 되기 전에는 그 PR들의 "검증됨"이 아무것도 의미하지 않는다.
EOF
```

---

## Self-Review

### 1. 스펙 커버리지

| 스펙 §4 항목 | 태스크 |
|---|---|
| 0-a java/php install publish 수정 | Task 2 |
| 0-b suite JSON 계약 + score.mjs | Task 4 (소비자), Task 5 (생산자) |
| 0-c security 프로브 판정 | Task 6 |
| 0-d 실행비트 + CI 가드 | Task 1 |
| 0-e 조용한 초록 제거 (install-verify) | Task 8 |
| 0-e 조용한 초록 제거 (verify.sh) | Task 9 |
| 0-e 조용한 초록 제거 (php-ci fail-open) | Task 7 |
| 0-f 변이 증명 | Task 10 |

스펙에 없으나 추가한 것:

- **Task 3(기준선 관측)** 과 **Task 11(최종 CI 검증)**. 게이트를 조이기 전후의 CI 실제 결과를 기록하지 않으면 "원래 깨져 있던 것"과 "이번에 깨진 것"을 구별할 수 없다. 스펙 §7의 "구조적 한계"(java/php 수정은 CI에서만 재현)가 이 두 태스크를 요구한다.
- **Task 8 Step 3b (`LANG_ORDER`에 kotlin 추가)**. 계획을 세우며 `install-matrix.mjs:8`에서 발견한 별개 결함이다(PR #26의 누락). 같은 파일을 이미 고치고 있고 1줄이므로 함께 닫는다. 행 순서만 어긋나므로 정확성 문제는 아니다.

### 계획 수립 중 실측으로 확인한 가정

- `score.test.mjs`의 `perfect` 케이스는 Task 4 Step 3 이후 **확정적으로 깨진다**(overall 100 → 80, 등급 A → B). Step 4는 필수다.
- `probe.mjs`는 두 하네스 모두 `harness/security` **디렉터리 전체**를 컨테이너에 마운트하므로, 신규 `verdict.mjs`가 자동으로 함께 들어간다. Task 6이 `install-all`을 깨뜨리지 않는다.
- `install-matrix.mjs`는 `export function main()` 안에서 `const signals = loadSignals(__dirname)`를 쓴다. Task 8의 `--strict` 블록을 넣을 위치가 확정됐다.

### 2. Placeholder 스캔

`TBD`·`TODO`·`적절히 처리`·`Task N과 유사` 없음. 모든 코드 스텝이 실제 코드를 담고 있다. Task 3·10의 문서 템플릿에 `<…>` 자리표시자가 있으나, 이는 **실행 중 관측한 값을 적는 칸**이며 구현자가 채워야 할 코드가 아니다.

### 3. 타입 일관성

- `testsPassed` — Task 4가 `su.testsPassed === true`로 읽고, Task 5의 9개 스크립트가 `\"testsPassed\":${TESTSPASSED}`로 쓴다. `TESTSPASSED`는 셸에서 `true`/`false` 리터럴 문자열이므로 JSON 불리언으로 직렬화된다. 일치.
- `failedLangs(signals) → string[]` — Task 8이 정의하고 Task 8 Step 5(install-verify.sh)와 Task 10 Step 4가 소비한다. 일치.
- `classify(status)` / `isDefended(status)` / `REJECT_STATUSES` — Task 6이 정의하고 같은 태스크의 probe.mjs와 Task 10 Step 3이 소비한다. 일치.
- `crashes` 필드 — Task 6이 security 신호에 추가한다. `score.mjs`는 이 필드를 읽지 않는다(보안 점수는 `defended/total`로 계산). 의도된 것이며, `crashes`는 진단용이다.

### 4. 순서 의존

Task 2 → Task 8 (publish를 고치기 전에 strict를 켜면 CI가 즉시 빨개진다).
Task 1 → Task 3 (실행비트 없이는 verify.sh가 CI에서 돌지 않는다).
Task 4 → Task 5 (소비자를 먼저 고치면 그 사이 신호는 fail-closed로 0점이 된다. 반대 순서면 게이트가 잠시 무력하다).
Task 3 → Task 9 (무엇이 원래 깨져 있는지 모른 채 strict를 켜면 원인을 오귀속한다).
Task 1·4·5·6·7·8·9 → Task 10 → Task 11.

---

**Plan complete and saved to `docs/superpowers/plans/2026-07-10-pr0-verification-gates.md`.**
