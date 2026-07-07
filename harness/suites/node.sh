#!/usr/bin/env bash
# harness/suites/node.sh — Node/TypeScript SDK 자체 단위테스트+커버리지+린트를 node:20-alpine
# 컨테이너에서 실행한다(CLAUDE.md Node 툴체인: `npm ci && npm test`[vitest run --coverage,
# 게이트 라인90/브랜치85] + `npm run lint`[eslint]). 마지막 줄에 JSON 신호 1줄을 출력한다.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (node/ 는 $ROOT/node)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[node.sh] docker not found on PATH" >&2
  exit 1
fi

# node/ 는 읽기전용으로 마운트하고 컨테이너 로컬(/src)로 복사해서 작업한다 — npm ci가 쓰는
# node_modules를 호스트에 남기지 않고(디스크/권한 부작용 없음), 어떤 툴체인 명령도 호스트
# 소스트리를 변형하지 않는다(go.sh와 동일한 방어 패턴).
RAW=$(docker run --rm -v "$ROOT/node:/src-ro:ro" node:20-alpine sh -c '
  cp -r /src-ro /src && cd /src
  npm ci >/dev/null 2>&1
  npm test 2>&1
  echo "___TESTEXIT=$?"
  npm run lint >/tmp/lint.log 2>&1
  echo "___LINTEXIT=$?"
  cat /tmp/lint.log
' 2>&1)
DOCKER_RC=$?

# ANSI 색상 코드 제거(vitest/eslint 컬러 출력 대비 파싱 안정화)
OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[node.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

UNIT=$(printf '%s\n' "$OUT" | grep -oE 'Tests +[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
COVROW=$(printf '%s\n' "$OUT" | grep -E '^All files' | head -1)
NUMS=$(printf '%s\n' "$COVROW" | grep -oE '[0-9]+(\.[0-9]+)?')
LINE=$(printf '%s\n' "$NUMS" | sed -n '4p')     # Stmts,Branch,Funcs,Lines 순 → 4번째=Lines
BRANCH=$(printf '%s\n' "$NUMS" | sed -n '2p')   # 2번째=Branch
LINTEXIT=$(printf '%s\n' "$OUT" | grep -oE '___LINTEXIT=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${LINTEXIT:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # 통합테스트(Testcontainers)는 Docker-in-Docker 필요 — best-effort opt-in(기본 미실행).
  IRAW=$(docker run --rm -v "$ROOT/node:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    node:20-alpine sh -c "cp -r /src-ro /src && cd /src && npm ci >/dev/null 2>&1 && npm run test:it 2>&1" 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -oE 'Tests +[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
fi

echo "{\"lang\":\"node\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":${BRANCH:-0},\"lintClean\":${LINTCLEAN},\"ran\":true}"
