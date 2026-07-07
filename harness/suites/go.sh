#!/usr/bin/env bash
# harness/suites/go.sh — Go SDK 자체 단위테스트+커버리지+린트를 golang:1.25-alpine 컨테이너에서
# 실행한다(CLAUDE.md Go 툴체인: `go test ./... -coverprofile=cover.out`[단위 40개, integration 태그
# 없이] + 네트워크 경계 파일(auth/admin*/client.go) 제외 게이트 커버리지 + `go vet ./...` +
# `gofmt -l`). 마지막 줄에 JSON 신호 1줄을 출력한다.
#
# ⚠️ 커버리지는 RAW(전체 statement %)가 아니라 GATED(네트워크 경계 파일 제외) 수치를 보고한다 —
# 다른 7개 언어는 커버리지 도구 설정 자체에 경계 제외를 굽는데(예: dotnet coverlet의 /p:Exclude,
# PHP phpunit.xml의 source exclude) Go만 raw `go test -cover`를 쓰면 ~59%로 불공정하게 낮게
# 나온다 — CLAUDE.md Go 툴체인 섹션의 게이트 계산(grep -vE 필터 후 go tool cover -func)과 동일하게
# 맞춰 실측 ~95.2%가 나오도록 한다.
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
  go test ./... -coverprofile=/tmp/cover.out -v 2>&1
  echo "___TESTEXIT=$?"
  grep -vE "/(auth|admin|admin_users|admin_clients|admin_realms|admin_roles|admin_groups|client)\.go:" /tmp/cover.out > /tmp/cover.filtered
  echo "___COVTOTAL=$(go tool cover -func=/tmp/cover.filtered | tail -1)"
' 2>&1)
DOCKER_RC=$?

OUT=$(printf '%s' "$RAW" | sed -E 's/\x1b\[[0-9;]*[a-zA-Z]//g')

if [ "$DOCKER_RC" -ne 0 ] && [ -z "$OUT" ]; then
  echo "[go.sh] docker run produced no output (rc=$DOCKER_RC)" >&2
  exit 1
fi

UNIT=$(printf '%s\n' "$OUT" | grep -c '^--- PASS:')
# 게이트(GATED) 커버리지: 네트워크 경계 파일(auth/admin*/client.go) 제외 후 `go tool cover -func`
# 총계 행("total:  (statements)  95.2%")에서 추출 — CLAUDE.md 문서화 수치(~95.2%)와 정합.
LINE=$(printf '%s\n' "$OUT" | grep -oE '___COVTOTAL=.*' | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?%' | tail -1 | tr -d '%')
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
