#!/usr/bin/env bash
# harness/suites/dotnet.sh — C#/.NET SDK 자체 단위테스트+커버리지(coverlet)+포맷검사를
# mcr.microsoft.com/dotnet/sdk:8.0-alpine 컨테이너에서 실행한다(CLAUDE.md .NET 툴체인:
# `dotnet test --filter "Category!=Integration"` + coverlet.msbuild으로 라인/브랜치 커버리지를
# 수집·보고 + `dotnet format --verify-no-changes`). 마지막 줄에 JSON 신호 1줄을 출력한다. 커버리지
# 게이트(90/85)는 이 스위트가 강제하지 않고 report/score.mjs가 신호로 적용한다(java.sh와 동형 — 스위트는
# 보고, 스코어러가 게이트).
#
# ⚠️ MSBuild 쉼표 파싱 결함(defect D의 진짜 근본 원인, Alpine/Debian 무관): coverlet 리스트값 프로퍼티의
# 리터럴 쉼표(`/p:ThresholdType="line,branch"`·`/p:Exclude="[*]A,[*]B,[*]C"`)를 Linux MSBuild가
# 프로퍼티/스위치 구분자로 파싱해 `MSB1006: Property is not valid. Switch: branch`로 죽는다 →
# `dotnet test`가 테스트 실행 전 실패해 단위테스트 0개로 집계됐다(스위트 0-테스트). 쉼표를 `%2c`로
# 이스케이프해 해소(no-op였던 `/p:ThresholdType`은 제거 — `/p:Threshold` 값이 없어 게이트 미작동이었다).
# Alpine에서 62 단위테스트 통과 + 커버리지 라인 97.38%/브랜치 93.75% 실측.
#
# ⚠️ Alpine(musl) 이미지 사용: 기존 Debian `mcr.microsoft.com/dotnet/sdk:8.0`은 Docker Desktop(Windows)
# 내장 DNS가 nuget.org의 CNAME 체인을 glibc 리졸버에 실패로 돌려줘 `dotnet restore`가 NU1301로 막힌다
# (다른 8개 suite/app 이미지와 동일한 Alpine 정책 — CLAUDE.md 하네스 게차). CI Linux는 Debian도 무해하나
# 정책 일치·로컬 Windows 실행 가능화를 위해 통일.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (dotnet/ 는 $ROOT/dotnet)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[dotnet.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/dotnet:/src-ro:ro" mcr.microsoft.com/dotnet/sdk:8.0-alpine sh -c '
  cp -r /src-ro /src && cd /src
  find . -name "*.cs" -exec sed -i "s/\r$//" {} +
  dotnet test --filter "Category!=Integration" \
    /p:CollectCoverage=true \
    /p:Exclude="[*]Xzawed.Keycloak.AuthClient%2c[*]Xzawed.Keycloak.Admin.*%2c[*]Xzawed.Keycloak.KeycloakClient" \
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
# coverlet.msbuild 콘솔 요약 테이블(| Module | Line | Branch | Method |)에서 **Total 행**을 읽는다.
# ⚠️ 예전에는 `head -1`로 첫 행을 읽었다. 계측 모듈이 하나뿐인 지금은 모듈 행과 Total 행의 값이
# 같아 우연히 맞았지만, 계측 대상이 둘 이상이 되는 순간 **알파벳순 첫 모듈**의 수치를 전체 커버리지로
# 조용히 보고하게 된다 — 틀렸는데 그럴듯해 보이는 숫자다(ruby의 0과 달리 눈에 띄지 않는다).
# Total 행을 못 찾으면 0으로 폴백하지 않고 아래에서 시끄럽게 죽는다.
TOTALROW=$(printf '%s\n' "$OUT" | grep -E '^\|[[:space:]]*Total[[:space:]]*\|' | tail -1)
LINE=$(printf '%s\n' "$TOTALROW" | grep -oE '[0-9]+(\.[0-9]+)?%' | sed -n '1p' | tr -d '%')
BRANCH=$(printf '%s\n' "$TOTALROW" | grep -oE '[0-9]+(\.[0-9]+)?%' | sed -n '2p' | tr -d '%')
FMTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___FMTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${FMTEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # Testcontainers.Keycloak(실제 Keycloak, Docker-in-Docker) 필요 — best-effort opt-in.
  IRAW=$(docker run --rm -v "$ROOT/dotnet:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    mcr.microsoft.com/dotnet/sdk:8.0-alpine sh -c '
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

# ⚠️ ruby·rust와 같은 원칙: 측정 실패를 0으로 접지 않는다. 테스트가 통과했는데 Total 행을 못
# 읽었다면 coverlet 출력 형식이 바뀐 것이고, 0을 보고하면 아무도 눈치채지 못한 채 감점만 남는다.
if [ "$TESTSPASSED" = "true" ] && { [ -z "$LINE" ] || [ -z "$BRANCH" ]; }; then
  echo "[dotnet.sh] FATAL: 단위테스트는 통과했는데 커버리지 Total 행을 읽지 못했다." >&2
  echo "[dotnet.sh]   Total 행='${TOTALROW:-<absent>}' parsed line='${LINE:-<empty>}' branch='${BRANCH:-<empty>}'" >&2
  echo "[dotnet.sh]   coverlet 요약 테이블 형식이 바뀌었을 가능성 — 0으로 보고하지 않는다." >&2
  echo "{\"lang\":\"dotnet\",\"unit\":${UNIT:-0},\"integration\":0,\"coverageLine\":null,\"coverageBranch\":null,\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":false,\"error\":\"coverage-extraction-failed\"}"
  exit 1
fi
echo "{\"lang\":\"dotnet\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"testsPassed\":${TESTSPASSED},\"ran\":true}"
