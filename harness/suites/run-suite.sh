#!/usr/bin/env bash
# harness/suites/run-suite.sh — 각 언어에 대해 suites/<lang>.sh를 실행하고
# 마지막 줄의 JSON 한 줄을 report/signals/<lang>.suite.json으로 추출한다.
#
# Usage: ./suites/run-suite.sh <lang> [<lang> ...]     (예: ./suites/run-suite.sh node go)
#
# 각 <lang>.sh는 해당 SDK 자체 단위테스트+커버리지+린트를 언어 툴체인 Docker 이미지에서
# 실행(재구현 아님)하고 마지막 줄에 JSON 신호를 출력하는 규약을 따른다(자세한 스키마는
# docs/superpowers/specs/2026-07-07-cross-language-verification-scoring-harness-design.md §4 참고).
#
# 기본은 단위+커버리지+린트만(무거운 통합테스트는 Docker-in-Docker 필요라 제외).
# SUITE_INTEGRATION=1 환경변수를 주면 각 <lang>.sh가 best-effort로 통합테스트도 시도한다
# (docker.sock 마운트 필요 — 로컬/CI 환경에 따라 동작이 다를 수 있음, opt-in).
#
# ⚠️ 8언어 전체 실행은 느리다(각 언어 툴체인 이미지 pull+의존성 설치+테스트) — 이 스크립트 자체는
# 무거운 전체 실행을 막지 않지만, PR 게이트에는 일부(예: node/go)만, 8언어 전체는 야간/수동(CI)에서
# 돌리는 것을 권장한다(harness/verify.sh 오케스트레이터가 8언어 기본값으로 이 스크립트를 호출).
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
