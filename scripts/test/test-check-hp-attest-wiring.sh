#!/usr/bin/env sh
# `check-hp-attest-wiring.mjs` 자가테스트 — 레인의 적대 경로 행렬 attest 배선(단계가 있다 · 조건이 없다 · 행렬과
# attest 가 읽는 공용 파일만 바꾼 PR 에서도 레인이 생긴다).
#
# ⚠️ 픽스처만 쓴다. 실제 트리 대조는 같은 잡이 `node scripts/check-hp-attest-wiring.mjs` 로 따로 한다.
# 무게는 셋이다.
#   (a) 양성 — 지우거나(단계 · 주석 처리) 무른(`if:` · `continue-on-error:` — 단계와 잡) 배선, 공용 파일이 빠진
#       `paths:`(플로우 · 블록 · 한 트리거만), 없는 트리거, 철자 틀린 `--lang`, 레인 없이 들어온 언어를 잡는다.
#   (b) 음성 — 정당한 표기(넓은 글롭 · `paths:` 없는 트리거 · 키와 같은 들여쓰기의 블록 시퀀스)를 통과시킨다.
#   (c) 공허 — 읽지 못한 모양(플로우 매핑 `on:` · `paths-ignore` · 변수 `--lang`)과 언어 0 은 통과가 아니라 판정 불가다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
GUARD="$DIR/../check-hp-attest-wiring.mjs"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

put() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# 플로우 맵 트리거 + 한 줄 run — go-ci.yml 모양.
lane_flow() { # $1=루트 $2=언어
  put "$1/.github/workflows/$2-ci.yml" <<EOF
name: $2 CI
on:
  push: { branches: [main], paths: ['$2/**', '.github/workflows/$2-ci.yml', 'scripts/check-hp-attest.mjs', 'scripts/test/test-security-defaults.sh'] }
  pull_request: { branches: [main], paths: ['$2/**', '.github/workflows/$2-ci.yml', 'scripts/check-hp-attest.mjs', 'scripts/test/test-security-defaults.sh'] }
  workflow_dispatch:
permissions:
  contents: read
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@0000000000000000000000000000000000000000
      - name: unit
        env:
          HP_ATTEST_DIR: \${{ runner.temp }}/hp-attest
          HP_ATTEST_NONCE: \${{ github.run_id }}
        run: echo unit
      - name: attest
        working-directory: .
        env:
          HP_ATTEST_DIR: \${{ runner.temp }}/hp-attest
          HP_ATTEST_NONCE: \${{ github.run_id }}
        run: node scripts/check-hp-attest.mjs "\$HP_ATTEST_DIR" --nonce "\$HP_ATTEST_NONCE" --lang $2
EOF
}

# 블록 트리거(플로우 시퀀스 paths 와 블록 시퀀스 paths) + 블록 스칼라 run — kotlin-ci.yml 모양.
lane_block() { # $1=루트 $2=언어
  put "$1/.github/workflows/$2-ci.yml" <<EOF
name: $2 CI
on:
  push:
    branches: [main]
    paths: ['$2/**', 'scripts/check-hp-attest.mjs', 'scripts/test/test-security-defaults.sh']
  pull_request:
    branches: [main]
    paths:
      - '$2/**'
      - 'scripts/check-hp-attest.mjs'
      - 'scripts/test/test-security-defaults.sh'
jobs:
  build-test:
    runs-on: ubuntu-latest
    steps:
      - name: unit
        run: echo unit
      - name: attest
        run: |
          set -eu
          node scripts/check-hp-attest.mjs "\$HP_ATTEST_DIR" --nonce "\$HP_ATTEST_NONCE" --lang $2
EOF
}

BASE="$TMP/_base"
mkdir -p "$BASE"
git -C "$BASE" init -q
git -C "$BASE" config core.autocrlf false
printf 'module x\n' | put "$BASE/lang-a/go.mod"
printf '{}\n' | put "$BASE/lang-b/package.json"
lane_flow "$BASE" lang-a
lane_block "$BASE" lang-b
git -C "$BASE" add -A

fork() { CASE="$TMP/$1"; cp -R "$BASE" "$CASE"; }
run() {
  git -C "$CASE" add -A
  set +e
  OUT="$(node "$GUARD" "$CASE" 2>&1)"
  CODE=$?
  set -e
}
expect() { # expect <이름> <종료코드> <출력에 있어야 할 것>
  assert_eq "$2" "$CODE" "[$1] 종료코드 — 출력: $OUT"
  assert_contains "$OUT" "$3" "[$1] 출력에 「$3」"
}
WA="$TMP/%s/.github/workflows/lang-a-ci.yml"
wa() { printf "$WA" "$1"; }
wb() { printf '%s/.github/workflows/lang-b-ci.yml' "$TMP/$1"; }

# ═══ 기본 — 두 모양 다 통과 ════════════════════════════════════════════════════════════
fork base; run
expect base 0 "ok    lang-a"
assert_contains "$OUT" "ok    lang-b" "[base] 블록 모양 레인"
assert_contains "$OUT" "attest 단계 2" "[base] 단계 수"

