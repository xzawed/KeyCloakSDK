# 통합 배포 가이드 + 릴리스 도우미 구현 계획 (WBS)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 9개 언어 SDK 실배포를 단일 `DEPLOY.md` + 도우미 2종(`release-readiness.sh` 읽기전용 대시보드, `release-trigger.sh` print-only 트리거)으로 통합한다.

**Architecture:** 9언어 배포 사실을 단일 데이터 모듈 `scripts/lib/deploy-facts.sh`(POSIX sh case 함수)에 넣고, 두 도우미 스크립트가 이를 소비한다(DRY). `DEPLOY.md`는 같은 사실을 사람용으로 문서화한다. 도우미는 태그를 절대 push하지 않고(human-gate) 시크릿 값도 출력하지 않는다.

**Tech Stack:** POSIX sh(git-bash/Linux 공통) · `gh`(secret 조회) · `curl`(레지스트리 존재) · `git`(태그) · Markdown.

## Global Constraints

- 도우미는 `git tag`/`git push`를 **실행하지 않는다**(명령 텍스트 출력만). 실배포는 사람이 수동 태그 push.
- 시크릿 **값 미출력** — `gh secret list`(이름·갱신일만) 사용. 값 echo 금지.
- release 워크플로(`.github/workflows/*-release.yml`)는 **수정하지 않는다**(문서·도우미만 추가).
- 모든 배포 사실(태그·시크릿명·dry-run·설치좌표)은 스펙 §2([2026-07-09-unified-deploy-guide-design.md](../specs/2026-07-09-unified-deploy-guide-design.md))의 실측값만 사용(추측 0).
- 스크립트는 `#!/usr/bin/env sh` + `set -eu`. 파일은 LF(루트 `.gitattributes`가 `*.sh eol=lf` 강제).
- 9개 언어 정확 목록·순서(권장 배포 순서, 쉬운 인증→어려운 인증): `go php rust dotnet python node ruby java kotlin`.

---

### Task 1: 배포 사실 데이터 모듈 + 테스트 하네스

**Files:**
- Create: `scripts/lib/deploy-facts.sh`
- Create: `scripts/test/assert.sh`
- Test: `scripts/test/test-deploy-facts.sh`

**Interfaces:**
- Produces: `DEPLOY_LANGS`(공백구분 9언어 문자열) · `df_known <lang>`(0/1) · `df_registry/df_auth/df_tag/df_versionbump/df_secrets/df_dryrun/df_install/df_coordinate/df_check_url <lang>`(stdout 1줄). `df_tag`·`df_install`(go/java/kotlin)은 `%s`=버전 placeholder를 포함한 printf 포맷.
- assert helpers: `assert_eq <expected> <actual> <msg>` · `assert_contains <haystack> <needle> <msg>` · `assert_fails <cmd...>` · `assert_ok <cmd...>` · `assert_report`(요약·실패 시 exit 1).

- [ ] **Step 1: assert 헬퍼 작성**

`scripts/test/assert.sh`:
```sh
#!/usr/bin/env sh
# 극소형 sh 테스트 어서션(외부 프레임워크 없음). 각 테스트가 source한다.
_A_PASS=0; _A_FAIL=0
assert_eq() { # expected actual msg
  if [ "$1" = "$2" ]; then _A_PASS=$((_A_PASS+1)); else _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$1" "$2" >&2; fi
}
assert_contains() { # haystack needle msg
  case "$1" in *"$2"*) _A_PASS=$((_A_PASS+1)) ;; *) _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  [%s] does not contain [%s]\n' "$3" "$1" "$2" >&2 ;; esac
}
assert_not_contains() { # haystack needle msg
  case "$1" in *"$2"*) _A_FAIL=$((_A_FAIL+1)); printf 'FAIL %s\n  [%s] unexpectedly contains [%s]\n' "$3" "$1" "$2" >&2 ;; *) _A_PASS=$((_A_PASS+1)) ;; esac
}
assert_ok() { # cmd... (expect exit 0)
  if "$@" >/dev/null 2>&1; then _A_PASS=$((_A_PASS+1)); else _A_FAIL=$((_A_FAIL+1)); printf 'FAIL expected success: %s\n' "$*" >&2; fi
}
assert_fails() { # cmd... (expect non-zero)
  if "$@" >/dev/null 2>&1; then _A_FAIL=$((_A_FAIL+1)); printf 'FAIL expected failure: %s\n' "$*" >&2; else _A_PASS=$((_A_PASS+1)); fi
}
assert_report() { printf '\n%s passed, %s failed\n' "$_A_PASS" "$_A_FAIL"; [ "$_A_FAIL" -eq 0 ]; }
```

