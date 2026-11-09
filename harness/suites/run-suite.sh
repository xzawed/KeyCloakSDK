#!/usr/bin/env bash
# harness/suites/run-suite.sh — 각 언어에 대해 suites/<lang>.sh를 실행하고
# 마지막 줄의 JSON 한 줄을 report/signals/<lang>.suite.json으로 추출한다.
#
# Usage: ./suites/run-suite.sh <lang> [<lang> ...]     (예: ./suites/run-suite.sh node go)
#
# 각 <lang>.sh는 해당 SDK 자체 단위테스트+커버리지+린트를 언어 툴체인 Docker 이미지에서
# 실행(재구현 아님)하고 마지막 줄에 JSON 신호를 출력하는 규약을 따른다(자세한 스키마는
# 가중 스코어링은 harness/README.md 와 report/score.mjs 가 소유.
#
# 기본은 단위+커버리지+린트만(무거운 통합테스트는 Docker-in-Docker 필요라 제외).
# SUITE_INTEGRATION=1 환경변수를 주면 각 <lang>.sh가 best-effort로 통합테스트도 시도한다
# (docker.sock 마운트 필요 — 로컬/CI 환경에 따라 동작이 다를 수 있음, opt-in).
#
# ⚠️ 8언어 전체 실행은 느리다(각 언어 툴체인 이미지 pull+의존성 설치+테스트) — 이 스크립트 자체는
# 무거운 전체 실행을 막지 않지만, PR 게이트에는 일부(예: node/go)만, 8언어 전체는 야간/수동(CI)에서
# 돌리는 것을 권장한다(harness/verify.sh 오케스트레이터가 8언어 기본값으로 이 스크립트를 호출).
#
# ⚠️ 실패 단서 규약(___SUITE_LOG_*) — 각 <lang>.sh 는 TESTSPASSED 를 정한 바로 다음 줄에서, 테스트가
# 깨졌으면 캡처한 출력 전체를 `___SUITE_LOG_BEGIN` · `___SUITE_LOG_END` 줄 사이에 stderr 로 낸다. 여기서
# 그것을 report/signals/<lang>.suite.raw 로 받고(야간 잡은 signals 아티팩트로 올린다), 실패한 언어의 실패
# 표지 줄을 잡 로그에 찍는다. 없으면 마지막 JSON 한 줄만 남아 어느 테스트가 깨졌는지 알 길이 없다 —
# 2026-11-06 야간(dotnet 통과 621/622)이 그렇게 끝났다. 가드: scripts/test/test-harness-suite-fail-log.sh.
set -uo pipefail
cd "$(dirname "$0")/.."   # -> harness/
mkdir -p report/signals
export MSYS_NO_PATHCONV=1

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <lang> [<lang> ...]   (go dotnet node python java php rust ruby)" >&2
  exit 2
fi

for L in "$@"; do
  echo "== [suite $L] =="
  if [ -x "suites/$L.sh" ]; then
    bash "suites/$L.sh" > "report/signals/$L.suite.raw" 2>&1 || true
  else
    echo "{\"lang\":\"$L\",\"ran\":false,\"error\":\"no suites/$L.sh\"}" > "report/signals/$L.suite.raw"
  fi
  # 각 <lang>.sh가 마지막 줄에 JSON 한 줄을 출력하도록 규약 → 추출. 규약 위반(크래시 등)이면 ran:false.
  if tail -1 "report/signals/$L.suite.raw" 2>/dev/null | grep -q '^{'; then
    tail -1 "report/signals/$L.suite.raw" > "report/signals/$L.suite.json"
  else
    echo "{\"lang\":\"$L\",\"ran\":false}" > "report/signals/$L.suite.json"
  fi
  echo "   -> report/signals/$L.suite.json : $(cat "report/signals/$L.suite.json")"
done

# 어떤 언어의 단위테스트라도 실패했거나 suite가 아예 돌지 못했으면 0이 아닌 코드로 끝낸다.
# verify.sh가 이 코드를 받아 전체 실행의 종료코드에 반영한다.
FAILED_SUITES=""
for L in "$@"; do
  RAN=$(node -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));console.log(j.ran===true&&j.testsPassed===true?"ok":"bad");}catch(e){console.log("bad");}' "report/signals/$L.suite.json")
  [ "$RAN" = "ok" ] || FAILED_SUITES="$FAILED_SUITES $L"
done
if [ -n "$FAILED_SUITES" ]; then
  # 실패 표지(아홉 러너의 실패 줄 모양 — go `--- FAIL` · dotnet `Failed` · surefire `<<< FAILURE` · gradle `FAILED` ·
  # vitest `FAIL` · phpunit `1) ` · pytest `FAILED` · rspec `rspec ./` · cargo `---- ` / `panicked`). 앞 40 줄만.
  SUITE_FAIL_RE='FAIL|Failed|failed|failures?|ERROR|Error Message|panic|^---- |^rspec \./|^ *[0-9]+\) '
  for L in $FAILED_SUITES; do
    BLOCK=$(sed -n '/^___SUITE_LOG_BEGIN$/,/^___SUITE_LOG_END$/p' "report/signals/$L.suite.raw" 2>/dev/null \
      | grep -vE '^___SUITE_LOG_(BEGIN|END)$')
    if [ -z "$BLOCK" ]; then
      echo "   !! [$L] 실패 단서 블록이 없다 — report/signals/$L.suite.raw 전체를 본다"
      continue
    fi
    HITS=$(printf '%s\n' "$BLOCK" | grep -E "$SUITE_FAIL_RE")
    echo "   !! [$L] 실패 표지 줄 $(printf '%s\n' "$HITS" | grep -c .) 개(앞 40) — 원문: report/signals/$L.suite.raw"
    printf '%s\n' "$HITS" | head -40 | sed 's/^/      /'
  done
  echo "== [suite] 실패:$FAILED_SUITES =="
  exit 1
fi
echo "== [suite] 전 언어 통과 =="
