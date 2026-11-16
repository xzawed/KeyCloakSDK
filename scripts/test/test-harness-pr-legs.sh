#!/usr/bin/env sh
# harness-pr-legs.mjs 자가테스트 — PR 이 하네스의 무거운 레그(score-all · install-all)를 깨울지의 판정과, harness.yml 의 그
# 배선(등록부 harness-legs-skip-pull-request).
#
# 판정은 진짜 harness.yml 의 pull_request.paths 로 한다(패턴을 여기 다시 적지 않는다). 배선은 진짜 파일이 맞아야 하고,
# 한 군데씩 비튼 사본은 각자 그 이름으로 실패해야 한다 — 특히 `!cancelled()` 가 빠지면 야간에 두 레그가 조용히 건너뛰어진다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
LEGS="$ROOT/scripts/harness-pr-legs.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

decide() { printf '%s\n' "$@" | node "$LEGS" "$ROOT" 2>/dev/null; }

# ── 판정 ─────────────────────────────────────────────────────────────────────────────────────────
assert_eq "heavy=true" "$(decide harness/install/install-verify.sh)" "[PR 레그] 설치 파이프라인을 고친 PR 이 install-all 을 안 깨운다"
assert_eq "heavy=true" "$(decide harness/suites/run-suite.sh)" "[PR 레그] 스위트 판정을 고친 PR 이 score-all 을 안 깨운다"
assert_eq "heavy=true" "$(decide .github/workflows/harness.yml)" "[PR 레그] 워크플로 자신을 고친 PR 이 레그를 안 깨운다"
assert_eq "heavy=true" "$(decide scripts/check-versions.mjs)" "[PR 레그] install-verify.sh 가 쓰는 check-versions.mjs 를 고친 PR 이 레그를 안 깨운다"
assert_eq "heavy=true" "$(decide go/jwt.go harness/apps/node/server.js)" "[PR 레그] go 와 하네스 앱을 함께 고친 PR 이 레그를 안 깨운다"
assert_eq "heavy=false" "$(decide go/jwt.go go/README.md)" "[PR 레그] go/** 만 고친 PR 이 레그를 깨운다 — go/** 는 mvp-go 몫이다"
assert_eq "heavy=false" "$(decide harness/README.md harness/install/README.md)" "[PR 레그] 문서만 고친 PR 이 레그를 깨운다"
assert_eq "heavy=false" "$(decide python/src/keycloak_sdk/auth.py)" "[PR 레그] 워크플로 paths 밖 파일이 레그를 깨운다"
assert_eq "heavy=false" "$(printf '' | node "$LEGS" "$ROOT" 2>/dev/null)" "[PR 레그] 바뀐 파일이 없는데 레그를 깨운다"
_why="$(printf '%s\n' harness/verify.sh | node "$LEGS" "$ROOT" 2>&1 >/dev/null)"
assert_contains "$_why" "레그를 깨운 파일: harness/verify.sh" "[PR 레그] 레그를 깨운 파일을 말하지 않는다"

# 못 읽으면 판정하지 않는다 — exit 2(그 PR 의 changes 잡이 빨갛다). 「깨울 것 없음」으로 끝나면 조용한 건너뜀이다.
mkdir -p "$TMP/none"
_rc=0
_o="$(printf 'harness/x.sh\n' | node "$LEGS" "$TMP/none" 2>&1)" || _rc=$?
assert_eq "2" "$_rc" "[PR 레그] 워크플로를 못 읽었는데 0 으로 끝난다"
assert_not_contains "$_o" "heavy=" "[PR 레그] 워크플로를 못 읽었는데 판정을 낸다"

# ── 배선 ─────────────────────────────────────────────────────────────────────────────────────────
_rc=0
_o="$(node "$LEGS" --wiring "$ROOT" 2>&1)" || _rc=$?
assert_eq "0" "$_rc" "[PR 레그] 진짜 harness.yml 의 배선이 어긋났다: $_o"

# 비튼 사본 — 한 군데씩. 각자 그 어긋남의 이름으로 exit 1 이어야 한다.
WF="$ROOT/.github/workflows/harness.yml"
twist() { # name sed-expression expected-message
  mkdir -p "$TMP/$1/.github/workflows"
  sed "$2" "$WF" > "$TMP/$1/.github/workflows/harness.yml"
  _trc=0
  _to="$(node "$LEGS" --wiring "$TMP/$1" 2>&1)" || _trc=$?
  assert_eq "1" "$_trc" "[PR 레그·배선] $1 — 어긋난 배선이 통과한다"
  assert_contains "$_to" "$3" "[PR 레그·배선] $1 — 어긋남을 그 이름으로 말하지 않는다"
}
twist no-cancelled 's/!cancelled() \&\& //' "잡의 if 가 고정한 글자와 다르다"
twist no-heavy "s/ || needs.changes.outputs.heavy == 'true'//" "잡의 if 가 고정한 글자와 다르다"
twist no-needs '/^    needs: changes$/d' "needs: changes 가 없다"
twist pipe 's#git diff --name-only "origin/$BASE_REF...HEAD" > "$RUNNER_TEMP/changed.txt"#git diff --name-only "origin/$BASE_REF...HEAD" | tee "$RUNNER_TEMP/changed.txt"#' "diff 를 파일로 받아 판정하지 않는다"
twist no-output 's/heavy: ${{ steps.legs.outputs.heavy }}/heavy: true/' "outputs.heavy 를 steps.legs 에서 내지 않는다"
twist changes-always "s/^    if: github.event_name == 'pull_request'$/    if: always()/" "changes 잡의 if 가 PR 전용이 아니다"
# 주석 속 사본은 배선이 아니다 — 진짜 if 를 지우고 주석에만 남기면 실패해야 한다.
twist commented-if "s/^    if: \${{ !cancelled()/    # if: \${{ !cancelled()/" "잡의 if 가 고정한 글자와 다르다"
# 조용히 망가지는 편집(Grok 레그) — 잡 if 의 글자는 그대로인데 레그가 안 돈다.
twist rename-id 's/^        id: legs$/        id: decide/' "id: legs 스텝이 없다"
twist step-if 's/^        id: legs$/        id: legs\n        if: false/' "잡 if 말고 if 가 있다"
twist output-env 's/^          BASE_REF: \${{ github.base_ref }}$/          BASE_REF: ${{ github.base_ref }}\n          GITHUB_OUTPUT: \/dev\/null/' "GITHUB_OUTPUT 을 덮는다"
twist no-schedule '/^  schedule:$/,+1d' "schedule 트리거가 없다"
twist no-dispatch '/^  workflow_dispatch:$/d' "workflow_dispatch 트리거가 없다"
twist shared-group "s/^  group: harness-.*$/  group: harness/" "concurrency 가 고정한 글자와 다르다"
twist cancel-all "s/^  cancel-in-progress: .*$/  cancel-in-progress: true/" "concurrency 가 고정한 글자와 다르다"
twist no-fetch-depth 's/with: { fetch-depth: 0 }/with: { persist-credentials: false }/' "fetch-depth: 0 이 없다"

assert_report