- [ ] **Step 2: 실패하는 테스트 작성** (`scripts/test/test-deploy-facts.sh`)

```sh
#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"

# 9개 언어 존재·순서
assert_eq "go php rust dotnet python node ruby java kotlin" "$DEPLOY_LANGS" "DEPLOY_LANGS 순서"
assert_ok df_known python; assert_fails df_known perl
# 태그 포맷(버전 주입)
assert_eq "py-v0.1.0" "$(printf "$(df_tag python)" 0.1.0)" "python 태그"
assert_eq "go/v0.1.0" "$(printf "$(df_tag go)" 0.1.0)" "go 태그"
assert_eq "v0.1.0" "$(printf "$(df_tag java)" 0.1.0)" "java 태그"
assert_eq "kotlin-v0.1.0" "$(printf "$(df_tag kotlin)" 0.1.0)" "kotlin 태그"
# 시크릿(정확 이름·개수)
assert_eq "MAVEN_GPG_PRIVATE_KEY MAVEN_GPG_PASSPHRASE CENTRAL_TOKEN_USER CENTRAL_TOKEN_PW" "$(df_secrets java)" "java 시크릿"
assert_eq "MAVEN_CENTRAL_USERNAME MAVEN_CENTRAL_PASSWORD SIGNING_IN_MEMORY_KEY SIGNING_IN_MEMORY_KEY_PASSWORD" "$(df_secrets kotlin)" "kotlin 시크릿"
assert_eq "NUGET_API_KEY" "$(df_secrets dotnet)" "dotnet 시크릿"
assert_eq "CARGO_REGISTRY_TOKEN" "$(df_secrets rust)" "rust 시크릿"
assert_eq "" "$(df_secrets python)" "python 시크릿 없음"
assert_eq "" "$(df_secrets go)" "go 시크릿 없음"
# auth 모델
assert_eq "none" "$(df_auth go)" "go auth"
assert_eq "webhook" "$(df_auth php)" "php auth"
assert_eq "api-token" "$(df_auth rust)" "rust auth"
assert_eq "OIDC" "$(df_auth python)" "python auth"
assert_eq "maven-gpg" "$(df_auth java)" "java auth"
# 설치 좌표(go는 버전 주입)
assert_eq "go get github.com/xzawed/KeyCloakSDK/go@v0.1.0" "$(printf "$(df_install go)" 0.1.0)" "go 설치"
assert_eq "pip install keycloak-sdk" "$(df_install python)" "python 설치"
# 모든 언어가 전 필드에 비어있지 않은 값을 반환하는지(check_url 제외 — go는 특수)
for L in $DEPLOY_LANGS; do
  for F in registry auth tag versionbump dryrun install coordinate; do
    v="$(df_$F "$L")"; assert_ok test -n "$v"
  done
done
assert_report
```

Run: `sh scripts/test/test-deploy-facts.sh`
Expected: FAIL — `deploy-facts.sh: No such file` 또는 함수 미정의.

- [ ] **Step 3: `scripts/lib/deploy-facts.sh` 구현**