# ═══ (a) 양성 ══════════════════════════════════════════════════════════════════════════
fork step-deleted; sed -i '/- name: attest/,$d' "$(wa step-deleted)"; run
expect step-deleted 1 "lang-a: attest"

fork step-if; sed -i 's/^      - name: attest$/      - name: attest\n        if: false/' "$(wa step-if)"; run
expect step-if 1 "attest 단계에 \`if:\`"

fork step-coe; sed -i 's/^      - name: attest$/      - name: attest\n        continue-on-error: true/' "$(wb step-coe)"; run
expect step-coe 1 "attest 단계에 \`continue-on-error:\`"

fork job-if; sed -i "s/^  build:\$/  build:\n    if: github.event_name == 'schedule'/" "$(wa job-if)"; run
expect job-if 1 "잡 \`build\` 에 \`if:\`"

fork job-coe; sed -i 's/^  build-test:$/  build-test:\n    continue-on-error: true/' "$(wb job-coe)"; run
expect job-coe 1 "잡 \`build-test\` 에 \`continue-on-error:\`"

fork flow-pr-only; sed -i "/^  pull_request:/s|, 'scripts/test/test-security-defaults.sh'||" "$(wa flow-pr-only)"; run
expect flow-pr-only 1 "\`pull_request.paths\` 가 scripts/test/test-security-defaults.sh"
assert_not_contains "$OUT" "\`push.paths\`" "[flow-pr-only] 고치지 않은 push 를 탓한다"

fork block-item; sed -i "/^      - 'scripts\/test\/test-security-defaults.sh'\$/d" "$(wb block-item)"; run
expect block-item 1 "lang-b-ci.yml: \`pull_request.paths\`"

fork flow-push-lang; sed -i "/^  push:/s|'lang-a/\*\*', ||" "$(wa flow-push-lang)"; run
expect flow-push-lang 1 "\`push.paths\` 가 \`lang-a/**\`"

fork no-push; sed -i '/^  push:/d' "$(wa no-push)"; run
expect no-push 1 "\`push\` 트리거가 없다"

fork commented; sed -i 's|^          node scripts/check-hp-attest.mjs|          # node scripts/check-hp-attest.mjs|' "$(wb commented)"; run
expect commented 1 "lang-b: attest"

fork lang-typo; sed -i 's/--lang lang-a$/--lang lang-x/' "$(wa lang-typo)"; run
expect lang-typo 1 "파생 언어 밖의 「lang-x」"
assert_contains "$OUT" "lang-a: attest" "[lang-typo] 원래 언어의 단계가 없어졌다"

fork new-lang; printf '[package]\n' | put "$CASE/lang-c/Cargo.toml"; run
expect new-lang 1 "lang-c: attest"

# ═══ (b) 음성 — 정당한 표기 ══════════════════════════════════════════════════════════
# 통과를 기대하는 변이는 빗나가도 통과한다 — 각 변이가 착지했는지 먼저 단언한다.
fork broad-glob; sed -i "s|'scripts/check-hp-attest.mjs', 'scripts/test/test-security-defaults.sh'|'scripts/**'|g" "$(wa broad-glob)"
assert_not_contains "$(cat "$(wa broad-glob)")" "test-security-defaults" "[broad-glob] 변이가 착지하지 않았다"
run; expect broad-glob 0 "ok    lang-a"

fork no-paths; sed -i "s|^  pull_request: {.*\$|  pull_request:|" "$(wa no-paths)"
assert_eq "1" "$(grep -c '^  pull_request:$' "$(wa no-paths)")" "[no-paths] 변이가 착지하지 않았다"
run; expect no-paths 0 "ok    lang-a"

fork compact-seq; sed -i 's/^      - \(.*\)'"'"'$/    - \1'"'"'/' "$(wb compact-seq)"
assert_eq "3" "$(grep -c "^    - '" "$(wb compact-seq)")" "[compact-seq] 변이가 착지하지 않았다"
run; expect compact-seq 0 "ok    lang-b"

# ═══ (c) 공허 — 판정 불가 ══════════════════════════════════════════════════════════════
fork flow-on; sed -i '/^on:$/,/^  workflow_dispatch:$/d' "$(wa flow-on)"; sed -i '1a on: { push: { branches: [main] }, pull_request: { branches: [main] } }' "$(wa flow-on)"; run
expect flow-on 2 "플로우 매핑"

fork paths-ignore; sed -i "s|^  pull_request: {.*\$|  pull_request: { paths-ignore: ['docs/**'] }|" "$(wa paths-ignore)"; run
expect paths-ignore 2 "paths-ignore"

fork var-lang; sed -i 's/--lang lang-a$/--lang "$L"/' "$(wa var-lang)"; run
expect var-lang 2 "변수"

CASE="$TMP/no-langs"; mkdir -p "$CASE"; git -C "$CASE" init -q; lane_flow "$CASE" lang-a; run
expect no-langs 2 "파생된 언어가 0 개"

assert_report
