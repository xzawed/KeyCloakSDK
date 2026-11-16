#!/usr/bin/env sh
# 통합 전용 커버리지의 레인 게이트 배선 — 언어마다 레인이 리포트(`scripts/integration-coverage.mjs report`)의 종료코드를
# **그대로** 받는가(0 만 통과). 실제 트리의 워크플로만 읽는다 — Docker · 툴체인이 필요 없다.
#
# 왜: 레인이 리포트를 `|| rc=$?` 로 받아 `[ "$rc" -le 1 ]` 로 끝내던 동안 소유 문제(exit 1 — 소유자 없는 미실행 함수 · 낡은
# 소유자)는 경고였고, main 이 DRIFT 인 채 초록이었다(등록부 integration-coverage-drift-is-warning-only — 8d3e24a7 이 들인 go
# 함수 둘이 소유자 없이 이틀 갔다). 이제 레인은 리포트를 맨 명령으로 부르고, 종료코드의 뜻과 실패 주석은 리포트가 소유한다 —
# 레인 사본이 그 표보다 좁아질 자리가 없다. 여기서는 그 배선만 고정한다:
#   (1) 언어 집합은 장부가 내보낸 값이다(`langs` — 트리와의 대조는 test-lang-universe.sh).
#   (2) 언어마다 주석 밖의 리포트 호출이 워크플로 전체에서 **한 줄**이고, 그 줄이 정확히
#       `run: node scripts/integration-coverage.mjs report <L> --out "$RUNNER_TEMP/integration-coverage"` 다 — `|| …` 를
#       붙이거나 여러 줄 `run: |` 안에 두면(종료코드를 다시 해석할 자리) 그 줄이 아니다.
#   (3) 그 스텝과 그 잡의 머리에 `if:` · `continue-on-error:` 가 없다 — 스텝을 건너뛰거나 실패를 초록으로 두는 손잡이다.
#   (4) 그 워크플로에 `shell:` 키가 없다(스텝 · 잡 `defaults` · 최상위 `defaults` · 인라인 맵 어디든) — 사용자 셸
#       `bash -c "bash {0} || true"` 가 (1)–(3) 을 지나며 종료코드를 삼켰다(Grok 레그).
#   (5) 리포트를 부르는 주석 밖 줄은 워크플로 전체에서 언어 수만큼이다 — 언어 인자를 변수로 감싼 사본도 센다.
set -eu
DIR="$(cd "$(dirname "$0")" && pwd)"
. "$DIR/assert.sh"
ROOT="$(cd "$DIR/../.." && pwd)"
WF="$ROOT/.github/workflows"

LANGS="$(node "$ROOT/scripts/integration-coverage.mjs" langs | sed -n 's/^covered //p')"
assert_ok test -n "$LANGS"

# gate_knobs <워크플로> <줄 번호> → 그 줄을 담은 스텝과 그 잡 머리의 `if:` · `continue-on-error:` 키(한 줄에 하나).
# 스텝은 들여쓰기 6 의 `- ` 로, 잡은 들여쓰기 2 의 `<id>:` 로 시작한다(레인 아홉의 모양). 그 줄 앞에 스텝 머리가 없으면
# `nostep` 을 낸다 — 모양이 달라 이 리더가 스텝을 못 찾은 것을 「손잡이 없음」으로 읽지 않는다.
gate_knobs() {
  awk -v n="$2" '
    hit && NR > n && (/^      - / || /^  [A-Za-z0-9_-]+:[[:space:]]*$/ || /^[^[:space:]#]/) { exit }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { job = ""; head = 1; step = ""; seen = 0 }
    head && /^    steps:/ { head = 0 }
    head && /^    (if|continue-on-error):/ { job = job "job " $1 "\n" }
    /^      - / { step = ""; seen = 1 }
    /^      - (if|continue-on-error):/ { step = step "step " $2 "\n" }
    /^        (if|continue-on-error):/ { step = step "step " $1 "\n" }
    NR == n { hit = 1; ok = seen }
    END { if (hit) { if (!ok) print "nostep"; printf "%s%s", job, step } }
  ' "$1"
}

n=0
for L in $LANGS; do
  n=$((n + 1))
  want="node scripts/integration-coverage.mjs report $L --out \"\$RUNNER_TEMP/integration-coverage\""
  hits="$(cd "$WF" && grep -nE "^[^#]*integration-coverage\.mjs report $L( |\$)" -- *.yml || true)"
  assert_eq 1 "$(printf '%s\n' "$hits" | grep -c .)" "[$L] 리포트를 부르는 주석 밖 워크플로 줄이 정확히 하나다 — ${hits:-없음}"
  f="${hits%%:*}"
  rest="${hits#*:}"
  at="${rest%%:*}"
  line="${rest#*:}"
  run="$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\(- \)\{0,1\}run:[[:space:]]*//p' | sed 's/[[:space:]]*$//')"
  assert_eq "$want" "$run" "[$L] $f:$at 은 리포트를 맨 \`run:\` 명령으로 부른다(종료코드를 그대로 받는다) — 줄: $line"
  [ -n "$f" ] || continue
  assert_eq '' "$(gate_knobs "$WF/$f" "$at")" "[$L] $f:$at 의 스텝과 잡 머리에 if · continue-on-error 가 없다"
  assert_eq 0 "$(grep -cE '^[^#]*(^|[^A-Za-z0-9_-])shell[[:space:]]*:' "$WF/$f" || true)" \
    "[$L] $f 에 shell: 키가 없다(사용자 셸이 종료코드를 삼킬 수 있다)"
done
assert_eq "$n" "$(cd "$WF" && grep -hcE '^[^#]*integration-coverage\.mjs report' -- *.yml | awk '{ s += $1 } END { print s + 0 }')" \
  "리포트를 부르는 주석 밖 워크플로 줄의 수 = 언어 수($n)"

assert_report