```sh
#!/usr/bin/env sh
# 9언어 배포 사실 — 단일 진실원천(SSOT). release-readiness.sh·release-trigger.sh·DEPLOY.md가 소비.
# 값은 스펙 §2(docs/superpowers/specs/2026-07-09-unified-deploy-guide-design.md) 실측. 추측 금지.
# 권장 배포 순서(쉬운 인증→어려운 인증).
DEPLOY_LANGS="go php rust dotnet python node ruby java kotlin"

df_known() { case " $DEPLOY_LANGS " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

df_registry() { case "$1" in
  go) echo "Go module proxy (proxy.golang.org)" ;; php) echo "Packagist" ;;
  rust) echo "crates.io" ;; dotnet) echo "NuGet" ;; python) echo "PyPI" ;;
  node) echo "npm" ;; ruby) echo "RubyGems" ;; java) echo "Maven Central" ;;
  kotlin) echo "Maven Central" ;; esac; }

df_auth() { case "$1" in
  go) echo "none" ;; php) echo "webhook" ;; rust|dotnet) echo "api-token" ;;
  python|node|ruby) echo "OIDC" ;; java|kotlin) echo "maven-gpg" ;; esac; }

df_tag() { case "$1" in   # printf 포맷; %s=버전
  go) echo "go/v%s" ;; php) echo "php-v%s" ;; rust) echo "rust-v%s" ;;
  dotnet) echo "dotnet-v%s" ;; python) echo "py-v%s" ;; node) echo "node-v%s" ;;
  ruby) echo "ruby-v%s" ;; java) echo "v%s" ;; kotlin) echo "kotlin-v%s" ;; esac; }

df_secrets() { case "$1" in   # 공백구분 GitHub secret 이름; OIDC/none/webhook은 빈 문자열
  java) echo "MAVEN_GPG_PRIVATE_KEY MAVEN_GPG_PASSPHRASE CENTRAL_TOKEN_USER CENTRAL_TOKEN_PW" ;;
  kotlin) echo "MAVEN_CENTRAL_USERNAME MAVEN_CENTRAL_PASSWORD SIGNING_IN_MEMORY_KEY SIGNING_IN_MEMORY_KEY_PASSWORD" ;;
  dotnet) echo "NUGET_API_KEY" ;; rust) echo "CARGO_REGISTRY_TOKEN" ;; *) echo "" ;; esac; }

df_versionbump() { case "$1" in
  go) echo "none (태그가 버전 SSOT)" ;; php) echo "none (태그가 버전 SSOT)" ;;
  dotnet) echo "none (태그가 -p:Version 주입)" ;;
  java) echo "auto (versions-maven-plugin이 태그값 주입; java/pom.xml은 -SNAPSHOT 유지)" ;;
  rust) echo "rust/Cargo.toml [package].version" ;;
  python) echo "python/pyproject.toml [project].version" ;;
  node) echo "node/package.json version" ;;
  ruby) echo "ruby/lib/keycloak_sdk/version.rb VERSION" ;;
  kotlin) echo "kotlin/build.gradle.kts version" ;; esac; }

df_dryrun() { case "$1" in
  go) echo "go -C go build ./... && go -C go vet ./... && go -C go test ./..." ;;
  php) echo "cd php && composer install && composer audit && vendor/bin/phpstan analyse && vendor/bin/phpunit --testsuite unit" ;;
  rust) echo "cd rust && cargo build --all-targets && cargo test && cargo clippy --all-targets -- -D warnings && cargo fmt --all --check" ;;
  dotnet) echo "dotnet pack dotnet/src/Xzawed.Keycloak.Sdk/Xzawed.Keycloak.Sdk.csproj -c Release" ;;
  python) echo "cd python && python -m build" ;;
  node) echo "cd node && npm run build && npm pack --dry-run" ;;
  ruby) echo "cd ruby && gem build keycloak-sdk.gemspec" ;;
  java) echo "mvn -f java/pom.xml -Prelease -DskipTests -DskipITs=true -Dgpg.skip=true package" ;;
  kotlin) echo "gradle -p kotlin publishToMavenLocal" ;; esac; }

df_install() { case "$1" in   # go/java/kotlin은 %s=버전
  go) echo "go get github.com/xzawed/KeyCloakSDK/go@v%s" ;;
  php) echo "composer require xzawed/keycloak-sdk" ;;
  rust) echo "cargo add keycloak-sdk" ;;
  dotnet) echo "dotnet add package Xzawed.Keycloak.Sdk" ;;
  python) echo "pip install keycloak-sdk" ;;
  node) echo "npm install @xzawed/keycloak-sdk" ;;
  ruby) echo "gem install keycloak-sdk" ;;
  java) echo "io.github.xzawed:keycloak-sdk:%s" ;;
  kotlin) echo "io.github.xzawed:keycloak-sdk-kotlin:%s" ;; esac; }

df_coordinate() { case "$1" in   # 레지스트리상 패키지 식별자(사람용 표시)
  go) echo "github.com/xzawed/KeyCloakSDK/go" ;; php) echo "xzawed/keycloak-sdk" ;;
  rust) echo "keycloak-sdk" ;; dotnet) echo "Xzawed.Keycloak.Sdk" ;;
  python) echo "keycloak-sdk" ;; node) echo "@xzawed/keycloak-sdk" ;;
  ruby) echo "keycloak-sdk" ;; java) echo "io.github.xzawed:keycloak-sdk" ;;
  kotlin) echo "io.github.xzawed:keycloak-sdk-kotlin" ;; esac; }

df_check_url() { case "$1" in   # 200이면 이미 게시됨(readiness). go는 빈 문자열(프록시 온디맨드 — 특수처리)
  python) echo "https://pypi.org/pypi/keycloak-sdk/json" ;;
  node) echo "https://registry.npmjs.org/@xzawed%2Fkeycloak-sdk" ;;
  rust) echo "https://crates.io/api/v1/crates/keycloak-sdk" ;;
  ruby) echo "https://rubygems.org/api/v1/gems/keycloak-sdk.json" ;;
  dotnet) echo "https://api.nuget.org/v3-flatcontainer/xzawed.keycloak.sdk/index.json" ;;
  php) echo "https://repo.packagist.org/p2/xzawed/keycloak-sdk.json" ;;
  java) echo "https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk/maven-metadata.xml" ;;
  kotlin) echo "https://repo1.maven.org/maven2/io/github/xzawed/keycloak-sdk-kotlin/maven-metadata.xml" ;;
  go) echo "" ;; esac; }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `sh scripts/test/test-deploy-facts.sh`
Expected: PASS — `N passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/deploy-facts.sh scripts/test/assert.sh scripts/test/test-deploy-facts.sh
git commit -m "feat(release): 9언어 배포 사실 데이터 모듈(deploy-facts.sh) + sh 테스트 하네스"
```

---

### Task 2: `release-trigger.sh` (print-only 트리거)

**Files:**
- Create: `scripts/release-trigger.sh`
- Test: `scripts/test/test-release-trigger.sh`

**Interfaces:**
- Consumes: `deploy-facts.sh`의 `df_*`.
- Produces: `release-trigger.sh <lang> <version>` — stdout에 버전범프 안내·dry-run·체크리스트·정확한 태그 push 명령·배포후 확인. exit 0. 잘못된 입력 → stderr usage + exit 1. **`git tag`/`git push`를 실행하는 라인이 없다**(출력만).

- [ ] **Step 1: 실패하는 테스트 작성** (`scripts/test/test-release-trigger.sh`)

```sh
#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-trigger.sh"

