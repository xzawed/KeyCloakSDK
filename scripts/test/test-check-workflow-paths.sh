#!/usr/bin/env sh
# check-workflow-paths.mjs 자가테스트 — `paths:` 로 거르는 워크플로가 PR 에서 쓰는 공유 파일을 그 `paths:` 가 받는가
# (등록부 guards-outside-their-own-pr-signal).
#
# 픽스처 저장소는 여기서 만든다 — 레인 하나(lane.yml)가 scripts/run-me.mjs 를 부르고(1단) 그것이 scripts/lib/dep.mjs 를 쓴다(2단).
# harness/h.sh 는 스텝의 working-directory 와 `cd` 두 길로 부른다. PR 에서 건너뛰는 잡 하나 · paths 없는 PR 워크플로 하나 ·
# PR 트리거가 없는 워크플로 하나가 scripts/skipped.sh 를 쓴다 — 셋 다 대조 대상이 아니다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-workflow-paths.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T="$TMP/t"
LANE="$T/.github/workflows/lane.yml"

fresh() {
  rm -rf "$T"
  mkdir -p "$T/.github/workflows" "$T/scripts/lib" "$T/harness" "$T/lang"
  printf '%s\n' "import './lib/dep.mjs'" "const DEP = 'scripts/lib/dep.mjs'" > "$T/scripts/run-me.mjs"
  printf '%s\n' 'export const x = 1' > "$T/scripts/lib/dep.mjs"
  printf '%s\n' 'echo h' > "$T/harness/h.sh"
  printf '%s\n' 'echo c' > "$T/scripts/commented.sh"
  printf '%s\n' 'echo s' > "$T/scripts/skipped.sh"
  : > "$T/lang/x.txt"
  cat > "$LANE" <<'EOF'
name: lane
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]
    paths: ['lang/**', '.github/workflows/lane.yml', 'scripts/run-me.mjs', 'scripts/lib/dep.mjs', 'harness/h.sh']
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: node scripts/run-me.mjs --flag
      # - run: sh scripts/commented.sh
      - name: 하네스(작업 디렉터리)
        working-directory: harness
        run: sh ./h.sh
      - name: 하네스(cd)
        run: |
          # sh scripts/commented.sh — 주석은 실행이 아니다
          cd harness && ./h.sh
  nightly-only:
    if: github.event_name == 'schedule' || github.event_name == 'workflow_dispatch'
    runs-on: ubuntu-latest
    steps:
      - run: sh scripts/skipped.sh
EOF
  cat > "$T/.github/workflows/all.yml" <<'EOF'
name: all
on:
  pull_request:
jobs:
  a:
    runs-on: ubuntu-latest
    steps:
      - run: sh scripts/skipped.sh
EOF
  cat > "$T/.github/workflows/nightly.yml" <<'EOF'
name: nightly
on:
  schedule:
    - cron: '0 0 * * *'
jobs:
  n:
    runs-on: ubuntu-latest
    steps:
      - run: sh scripts/skipped.sh
EOF
  git -C "$T" init -q
  git -C "$T" config core.autocrlf false
  git -C "$T" add -A
}
run() {
  git -C "$T" add -A
  OUT="$(node "$GUARD" "$T" "$@" 2>&1)" && RC=0 || RC=$?
}
# drop_path <글롭> — lane.yml 의 pull_request paths 에서 그 항목을 뺀다.
drop_path() { sed -i "s|, '$1'||" "$LANE"; assert_not_contains "$(cat "$LANE")" "'$1'" "(paths 에서 $1 을 뺐는지 먼저 본다)"; }

# ── 대조군: 정상 픽스처 ─────────────────────────────────────────────────────────────────────
fresh
run
assert_eq 0 "$RC" "정상 픽스처는 exit 0 — 출력: $OUT"
assert_contains "$OUT" "ok    lane.yml" "대상 워크플로를 찍는다"
# 쓰는 공유 파일은 셋(1단 run-me · 2단 dep · 하네스 h) — 주석의 commented.sh 와 PR 에서 건너뛰는 잡의 skipped.sh 는 아니다.
assert_contains "$OUT" "대상 1 · 쓰는 공유 파일 3 · PR 에서 건너뛰는 잡 1 · FAIL 0 · 판정 불가 0" "대상 · 쓰는 파일 · 건너뛰는 잡을 실제로 센다"
assert_not_contains "$OUT" "commented.sh" "주석 속 파일을 쓰는 것으로 세지 않는다"

