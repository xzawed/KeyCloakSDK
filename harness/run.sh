#!/usr/bin/env bash
# 전체 하네스 파이프라인. Usage: ./run.sh [go dotnet node python java]  (기본 go)
set -euo pipefail
cd "$(dirname "$0")"
LANGS=("${@:-go}")
# Windows Git Bash의 MSYS 경로변환이 -v 컨테이너 경로를 망가뜨리는 것 방지(Linux CI엔 무해).
export MSYS_NO_PATHCONV=1

# 모든 앱은 컨테이너 내부 8090 사용(계약 단순화). 함수는 첫 사용 전에 정의.
app_port() { echo 8090; }

cleanup() { docker compose --profile apps down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== Keycloak 기동 =="
docker compose up -d keycloak
timeout 240 bash -c 'until [ "$(docker inspect -f "{{.State.Health.Status}}" "$(docker compose ps -q keycloak)")" = healthy ]; do sleep 3; done'

# ⚠️ **compose 네트워크 이름을 박지 말 것 — `verify.sh` 가 이미 배운 것이다.**
# 예전엔 `NET=harness_default` 를 위에 박아 뒀다. 그 이름은 **디렉터리 이름에서 오는 기본값**이라,
# `COMPOSE_PROJECT_NAME` 을 바꾸거나 이 디렉터리를 리네임하면 가정이 깨지고 k6 컨테이너가
# keycloak 을 DNS 로 못 찾아 **조용히 전부 실패**한다(`verify.sh:14-22` 가 그 실패 모드를 적고 있다).
# keycloak 이 기동된 **뒤** 실제 네트워크를 조회하고, 실패할 때만 기본값으로 폴백한다.
# ⚠️ 두 스크립트가 다시 갈리지 않게 `scripts/test/test-harness-network.sh` 가 대조한다.
NET="$(docker compose ps --format '{{.Networks}}' keycloak 2>/dev/null | head -1)"
[ -z "$NET" ] && NET=harness_default

# k6 컨테이너(비-root uid 12345)가 호스트 마운트 report/에 handleSummary JSON을 쓸 수 있도록(Linux CI 권한). Windows엔 무해.
mkdir -p report report/signals && chmod -R 777 report 2>/dev/null || true

# ⚠️ **실패의 원인을 남긴다 — `verify.sh` 가 이미 배운 것이다.** 앱을 `stop` 하고 EXIT 트랩이
# `down -v` 로 지우면 컨테이너 로그가 사라져, 「무엇이 실패했다」만 남고 **왜**가 사라진다
# (실측 2026-09-16: 야간이 여드레 빨갰는데 앱 예외 문장이 어디에도 없었다).
# ⚠️ 두 스크립트가 다시 갈리지 않게 `scripts/test/test-harness-failure-evidence.sh` 가 대조한다.
capture_app_log() { # $1=lang
  if docker compose logs --no-color --tail 300 "app-$1" > "report/signals/$1.app.log" 2>&1; then
    [ -s "report/signals/$1.app.log" ] || printf '(빈 로그 — app-%s 가 stdout/stderr 에 아무것도 쓰지 않았다)\n' "$1" > "report/signals/$1.app.log"
  else
    # ⚠️ `2>&1` 이라 실패하면 파일에 든 것은 앱 출력이 아니라 CLI 오류다 — 무엇인지 적는다.
    _cli="$(cat "report/signals/$1.app.log" 2>/dev/null || true)"
    printf '(docker compose logs 실패 — 아래는 앱 출력이 아니라 CLI 오류다)\n%s\n' "$_cli" > "report/signals/$1.app.log"
  fi
}
capture_compose_ps() { # $1=lang
  docker compose ps -a > "report/signals/$1.compose-ps.txt" 2>&1 || true
}

rc=0
for SDK_LANG in "${LANGS[@]}"; do
  echo "== [$SDK_LANG] 앱 빌드·기동 =="
  docker compose --profile apps up -d --build "app-$SDK_LANG" || { capture_compose_ps "$SDK_LANG"; capture_app_log "$SDK_LANG"; rc=1; continue; }
  PORT=$(docker compose port "app-$SDK_LANG" "$(app_port "$SDK_LANG")" 2>/dev/null | sed 's/.*://')
  timeout 90 bash -c "until curl -fsS http://localhost:$PORT/healthz >/dev/null 2>&1; do sleep 2; done" || { capture_app_log "$SDK_LANG"; capture_compose_ps "$SDK_LANG"; rc=1; docker compose --profile apps stop "app-$SDK_LANG" >/dev/null 2>&1 || true; continue; }
  echo "== [$SDK_LANG] k6 실행 =="
  docker run --rm --network "$NET" -v "$PWD/driver:/scripts" -v "$PWD/report:/report" \
    -e "BASE_URL=http://app-$SDK_LANG:$(app_port "$SDK_LANG")" -e KC_URL=http://keycloak:8080 -e "LANG=$SDK_LANG" \
    grafana/k6 run /scripts/scenarios.js || rc=1
  # ⚠️ stop 앞에서 남긴다 — EXIT 트랩의 `down -v` 뒤에는 읽을 컨테이너가 없다.
  capture_app_log "$SDK_LANG"
  docker compose --profile apps stop "app-$SDK_LANG" >/dev/null
done

echo "== 리포트 취합 =="
node report/aggregate.mjs "${LANGS[@]}" || rc=1
echo "== 완료 (rc=$rc) — report/RESULTS.md =="
exit $rc