out="$(sh "$SH" python 0.1.0)"
assert_contains "$out" "git tag py-v0.1.0 && git push origin py-v0.1.0" "python 태그 명령"
assert_contains "$out" "python/pyproject.toml" "python 버전범프 파일"
assert_contains "$out" "python -m build" "python dry-run"
assert_contains "$out" "pending-publisher" "python OIDC 주의(사전등록)"

out="$(sh "$SH" go 0.1.0)"
assert_contains "$out" "git tag go/v0.1.0 && git push origin go/v0.1.0" "go 태그 명령(go/ 접두)"
assert_contains "$out" "버전 파일 수정 불필요" "go 자동버전 안내"

out="$(sh "$SH" java 2.0.0)"
assert_contains "$out" "git tag v2.0.0 && git push origin v2.0.0" "java 태그 명령"
assert_contains "$out" "Portal" "java Maven 수동 release 주의"

# 입력 검증
assert_fails sh "$SH" perl 0.1.0       # 알 수 없는 언어
assert_fails sh "$SH" python 1.2         # 비-semver
assert_fails sh "$SH" python             # 인자 부족

# human-gate 불변식: 스크립트가 실제로 git을 변경하는 라인이 없어야 함(주석/echo 안의 문자열은 허용)
# 실행 라인만 검사: 줄 시작(공백 후)이 git tag/push로 시작하는 라인이 없어야 한다.
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push)|"\$GIT")' "$SH" || true)" "trigger는 git 변경 라인 없음"
assert_report
```

Run: `sh scripts/test/test-release-trigger.sh`
Expected: FAIL — `release-trigger.sh: No such file`.

- [ ] **Step 2: `scripts/release-trigger.sh` 구현**

```sh
#!/usr/bin/env sh
# release-trigger.sh — 언어·버전 입력 시 정확한 태그 push 명령 + 사전 체크리스트를 "출력만" 한다.
# ⚠️ human-gate: 이 스크립트는 git tag/push를 절대 실행하지 않는다. 출력된 명령은 사람이 복사해 실행한다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib/deploy-facts.sh"

usage() { echo "usage: release-trigger.sh <lang> <version>   (lang: $DEPLOY_LANGS; version: X.Y.Z)" >&2; exit 1; }