# ── 1단 · 2단 ────────────────────────────────────────────────────────────────────────────────
fresh; drop_path scripts/run-me.mjs; run
assert_eq 1 "$RC" "run 이 대는 파일을 paths 가 안 받으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "잡 \`build\` 가 scripts/run-me.mjs 를 쓰는데 \`pull_request.paths\` 가 그것을 받지 않는다" "1단을 지목한다"
fresh; drop_path scripts/lib/dep.mjs; run
assert_eq 1 "$RC" "스크립트가 쓰는 파일을 paths 가 안 받으면 exit 1 — 출력: $OUT"
assert_contains "$OUT" "→ scripts/run-me.mjs 가 scripts/lib/dep.mjs 를 쓰는데" "2단을 그 경유와 함께 지목한다"
# .mjs 의 상대 가져오기만으로도 — 저장소 경로 글자를 지워도 `import './lib/dep.mjs'` 가 그 파일을 쓴다(Grok 적대 레그).
fresh; printf '%s\n' "import './lib/dep.mjs'" > "$T/scripts/run-me.mjs"; drop_path scripts/lib/dep.mjs; run
assert_eq 1 "$RC" ".mjs 의 상대 가져오기를 2단으로 안 본다 — 출력: $OUT"
assert_contains "$OUT" "→ scripts/run-me.mjs 가 scripts/lib/dep.mjs 를 쓰는데" "상대 가져오기를 그 스크립트 자리에서 푼다"
fresh; printf '%s\n' "const u = new URL('./lib/dep.mjs', import.meta.url)" > "$T/scripts/run-me.mjs"; drop_path scripts/lib/dep.mjs; run
assert_eq 1 "$RC" "new URL(…, import.meta.url) 을 2단으로 안 본다 — 출력: $OUT"

# ── 작업 디렉터리 · cd ───────────────────────────────────────────────────────────────────────
# 두 길이 같은 파일을 대므로 한 길씩 남긴다 — 각 길만으로도 harness/h.sh 를 찾아야 한다.
fresh; sed -i 's|          cd harness \&\& ./h.sh|          true|' "$LANE"; drop_path harness/h.sh; run
assert_eq 1 "$RC" "스텝 working-directory 로 부른 파일을 못 찾았다 — 출력: $OUT"
assert_contains "$OUT" "harness/h.sh 를 쓰는데" "working-directory 를 푼다"
fresh; sed -i 's|        run: sh ./h.sh|        run: "true"|' "$LANE"; drop_path harness/h.sh; run
assert_eq 1 "$RC" "cd 뒤 상대 경로로 부른 파일을 못 찾았다 — 출력: $OUT"
assert_contains "$OUT" "harness/h.sh 를 쓰는데" "cd 를 따라간다"
# `$GITHUB_WORKSPACE/` 는 저장소 루트다 — 작업 디렉터리가 harness 여도.
fresh; sed -i 's|        run: sh ./h.sh|        run: node "$GITHUB_WORKSPACE/scripts/run-me.mjs"|' "$LANE"; sed -i 's|      - run: node scripts/run-me.mjs --flag|      - run: "true"|' "$LANE"; drop_path scripts/run-me.mjs; run
assert_eq 1 "$RC" "\$GITHUB_WORKSPACE 로 부른 파일을 못 찾았다 — 출력: $OUT"
assert_contains "$OUT" "scripts/run-me.mjs 를 쓰는데" "\$GITHUB_WORKSPACE 를 저장소 루트로 푼다"

# ── PR 에서 건너뛰는 잡 ──────────────────────────────────────────────────────────────────────
# 이벤트 등식의 `||` 에 pull_request 가 있거나, 그 꼴이 아닌 조건이면 PR 에서 돈다(보수적).
fresh; sed -i "s|    if: github.event_name == 'schedule' \|\| github.event_name == 'workflow_dispatch'|    if: github.event_name == 'schedule' \|\| github.event_name == 'pull_request'|" "$LANE"; run
assert_eq 1 "$RC" "pull_request 가 든 if 를 건너뛰는 잡으로 봤다 — 출력: $OUT"
assert_contains "$OUT" "잡 \`nightly-only\` 가 scripts/skipped.sh 를 쓰는데" "PR 에서 도는 잡의 파일을 지목한다"
fresh; sed -i "s|    if: github.event_name == 'schedule' \|\| github.event_name == 'workflow_dispatch'|    if: always()|" "$LANE"; run
assert_eq 1 "$RC" "이벤트 등식이 아닌 if 를 건너뛰는 잡으로 봤다 — 출력: $OUT"

# ── 판정 불가 · 하한 · 옵션 ──────────────────────────────────────────────────────────────────
fresh; sed -i '2,7d' "$LANE"; sed -i "1a on: { pull_request: { paths: ['lang/**'] } }" "$LANE"; run
assert_eq 2 "$RC" "트리거를 읽을 수 없는 꼴을 통과로 넘겼다 — 출력: $OUT"
assert_contains "$OUT" "판정 불가" "판정 불가를 말한다"
fresh; run --min-workflows=2
assert_eq 1 "$RC" "대상 하한을 못 지켰는데 통과했다"
assert_contains "$OUT" "paths 로 거르는 PR 워크플로가 1개뿐이다(기대 2개 이상)" "대상 하한이 공허를 막는다"
fresh; run --min-files=4
assert_eq 1 "$RC" "파일 하한을 못 지켰는데 통과했다"
assert_contains "$OUT" "쓰는 공유 파일이 3개뿐이다(기대 4개 이상)" "파일 하한이 공허를 막는다"
fresh; run --min-files=3 --min-workflows=1
assert_eq 0 "$RC" "실측과 같은 하한에서 통과해야 한다 — 출력: $OUT"
fresh; run --no-such-option
assert_eq 2 "$RC" "모르는 옵션을 받아들였다"

# ── 실제 트리 — CI 와 같은 호출(인자 없는 루트 · CI 의 하한) ─────────────────────────────────
# 루트를 주지 않으면 이 가드 자리(`scripts/` 의 부모)다. CI 는 그 꼴로 부른다 — 자가테스트도 그 꼴을 탄다
# (등록부 selftests-miss-the-real-callsite).
OUT="$(node "$GUARD" --min-workflows=12 --min-files=105 2>&1)" && RC=0 || RC=$?
assert_eq 0 "$RC" "실제 트리 — 출력: $OUT"

assert_report
