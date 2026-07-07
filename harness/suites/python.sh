#!/usr/bin/env bash
# harness/suites/python.sh — Python SDK 자체 단위테스트+커버리지+린트를 python:3.12-alpine
# 컨테이너에서 실행한다(CLAUDE.md Python 툴체인: `pytest -m "not integration" --cov=keycloak_sdk`
# + `ruff check`). 마지막 줄에 JSON 신호 1줄을 출력한다.
#
# ⚠️ 미실행 검증(untested-here) — node/go 2개 언어로 이 스위트 메커니즘을 검증했고, 이 스크립트는
# CLAUDE.md 커맨드로 작성했으나 실제 컨테이너 실행으로 확인하지 않았다(8언어 전체 실행은 CI 야간/수동
# 범위). Alpine(musl)에는 manylinux(glibc) 휠이 없는 네이티브 확장(예: joserfc의 cryptography 백엔드)이
# 있을 수 있어 빌드툴체인(gcc/musl-dev/libffi-dev/openssl-dev/rust)을 선제 설치한다 — 실행 시 pip 빌드가
# 느리거나 실패하면 python:3.12-slim(Debian) 대체를 검토할 것.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (python/ 는 $ROOT/python)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[python.sh] docker not found on PATH" >&2
  exit 1
fi

RAW=$(docker run --rm -v "$ROOT/python:/src-ro:ro" python:3.12-alpine sh -c '
  cp -r /src-ro /src && cd /src
  apk add --no-cache build-base libffi-dev openssl-dev cargo >/dev/null 2>&1
  pip install --quiet --no-input -e ".[dev]" >/tmp/install.log 2>&1
  echo "___INSTALLEXIT=$?"
  python -m pytest -m "not integration" --cov=keycloak_sdk --cov-report=term 2>&1
  echo "___TESTEXIT=$?"
  python -m coverage json -o /tmp/cov.json >/dev/null 2>&1
  python -c "
import json
try:
    t = json.load(open(\"/tmp/cov.json\"))[\"totals\"]
    nb = t.get(\"num_branches\", 0)
    cb = t.get(\"covered_branches\", 0)
    print(\"___BRANCH=\" + (f\"{cb / nb * 100:.1f}\" if nb else \"0\"))
except Exception:
    print(\"___BRANCH=0\")
"
  python -m ruff check src tests examples >/tmp/ruff.log 2>&1
  echo "___LINTEXIT=$?"
  cat /tmp/ruff.log
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[python.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

# pytest -q 요약: "224 passed in 12.34s" (실패 섞이면 "N passed, M failed in ..."도 매치)
UNIT=$(printf '%s\n' "$OUT" | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+')
# pytest-cov term 리포트 마지막 TOTAL 행의 커버리지 % (예: "TOTAL   1234   56   93%")
LINE=$(printf '%s\n' "$OUT" | grep -E '^TOTAL' | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')
# pyproject.toml의 `branch = true`로 `coverage json`이 산출한 covered_branches/num_branches에서 계산
# (term 리포트의 TOTAL 행은 stmt+branch 결합 %만 주고 순수 branch %는 별도 제공하지 않음).
BRANCH=$(printf '%s\n' "$OUT" | grep -oE '___BRANCH=.*' | tail -1 | cut -d= -f2)
LINTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___LINTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${LINTEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # Testcontainers 통합테스트는 Docker-in-Docker 필요 — best-effort opt-in(기본 미실행).
  IRAW=$(docker run --rm -v "$ROOT/python:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    python:3.12-alpine sh -c '
      cp -r /src-ro /src && cd /src
      apk add --no-cache build-base libffi-dev openssl-dev cargo docker-cli >/dev/null 2>&1
      pip install --quiet --no-input -e ".[dev]" >/dev/null 2>&1
      python -m pytest -m integration 2>&1
    ' 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -oE '[0-9]+ passed' | tail -1 | grep -oE '[0-9]+')
fi

echo "{\"lang\":\"python\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"ran\":true}"