[ $# -eq 2 ] || usage
LANG_="$1"; VER="$2"
df_known "$LANG_" || { echo "error: unknown lang '$LANG_'" >&2; usage; }
# semver X.Y.Z 검증(프리릴리스 접미 미지원 — 필요 시 확장)
echo "$VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "error: version must be X.Y.Z (got '$VER')" >&2; usage; }

TAG="$(printf "$(df_tag "$LANG_")" "$VER")"
BUMP="$(df_versionbump "$LANG_")"
AUTH="$(df_auth "$LANG_")"

printf '=== 릴리스 트리거 안내: %s v%s ===\n\n' "$LANG_" "$VER"

printf '1) 버전 범프\n'
case "$BUMP" in
  none*|auto*) printf '   버전 파일 수정 불필요 — %s\n' "$BUMP" ;;
  *) printf '   ⚠️ 태그 push 전에 수동으로 올릴 것: %s → 값을 %s로\n' "$BUMP" "$VER" ;;
esac

printf '\n2) dry-run (배포 없이 로컬 산출물 검증)\n   %s\n' "$(df_dryrun "$LANG_")"

printf '\n3) 사전 점검\n   ./scripts/release-readiness.sh %s   # 시크릿·레지스트리·태그 상태 확인\n' "$LANG_"
case "$AUTH" in
  OIDC) printf '   ℹ️ OIDC: pending-publisher가 %s에 사전등록돼 있어야 함(owner=xzawed/repo=KeyCloakSDK/workflow=%s)\n' "$(df_registry "$LANG_")" "$(basename "$(df_workflow_hint "$LANG_")")" ;;
  maven-gpg) printf '   ℹ️ Maven: 배포는 Central Portal 스테이징까지만 자동 — 이후 Portal 콘솔에서 사람이 수동 Publish(2단계)\n' ;;
  api-token) printf '   ℹ️ api-token: %s 시크릿이 등록돼 있어야 함(미설정 시 %s)\n' "$(df_secrets "$LANG_")" "$( [ "$LANG_" = dotnet ] && echo '조용히 스킵' || echo '하드 실패' )" ;;
  webhook) printf '   ℹ️ webhook: Packagist에 xzawed/keycloak-sdk 저장소가 1회 등록돼 있어야 자동 게시됨\n' ;;
  none) printf '   ℹ️ 무설정: 태그 push 시 Go 프록시가 자동 캐시\n' ;;
esac

printf '\n4) 태그 push (⚠️ 사람이 직접 실행 — 이 스크립트는 실행하지 않음)\n   git tag %s && git push origin %s\n' "$TAG" "$TAG"

printf '\n5) 배포 확인\n   GitHub Actions에서 %s 워크플로 성공 확인' "$LANG_"
[ "$AUTH" = maven-gpg ] && printf ' → Central Portal 콘솔에서 수동 Publish'
INST="$(printf "$(df_install "$LANG_")" "$VER")"
printf '\n   배포 후 설치: %s\n' "$INST"
```

**참고:** `df_workflow_hint`는 위 case의 OIDC 분기에서만 쓰인다. deploy-facts.sh에 추가한다:
```sh
df_workflow_hint() { case "$1" in
  python) echo "python-release.yml" ;; node) echo "node-release.yml" ;; ruby) echo "ruby-release.yml" ;;
  *) echo "" ;; esac; }
```
(Task 1 재검토: `df_workflow_hint`를 deploy-facts.sh에 추가하고 test-deploy-facts.sh에 `assert_eq "python-release.yml" "$(df_workflow_hint python)"` 1줄 추가한 뒤 커밋에 포함. 이미 Task 1을 완료했다면 이 함수만 추가하는 소규모 후속 커밋으로 처리.)

- [ ] **Step 3: 실행권한·LF 확인 후 테스트**

Run: `sh scripts/test/test-release-trigger.sh`
Expected: PASS — `N passed, 0 failed`. (특히 human-gate grep 어서션 `0`.)

- [ ] **Step 4: Commit**

```bash
git add scripts/release-trigger.sh scripts/test/test-release-trigger.sh scripts/lib/deploy-facts.sh scripts/test/test-deploy-facts.sh
git commit -m "feat(release): release-trigger.sh (print-only 태그 명령 안내, human-gate) + df_workflow_hint"
```

---

### Task 3: `release-readiness.sh` (읽기전용 준비상태 대시보드)

**Files:**
- Create: `scripts/release-readiness.sh`
- Test: `scripts/test/test-release-readiness.sh`

**Interfaces:**
- Consumes: `deploy-facts.sh`의 `df_*`.
- Produces: `release-readiness.sh [lang ...]`(인자 없으면 전체) — 언어별 1행 요약(시크릿/레지스트리/태그/판정). exit 0(읽기전용). 순수 판정 함수 `rr_verdict <secrets_state> <registry_state> <tag_state>`를 분리해 단위테스트 가능하게 한다.
- 외부 호출은 재정의 가능한 래퍼로: `rr_secret_set <name>`(gh) · `rr_url_exists <url>`(curl) · `rr_tag_exists <pattern>`(git). 테스트는 이들을 stub한다.

- [ ] **Step 1: 실패하는 테스트 작성** (`scripts/test/test-release-readiness.sh`)

```sh
#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
SH="$DIR/../release-readiness.sh"

