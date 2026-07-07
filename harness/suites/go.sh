#!/usr/bin/env bash
# harness/suites/go.sh — Go SDK 자체 단위테스트+커버리지+린트를 golang:1.25-alpine 컨테이너에서
# 실행한다(CLAUDE.md Go 툴체인: `go test ./... -cover`[단위 40개, integration 태그 없이] +
# `go vet ./...` + `gofmt -l`). 마지막 줄에 JSON 신호 1줄을 출력한다.
set -uo pipefail
cd "$(dirname "$0")/.."          # -> harness/
ROOT="$(cd .. && pwd)"           # 리포 루트 (go/ 는 $ROOT/go)
export MSYS_NO_PATHCONV=1

if ! command -v docker >/dev/null 2>&1; then
  echo "[go.sh] docker not found on PATH" >&2
  exit 1
fi

# go/ 는 읽기전용으로 마운트하고 컨테이너 로컬(/src)로 복사해서 작업한다:
#  (1) 호스트 소스트리를 어떤 툴체인 명령도 변형하지 않음(부작용 없는 실행)
#  (2) 이 리포는 Windows에서 core.autocrlf=true로 체크아웃되어 .go가 CRLF다 — Linux gofmt는
#      (Windows-native gofmt와 달리) CRLF를 원복하지 않아 매 파일을 오탐 플래그한다(실측 확인됨,
#      diff가 CRLF뿐 실제 포맷 차이 없음). 컨테이너 로컬 복사본에서만 LF로 정규화해 오탐을 제거한다.
RAW=$(docker run --rm -v "$ROOT/go:/src-ro:ro" -e GOFLAGS=-mod=mod golang:1.25-alpine sh -c '
  set -e
  cp -r /src-ro /src && cd /src
  find . -name "*.go" -exec sed -i "s/\r$//" {} +
  set +e
  go vet ./... >/tmp/vet.log 2>&1
  echo "___VETEXIT=$?"
  cat /tmp/vet.log
  gofmt -l . >/tmp/fmt.log 2>&1
  echo "___FMTLINES=$(wc -l < /tmp/fmt.log)"
  cat /tmp/fmt.log
  go test ./... -cover -v 2>&1
  echo "___TESTEXIT=$?"
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[go.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

UNIT=$(printf '%s\n' "$OUT" | grep -c '^--- PASS:')
LINE=$(printf '%s\n' "$OUT" | grep -oE 'coverage: [0-9]+(\.[0-9]+)?% of statements' | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
VETEXIT=$(printf '%s\n' "$OUT" | grep -oE '___VETEXIT=[0-9]+' | tail -1 | cut -d= -f2)
FMTLINES=$(printf '%s\n' "$OUT" | grep -oE '___FMTLINES=[0-9]+' | tail -1 | cut -d= -f2)
if [ "${VETEXIT:-1}" = "0" ] && [ "${FMTLINES:-1}" = "0" ]; then LINTCLEAN=true; else LINTCLEAN=false; fi

INTEGRATION=0
if [ "${SUITE_INTEGRATION:-0}" = "1" ]; then
  # E2E 통합테스트는 실제 Keycloak(Testcontainers, Docker-in-Docker) 필요 — best-effort opt-in.
  IRAW=$(docker run --rm -v "$ROOT/go:/src-ro:ro" -v /var/run/docker.sock:/var/run/docker.sock \
    -e GOFLAGS=-mod=mod golang:1.25-alpine sh -c "cp -r /src-ro /src && cd /src && find . -name '*.go' -exec sed -i 's/\r\$//' {} + && go test -tags=integration -run TestE2E -count=1 -v ./... 2>&1" 2>&1 || true)
  IOUT=$(printf '%s' "$IRAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')
  INTEGRATION=$(printf '%s\n' "$IOUT" | grep -c '^--- PASS:')
fi

echo "{\"lang\":\"go\",\"unit\":${UNIT:-0},\"integration\":${INTEGRATION:-0},\"coverageLine\":${LINE:-0},\"coverageBranch\":0,\"lintClean\":${LINTCLEAN},\"ran\":true}"
