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
# SimpleCov 콘솔 요약(신 포맷 ~0.22 — 구 "N / M LOC (X%) covered"에서 변경됨):
#   "Line Coverage: 100.0% (212 / 212)"  /  "Branch Coverage: 93.75% (45 / 48)"
# ⚠️ 구 LOC 정규식은 이 포맷과 매치하지 않아 커버리지가 0으로 집계돼 스코어카드에서 ruby가
# 부당하게 감점됐다(실측 라인 100%/브랜치 93.75%). 신 포맷으로 라인+브랜치를 파싱한다.
LINE=$(printf '%s\n' "$OUT" | grep -oE 'Line Coverage: [0-9]+(\.[0-9]+)?%' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?')
BRANCH=$(printf '%s\n' "$OUT" | grep -oE 'Branch Coverage: [0-9]+(\.[0-9]+)?%' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?')
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
echo "{\"lang\":\"ruby\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