# 순수 판정 함수 단위테스트(외부호출 stub — 소싱해 override)
. "$SH" --lib   # --lib: 함수만 로드하고 main 실행 안 함
assert_eq "✅ 준비완료" "$(rr_verdict set exists none)" "시크릿O·미게시·태그無 → 준비완료"
assert_eq "⚠️ 설정필요: 시크릿" "$(rr_verdict unset exists none)" "시크릿X → 설정필요"
assert_eq "ℹ️ 이미 게시됨" "$(rr_verdict set published none)" "이미 게시 → 안내"
assert_eq "✅ 준비완료" "$(rr_verdict na exists none)" "OIDC(시크릿 na) → 준비완료"

# 스모크: 실제 실행(읽기전용, gh/curl 없어도 크래시 없이 ?로 격리)
out="$(sh "$SH" go python 2>/dev/null || true)"
assert_contains "$out" "go" "go 행 존재"
assert_contains "$out" "python" "python 행 존재"

# 상태 불변식: readiness는 git/파일을 변경하는 라인이 없어야 함
assert_eq "0" "$(grep -cE '^[[:space:]]*(git[[:space:]]+(tag|push|commit|add|checkout)|rm|mv|>[^&])' "$SH" || true)" "readiness는 상태변경 없음"
# 시크릿 값 출력 금지: gh secret list는 --json 없이 이름만; 값 echo 패턴 부재
assert_eq "0" "$(grep -cE 'secret (view|get)|gh api.*secrets' "$SH" || true)" "시크릿 값 미조회"
assert_report
```

Run: `sh scripts/test/test-release-readiness.sh`
Expected: FAIL — 파일 없음.

- [ ] **Step 2: `scripts/release-readiness.sh` 구현**

```sh
#!/usr/bin/env sh
# release-readiness.sh — 언어별 실배포 준비상태(시크릿·레지스트리·태그)를 읽기전용으로 리포트.
# ⚠️ 읽기전용: 어떤 상태도 변경하지 않는다. 시크릿 값은 조회/출력하지 않는다(이름·존재만).
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/lib/deploy-facts.sh"

# 외부호출 래퍼(테스트에서 override 가능) — 실패는 조용히 '?'로 격리.
rr_secret_set() { # <name> → 0 if a repo secret with this name exists
  command -v gh >/dev/null 2>&1 || return 2
  gh secret list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}
rr_url_exists() { # <url> → 0 if HTTP 200
  command -v curl >/dev/null 2>&1 || return 2
  curl -sfI "$1" >/dev/null 2>&1 || curl -sf "$1" >/dev/null 2>&1
}
rr_tag_exists() { # <glob> → 0 if any matching tag
  [ -n "$(git tag -l "$1" 2>/dev/null | head -1)" ]
}

# 순수 판정(단위테스트 대상): secrets∈{set,unset,na} registry∈{published,exists(미게시),unknown} tag∈{none,present}
rr_verdict() { # <secrets> <registry> <tag>
  if [ "$3" = present ]; then echo "ℹ️ 태그 이미 존재"; return; fi
  if [ "$2" = published ]; then echo "ℹ️ 이미 게시됨"; return; fi
  case "$1" in
    unset) echo "⚠️ 설정필요: 시크릿" ;;
    *) echo "✅ 준비완료" ;;   # set 또는 na(OIDC/none/webhook)
  esac
}

rr_secrets_state() { # <lang> → set|unset|na
  s="$(df_secrets "$1")"
  [ -z "$s" ] && { echo na; return; }
  for name in $s; do rr_secret_set "$name" || { echo unset; return; }; done
  echo set
}

