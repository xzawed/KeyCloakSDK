#!/usr/bin/env bash
# harness/suites/dotnet.sh — C#/.NET SDK 자체 단위테스트+커버리지(coverlet)+포맷검사를
# mcr.microsoft.com/dotnet/sdk:8.0 컨테이너에서 실행한다(CLAUDE.md .NET 툴체인:
# `dotnet test --filter "Category!=Integration"` + coverlet.msbuild 게이트 90/85 +
# `dotnet format --verify-no-changes`). 마지막 줄에 JSON 신호 1줄을 출력한다.
#
# ⚠️ 미실행 검증(untested-here) — node/go 2개 언어로 이 스위트 메커니즘을 검증했고, 이 스크립트는
# CLAUDE.md 커맨드로 작성했으나 실제 컨테이너 실행으로 확인하지 않았다(8언어 전체 실행은 CI 야간/수동
# 범위).
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (dotnet/ 는 $ROOT/dotnet)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[dotnet.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/dotnet:/src-ro:ro" mcr.microsoft.com/dotnet/sdk:8.0 sh -c '
  cp -r /src-ro /src && cd /src
  find . -name "*.cs" -exec sed -i "s/\r$//" {} +
  dotnet test --filter "Category!=Integration" \
    /p:CollectCoverage=true /p:ThresholdType="line,branch" \
    /p:Exclude="[*]Xzawed.Keycloak.AuthClient,[*]Xzawed.Keycloak.Admin.*,[*]Xzawed.Keycloak.KeycloakClient" \
    2>&1
  echo "___TESTEXIT=$?"
  dotnet format Keycloak.Sdk.sln --verify-no-changes >/tmp/fmt.log 2>&1
  echo "___FMTEXIT=$?"
  cat /tmp/fmt.log
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[dotnet.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

# dotnet test(VSTest) 요약은 카운터를 우측 정렬로 패딩한다:
#   "Passed!  - Failed:     0, Passed:    58, Skipped:     0, Total:    58"
# 리터럴 단일 공백(`Passed: `)은 이 패딩과 매치하지 않으므로 공백류를 관용한다.
UNIT=$(printf '%s\n' "$OUT" | grep -oiE 'Passed:[[:space:]]+[0-9]+' | tail -1 | grep -oE '[0-9]+$')
# coverlet.msbuild 콘솔 요약 테이블(| Module | Line | Branch | Method |); 첫 % 값을 라인으로 근사.
LINE=$(printf '%s\n' "$OUT" | grep -E '^\| .*%' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | sed -n '1p' | tr -d '%')
BRANCH=$(printf '%s\n' "$OUT" | grep -E '^\| .*%' | head -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | sed -n '2p' | tr -d '%')
FMTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___FMTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${FMTEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # Testcontainers.Keycloak(실제 Keycloak, Docker-in-Docker) 필요 — best-effort opt-in.
  IRAW=$(docker run --rm -v "$ROOT/dotnet:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    mcr.microsoft.com/dotnet/sdk:8.0 sh -c '
      cp -r /src-ro /src && cd /src
      find . -name "*.cs" -exec sed -i "s/\r$//" {} +
      dotnet test --filter "Category=Integration" 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -oiE 'Passed:[[:space:]]+[0-9]+' | tail -1 | grep -oE '[0-9]+$')
fi

# 단위테스트 종료코드. 이 값을 버리면 테스트가 깨져도 커버리지 만점이 유지된다(PR 0, I1).
# 마커가 아예 없으면(컨테이너가 중간에 죽은 경우) 실패로 간주한다 — fail-closed.
TESTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___TESTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${TESTEXIT:-1}" = "0" ]; then TESTSPASSED=true; else TESTSPASSED=false; fi
echo "{\"lang\":\"dotnet\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
