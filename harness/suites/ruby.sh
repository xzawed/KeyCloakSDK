#!/usr/bin/env bash
# harness/suites/ruby.sh — Ruby SDK 자체 단위테스트+커버리지(SimpleCov)+린트를 ruby:3.4-alpine
# 컨테이너에서 실행한다(`bundle exec rspec`[spec_helper.rb의 SimpleCov가 line 90/branch 85 게이트]
# + `bundle exec rubocop`). 마지막 줄에 JSON 신호 1줄을 출력한다.
#
# ⚠️ 미실행 검증(untested-here) — node/go 2개 언어로 이 스위트 메커니즘을 검증했고, 이 스크립트는
# ruby/Rakefile·ruby/spec/spec_helper.rb의 실제 커맨드로 작성했으나(CLAUDE.md에는 아직 Ruby 툴체인
# 섹션이 없음 — Ruby SDK가 이 시점 작업 중이라) 실제 컨테이너 실행으로 확인하지 않았다(8언어 전체
# 실행은 CI 야간/수동 범위).
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (ruby/ 는 $ROOT/ruby)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[ruby.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/ruby:/src-ro:ro" ruby:3.4-alpine sh -c '
  cp -r /src-ro /src && cd /src
  rm -rf coverage
  find . -name "*.rb" -exec sed -i "s/\r$//" {} +
  apk add --no-cache build-base >/dev/null 2>&1
  bundle install --quiet >/tmp/install.log 2>&1
  echo "___INSTALLEXIT=$?"
  bundle exec rspec --tag ~integration 2>&1
  echo "___TESTEXIT=$?"
  # 커버리지는 콘솔 텍스트가 아니라 SimpleCov가 쓴 산출물에서 읽는다 — 콘솔 요약 문구는
  # simplecov 메이저마다 바뀌지만(0.22 "Line Coverage: 100.0% (214 / 214)" →
  # 1.0 "Line coverage: 214 / 214 (100.00%)") .last_run.json 스키마는 0.9부터 안정적이고,
  # SimpleCov 자신의 minimum_coverage 게이트가 먹는 바로 그 파일이다.
  if [ -f coverage/.last_run.json ]; then
    echo "___COV_LAST_RUN=$(tr -d "\n\r " < coverage/.last_run.json)"
  else
    echo "___COV_LAST_RUN=MISSING"
  fi
  bundle exec rubocop >/tmp/rubocop.log 2>&1
  echo "___LINTEXIT=$?"
  cat /tmp/rubocop.log
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[ruby.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

# rspec 요약: "64 examples, 0 failures"
UNIT=$(printf '%s\n' "$OUT" | grep -oE '[0-9]+ examples?' | head -1 | grep -oE '[0-9]+')
# 커버리지: SimpleCov 산출물 coverage/.last_run.json({"result":{"line":100.0,"branch":95.83}})에서
# 읽는다. ⚠️ 콘솔 문구 파싱으로 돌아가지 말 것 — simplecov 0.22→1.0 범프(dependabot 6da01c2)가
# 문구를 "Line Coverage: 100.0% (214 / 214)" → "Line coverage: 214 / 214 (100.00%)"로 바꿔
# 대소문자·순서 양쪽이 어긋났고, 정규식이 조용히 빈 값→0으로 폴백해 ruby가 커버리지 10점으로
# 오집계됐다(run 30653201172). 산출물 스키마는 그 범프를 그대로 통과한다.
COVJSON=$(printf '%s\n' "$OUT" | grep -oE '___COV_LAST_RUN=.*' | tail -1 | cut -d= -f2-)
LINE=$(printf '%s\n' "$COVJSON" | grep -oE '"line":[0-9]+(\.[0-9]+)?' | head -1 | cut -d: -f2)
BRANCH=$(printf '%s\n' "$COVJSON" | grep -oE '"branch":[0-9]+(\.[0-9]+)?' | head -1 | cut -d: -f2)
LINTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___LINTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${LINTEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # 통합테스트(RUN_INTEGRATION=1, 실제 Keycloak 필요) — Docker-in-Docker best-effort opt-in.
  IRAW=$(docker run --rm -v "$ROOT/ruby:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    ruby:3.4-alpine sh -c '
      cp -r /src-ro /src && cd /src
      apk add --no-cache build-base docker-cli >/dev/null 2>&1
      bundle install --quiet >/dev/null 2>&1
      RUN_INTEGRATION=1 bundle exec rspec --tag integration 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -oE '[0-9]+ examples?' | head -1 | grep -oE '[0-9]+')
fi

# 단위테스트 종료코드 + 의존성 설치 종료코드. 설치가 실패하면 테스트는 돌지도 않았으므로 실패다.
# 마커가 아예 없으면 실패로 간주한다 — fail-closed.
TESTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___TESTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
INSTALLEXIT=$(printf '%s\n' "$OUT" | grep -oE '___INSTALLEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${TESTEXIT:-1}" = "0" ] && [ "${INSTALLEXIT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi

# 커버리지를 못 읽었으면 0을 보고하지 말고 시끄럽게 죽는다. "실측 0%"와 "읽지 못함"이 같은 값이면
# 추출기가 깨져도 아무도 모른다(이 버그가 정확히 그랬다 — 통과하는 테스트가 잡아줄 수 없는 부류다).
# 단위테스트가 실제로 통과했을 때만 강제한다: 테스트가 깨진 실행은 커버리지 산출물이 없는 게 정상이고
# score.mjs가 이미 testsPassed=false에 커버리지 0점을 준다(score.mjs:23-27).
if [ "$TESTSPASSED" = "true" ] && { [ -z "$LINE" ] || [ -z "$BRANCH" ]; }; then
  echo "[ruby.sh] FATAL: 단위테스트는 통과했는데 커버리지를 추출하지 못했다." >&2
  echo "[ruby.sh]   marker '___COV_LAST_RUN' = '${COVJSON:-<absent>}'" >&2
  echo "[ruby.sh]   parsed line='${LINE:-<empty>}' branch='${BRANCH:-<empty>}'" >&2
  echo "[ruby.sh]   SimpleCov 산출물 포맷/경로가 바뀌었을 가능성 — 0으로 보고하지 않는다." >&2
  echo "{\"lang\":\"ruby\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":null,\"coverageBranch\":null,\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":false,\"error\":\"coverage-extraction-failed\"}"
  exit 1
fi

echo "{\"lang\":\"ruby\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