rr_registry_state() { # <lang> → published|exists|unknown  (exists = 확인됨·미게시)
  url="$(df_check_url "$1")"
  [ -z "$url" ] && { echo exists; return; }   # go: 프록시 온디맨드 — 미게시로 간주
  if rr_url_exists "$url"; then echo published; else
    # curl 자체가 없거나 네트워크 실패면 unknown, 200 아님이면 exists(미게시)
    command -v curl >/dev/null 2>&1 && echo exists || echo unknown
  fi
}

rr_row() { # <lang>
  L="$1"
  sec="$(rr_secrets_state "$L")"
  reg="$(rr_registry_state "$L")"
  tagpat="$(printf "$(df_tag "$L")" '*')"
  if rr_tag_exists "$tagpat"; then tag=present; else tag=none; fi
  verdict="$(rr_verdict "$sec" "$reg" "$tag")"
  printf '%-8s auth=%-10s secrets=%-6s registry=%-10s tag=%-8s %s\n' "$L" "$(df_auth "$L")" "$sec" "$reg" "$tag" "$verdict"
}

rr_main() {
  langs="$*"; [ -z "$langs" ] && langs="$DEPLOY_LANGS"
  command -v gh   >/dev/null 2>&1 || echo "ℹ️ gh 미설치/미인증 — secrets는 '?(na)'로 표시" >&2
  command -v curl >/dev/null 2>&1 || echo "ℹ️ curl 미설치 — registry는 'unknown'으로 표시" >&2
  for L in $langs; do df_known "$L" && rr_row "$L" || echo "?? unknown lang: $L" >&2; done
}

# --lib: 함수만 로드(테스트용). 그 외: main 실행.
[ "${1:-}" = "--lib" ] || rr_main "$@"
```

- [ ] **Step 3: 테스트 통과 확인**

Run: `sh scripts/test/test-release-readiness.sh`
Expected: PASS. (판정 함수 단위테스트 + 스모크 + 상태 불변식 grep.)

- [ ] **Step 4: 실제 스모크(선택, 네트워크 있으면)**

Run: `sh scripts/release-readiness.sh`
Expected: 9행 출력. 미게시 패키지는 `registry=exists`, 시크릿 미설정은 `⚠️ 설정필요`. 크래시 없음.

- [ ] **Step 5: Commit**

```bash
git add scripts/release-readiness.sh scripts/test/test-release-readiness.sh
git commit -m "feat(release): release-readiness.sh (읽기전용 준비상태 대시보드, 시크릿 값 미노출)"
```

---

### Task 4: 통합 `DEPLOY.md`

**Files:**
- Modify: `DEPLOY.md` (현재 79줄, Java·Python만 → 9언어 통합 재작성)
- Test: `scripts/test/test-deploy-md.sh` (완결성 검사)

**Interfaces:**
- Consumes: 스펙 §2·§3 + `deploy-facts.sh`(사실 일치 확인).

- [ ] **Step 1: 완결성 검사 테스트 작성** (`scripts/test/test-deploy-md.sh`)

```sh
#!/usr/bin/env sh
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
. "$DIR/../lib/deploy-facts.sh"
DOC="$DIR/../../DEPLOY.md"
body="$(cat "$DOC")"

# 9개 언어 섹션·태그·시크릿·설치좌표가 모두 문서에 존재
for L in $DEPLOY_LANGS; do
  assert_contains "$body" "$(printf "$(df_tag "$L")" X.Y.Z | sed 's/X.Y.Z/*/')" "태그포맷 $L"
  for s in $(df_secrets "$L"); do assert_contains "$body" "$s" "시크릿 $s"; done
done
# 두 도우미 스크립트 참조
assert_contains "$body" "scripts/release-readiness.sh" "readiness 참조"
assert_contains "$body" "scripts/release-trigger.sh" "trigger 참조"
# 권장 순서·인증모델 그룹 헤딩 존재
assert_contains "$body" "준비상태 매트릭스" "매트릭스 섹션"
assert_contains "$body" "human-gate" "human-gate 원칙"
assert_report
```

Run: `sh scripts/test/test-deploy-md.sh`
Expected: FAIL — 기존 DEPLOY.md에 7개 언어 태그/시크릿/스크립트 참조 없음.

- [ ] **Step 2: `DEPLOY.md` 재작성**

스펙 §3 구조를 따라 재작성한다(내용은 스펙 §2 실측 + `deploy-facts.sh` 값과 일치). 섹션:
1. **§0 개요 + 준비상태 매트릭스** — 스펙 §2 표(9언어×레지스트리·인증·태그·버전범프·시크릿개수·설치좌표) + 권장 배포 순서(`go php rust dotnet python node ruby java kotlin`) + "지금 상태: `./scripts/release-readiness.sh`".
2. **§1 공통 원칙** — 태그 드리븐 · `needs:verify` 게이트 · human-gate · 되돌릴 수 없음 · dry-run 필수 · 버전범프 규칙(자동 4: go/php/dotnet/java vs 수동 5: rust/python/node/ruby/kotlin).
3. **§2 인증 모델별 1회 설정** — A. Maven+GPG(Java·Kotlin: 네임스페이스 검증·GPG키 생성+키서버 배포·Portal 토큰·시크릿[언어별 이름 명기]·2단계 수동 release) / B. OIDC(Python·Node·Ruby: pending-publisher 값 owner=xzawed·repo=KeyCloakSDK·workflow파일명·environment[Ruby=release]·Ruby 닭달걀) / C. api-token(.NET·Rust: 토큰 발급·시크릿 등록·미설정 시 동작[.NET 조용히 스킵/Rust 하드실패]) / D. webhook(PHP: Packagist 저장소 등록) / E. none(Go).
4. **§3 언어별 상세**(9, 권장순서) — 각: 1회 설정(→§2 그룹 참조) · 버전 범프 위치(`df_versionbump`) · dry-run(`df_dryrun`) · 태그·트리거(`df_tag` + `./scripts/release-trigger.sh <lang> <ver>` 안내) · 배포 확인 · 설치 좌표(`df_install`).
5. **§4 릴리스 절차 요약** — 버전범프 → dry-run → `release-readiness.sh` → `release-trigger.sh` → 사람 태그 push → Actions 확인 → (Maven) Portal 수동 release.
6. **§5 공통 주의** — 기존 DEPLOY.md의 "공통 주의" 유지·확장.

각 태그/시크릿명/설치명은 반드시 `deploy-facts.sh`와 문자열 일치(테스트가 강제).

- [ ] **Step 3: 완결성 테스트 통과 확인**

Run: `sh scripts/test/test-deploy-md.sh`
Expected: PASS.

- [ ] **Step 4: 전체 테스트 재실행(무회귀)**

Run: `for t in scripts/test/test-*.sh; do echo "== $t =="; sh "$t" || exit 1; done`
Expected: 모든 테스트 PASS.

- [ ] **Step 5: Commit**

```bash
git add DEPLOY.md scripts/test/test-deploy-md.sh
git commit -m "docs(deploy): DEPLOY.md 9언어 통합 — 준비상태 매트릭스+인증모델별 1회설정+언어별 상세+도우미 연동"
```

---

## Self-Review (계획 검토)

**1. 스펙 커버리지:**
- §3 DEPLOY.md 구조 → Task 4. ✓
- §4 release-readiness → Task 3. ✓
- §5 release-trigger → Task 2. ✓
- §2 사실 레퍼런스 → Task 1(deploy-facts.sh SSOT) + Task 4(문서 반영). ✓
- §6 검증(trigger 출력 assert·push 미호출 grep·readiness 읽기전용) → Task 2/3 테스트. ✓
- 전역 제약(태그 미push·시크릿 값 미노출·워크플로 무수정) → Task 2/3 불변식 grep 어서션 + Task 범위(워크플로 미변경). ✓

**2. 플레이스홀더 스캔:** 스크립트·테스트는 완전한 코드. DEPLOY.md(Task 4)는 산출물 자체가 문서라 구조+데이터소스(§2·deploy-facts.sh)를 명시하고 완결성 테스트로 강제 — "TBD" 없음. ✓

**3. 타입 일관성:** `df_tag`는 printf 포맷(%s), `df_install`의 go/java/kotlin도 %s — trigger/readiness/test 모두 `printf "$(df_tag …)" "$VER"` 일관 사용. `rr_verdict` 시그니처(secrets/registry/tag)가 Task 3 전체에서 일관. `df_workflow_hint`는 Task 2 Step 2에서 deploy-facts.sh에 추가(Task 1 보강 명시). ✓

**의존성:** Task 1 → 2 → 3 → 4 순차(각 후속이 deploy-facts.sh 소비). 각 태스크는 독립 테스트 통과로 리뷰 게이트 성립.
